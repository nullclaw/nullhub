const std = @import("std");
const paths_mod = @import("../core/paths.zig");

// ─── Response types ──────────────────────────────────────────────────────────

pub const ApiResponse = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

// ─── JSON helpers ────────────────────────────────────────────────────────────

fn appendEscaped(buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => try buf.append(c),
        }
    }
}

// ─── Query parameter parsing ─────────────────────────────────────────────────

/// Extract the `lines` query parameter from a target URL.
/// Returns 100 as default if not specified.
pub fn parseLines(target: []const u8) usize {
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return 100;
    const query = target[qmark + 1 ..];

    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (std.mem.startsWith(u8, param, "lines=")) {
            const val = param["lines=".len..];
            return std.fmt.parseInt(usize, val, 10) catch 100;
        }
    }
    return 100;
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

/// GET /api/instances/{c}/{n}/logs?lines=N — read last N lines from stdout.log.
pub fn handleGet(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8, name: []const u8, max_lines: usize) ApiResponse {
    const logs_dir = p.instanceLogs(allocator, component, name) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(logs_dir);

    const log_path = std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" }) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(log_path);

    const file = std.fs.openFileAbsolute(log_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Return empty lines array when log file doesn't exist.
            return .{
                .status = "200 OK",
                .content_type = "application/json",
                .body = "{\"lines\":[]}",
            };
        },
        else => return .{
            .status = "500 Internal Server Error",
            .content_type = "application/json",
            .body = "{\"error\":\"internal error\"}",
        },
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 16 * 1024 * 1024) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(contents);

    // Split into lines and take last N.
    var buf = std.ArrayList(u8).init(allocator);
    buildLinesJson(&buf, contents, max_lines) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    return .{ .status = "200 OK", .content_type = "application/json", .body = buf.items };
}

fn buildLinesJson(buf: *std.ArrayList(u8), contents: []const u8, max_lines: usize) !void {
    // Collect all lines.
    var all_lines = std.ArrayList([]const u8).init(buf.allocator);
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

/// GET /api/instances/{c}/{n}/logs/stream — SSE endpoint placeholder.
pub fn handleStream() ApiResponse {
    return .{
        .status = "200 OK",
        .content_type = "text/event-stream",
        .body = "event: connected\ndata: {}\n\n",
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

test "handleGet returns empty lines when no log file" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-logs-api-empty";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const resp = handleGet(allocator, p, "nullclaw", "my-agent", 100);
    try std.testing.expectEqualStrings("200 OK", resp.status);
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

    const resp = handleGet(allocator, p, "nullclaw", "my-agent", 100);
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

    const resp = handleGet(allocator, p, "nullclaw", "my-agent", 2);
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

test "handleStream returns SSE placeholder" {
    const resp = handleStream();
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("text/event-stream", resp.content_type);
    try std.testing.expectEqualStrings("event: connected\ndata: {}\n\n", resp.body);
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
