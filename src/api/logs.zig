const std = @import("std");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");

const ApiResponse = helpers.ApiResponse;
const appendEscaped = helpers.appendEscaped;

const SUPERVISOR_PREFIX = "[nullhub/supervisor]";
const MAX_LOG_BYTES = 16 * 1024 * 1024;

pub const LogSource = enum {
    instance,
    nullhub,
};

// ─── Query parameter parsing ─────────────────────────────────────────────────

/// Extract the `lines` query parameter from a target URL.
/// Returns 100 as default if not specified.
pub fn parseLines(target: []const u8) usize {
    const val = queryValue(target, "lines") orelse return 100;
    return std.fmt.parseInt(usize, val, 10) catch 100;
}

pub fn parseSource(target: []const u8) LogSource {
    const val = queryValue(target, "source") orelse return .instance;
    if (std.mem.eql(u8, val, "nullhub") or std.mem.eql(u8, val, "supervisor")) {
        return .nullhub;
    }
    return .instance;
}

fn queryValue(target: []const u8, key: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qmark + 1 ..];

    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (std.mem.indexOfScalar(u8, param, '=')) |eq| {
            if (std.mem.eql(u8, param[0..eq], key)) return param[eq + 1 ..];
            continue;
        }
        if (std.mem.eql(u8, param, key)) return "";
    }
    return null;
}

/// Strip query string from target to get the path portion.
pub fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |qmark| {
        return target[0..qmark];
    }
    return target;
}

// ─── Path parsing ────────────────────────────────────────────────────────────

pub const ParsedLogsPath = struct {
    component: []const u8,
    name: []const u8,
    is_stream: bool,
};

/// Parse /api/instances/{c}/{n}/logs or /api/instances/{c}/{n}/logs/stream.
pub fn parseLogsPath(target: []const u8) ?ParsedLogsPath {
    const clean = stripQuery(target);
    const prefix = "/api/instances/";

    if (!std.mem.startsWith(u8, clean, prefix)) return null;

    const rest = clean[prefix.len..];
    if (rest.len == 0) return null;

    var it = std.mem.splitScalar(u8, rest, '/');
    const component = it.next() orelse return null;
    if (component.len == 0) return null;

    const name = it.next() orelse return null;
    if (name.len == 0) return null;

    const logs_segment = it.next() orelse return null;
    if (!std.mem.eql(u8, logs_segment, "logs")) return null;

    const next_segment = it.next();
    if (next_segment) |seg| {
        if (!std.mem.eql(u8, seg, "stream")) return null;
        // No more segments allowed.
        if (it.next() != null) return null;
        return .{ .component = component, .name = name, .is_stream = true };
    }

    return .{ .component = component, .name = name, .is_stream = false };
}

/// Check if a target path matches the logs pattern.
pub fn isLogsPath(target: []const u8) bool {
    return parseLogsPath(target) != null;
}

// ─── Handlers ────────────────────────────────────────────────────────────────

fn readTailLinesJson(
    allocator: std.mem.Allocator,
    p: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    max_lines: usize,
    source: LogSource,
) ![]u8 {
    const contents = try readSourceContents(allocator, p, component, name, source);
    defer allocator.free(contents);

    // Split into lines and take last N.
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buildLinesJson(&buf, contents, max_lines);
    return buf.items;
}

fn readSourceContents(
    allocator: std.mem.Allocator,
    p: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    source: LogSource,
) ![]u8 {
    const logs_dir = p.instanceLogs(allocator, component, name) catch return error.PathBuildFailed;
    defer allocator.free(logs_dir);

    const stdout_log_path = std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" }) catch return error.PathBuildFailed;
    defer allocator.free(stdout_log_path);
    const stdout_contents = try readFileOrEmpty(allocator, stdout_log_path);
    defer allocator.free(stdout_contents);

    return switch (source) {
        .instance => filterLegacyStdout(allocator, stdout_contents, .instance),
        .nullhub => blk: {
            const legacy_nullhub = try filterLegacyStdout(allocator, stdout_contents, .nullhub);
            defer allocator.free(legacy_nullhub);

            const nullhub_log_path = std.fs.path.join(allocator, &.{ logs_dir, "nullhub.log" }) catch return error.PathBuildFailed;
            defer allocator.free(nullhub_log_path);
            const nullhub_contents = try readFileOrEmpty(allocator, nullhub_log_path);
            defer allocator.free(nullhub_contents);

            break :blk joinContents(allocator, &.{ legacy_nullhub, nullhub_contents });
        },
    };
}

