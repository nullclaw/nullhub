const std = @import("std");
const std_compat = @import("compat");

const Allocator = std.mem.Allocator;

pub const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

pub const ForwardOptions = struct {
    method: []const u8,
    base_url: []const u8,
    path: []const u8,
    body: []const u8,
    bearer_token: ?[]const u8 = null,
    unreachable_body: []const u8 = "{\"error\":\"upstream unreachable\"}",
};

pub fn isPathInNamespace(target: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, target, prefix) or
        (target.len > prefix.len and
            std.mem.startsWith(u8, target, prefix) and
            target[prefix.len] == '/');
}

pub fn forward(allocator: Allocator, opts: ForwardOptions) Response {
    const http_method = parseMethod(opts.method) orelse
        return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };

    const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ opts.base_url, opts.path }) catch
        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
    defer allocator.free(url);

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var header_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (opts.bearer_token) |token| blk: {
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
        .payload = if (opts.body.len > 0) opts.body else null,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
    }) catch {
        return .{ .status = "502 Bad Gateway", .content_type = "application/json", .body = opts.unreachable_body };
    };

    const resp_body = response_body.toOwnedSlice() catch
        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };

    return .{
        .status = mapStatus(@intFromEnum(result.status)),
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

test "isPathInNamespace matches exact and slash-delimited paths" {
    try std.testing.expect(isPathInNamespace("/api/observability", "/api/observability"));
    try std.testing.expect(isPathInNamespace("/api/observability/v1/runs", "/api/observability"));
    try std.testing.expect(isPathInNamespace("/api/observability/v1/runs?limit=1", "/api/observability"));
    try std.testing.expect(!isPathInNamespace("/api/observability?limit=1", "/api/observability"));
    try std.testing.expect(!isPathInNamespace("/api/observability-extra", "/api/observability"));
    try std.testing.expect(!isPathInNamespace("/api/orchestration", "/api/observability"));
}
