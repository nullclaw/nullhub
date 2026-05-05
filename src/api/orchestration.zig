const std = @import("std");
const std_compat = @import("compat");
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

const Backend = enum {
    boiler,
    tickets,

    fn notConfiguredBody(self: Backend) []const u8 {
        return switch (self) {
            .boiler => "{\"error\":\"NullBoiler not configured\"}",
            .tickets => "{\"error\":\"NullTickets not configured\"}",
        };
    }

    fn unreachableBody(self: Backend) []const u8 {
        return switch (self) {
            .boiler => "{\"error\":\"NullBoiler unreachable\"}",
            .tickets => "{\"error\":\"NullTickets unreachable\"}",
        };
    }
};

pub fn isProxyPath(target: []const u8) bool {
    return std.mem.eql(u8, target, prefix) or std.mem.startsWith(u8, target, prefix ++ "/");
}

fn isStorePath(target: []const u8) bool {
    return std.mem.eql(u8, target, store_prefix) or std.mem.startsWith(u8, target, store_prefix ++ "/");
}

const ProxyTarget = struct {
    backend: Backend,
    base_url: []const u8,
    token: ?[]const u8,
};

fn backendForPath(target: []const u8) ?Backend {
    if (!isProxyPath(target)) return null;
    return if (isStorePath(target)) .tickets else .boiler;
}

fn resolveProxyTarget(target: []const u8, cfg: Config) ?ProxyTarget {
    const backend = backendForPath(target) orelse return null;
    return switch (backend) {
        .tickets => blk: {
            const base_url = cfg.tickets_url orelse return null;
            break :blk .{
                .backend = .tickets,
                .base_url = base_url,
                .token = cfg.tickets_token,
            };
        },
        .boiler => blk: {
            const base_url = cfg.boiler_url orelse return null;
            break :blk .{
                .backend = .boiler,
                .base_url = base_url,
                .token = cfg.boiler_token,
            };
        },
    };
}

/// Proxies orchestration API requests to the local orchestration stack.
/// `/api/orchestration/store/*` goes to NullTickets; all other orchestration
/// routes go to NullBoiler. The shared prefix is stripped before forwarding.
pub fn handle(allocator: Allocator, method: []const u8, target: []const u8, body: []const u8, cfg: Config) Response {
    if (!isProxyPath(target)) {
        return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
    }
    const backend = backendForPath(target) orelse
        return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
    const resolved = resolveProxyTarget(target, cfg) orelse
        return .{ .status = "503 Service Unavailable", .content_type = "application/json", .body = backend.notConfiguredBody() };

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
        return .{ .status = "502 Bad Gateway", .content_type = "application/json", .body = resolved.backend.unreachableBody() };
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

const TestUpstream = struct {
    allocator: Allocator,
    server: std_compat.net.Server,
    thread: std.Thread,
    stop_flag: std.atomic.Value(bool),

    fn start(allocator: Allocator, response: []const u8) !TestUpstream {
        const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
        var server = try addr.listen(.{});
        errdefer server.deinit();

        const response_owned = try allocator.dupe(u8, response);
        errdefer allocator.free(response_owned);

        var upstream = TestUpstream{
            .allocator = allocator,
            .server = server,
            .thread = undefined,
            .stop_flag = std.atomic.Value(bool).init(false),
        };

        upstream.thread = try std.Thread.spawn(.{}, struct {
            fn run(ctx: struct {
                server: *std_compat.net.Server,
                stop_flag: *std.atomic.Value(bool),
                allocator: Allocator,
                response: []u8,
            }) void {
                defer ctx.allocator.free(ctx.response);

                while (!ctx.stop_flag.load(.acquire)) {
                    var conn = ctx.server.accept() catch |err| switch (err) {
                        error.WouldBlock => {
                            std.time.sleep(10 * std.time.ns_per_ms);
                            continue;
                        },
                        else => return,
                    };
                    defer conn.stream.close();

                    var read_buf: [1024]u8 = undefined;
                    _ = conn.stream.read(&read_buf) catch return;
                    _ = conn.stream.write(ctx.response) catch return;
                    return;
                }
            }
        }.run, .{.{
            .server = &upstream.server,
            .stop_flag = &upstream.stop_flag,
            .allocator = allocator,
            .response = response_owned,
        }});

        return upstream;
    }

    fn deinit(self: *TestUpstream) void {
        self.stop_flag.store(true, .release);
        self.server.deinit();
        self.thread.join();
    }

    fn baseUrl(self: *const TestUpstream, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{self.server.listen_address.in.getPort()});
    }
};

test "isProxyPath matches orchestration namespace" {
    try std.testing.expect(isProxyPath("/api/orchestration"));
    try std.testing.expect(isProxyPath("/api/orchestration/runs"));
    try std.testing.expect(isProxyPath("/api/orchestration/store/search"));
    try std.testing.expect(!isProxyPath("/api/instances"));
}

test "backendForPath routes store requests to tickets backend" {
    try std.testing.expectEqual(Backend.tickets, backendForPath("/api/orchestration/store/search").?);
    try std.testing.expectEqual(Backend.boiler, backendForPath("/api/orchestration/runs").?);
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

test "handle returns 404 for non-orchestration paths" {
    const resp = handle(std.testing.allocator, "GET", "/api/status", "", .{});
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", resp.body);
}

test "handle rejects unsupported methods before fetch" {
    const resp = handle(std.testing.allocator, "HEAD", "/api/orchestration/runs", "", .{
        .boiler_url = "http://127.0.0.1:8080",
    });
    try std.testing.expectEqualStrings("405 Method Not Allowed", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"method not allowed\"}", resp.body);
}

test "handle passes through upstream 409 status and body" {
    if (comptime @import("builtin").os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var upstream = try TestUpstream.start(allocator,
        "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\nContent-Length: 19\r\n\r\n{\"error\":\"conflict\"}"
    );
    defer upstream.deinit();

    const base_url = try upstream.baseUrl(allocator);
    defer allocator.free(base_url);

    const resp = handle(allocator, "GET", "/api/orchestration/runs", "", .{
        .boiler_url = base_url,
    });
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("409 Conflict", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"conflict\"}", resp.body);
}
