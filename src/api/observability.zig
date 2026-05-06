const std = @import("std");
const std_compat = @import("compat");

const Allocator = std.mem.Allocator;

const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const prefix = "/api/observability";

pub const Config = struct {
    watch_url: ?[]const u8 = null,
    watch_token: ?[]const u8 = null,
};

pub fn isProxyPath(target: []const u8) bool {
    return std.mem.eql(u8, target, prefix) or std.mem.startsWith(u8, target, prefix ++ "/");
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
    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, path }) catch
        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };

    const http_method = parseMethod(method) orelse
        return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var header_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (cfg.watch_token) |token| blk: {
        auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch
            return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
        header_buf[0] = .{ .name = "Authorization", .value = auth_header.? };
        break :blk header_buf[0..1];
    } else &.{};

    var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = http_method,
        .payload = if (body.len > 0) body else null,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
    }) catch {
        return .{ .status = "502 Bad Gateway", .content_type = "application/json", .body = "{\"error\":\"NullWatch unreachable\"}" };
    };

    const status_code: u10 = @intFromEnum(result.status);
    const resp_body = response_body.toOwnedSlice() catch
        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };

    return .{
        .status = mapStatus(status_code),
        .content_type = "application/json",
        .body = resp_body,
    };
}

fn parseMethod(method: []const u8) ?std.http.Method {
    if (std.mem.eql(u8, method, "GET")) return .GET;
    if (std.mem.eql(u8, method, "POST")) return .POST;
    if (std.mem.eql(u8, method, "PUT")) return .PUT;
    if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
    if (std.mem.eql(u8, method, "PATCH")) return .PATCH;
    return null;
}

fn mapStatus(code: u10) []const u8 {
    return switch (code) {
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        409 => "409 Conflict",
        415 => "415 Unsupported Media Type",
        422 => "422 Unprocessable Entity",
        500 => "500 Internal Server Error",
        502 => "502 Bad Gateway",
        503 => "503 Service Unavailable",
        else => if (code >= 200 and code < 300) "200 OK" else if (code >= 400 and code < 500) "400 Bad Request" else "500 Internal Server Error",
    };
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
