const std = @import("std");
const builtin = @import("builtin");

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/settings — return hub configuration defaults.
/// Caller owns the returned memory.
pub fn handleGetSettings(allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice(
        "{\"port\":9800,\"host\":\"127.0.0.1\",\"auth_token\":null,\"auto_update_check\":true}",
    );

    return try buf.toOwnedSlice();
}

/// PUT /api/settings — update hub settings. Echo the body back as acknowledgment.
/// Caller owns the returned memory.
pub fn handlePutSettings(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    // Validate the body is parseable JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch {
        return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}");
    };
    defer parsed.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"status\":\"ok\",\"settings\":");
    try buf.appendSlice(body);
    try buf.append('}');

    return try buf.toOwnedSlice();
}

/// POST /api/service/install — detect platform and return dry-run service registration info.
/// Caller owns the returned memory.
pub fn handleServiceInstall(allocator: std.mem.Allocator) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    const os = builtin.os.tag;
    if (os == .macos) {
        try buf.appendSlice(
            "{\"status\":\"ok\",\"platform\":\"macos\",\"service_type\":\"launchd\"," ++
                "\"path\":\"~/Library/LaunchAgents/com.nullhub.agent.plist\"," ++
                "\"message\":\"Service registration prepared (dry run)\"}",
        );
    } else if (os == .linux) {
        try buf.appendSlice(
            "{\"status\":\"ok\",\"platform\":\"linux\",\"service_type\":\"systemd\"," ++
                "\"path\":\"~/.config/systemd/user/nullhub.service\"," ++
                "\"message\":\"Service registration prepared (dry run)\"}",
        );
    } else {
        try buf.appendSlice(
            "{\"status\":\"error\",\"message\":\"unsupported platform\"}",
        );
    }

    return try buf.toOwnedSlice();
}

/// POST /api/service/uninstall — stub that returns success.
/// Caller owns the returned memory.
pub fn handleServiceUninstall(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, "{\"status\":\"ok\",\"message\":\"Service unregistered\"}");
}

/// GET /api/service/status — stub returning registration status.
/// Caller owns the returned memory.
pub fn handleServiceStatus(allocator: std.mem.Allocator) ![]const u8 {
    const os = builtin.os.tag;
    const service_type = if (os == .macos) "launchd" else if (os == .linux) "systemd" else "unknown";

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"registered\":false,\"running\":false,\"service_type\":\"");
    try buf.appendSlice(service_type);
    try buf.appendSlice("\"}");

    return try buf.toOwnedSlice();
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "handleGetSettings returns valid JSON with defaults" {
    const allocator = std.testing.allocator;

    const json = try handleGetSettings(allocator);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(
        struct {
            port: u16,
            host: []const u8,
            auth_token: ?[]const u8,
            auto_update_check: bool,
        },
        allocator,
        json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(u16, 9800), parsed.value.port);
    try std.testing.expectEqualStrings("127.0.0.1", parsed.value.host);
    try std.testing.expect(parsed.value.auth_token == null);
    try std.testing.expect(parsed.value.auto_update_check == true);
}

test "handlePutSettings returns ok status" {
    const allocator = std.testing.allocator;

    const body = "{\"port\":9801,\"host\":\"0.0.0.0\"}";
    const json = try handlePutSettings(allocator, body);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"settings\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"port\":9801") != null);
}

test "handlePutSettings rejects invalid JSON" {
    const allocator = std.testing.allocator;

    const json = try handlePutSettings(allocator, "not json");
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") != null);
}

test "handleServiceInstall returns platform info" {
    const allocator = std.testing.allocator;

    const json = try handleServiceInstall(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);

    const os = builtin.os.tag;
    if (os == .macos) {
        try std.testing.expect(std.mem.indexOf(u8, json, "\"platform\":\"macos\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"service_type\":\"launchd\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "com.nullhub.agent.plist") != null);
    } else if (os == .linux) {
        try std.testing.expect(std.mem.indexOf(u8, json, "\"platform\":\"linux\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "\"service_type\":\"systemd\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, json, "nullhub.service") != null);
    }
    try std.testing.expect(std.mem.indexOf(u8, json, "dry run") != null);
}

test "handleServiceStatus returns registered false" {
    const allocator = std.testing.allocator;

    const json = try handleServiceStatus(allocator);
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(
        struct {
            registered: bool,
            running: bool,
            service_type: []const u8,
        },
        allocator,
        json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expect(parsed.value.registered == false);
    try std.testing.expect(parsed.value.running == false);
    try std.testing.expect(parsed.value.service_type.len > 0);
}

test "handleServiceUninstall returns ok" {
    const allocator = std.testing.allocator;

    const json = try handleServiceUninstall(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);
}
