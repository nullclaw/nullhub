const std = @import("std");
const http_proxy = @import("proxy.zig");

const Allocator = std.mem.Allocator;

const Response = http_proxy.Response;

const prefix = "/api/observability";

pub const Config = struct {
    watch_url: ?[]const u8 = null,
    watch_token: ?[]const u8 = null,
};

pub fn isProxyPath(target: []const u8) bool {
    return http_proxy.isPathInNamespace(target, prefix);
}

/// Proxies observability API requests to a local NullWatch instance.
/// The shared `/api/observability` prefix is stripped before forwarding, so
/// `/api/observability/v1/runs` becomes `/v1/runs` on NullWatch.
pub fn handle(allocator: Allocator, method: []const u8, target: []const u8, body: []const u8, cfg: Config) Response {
    if (!isProxyPath(target)) {
        return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
    }

    const base_url = cfg.watch_url orelse
        return .{ .status = "503 Service Unavailable", .content_type = "application/json", .body = "{\"error\":\"NullWatch not configured\"}" };

    const proxied_path = target[prefix.len..];
    const path = if (proxied_path.len == 0) "/v1/summary" else proxied_path;
    return http_proxy.forward(allocator, .{
        .method = method,
        .base_url = base_url,
        .path = path,
        .body = body,
        .bearer_token = cfg.watch_token,
        .unreachable_body = "{\"error\":\"NullWatch unreachable\"}",
    });
}

test "isProxyPath matches observability namespace" {
    try std.testing.expect(isProxyPath("/api/observability"));
    try std.testing.expect(isProxyPath("/api/observability/v1/runs"));
    try std.testing.expect(isProxyPath("/api/observability/health"));
    try std.testing.expect(!isProxyPath("/api/orchestration/v1/runs"));
}

test "handle returns not configured without NullWatch URL" {
    const resp = handle(std.testing.allocator, "GET", "/api/observability/v1/summary", "", .{});
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"NullWatch not configured\"}", resp.body);
}

test "handle rejects non-observability paths" {
    const resp = handle(std.testing.allocator, "GET", "/api/status", "", .{
        .watch_url = "http://127.0.0.1:7710",
    });
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}
