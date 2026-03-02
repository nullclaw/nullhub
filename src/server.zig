const std = @import("std");
const auth = @import("auth.zig");
const instances_api = @import("api/instances.zig");
const platform = @import("core/platform.zig");
const components_api = @import("api/components.zig");
const config_api = @import("api/config.zig");
const logs_api = @import("api/logs.zig");
const status_api = @import("api/status.zig");
const paths_mod = @import("core/paths.zig");
const wizard_api = @import("api/wizard.zig");

const version = "0.1.0";
const max_request_size: usize = 65_536;

pub const Server = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    auth_token: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) Server {
        return .{ .allocator = allocator, .host = host, .port = port };
    }

    pub fn run(self: *Server) !void {
        const addr = try std.net.Address.resolveIp(self.host, self.port);
        var listener = try addr.listen(.{ .reuse_address = true });
        defer listener.deinit();

        std.debug.print("listening on http://{s}:{d}\n", .{ self.host, self.port });

        while (true) {
            const conn = listener.accept() catch |err| {
                std.debug.print("accept error: {}\n", .{err});
                continue;
            };
            defer conn.stream.close();

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            self.handleConnection(conn, arena.allocator()) catch |err| {
                std.debug.print("request error: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *Server, conn: std.net.Server.Connection, alloc: std.mem.Allocator) !void {
        var req_buf: [max_request_size]u8 = undefined;
        const n = conn.stream.read(&req_buf) catch return;
        if (n == 0) return;
        const raw = req_buf[0..n];

        // Parse request line
        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;

        // Read remaining body if Content-Length indicates more data
        const body = readBody(raw, n, conn.stream, alloc) catch return;

        // Handle OPTIONS preflight
        if (std.mem.eql(u8, method, "OPTIONS")) {
            try sendResponse(conn.stream, .{
                .status = "204 No Content",
                .content_type = "text/plain",
                .body = "",
            });
            return;
        }

        // Auth check for protected API paths
        if (self.auth_token != null and !auth.isPublicPath(target)) {
            if (!auth.checkAuth(raw, self.auth_token)) {
                try sendResponse(conn.stream, .{
                    .status = "401 Unauthorized",
                    .content_type = "application/json",
                    .body = "{\"error\":\"unauthorized\"}",
                });
                return;
            }
        }

        // Route dispatch
        const response = route(alloc, method, target, body);
        try sendResponse(conn.stream, response);
    }
};

const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

fn jsonResponse(body: []const u8) Response {
    return .{ .status = "200 OK", .content_type = "application/json", .body = body };
}

fn readBody(raw: []const u8, n: usize, stream: std.net.Stream, alloc: std.mem.Allocator) ![]const u8 {
    if (extractHeader(raw, "Content-Length")) |cl_str| {
        const content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
        if (content_length > 0) {
            const header_end_pos = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return "";
            const body_start = header_end_pos + 4;
            const body_received = n - body_start;
            if (body_received >= content_length) {
                return raw[body_start .. body_start + content_length];
            }
            // Need to read more data from the stream
            const total_size = body_start + content_length;
            if (total_size > max_request_size) return error.RequestTooLarge;
            const full_buf = try alloc.alloc(u8, total_size);
            @memcpy(full_buf[0..n], raw);
            var total_read = n;
            while (total_read < total_size) {
                const extra = stream.read(full_buf[total_read..total_size]) catch break;
                if (extra == 0) break;
                total_read += extra;
            }
            return full_buf[body_start..total_read];
        }
    }
    return extractBody(raw);
}

fn route(allocator: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) Response {
    if (std.mem.eql(u8, method, "GET")) {
        if (std.mem.eql(u8, target, "/health")) {
            return .{
                .status = "200 OK",
                .content_type = "application/json",
                .body = "{\"status\":\"ok\"}",
            };
        }
        if (std.mem.eql(u8, target, "/api/status")) {
            return .{
                .status = "200 OK",
                .content_type = "application/json",
                .body = "{\"hub\":{\"version\":\"" ++ version ++ "\",\"platform\":\"" ++ comptime platform.detect().toString() ++ "\"}}",
            };
        }
        if (std.mem.eql(u8, target, "/api/components")) {
            if (components_api.handleList(allocator)) |json| {
                return .{
                    .status = "200 OK",
                    .content_type = "application/json",
                    .body = json,
                };
            } else |_| {
                return .{
                    .status = "500 Internal Server Error",
                    .content_type = "application/json",
                    .body = "{\"error\":\"internal server error\"}",
                };
            }
        }
        if (components_api.isManifestPath(target)) {
            if (components_api.extractComponentName(target)) |comp_name| {
                if (components_api.handleManifest(allocator, comp_name)) |maybe_json| {
                    if (maybe_json) |json| {
                        return .{
                            .status = "200 OK",
                            .content_type = "application/json",
                            .body = json,
                        };
                    }
                } else |_| {}
            }
            return .{
                .status = "404 Not Found",
                .content_type = "application/json",
                .body = "{\"error\":\"manifest not found\"}",
            };
        }
    }

    if (std.mem.eql(u8, method, "POST")) {
        if (std.mem.eql(u8, target, "/api/components/refresh")) {
            if (components_api.handleRefresh(allocator)) |json| {
                return .{
                    .status = "200 OK",
                    .content_type = "application/json",
                    .body = json,
                };
            } else |_| {
                return .{
                    .status = "500 Internal Server Error",
                    .content_type = "application/json",
                    .body = "{\"error\":\"internal server error\"}",
                };
            }
        }
    }

    // Wizard API
    if (wizard_api.isWizardPath(target)) {
        if (wizard_api.extractComponentName(target)) |comp_name| {
            if (std.mem.eql(u8, method, "GET")) {
                if (wizard_api.handleGetWizard(allocator, comp_name)) |json| {
                    return .{
                        .status = "200 OK",
                        .content_type = "application/json",
                        .body = json,
                    };
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"component not found\"}",
                };
            }
            if (std.mem.eql(u8, method, "POST")) {
                if (wizard_api.handlePostWizard(allocator, comp_name, body)) |json| {
                    return .{
                        .status = "200 OK",
                        .content_type = "application/json",
                        .body = json,
                    };
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"component not found\"}",
                };
            }
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }
    }

    // Config API — /api/instances/{c}/{n}/config
    if (config_api.isConfigPath(target)) {
        if (config_api.parseConfigPath(target)) |parsed| {
            const p = paths_mod.Paths.init(allocator, null) catch return .{
                .status = "500 Internal Server Error",
                .content_type = "application/json",
                .body = "{\"error\":\"internal error\"}",
            };
            if (std.mem.eql(u8, method, "GET")) {
                const resp = config_api.handleGet(allocator, p, parsed.component, parsed.name);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
            if (std.mem.eql(u8, method, "PUT")) {
                const resp = config_api.handlePut(allocator, p, parsed.component, parsed.name, body);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
            if (std.mem.eql(u8, method, "PATCH")) {
                const resp = config_api.handlePatch(allocator, p, parsed.component, parsed.name, body);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }
    }

    // Logs API — /api/instances/{c}/{n}/logs and /api/instances/{c}/{n}/logs/stream
    if (logs_api.isLogsPath(target)) {
        if (logs_api.parseLogsPath(target)) |parsed| {
            if (!std.mem.eql(u8, method, "GET")) {
                return .{
                    .status = "405 Method Not Allowed",
                    .content_type = "application/json",
                    .body = "{\"error\":\"method not allowed\"}",
                };
            }
            if (parsed.is_stream) {
                const resp = logs_api.handleStream();
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
            const p = paths_mod.Paths.init(allocator, null) catch return .{
                .status = "500 Internal Server Error",
                .content_type = "application/json",
                .body = "{\"error\":\"internal error\"}",
            };
            const max_lines = logs_api.parseLines(target);
            const resp = logs_api.handleGet(allocator, p, parsed.component, parsed.name, max_lines);
            return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
        }
    }

    // Instances API — route matching only (State integration pending).
    if (std.mem.startsWith(u8, target, "/api/instances")) {
        if (std.mem.eql(u8, target, "/api/instances")) {
            if (std.mem.eql(u8, method, "GET")) {
                return .{
                    .status = "200 OK",
                    .content_type = "application/json",
                    .body = "{\"instances\":{}}",
                };
            }
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }
        if (instances_api.parsePath(target)) |parsed| {
            if (parsed.action) |action| {
                if (!std.mem.eql(u8, method, "POST")) {
                    return .{
                        .status = "405 Method Not Allowed",
                        .content_type = "application/json",
                        .body = "{\"error\":\"method not allowed\"}",
                    };
                }
                if (std.mem.eql(u8, action, "start")) return jsonResponse("{\"status\":\"started\"}");
                if (std.mem.eql(u8, action, "stop")) return jsonResponse("{\"status\":\"stopped\"}");
                if (std.mem.eql(u8, action, "restart")) return jsonResponse("{\"status\":\"restarted\"}");
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"not found\"}",
                };
            }
            if (std.mem.eql(u8, method, "GET")) return jsonResponse("{\"error\":\"state not initialized\"}");
            if (std.mem.eql(u8, method, "DELETE")) return jsonResponse("{\"status\":\"deleted\"}");
            if (std.mem.eql(u8, method, "PATCH")) return jsonResponse("{\"status\":\"updated\"}");
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }
    }

    return .{
        .status = "404 Not Found",
        .content_type = "application/json",
        .body = "{\"error\":\"not found\"}",
    };
}

fn sendResponse(stream: std.net.Stream, response: Response) !void {
    var buf: [512]u8 = undefined;
    const header = try std.fmt.bufPrint(&buf,
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
            "Connection: close\r\n\r\n",
        .{ response.status, response.content_type, response.body.len },
    );
    _ = try stream.write(header);
    if (response.body.len > 0) {
        _ = try stream.write(response.body);
    }
}

pub fn extractBody(raw: []const u8) []const u8 {
    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |pos| {
        const body_start = pos + 4;
        if (body_start < raw.len) {
            return raw[body_start..];
        }
    }
    return "";
}

pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    const headers = raw[0..header_end];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // skip request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const hdr_key = line[0..colon];
            if (std.ascii.eqlIgnoreCase(hdr_key, name)) {
                return std.mem.trimLeft(u8, line[colon + 1 ..], " ");
            }
        }
    }
    return null;
}

// --- Tests ---

test "route GET /health returns 200 OK" {
    const resp = route(std.testing.allocator, "GET", "/health", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
}

test "route GET /api/status returns version and platform" {
    const resp = route(std.testing.allocator, "GET", "/api/status", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    // Body should contain version
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "0.1.0") != null);
    // Body should contain platform key
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "platform") != null);
}

