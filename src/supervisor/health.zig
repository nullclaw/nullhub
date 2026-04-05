const std = @import("std");
const net_compat = @import("../net_compat.zig");

pub const HealthCheckResult = struct {
    ok: bool,
    status_code: ?u16 = null,
    error_message: ?[]const u8 = null,
    response_time_ms: u64 = 0,
};

/// Check health of a component by making HTTP GET to its health endpoint.
/// Returns ok=true if response status is 200.
pub fn check(allocator: std.mem.Allocator, host: []const u8, port: u16, endpoint: []const u8) HealthCheckResult {
    const start = std.time.milliTimestamp();

    // Resolve address
    const addr = std.net.Address.resolveIp(host, port) catch {
        return .{ .ok = false, .error_message = "failed to resolve address" };
    };

    // Connect via TCP
    const stream = std.net.tcpConnectToAddress(addr) catch {
        return .{ .ok = false, .error_message = "connection refused" };
    };
    defer stream.close();

    // Build and send GET request
    const request = std.fmt.allocPrint(allocator, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ endpoint, host, port }) catch {
        return .{ .ok = false, .error_message = "failed to build request" };
    };
    defer allocator.free(request);

    net_compat.streamWriteAll(stream, request) catch {
        return .{ .ok = false, .error_message = "failed to send request" };
    };

    // Read response (just need the status line)
    var buf: [1024]u8 = undefined;
    const n = net_compat.streamRead(stream, &buf) catch {
        return .{ .ok = false, .error_message = "failed to read response" };
    };

    if (n == 0) {
        return .{ .ok = false, .error_message = "empty response" };
    }

    const elapsed: u64 = @intCast(std.time.milliTimestamp() - start);

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
