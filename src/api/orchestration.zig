const std = @import("std");
const Allocator = std.mem.Allocator;

const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

const prefix = "/api/orchestration";

/// Proxies orchestration API requests to NullBoiler.
/// Strips the /api/orchestration prefix and forwards to NullBoiler's REST API.
pub fn handle(allocator: Allocator, method: []const u8, target: []const u8, body: []const u8, boiler_url: []const u8, boiler_token: ?[]const u8) Response {
    if (!std.mem.startsWith(u8, target, prefix)) {
        return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
    }

    const boiler_path = target[prefix.len..];
    const path = if (boiler_path.len == 0) "/" else boiler_path;

    // Build full URL: boiler_url + path
    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ boiler_url, path }) catch
        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };

    // Resolve HTTP method string to enum
    const http_method = parseMethod(method) orelse
        return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };

    // Build auth header if token provided
    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var header_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (boiler_token) |token| blk: {
        auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch
            return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
        header_buf[0] = .{ .name = "Authorization", .value = auth_header.? };
        break :blk header_buf[0..1];
    } else &.{};

    // Make HTTP request to NullBoiler
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
        return .{ .status = "502 Bad Gateway", .content_type = "application/json", .body = "{\"error\":\"NullBoiler unreachable\"}" };
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
