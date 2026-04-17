const std = @import("std");
const std_compat = @import("compat");
const fs_compat = @import("../fs_compat.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");
const helpers = @import("helpers.zig");
const nullclaw_admin = @import("nullclaw_admin.zig");
const query = @import("query.zig");

const ApiResponse = helpers.ApiResponse;

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/instances/{c}/{n}/config — read instance config file.
///
/// Optional query:
///   path=<dotted.path> — return a single JSON value wrapped as
///   {"path":"...","value":...} instead of the raw config body.
pub fn handleGet(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8, name: []const u8, target: []const u8) ApiResponse {
    const contents = readConfigFile(allocator, p, component, name) catch |err| switch (err) {
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

    const path = query.valueAlloc(allocator, target, "path") catch return helpers.serverError();
    defer if (path) |value| allocator.free(value);

    const path_value = path orelse return .{
        .status = "200 OK",
        .content_type = "application/json",
        .body = contents,
    };

    errdefer allocator.free(contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return .{
        .status = "400 Bad Request",
        .content_type = "application/json",
        .body = "{\"error\":\"invalid config JSON\"}",
    };
    defer parsed.deinit();

    const value = lookupJsonPath(parsed.value, path_value) orelse return .{
        .status = "404 Not Found",
        .content_type = "application/json",
        .body = "{\"error\":\"config path not found\"}",
    };

    const value_json = std.json.Stringify.valueAlloc(allocator, value, .{}) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(value_json);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice("{\"path\":\"") catch return helpers.serverError();
    helpers.appendEscaped(&buf, path_value) catch return helpers.serverError();
    buf.appendSlice("\",\"value\":") catch return helpers.serverError();
    buf.appendSlice(value_json) catch return helpers.serverError();
    buf.appendSlice("}") catch return helpers.serverError();

    allocator.free(contents);
    return .{ .status = "200 OK", .content_type = "application/json", .body = buf.items };
}

pub fn handleGetManaged(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    p: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    target: []const u8,
) ApiResponse {
    const path = query.valueAlloc(allocator, target, "path") catch return helpers.serverError();
    defer if (path) |value| allocator.free(value);

    if (nullclaw_admin.tryReadConfigJson(allocator, s, p, component, name, path)) |body| {
        return .{ .status = "200 OK", .content_type = "application/json", .body = body };
    }
    return handleGet(allocator, p, component, name, target);
}

fn readConfigFile(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8, name: []const u8) ![]u8 {
    const config_path = p.instanceConfig(allocator, component, name) catch |err| return err;
    defer allocator.free(config_path);

    const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close();

    return try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
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

    const dir_path = p.instanceDir(allocator, component, name) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    defer allocator.free(dir_path);

    fs_compat.makePath(dir_path) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"cannot create instance directory\"}",
    };

    const file = std_compat.fs.createFileAbsolute(config_path, .{}) catch return .{
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

/// Parse a config-related sub-path from a parsed instance path.
/// Returns true if the path ends with "/config".
pub fn isConfigPath(target: []const u8) bool {
    return std.mem.endsWith(u8, query.stripTarget(target), "/config");
}

/// Extract component and name from /api/instances/{c}/{n}/config.
pub const ParsedConfigPath = struct {
    component: []const u8,
    name: []const u8,
};

pub fn parseConfigPath(target: []const u8) ?ParsedConfigPath {
    const prefix = "/api/instances/";
    const suffix = "/config";
    const clean = query.stripTarget(target);

    if (!std.mem.startsWith(u8, clean, prefix)) return null;
    if (!std.mem.endsWith(u8, clean, suffix)) return null;

    const rest = clean[prefix.len .. clean.len - suffix.len];
    if (rest.len == 0) return null;

    const sep = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const component = rest[0..sep];
    const name = rest[sep + 1 ..];

    if (component.len == 0 or name.len == 0) return null;
    // Ensure no extra slashes in name.
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;

    return .{ .component = component, .name = name };
}

fn lookupJsonPath(root: std.json.Value, dot_path: []const u8) ?std.json.Value {
    if (dot_path.len == 0) return null;

    var current = root;
    var it = std.mem.splitScalar(u8, dot_path, '.');
    while (it.next()) |segment| {
        if (segment.len == 0) return null;
        current = switch (current) {
            .object => |obj| obj.get(segment) orelse return null,
            else => return null,
        };
    }
    return current;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "parseConfigPath: valid path" {
    const p = parseConfigPath("/api/instances/nullclaw/my-agent/config").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
}

test "parseConfigPath: keeps working with query string" {
    const p = parseConfigPath("/api/instances/nullclaw/my-agent/config?path=gateway.port").?;
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
    std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const resp = handleGet(allocator, p, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/config");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"config not found\"}", resp.body);
}

test "handlePut writes config file" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-config-api-put";
    std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const body = "{\"key\":\"value\"}";
    const resp = handlePut(allocator, p, "nullclaw", "my-agent", body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"saved\"}", resp.body);

    // Verify the file was written.
    const config_path = try p.instanceConfig(allocator, "nullclaw", "my-agent");
    defer allocator.free(config_path);

    const file = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings(body, contents);
}

test "handleGet reads written config" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-config-api-roundtrip";
    std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const body = "{\"port\":8080}";
    const put_resp = handlePut(allocator, p, "nullclaw", "my-agent", body);
    try std.testing.expectEqualStrings("200 OK", put_resp.status);

    const get_resp = handleGet(allocator, p, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/config");
    defer allocator.free(get_resp.body);
    try std.testing.expectEqualStrings("200 OK", get_resp.status);
    try std.testing.expectEqualStrings(body, get_resp.body);
}

test "handleGet returns a single dotted-path value when path query is present" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-config-api-path";
    std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const body = "{\"gateway\":{\"port\":8080},\"default_provider\":\"openrouter\"}";
    const put_resp = handlePut(allocator, p, "nullclaw", "my-agent", body);
    try std.testing.expectEqualStrings("200 OK", put_resp.status);

    const get_resp = handleGet(allocator, p, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/config?path=gateway.port");
    defer allocator.free(get_resp.body);
    try std.testing.expectEqualStrings("200 OK", get_resp.status);
    try std.testing.expectEqualStrings("{\"path\":\"gateway.port\",\"value\":8080}", get_resp.body);
}

test "handlePatch writes config (same as PUT for now)" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-config-api-patch";
    std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    const body = "{\"updated\":true}";
    const resp = handlePatch(allocator, p, "nullclaw", "my-agent", body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"saved\"}", resp.body);
}