fn readFileOrEmpty(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, ""),
        else => return err,
    };
    defer file.close();
    return file.readToEndAlloc(allocator, MAX_LOG_BYTES);
}

fn filterLegacyStdout(allocator: std.mem.Allocator, contents: []const u8, source: LogSource) ![]u8 {
    var filtered = std.array_list.Managed(u8).init(allocator);
    errdefer filtered.deinit();

    var wrote_any = false;
    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |line| {
        const is_supervisor_line = std.mem.startsWith(u8, line, SUPERVISOR_PREFIX);
        const keep = switch (source) {
            .instance => !is_supervisor_line,
            .nullhub => is_supervisor_line,
        };
        if (!keep) continue;

        if (wrote_any) try filtered.append('\n');
        try filtered.appendSlice(line);
        wrote_any = true;
    }

    if (wrote_any and contents.len > 0 and contents[contents.len - 1] == '\n') {
        try filtered.append('\n');
    }

    if (filtered.items.len == 0) return allocator.dupe(u8, "");
    return filtered.toOwnedSlice();
}

fn joinContents(allocator: std.mem.Allocator, parts: []const []const u8) ![]u8 {
    var joined = std.array_list.Managed(u8).init(allocator);
    errdefer joined.deinit();

    var wrote_any = false;
    for (parts) |part| {
        if (part.len == 0) continue;
        if (wrote_any and joined.items.len > 0 and joined.items[joined.items.len - 1] != '\n') {
            try joined.append('\n');
        }
        try joined.appendSlice(part);
        wrote_any = true;
    }

    if (joined.items.len == 0) return allocator.dupe(u8, "");
    return joined.toOwnedSlice();
}

fn writeFileBestEffort(path: []const u8, contents: []const u8) void {
    if (std.fs.createFileAbsolute(path, .{ .truncate = true })) |file| {
        defer file.close();
        file.writeAll(contents) catch {};
    } else |_| {}
}

/// GET /api/instances/{c}/{n}/logs?lines=N&source=instance|nullhub — read last N lines from the selected log source.
pub fn handleGet(
    allocator: std.mem.Allocator,
    p: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    max_lines: usize,
    source: LogSource,
) ApiResponse {
    const body = readTailLinesJson(allocator, p, component, name, max_lines, source) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    return .{ .status = "200 OK", .content_type = "application/json", .body = body };
}

fn buildLinesJson(buf: *std.array_list.Managed(u8), contents: []const u8, max_lines: usize) !void {
    // Collect all lines.
    var all_lines = std.array_list.Managed([]const u8).init(buf.allocator);
    defer all_lines.deinit();

    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |line| {
        try all_lines.append(line);
    }

    // Remove trailing empty line from final newline.
    if (all_lines.items.len > 0 and all_lines.items[all_lines.items.len - 1].len == 0) {
        _ = all_lines.pop();
    }

    // Take last N lines.
    const total = all_lines.items.len;
    const start = if (total > max_lines) total - max_lines else 0;
    const lines = all_lines.items[start..];

    try buf.appendSlice("{\"lines\":[");
    for (lines, 0..) |line, i| {
        if (i > 0) try buf.append(',');
        try buf.append('"');
        try appendEscaped(buf, line);
        try buf.append('"');
    }
    try buf.appendSlice("]}");
}

