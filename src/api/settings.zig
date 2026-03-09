const std = @import("std");
const builtin = @import("builtin");
const access = @import("../access.zig");

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/settings — return hub configuration defaults.
/// Caller owns the returned memory.
pub fn handleGetSettings(allocator: std.mem.Allocator, host: []const u8, port: u16, access_options: access.Options) ![]const u8 {
    var urls = try access.buildAccessUrlsWithOptions(allocator, host, port, access_options);
    defer urls.deinit(allocator);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"port\":");
    try buf.writer().print("{d}", .{port});
    try buf.appendSlice(",\"host\":\"");
    try buf.appendSlice(host);
    try buf.appendSlice("\",\"auth_token\":null,\"auto_update_check\":true,");
    try appendAccessJson(&buf, urls);
    try buf.append('}');

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

fn appendAccessJson(buf: *std.array_list.Managed(u8), urls: access.AccessUrls) !void {
    try buf.appendSlice("\"access\":{");
    try buf.appendSlice("\"browser_open_url\":\"");
    try buf.appendSlice(urls.browser_open_url);
    try buf.appendSlice("\",\"direct_url\":\"");
    try buf.appendSlice(urls.direct_url);
    try buf.appendSlice("\",\"canonical_url\":\"");
    try buf.appendSlice(urls.canonical_url);
    try buf.appendSlice("\",\"fallback_url\":\"");
    try buf.appendSlice(urls.fallback_url);
    try buf.appendSlice("\",\"local_alias_chain\":");
    try buf.appendSlice(if (urls.local_alias_chain) "true" else "false");
    try buf.appendSlice(",\"public_alias_active\":");
    try buf.appendSlice(if (urls.public_alias_active) "true" else "false");
    try buf.appendSlice(",\"public_alias_provider\":\"");
    try buf.appendSlice(urls.public_alias_provider);
    try buf.append('"');
    try buf.appendSlice(",\"public_alias_url\":");
    if (urls.public_alias_url) |url| {
        try buf.append('"');
        try buf.appendSlice(url);
        try buf.append('"');
    } else {
        try buf.appendSlice("null");
    }
    try buf.append('}');
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "handleGetSettings returns valid JSON with defaults" {
    const allocator = std.testing.allocator;

    const json = try handleGetSettings(allocator, access.default_bind_host, access.default_port, .{});
    defer allocator.free(json);

    const parsed = try std.json.parseFromSlice(
        struct {
            port: u16,
            host: []const u8,
            auth_token: ?[]const u8,
            auto_update_check: bool,
            access: struct {
                browser_open_url: []const u8,
                direct_url: []const u8,
                canonical_url: []const u8,
                fallback_url: []const u8,
                local_alias_chain: bool,
                public_alias_active: bool,
                public_alias_provider: []const u8,
                public_alias_url: ?[]const u8,
            },
        },
        allocator,
        json,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(access.default_port, parsed.value.port);
    try std.testing.expectEqualStrings(access.default_bind_host, parsed.value.host);
    try std.testing.expect(parsed.value.auth_token == null);
    try std.testing.expect(parsed.value.auto_update_check == true);
    try std.testing.expect(parsed.value.access.local_alias_chain);
    try std.testing.expect(!parsed.value.access.public_alias_active);
    try std.testing.expectEqualStrings("none", parsed.value.access.public_alias_provider);
    try std.testing.expectEqualStrings("http://nullhub.localhost:19800", parsed.value.access.browser_open_url);
    try std.testing.expectEqualStrings("http://nullhub.local:19800", parsed.value.access.public_alias_url.?);
}

test "handlePutSettings returns ok status" {
    const allocator = std.testing.allocator;

    const body = "{\"port\":19801,\"host\":\"0.0.0.0\"}";
    const json = try handlePutSettings(allocator, body);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"settings\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"port\":19801") != null);
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