test "route unknown path returns 404" {
    const resp = route(std.testing.allocator, "GET", "/nonexistent", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", resp.body);
}

test "route POST to GET-only route returns 404" {
    const resp = route(std.testing.allocator, "POST", "/health", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "route GET /api/components returns component list" {
    const resp = route(std.testing.allocator, "GET", "/api/components", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"components\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"nullclaw\"") != null);
}

test "route GET /api/components/{name}/manifest returns 404 for uncached" {
    const resp = route(std.testing.allocator, "GET", "/api/components/nullclaw/manifest", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"manifest not found\"}", resp.body);
}

test "route POST /api/components/refresh returns 200" {
    const resp = route(std.testing.allocator, "POST", "/api/components/refresh", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
}

test "extractHeader finds Content-Length" {
    const raw = "GET / HTTP/1.1\r\nContent-Length: 42\r\nHost: localhost\r\n\r\nbody";
    const val = extractHeader(raw, "Content-Length");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("42", val.?);
}

test "extractHeader returns null for missing header" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(extractHeader(raw, "Content-Length") == null);
}

test "extractHeader is case-insensitive" {
    const raw = "GET / HTTP/1.1\r\ncontent-length: 10\r\n\r\n";
    const val = extractHeader(raw, "Content-Length");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("10", val.?);
}

test "extractBody returns body after headers" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nhello world";
    try std.testing.expectEqualStrings("hello world", extractBody(raw));
}

test "extractBody returns empty for no body" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expectEqualStrings("", extractBody(raw));
}

