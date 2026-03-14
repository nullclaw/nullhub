const std = @import("std");
const Allocator = std.mem.Allocator;

const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const prefix = "/api/orchestration";
const store_prefix = "/api/orchestration/store";

pub const Config = struct {
    boiler_url: ?[]const u8 = null,
    boiler_token: ?[]const u8 = null,
    tickets_url: ?[]const u8 = null,
    tickets_token: ?[]const u8 = null,
};

pub fn isProxyPath(target: []const u8) bool {
    return std.mem.eql(u8, target, prefix) or std.mem.startsWith(u8, target, prefix ++ "/");
}

fn isStorePath(target: []const u8) bool {
    return std.mem.eql(u8, target, store_prefix) or std.mem.startsWith(u8, target, store_prefix ++ "/");
}

const ProxyTarget = struct {
    base_url: []const u8,
    token: ?[]const u8,
    unavailable_body: []const u8,
    unreachable_body: []const u8,
};

fn resolveProxyTarget(target: []const u8, cfg: Config) ?ProxyTarget {
    if (!isProxyPath(target)) return null;
    if (isStorePath(target)) {
        const base_url = cfg.tickets_url orelse return .{
            .base_url = "",
            .token = null,
            .unavailable_body = "{\"error\":\"NullTickets not configured\"}",
            .unreachable_body = "{\"error\":\"NullTickets unreachable\"}",
        };
        return .{
            .base_url = base_url,
            .token = cfg.tickets_token,
            .unavailable_body = "",
            .unreachable_body = "{\"error\":\"NullTickets unreachable\"}",
        };
    }

    const base_url = cfg.boiler_url orelse return .{
        .base_url = "",
        .token = null,
        .unavailable_body = "{\"error\":\"NullBoiler not configured\"}",
        .unreachable_body = "{\"error\":\"NullBoiler unreachable\"}",
    };
    return .{
        .base_url = base_url,
        .token = cfg.boiler_token,
        .unavailable_body = "",
        .unreachable_body = "{\"error\":\"NullBoiler unreachable\"}",
    };
}

/// Proxies orchestration API requests to the local orchestration stack.
/// `/api/orchestration/store/*` goes to NullTickets; all other orchestration
/// routes go to NullBoiler. The shared prefix is stripped before forwarding.
pub fn handle(allocator: Allocator, method: []const u8, target: []const u8, body: []const u8, cfg: Config) Response {
    if (!isProxyPath(target)) {
        return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
    }
    const resolved = resolveProxyTarget(target, cfg) orelse
        return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
    if (resolved.unavailable_body.len > 0) {
        return .{ .status = "503 Service Unavailable", .content_type = "application/json", .body = resolved.unavailable_body };
    }

    const proxied_path = target[prefix.len..];
    const path = if (proxied_path.len == 0) "/" else proxied_path;

    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ resolved.base_url, path }) catch
        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };

    const http_method = parseMethod(method) orelse
        return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var header_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (resolved.token) |token| blk: {
        auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch
            return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
        header_buf[0] = .{ .name = "Authorization", .value = auth_header.? };
        break :blk header_buf[0..1];
    } else &.{};

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = http_method,
        .payload = if (body.len > 0) body else null,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
    }) catch {
        return .{ .status = "502 Bad Gateway", .content_type = "application/json", .body = resolved.unreachable_body };
    };

    const status_code: u10 = @intFromEnum(result.status);
    const resp_body = response_body.toOwnedSlice() catch
        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };

    const status = mapStatus(status_code);

    return .{
        .status = status,
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
        422 => "422 Unprocessable Entity",
        500 => "500 Internal Server Error",
        502 => "502 Bad Gateway",
        503 => "503 Service Unavailable",
        else => if (code >= 200 and code < 300) "200 OK" else if (code >= 400 and code < 500) "400 Bad Request" else "500 Internal Server Error",
    };
}

test "isProxyPath matches orchestration namespace" {
    try std.testing.expect(isProxyPath("/api/orchestration"));
    try std.testing.expect(isProxyPath("/api/orchestration/runs"));
    try std.testing.expect(isProxyPath("/api/orchestration/store/search"));
    try std.testing.expect(!isProxyPath("/api/instances"));
}

test "handle routes store paths to NullTickets config" {
    const resp = handle(std.testing.allocator, "GET", "/api/orchestration/store/search", "", .{
        .boiler_url = "http://127.0.0.1:8080",
    });
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"NullTickets not configured\"}", resp.body);
}

test "handle routes non-store paths to NullBoiler config" {
    const resp = handle(std.testing.allocator, "GET", "/api/orchestration/runs", "", .{
        .tickets_url = "http://127.0.0.1:7711",
    });
    try std.testing.expectEqualStrings("503 Service Unavailable", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"NullBoiler not configured\"}", resp.body);
}
