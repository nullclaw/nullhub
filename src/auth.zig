const std = @import("std");
const server = @import("server.zig");

/// Checks if a raw HTTP request carries a valid bearer token.
/// If `expected_token` is null, auth is disabled and always returns true.
pub fn checkAuth(raw_request: []const u8, expected_token: ?[]const u8) bool {
    const expected = expected_token orelse return true;
    const provided = extractBearerToken(raw_request) orelse return false;
    if (provided.len != expected.len) return false;
    // Constant-time comparison to prevent timing attacks.
    var diff: u8 = 0;
    for (provided, expected) |a, b| {
        diff |= a ^ b;
    }
    return diff == 0;
}

/// Extracts the bearer token from the Authorization header in a raw HTTP request.
/// Returns null if the header is missing or not in "Bearer {token}" format.
pub fn extractBearerToken(raw_request: []const u8) ?[]const u8 {
    const value = server.extractHeader(raw_request, "Authorization") orelse return null;
    const prefix = "Bearer ";
    if (value.len > prefix.len and std.ascii.startsWithIgnoreCase(value, prefix)) {
        return value[prefix.len..];
    }
    return null;
}

fn pathWithoutQuery(path: []const u8) []const u8 {
    const query = std.mem.indexOfScalar(u8, path, '?') orelse return path;
    return path[0..query];
}

pub fn isApiPath(path: []const u8) bool {
    const clean_path = pathWithoutQuery(path);
    return std.mem.eql(u8, clean_path, "/api") or
        std.mem.startsWith(u8, clean_path, "/api/");
}

/// Returns true for paths that do not require authentication.
/// Public paths: /health and any path outside the /api namespace.
pub fn isPublicPath(path: []const u8) bool {
    if (std.mem.eql(u8, pathWithoutQuery(path), "/health")) return true;
    return !isApiPath(path);
}

// --- Tests ---

test "extractBearerToken extracts token from valid header" {
    const raw = "GET /api/status HTTP/1.1\r\nAuthorization: Bearer my-secret-token\r\nHost: localhost\r\n\r\n";
    const token = extractBearerToken(raw);
    try std.testing.expect(token != null);
    try std.testing.expectEqualStrings("my-secret-token", token.?);
}

test "extractBearerToken returns null for missing header" {
    const raw = "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(extractBearerToken(raw) == null);
}

test "extractBearerToken returns null for non-Bearer auth" {
    const raw = "GET /api/status HTTP/1.1\r\nAuthorization: Basic dXNlcjpwYXNz\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(extractBearerToken(raw) == null);
}

test "checkAuth returns true when token is null (auth disabled)" {
    const raw = "GET /api/status HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(checkAuth(raw, null) == true);
}

test "checkAuth returns true for matching token" {
    const raw = "GET /api/status HTTP/1.1\r\nAuthorization: Bearer correct-token\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(checkAuth(raw, "correct-token") == true);
}

test "checkAuth returns false for wrong token" {
    const raw = "GET /api/status HTTP/1.1\r\nAuthorization: Bearer wrong-token\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(checkAuth(raw, "correct-token") == false);
}

test "isPublicPath returns true for /health" {
    try std.testing.expect(isPublicPath("/health") == true);
}

test "isPublicPath returns true for static paths like /index.html" {
    try std.testing.expect(isPublicPath("/index.html") == true);
}

test "isPublicPath returns false for /api/status" {
    try std.testing.expect(isPublicPath("/api/status") == false);
}

test "isPublicPath returns false for bare /api" {
    try std.testing.expect(isPublicPath("/api") == false);
}

test "isPublicPath returns false for bare /api with query string" {
    try std.testing.expect(isPublicPath("/api?format=json") == false);
}

test "isApiPath only matches the api namespace" {
    try std.testing.expect(isApiPath("/api"));
    try std.testing.expect(isApiPath("/api?format=json"));
    try std.testing.expect(isApiPath("/api/status"));
    try std.testing.expect(isApiPath("/api/status?format=json"));
    try std.testing.expect(!isApiPath("/apiary"));
    try std.testing.expect(!isApiPath("/ui/api"));
}