/// DELETE /api/instances/{c}/{n}/logs?source=instance|nullhub — clear the selected log source.
pub fn handleDelete(
    allocator: std.mem.Allocator,
    p: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    source: LogSource,
) ApiResponse {
    const logs_dir = p.instanceLogs(allocator, component, name) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(logs_dir);

    const stdout_log_path = std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" }) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(stdout_log_path);

    const stdout_contents = readFileOrEmpty(allocator, stdout_log_path) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(stdout_contents);

    switch (source) {
        .instance => {
            const preserved_nullhub = filterLegacyStdout(allocator, stdout_contents, .nullhub) catch return .{
                .status = "500 Internal Server Error",
                .content_type = "application/json",
                .body = "{\"error\":\"internal error\"}",
            };
            defer allocator.free(preserved_nullhub);
            writeFileBestEffort(stdout_log_path, preserved_nullhub);
        },
        .nullhub => {
            const preserved_instance = filterLegacyStdout(allocator, stdout_contents, .instance) catch return .{
                .status = "500 Internal Server Error",
                .content_type = "application/json",
                .body = "{\"error\":\"internal error\"}",
            };
            defer allocator.free(preserved_instance);
            writeFileBestEffort(stdout_log_path, preserved_instance);

            const nullhub_log_path = std.fs.path.join(allocator, &.{ logs_dir, "nullhub.log" }) catch return .{
                .status = "500 Internal Server Error",
                .content_type = "application/json",
                .body = "{\"error\":\"internal error\"}",
            };
            defer allocator.free(nullhub_log_path);
            writeFileBestEffort(nullhub_log_path, "");
        },
    }

    return .{
        .status = "200 OK",
        .content_type = "application/json",
        .body = "{\"status\":\"cleared\"}",
    };
}

/// GET /api/instances/{c}/{n}/logs/stream — snapshot SSE response with current tail.
pub fn handleStream(
    allocator: std.mem.Allocator,
    p: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    max_lines: usize,
    source: LogSource,
) ApiResponse {
    const lines_json = readTailLinesJson(allocator, p, component, name, max_lines, source) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "text/event-stream",
        .body = "event: error\ndata: {\"error\":\"log_read_failed\"}\n\n",
    };
    defer allocator.free(lines_json);

    var body = std.array_list.Managed(u8).init(allocator);
    body.appendSlice("retry: 3000\n") catch return .{
        .status = "500 Internal Server Error",
        .content_type = "text/event-stream",
        .body = "event: error\ndata: {\"error\":\"stream_build_failed\"}\n\n",
    };
    body.appendSlice("event: connected\ndata: {}\n\n") catch return .{
        .status = "500 Internal Server Error",
        .content_type = "text/event-stream",
        .body = "event: error\ndata: {\"error\":\"stream_build_failed\"}\n\n",
    };
    body.appendSlice("event: snapshot\ndata: ") catch return .{
        .status = "500 Internal Server Error",
        .content_type = "text/event-stream",
        .body = "event: error\ndata: {\"error\":\"stream_build_failed\"}\n\n",
    };
    body.appendSlice(lines_json) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "text/event-stream",
        .body = "event: error\ndata: {\"error\":\"stream_build_failed\"}\n\n",
    };
    body.appendSlice("\n\nevent: end\ndata: {}\n\n") catch return .{
        .status = "500 Internal Server Error",
        .content_type = "text/event-stream",
        .body = "event: error\ndata: {\"error\":\"stream_build_failed\"}\n\n",
    };

    return .{
        .status = "200 OK",
        .content_type = "text/event-stream",
        .body = body.items,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "parseLogsPath: valid logs path" {
    const p = parseLogsPath("/api/instances/nullclaw/my-agent/logs").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
    try std.testing.expect(!p.is_stream);
}

test "parseLogsPath: valid stream path" {
    const p = parseLogsPath("/api/instances/nullclaw/my-agent/logs/stream").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
    try std.testing.expect(p.is_stream);
}

test "parseLogsPath: with query string" {
    const p = parseLogsPath("/api/instances/nullclaw/my-agent/logs?lines=50").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
    try std.testing.expect(!p.is_stream);
}

test "parseLogsPath: rejects non-logs path" {
    try std.testing.expect(parseLogsPath("/api/instances/nullclaw/my-agent/config") == null);
}

test "parseLogsPath: rejects too many segments" {
    try std.testing.expect(parseLogsPath("/api/instances/nullclaw/my-agent/logs/stream/extra") == null);
}

test "parseLines: extracts line count" {
    try std.testing.expectEqual(@as(usize, 50), parseLines("/api/instances/x/y/logs?lines=50"));
}

test "parseLines: default to 100" {
    try std.testing.expectEqual(@as(usize, 100), parseLines("/api/instances/x/y/logs"));
}

test "parseLines: invalid value defaults to 100" {
    try std.testing.expectEqual(@as(usize, 100), parseLines("/api/instances/x/y/logs?lines=abc"));
}

test "parseSource defaults to instance" {
    try std.testing.expectEqual(LogSource.instance, parseSource("/api/instances/x/y/logs"));
}

test "parseSource reads nullhub source" {
    try std.testing.expectEqual(LogSource.nullhub, parseSource("/api/instances/x/y/logs?source=nullhub"));
    try std.testing.expectEqual(LogSource.nullhub, parseSource("/api/instances/x/y/logs?source=supervisor"));
}

test "handleGet returns empty lines when no log file" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-logs-api-empty";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const resp = handleGet(allocator, p, "nullclaw", "my-agent", 100, .instance);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("{\"lines\":[]}", resp.body);
}

