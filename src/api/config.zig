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

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/instances/{c}/{n}/config — read instance config file.
pub fn handleGet(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    const config_path = p.instanceConfig(allocator, component, name) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{
            .status = "404 Not Found",
            .content_type = "application/json",
            .body = "{\"error\":\"config not found\"}",
        },
        else => return .{
            .status = "500 Internal Server Error",
            .content_type = "application/json",
            .body = "{\"error\":\"internal error\"}",
        },
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    return .{ .status = "200 OK", .content_type = "application/json", .body = contents };
}

/// PUT /api/instances/{c}/{n}/config — replace config file with request body.
pub fn handlePut(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8, name: []const u8, body: []const u8) ApiResponse {
    return writeConfig(allocator, p, component, name, body);
}

/// PATCH /api/instances/{c}/{n}/config — for now, same as PUT.
pub fn handlePatch(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8, name: []const u8, body: []const u8) ApiResponse {
    return writeConfig(allocator, p, component, name, body);
}

fn writeConfig(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8, name: []const u8, body: []const u8) ApiResponse {
    const config_path = p.instanceConfig(allocator, component, name) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(config_path);

    // Ensure the parent directory exists.
    const dir_path = p.instanceDir(allocator, component, name) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(dir_path);

    std.fs.makeDirAbsolute(dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => {
            // Try creating parent directories.
            const inst_base = p.instanceDir(allocator, component, "") catch return .{
                .status = "500 Internal Server Error",
                .content_type = "application/json",
                .body = "{\"error\":\"internal error\"}",
            };
            defer allocator.free(inst_base);
            // Use makePath for nested creation.
            makeDirRecursive(dir_path) catch return .{
                .status = "500 Internal Server Error",
                .content_type = "application/json",
                .body = "{\"error\":\"cannot create instance directory\"}",
            };
        },
    };

    const file = std.fs.createFileAbsolute(config_path, .{}) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"cannot write config\"}",
    };
    defer file.close();

    file.writeAll(body) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"cannot write config\"}",
    };

    return .{ .status = "200 OK", .content_type = "application/json", .body = "{\"status\":\"saved\"}" };
}

fn makeDirRecursive(path: []const u8) !void {
    // Walk from root to leaf, creating each segment.
    var i: usize = 1; // skip leading /
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

/// Parse a config-related sub-path from a parsed instance path.
/// Returns true if the path ends with "/config".
pub fn isConfigPath(target: []const u8) bool {
    return std.mem.endsWith(u8, target, "/config");
}

/// Extract component and name from /api/instances/{c}/{n}/config.
pub const ParsedConfigPath = struct {
    component: []const u8,
    name: []const u8,
};

pub fn parseConfigPath(target: []const u8) ?ParsedConfigPath {
    const prefix = "/api/instances/";
    const suffix = "/config";

    if (!std.mem.startsWith(u8, target, prefix)) return null;
    if (!std.mem.endsWith(u8, target, suffix)) return null;

    const rest = target[prefix.len .. target.len - suffix.len];
    if (rest.len == 0) return null;

    const sep = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const component = rest[0..sep];
    const name = rest[sep + 1 ..];

    if (component.len == 0 or name.len == 0) return null;
    // Ensure no extra slashes in name.
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;

    return .{ .component = component, .name = name };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "parseConfigPath: valid path" {
    const p = parseConfigPath("/api/instances/nullclaw/my-agent/config").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
}

test "parseConfigPath: rejects path without /config suffix" {
    try std.testing.expect(parseConfigPath("/api/instances/nullclaw/my-agent") == null);
}

test "parseConfigPath: rejects path with extra segments" {
    try std.testing.expect(parseConfigPath("/api/instances/nullclaw/my-agent/config/extra") == null);
}

test "parseConfigPath: rejects path without name" {
    try std.testing.expect(parseConfigPath("/api/instances/nullclaw//config") == null);
}

test "isConfigPath detects config suffix" {
    try std.testing.expect(isConfigPath("/api/instances/nullclaw/my-agent/config"));
    try std.testing.expect(!isConfigPath("/api/instances/nullclaw/my-agent"));
    try std.testing.expect(!isConfigPath("/api/instances/nullclaw/my-agent/logs"));
}

test "handleGet returns 404 when no config file exists" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-config-api-get";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const resp = handleGet(allocator, p, "nullclaw", "my-agent");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"config not found\"}", resp.body);
}

test "handlePut writes config file" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-config-api-put";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const body = "{\"key\":\"value\"}";
    const resp = handlePut(allocator, p, "nullclaw", "my-agent", body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"saved\"}", resp.body);

    // Verify the file was written.
    const config_path = try p.instanceConfig(allocator, "nullclaw", "my-agent");
    defer allocator.free(config_path);

    const file = try std.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings(body, contents);
}

test "handleGet reads written config" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-config-api-roundtrip";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const body = "{\"port\":8080}";
    const put_resp = handlePut(allocator, p, "nullclaw", "my-agent", body);
    try std.testing.expectEqualStrings("200 OK", put_resp.status);

    const get_resp = handleGet(allocator, p, "nullclaw", "my-agent");
    defer allocator.free(get_resp.body);
    try std.testing.expectEqualStrings("200 OK", get_resp.status);
    try std.testing.expectEqualStrings(body, get_resp.body);
}

test "handlePatch writes config (same as PUT for now)" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-config-api-patch";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const body = "{\"updated\":true}";
    const resp = handlePatch(allocator, p, "nullclaw", "my-agent", body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"saved\"}", resp.body);
}
