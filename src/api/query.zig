const std = @import("std");

pub fn stripTarget(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |idx| {
        return target[0..idx];
    }
    return target;
}

pub fn valueRaw(target: []const u8, key: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qmark + 1 ..];

    var params = std.mem.splitScalar(u8, query, '&');
    while (params.next()) |param| {
        if (std.mem.indexOfScalar(u8, param, '=')) |eq| {
            if (std.mem.eql(u8, param[0..eq], key)) return param[eq + 1 ..];
            continue;
        }
        if (std.mem.eql(u8, param, key)) return "";
    }
    return null;
}

pub fn valueAlloc(allocator: std.mem.Allocator, target: []const u8, key: []const u8) !?[]u8 {
    const raw = valueRaw(target, key) orelse return null;

    const encoded = try allocator.dupe(u8, raw);
    for (encoded) |*ch| {
        if (ch.* == '+') ch.* = ' ';
    }

    const decoded = std.Uri.percentDecodeInPlace(encoded);
    if (decoded.ptr == encoded.ptr and decoded.len == encoded.len) return encoded;

    const out = try allocator.dupe(u8, decoded);
    allocator.free(encoded);
    return out;
}

pub fn boolValue(target: []const u8, key: []const u8) bool {
    const raw = valueRaw(target, key) orelse return false;
    return std.mem.eql(u8, raw, "1") or
        std.ascii.eqlIgnoreCase(raw, "true") or
        std.ascii.eqlIgnoreCase(raw, "yes");
}

pub fn usizeValue(target: []const u8, key: []const u8, default_value: usize) usize {
    const raw = valueRaw(target, key) orelse return default_value;
    return std.fmt.parseInt(usize, raw, 10) catch default_value;
}

test "valueAlloc decodes percent-encoded and plus-separated values" {
    const allocator = std.testing.allocator;
    const value = (try valueAlloc(allocator, "/api/test?query=hello+world%2Fskills", "query")).?;
    defer allocator.free(value);
    try std.testing.expectEqualStrings("hello world/skills", value);
}

test "boolValue accepts common truthy forms" {
    try std.testing.expect(boolValue("/api/test?stats=1", "stats"));
    try std.testing.expect(boolValue("/api/test?stats=true", "stats"));
    try std.testing.expect(boolValue("/api/test?stats=YES", "stats"));
    try std.testing.expect(!boolValue("/api/test?stats=false", "stats"));
}

test "stripTarget removes query suffix" {
    try std.testing.expectEqualStrings("/api/test", stripTarget("/api/test?foo=bar"));
    try std.testing.expectEqualStrings("/api/test", stripTarget("/api/test"));
}