test "handleGet reads actual log content" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-logs-api-read";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    // Create the logs directory and write a log file.
    const logs_dir = try p.instanceLogs(allocator, "nullclaw", "my-agent");
    defer allocator.free(logs_dir);

    // Create directories recursively.
    makeDirRecursive(logs_dir) catch unreachable;

    const log_path = try std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" });
    defer allocator.free(log_path);

    {
        const file = try std.fs.createFileAbsolute(log_path, .{});
        defer file.close();
        try file.writeAll("line1\nline2\nline3\n");
    }

    const resp = handleGet(allocator, p, "nullclaw", "my-agent", 100, .instance);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);

    // Parse and verify.
    const parsed = try std.json.parseFromSlice(
        struct { lines: [][]const u8 },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 3), parsed.value.lines.len);
    try std.testing.expectEqualStrings("line1", parsed.value.lines[0]);
    try std.testing.expectEqualStrings("line2", parsed.value.lines[1]);
    try std.testing.expectEqualStrings("line3", parsed.value.lines[2]);
}

test "handleGet tails last N lines" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-logs-api-tail";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const logs_dir = try p.instanceLogs(allocator, "nullclaw", "my-agent");
    defer allocator.free(logs_dir);
    makeDirRecursive(logs_dir) catch unreachable;

    const log_path = try std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" });
    defer allocator.free(log_path);

    {
        const file = try std.fs.createFileAbsolute(log_path, .{});
        defer file.close();
        try file.writeAll("a\nb\nc\nd\ne\n");
    }

    const resp = handleGet(allocator, p, "nullclaw", "my-agent", 2, .instance);
    defer allocator.free(resp.body);

    const parsed = try std.json.parseFromSlice(
        struct { lines: [][]const u8 },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.lines.len);
    try std.testing.expectEqualStrings("d", parsed.value.lines[0]);
    try std.testing.expectEqualStrings("e", parsed.value.lines[1]);
}

test "handleStream returns SSE snapshot" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-logs-api-stream";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const logs_dir = try p.instanceLogs(allocator, "nullclaw", "my-agent");
    defer allocator.free(logs_dir);
    makeDirRecursive(logs_dir) catch unreachable;

    const log_path = try std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" });
    defer allocator.free(log_path);

    {
        const file = try std.fs.createFileAbsolute(log_path, .{});
        defer file.close();
        try file.writeAll("line-a\nline-b\n");
    }

    const resp = handleStream(allocator, p, "nullclaw", "my-agent", 50, .instance);
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("text/event-stream", resp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "event: connected") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "event: snapshot") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"line-a\"") != null);
}

