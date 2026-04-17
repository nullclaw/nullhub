const std = @import("std");
const builtin = @import("builtin");
const std_compat = @import("compat");
const net_compat = @import("../net_compat.zig");

const health_response_timeout_ms: u32 = 750;

pub const HealthCheckResult = struct {
    ok: bool,
    status_code: ?u16 = null,
    error_message: ?[]const u8 = null,
    response_time_ms: u64 = 0,
};

const windows_socket_error = -1;

const ws2_32 = if (builtin.os.tag == .windows) struct {
    extern "ws2_32" fn setsockopt(
        socket: std.posix.socket_t,
        level: i32,
        optname: i32,
        optval: ?*const anyopaque,
        optlen: i32,
    ) callconv(std.builtin.CallingConvention.winapi) i32;
} else struct {};

fn elapsedSince(start_ms: i64) u64 {
    const elapsed = std_compat.time.milliTimestamp() - start_ms;
    return if (elapsed <= 0) 0 else @intCast(elapsed);
}

fn configureReadTimeout(stream: std_compat.net.Stream, timeout_ms: u32) !void {
    switch (builtin.os.tag) {
        .windows => {
            var timeout: u32 = timeout_ms;
            const rc = ws2_32.setsockopt(
                stream.handle,
                std.os.windows.ws2_32.SOL.SOCKET,
                std.os.windows.ws2_32.SO.RCVTIMEO,
                std.mem.asBytes(&timeout).ptr,
                @sizeOf(u32),
            );
            if (rc == windows_socket_error) return error.Unexpected;
        },
        .wasi => {},
        else => {
            const timeout = std.posix.timeval{
                .sec = @intCast(@divTrunc(timeout_ms, 1000)),
                .usec = @intCast(@mod(timeout_ms, 1000) * std.time.us_per_ms),
            };
            try std.posix.setsockopt(
                stream.handle,
                std.posix.SOL.SOCKET,
                std.posix.SO.RCVTIMEO,
                std.mem.asBytes(&timeout),
            );
        },
    }
}

fn readFailureMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.Timeout, error.WouldBlock, error.ConnectionTimedOut => "timed out waiting for response",
        else => "failed to read response",
    };
}

/// Check health of a component by making HTTP GET to its health endpoint.
/// Returns ok=true if response status is 200.
pub fn check(allocator: std.mem.Allocator, host: []const u8, port: u16, endpoint: []const u8) HealthCheckResult {
    const start = std_compat.time.milliTimestamp();

    // Resolve address
    const addr = std_compat.net.Address.resolveIp(host, port) catch {
        return .{ .ok = false, .error_message = "failed to resolve address", .response_time_ms = elapsedSince(start) };
    };

    // Connect via TCP
    const stream = std_compat.net.tcpConnectToAddress(addr) catch {
        return .{ .ok = false, .error_message = "connection refused", .response_time_ms = elapsedSince(start) };
    };
    defer stream.close();

    configureReadTimeout(stream, health_response_timeout_ms) catch {
        return .{ .ok = false, .error_message = "failed to configure read timeout", .response_time_ms = elapsedSince(start) };
    };

    // Build and send GET request
    const request = std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ endpoint, host, port }) catch {
        return .{ .ok = false, .error_message = "failed to build request", .response_time_ms = elapsedSince(start) };
    };
    defer allocator.free(request);

    net_compat.streamWriteAll(stream, request) catch {
        return .{ .ok = false, .error_message = "failed to send request", .response_time_ms = elapsedSince(start) };
    };

    // Read response (just need the status line)
    var buf: [1024]u8 = undefined;
    const n = net_compat.streamRead(stream, &buf) catch |err| {
        return .{ .ok = false, .error_message = readFailureMessage(err), .response_time_ms = elapsedSince(start) };
    };

    if (n == 0) {
        return .{ .ok = false, .error_message = "empty response", .response_time_ms = elapsedSince(start) };
    }

    const elapsed = elapsedSince(start);

    // Parse status line: "HTTP/1.1 200 OK\r\n..."
    const response = buf[0..n];
    const status_code = parseStatusCode(response);

    return .{
        .ok = if (status_code) |code| code == 200 else false,
        .status_code = status_code,
        .response_time_ms = elapsed,
    };
}

fn parseStatusCode(response: []const u8) ?u16 {
    // Expect "HTTP/1.x NNN ..." — find the space after the version, then parse 3 digits.
    if (!std.mem.startsWith(u8, response, "HTTP/1.")) return null;

    const space_idx = std.mem.indexOf(u8, response, " ") orelse return null;
    if (space_idx + 4 > response.len) return null;

    return std.fmt.parseInt(u16, response[space_idx + 1 .. space_idx + 4], 10) catch null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "parseStatusCode parses 200" {
    try std.testing.expectEqual(@as(?u16, 200), parseStatusCode("HTTP/1.1 200 OK\r\n"));
}

test "parseStatusCode parses 404" {
    try std.testing.expectEqual(@as(?u16, 404), parseStatusCode("HTTP/1.1 404 Not Found\r\n"));
}

test "parseStatusCode parses 500" {
    try std.testing.expectEqual(@as(?u16, 500), parseStatusCode("HTTP/1.1 500 Internal Server Error\r\n"));
}

test "parseStatusCode parses HTTP/1.0" {
    try std.testing.expectEqual(@as(?u16, 200), parseStatusCode("HTTP/1.0 200 OK\r\n"));
}

test "parseStatusCode handles garbage" {
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("not http"));
}

test "parseStatusCode handles empty input" {
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode(""));
}

test "parseStatusCode handles truncated input" {
    try std.testing.expectEqual(@as(?u16, null), parseStatusCode("HTTP/1.1 2"));
}

test "check against non-listening port returns not ok" {
    const result = check(std.testing.allocator, "127.0.0.1", 19999, "/health");
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(@as(?u16, null), result.status_code);
    try std.testing.expect(result.error_message != null);
}

test "check times out when server accepts but does not respond" {
    const ThreadCtx = struct {
        server: *std_compat.net.Server,

        fn run(ctx: @This()) void {
            var conn = ctx.server.accept() catch return;
            defer conn.stream.close();
            std_compat.thread.sleep(3 * std.time.ns_per_s);
        }
    };

    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var server = try addr.listen(.{});
    defer server.deinit();

    const port = server.listen_address.in.getPort();
    const thread = try std.Thread.spawn(.{}, ThreadCtx.run, .{.{ .server = &server }});
    defer thread.join();

    const result = check(std.testing.allocator, "127.0.0.1", port, "/health");
    try std.testing.expect(!result.ok);
    try std.testing.expectEqual(@as(?u16, null), result.status_code);
    try std.testing.expectEqualStrings("timed out waiting for response", result.error_message.?);
    try std.testing.expect(result.response_time_ms < 2_500);
}