test "route GET /api/instances returns empty instances" {
    const resp = route(std.testing.allocator, "GET", "/api/instances", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"instances\":{}}", resp.body);
}

test "route POST /api/instances/{component}/{name}/start returns 200" {
    const resp = route(std.testing.allocator, "POST", "/api/instances/nullclaw/my-agent/start", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"started\"}", resp.body);
}

test "route POST /api/instances/{component}/{name}/stop returns 200" {
    const resp = route(std.testing.allocator, "POST", "/api/instances/nullclaw/my-agent/stop", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"stopped\"}", resp.body);
}

test "route POST /api/instances/{component}/{name}/restart returns 200" {
    const resp = route(std.testing.allocator, "POST", "/api/instances/nullclaw/my-agent/restart", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"restarted\"}", resp.body);
}

test "route DELETE /api/instances/{component}/{name} returns 200" {
    const resp = route(std.testing.allocator, "DELETE", "/api/instances/nullclaw/my-agent", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"deleted\"}", resp.body);
}

test "route PATCH /api/instances/{component}/{name} returns 200" {
    const resp = route(std.testing.allocator, "PATCH", "/api/instances/nullclaw/my-agent", "{\"auto_start\":true}");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"updated\"}", resp.body);
}

test "route GET /api/instances with wrong method returns 405" {
    const resp = route(std.testing.allocator, "POST", "/api/instances", "");
    try std.testing.expectEqualStrings("405 Method Not Allowed", resp.status);
}

test "Server init sets fields" {
    const s = Server.init(std.testing.allocator, "127.0.0.1", 9800);
    try std.testing.expectEqualStrings("127.0.0.1", s.host);
    try std.testing.expectEqual(@as(u16, 9800), s.port);
}