test "handleGet separates legacy stdout and nullhub logs by source" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-logs-api-sources";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const logs_dir = try p.instanceLogs(allocator, "nullclaw", "my-agent");
    defer allocator.free(logs_dir);
    makeDirRecursive(logs_dir) catch unreachable;

    const stdout_log_path = try std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" });
    defer allocator.free(stdout_log_path);
    const nullhub_log_path = try std.fs.path.join(allocator, &.{ logs_dir, "nullhub.log" });
    defer allocator.free(nullhub_log_path);

    {
        const file = try std.fs.createFileAbsolute(stdout_log_path, .{});
        defer file.close();
        try file.writeAll("app line 1\n[nullhub/supervisor][1] old diag\napp line 2\n");
    }
    {
        const file = try std.fs.createFileAbsolute(nullhub_log_path, .{});
        defer file.close();
        try file.writeAll("[nullhub/supervisor][2] new diag\n");
    }

    const instance_resp = handleGet(allocator, p, "nullclaw", "my-agent", 100, .instance);
    defer allocator.free(instance_resp.body);
    const instance_parsed = try std.json.parseFromSlice(
        struct { lines: [][]const u8 },
        allocator,
        instance_resp.body,
        .{ .allocate = .alloc_always },
    );
    defer instance_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), instance_parsed.value.lines.len);
    try std.testing.expectEqualStrings("app line 1", instance_parsed.value.lines[0]);
    try std.testing.expectEqualStrings("app line 2", instance_parsed.value.lines[1]);

    const nullhub_resp = handleGet(allocator, p, "nullclaw", "my-agent", 100, .nullhub);
    defer allocator.free(nullhub_resp.body);
    const nullhub_parsed = try std.json.parseFromSlice(
        struct { lines: [][]const u8 },
        allocator,
        nullhub_resp.body,
        .{ .allocate = .alloc_always },
    );
    defer nullhub_parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), nullhub_parsed.value.lines.len);
    try std.testing.expectEqualStrings("[nullhub/supervisor][1] old diag", nullhub_parsed.value.lines[0]);
    try std.testing.expectEqualStrings("[nullhub/supervisor][2] new diag", nullhub_parsed.value.lines[1]);
}

test "handleDelete clears selected source while preserving the other" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-logs-api-clear-source";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const logs_dir = try p.instanceLogs(allocator, "nullclaw", "my-agent");
    defer allocator.free(logs_dir);
    makeDirRecursive(logs_dir) catch unreachable;

    const stdout_log_path = try std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" });
    defer allocator.free(stdout_log_path);
    const nullhub_log_path = try std.fs.path.join(allocator, &.{ logs_dir, "nullhub.log" });
    defer allocator.free(nullhub_log_path);

    {
        const file = try std.fs.createFileAbsolute(stdout_log_path, .{});
        defer file.close();
        try file.writeAll("app line\n[nullhub/supervisor][1] legacy diag\n");
    }
    {
        const file = try std.fs.createFileAbsolute(nullhub_log_path, .{});
        defer file.close();
        try file.writeAll("[nullhub/supervisor][2] dedicated diag\n");
    }

    const clear_nullhub = handleDelete(allocator, p, "nullclaw", "my-agent", .nullhub);
    try std.testing.expectEqualStrings("200 OK", clear_nullhub.status);

    {
        const file = try std.fs.openFileAbsolute(stdout_log_path, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(contents);
        try std.testing.expectEqualStrings("app line\n", contents);
    }
    {
        const file = try std.fs.openFileAbsolute(nullhub_log_path, .{});
        defer file.close();
        const contents = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(contents);
        try std.testing.expectEqualStrings("", contents);
    }
}

test "isLogsPath detects logs paths" {
    try std.testing.expect(isLogsPath("/api/instances/nullclaw/my-agent/logs"));
    try std.testing.expect(isLogsPath("/api/instances/nullclaw/my-agent/logs/stream"));
    try std.testing.expect(isLogsPath("/api/instances/nullclaw/my-agent/logs?lines=50"));
    try std.testing.expect(!isLogsPath("/api/instances/nullclaw/my-agent/config"));
    try std.testing.expect(!isLogsPath("/api/instances/nullclaw/my-agent"));
}

fn makeDirRecursive(path: []const u8) !void {
    var i: usize = 1;
    while (i < path.len) {
        if (path[i] == '/') {
            std.fs.makeDirAbsolute(path[0..i]) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
        i += 1;
    }
    std.fs.makeDirAbsolute(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}
