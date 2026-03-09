const std = @import("std");

pub const default_port: u16 = 19800;
pub const default_bind_host = "127.0.0.1";
pub const public_alias_host = "nullhub.local";
pub const canonical_local_host = "nullhub.localhost";
pub const fallback_local_host = "127.0.0.1";

pub const AccessUrls = struct {
    local_alias_chain: bool,
    direct_url: []const u8,
    browser_open_url: []const u8,
    canonical_url: []const u8,
    fallback_url: []const u8,
    public_alias_url: ?[]const u8,

    pub fn deinit(self: *AccessUrls, allocator: std.mem.Allocator) void {
        allocator.free(self.direct_url);
        allocator.free(self.browser_open_url);
        allocator.free(self.canonical_url);
        allocator.free(self.fallback_url);
        if (self.public_alias_url) |url| allocator.free(url);
    }
};

pub fn isLocalBindHost(host: []const u8) bool {
    return host.len == 0 or
        std.ascii.eqlIgnoreCase(host, "127.0.0.1") or
        std.ascii.eqlIgnoreCase(host, "localhost") or
        std.ascii.eqlIgnoreCase(host, "0.0.0.0") or
        std.ascii.eqlIgnoreCase(host, "::1") or
        std.ascii.eqlIgnoreCase(host, "[::1]") or
        std.ascii.eqlIgnoreCase(host, "::");
}

pub fn buildAccessUrls(allocator: std.mem.Allocator, host: []const u8, port: u16) !AccessUrls {
    if (isLocalBindHost(host)) {
        const public_alias_url = try buildUrl(allocator, public_alias_host, port);
        errdefer allocator.free(public_alias_url);

        const canonical_url = try buildUrl(allocator, canonical_local_host, port);
        errdefer allocator.free(canonical_url);

        const fallback_url = try buildUrl(allocator, fallback_local_host, port);
        errdefer allocator.free(fallback_url);

        const browser_open_url = try buildUrl(allocator, canonical_local_host, port);
        errdefer allocator.free(browser_open_url);

        const direct_url = try buildUrl(allocator, fallback_local_host, port);
        errdefer allocator.free(direct_url);

        return .{
            .local_alias_chain = true,
            .direct_url = direct_url,
            .browser_open_url = browser_open_url,
            .canonical_url = canonical_url,
            .fallback_url = fallback_url,
            .public_alias_url = public_alias_url,
        };
    }

    const direct_url = try buildUrl(allocator, host, port);
    errdefer allocator.free(direct_url);

    const browser_open_url = try buildUrl(allocator, host, port);
    errdefer allocator.free(browser_open_url);

    const canonical_url = try buildUrl(allocator, host, port);
    errdefer allocator.free(canonical_url);

    const fallback_url = try buildUrl(allocator, host, port);
    errdefer allocator.free(fallback_url);

    return .{
        .local_alias_chain = false,
        .direct_url = direct_url,
        .browser_open_url = browser_open_url,
        .canonical_url = canonical_url,
        .fallback_url = fallback_url,
        .public_alias_url = null,
    };
}

fn buildUrl(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]const u8 {
    return std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, port });
}

test "buildAccessUrls uses nullhub local chain for loopback binds" {
    var urls = try buildAccessUrls(std.testing.allocator, "127.0.0.1", default_port);
    defer urls.deinit(std.testing.allocator);

    try std.testing.expect(urls.local_alias_chain);
    try std.testing.expectEqualStrings("http://nullhub.local:19800", urls.public_alias_url.?);
    try std.testing.expectEqualStrings("http://nullhub.localhost:19800", urls.browser_open_url);
    try std.testing.expectEqualStrings("http://nullhub.localhost:19800", urls.canonical_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:19800", urls.fallback_url);
    try std.testing.expectEqualStrings("http://127.0.0.1:19800", urls.direct_url);
}

test "buildAccessUrls keeps direct host for non-local binds" {
    var urls = try buildAccessUrls(std.testing.allocator, "192.168.1.50", 22000);
    defer urls.deinit(std.testing.allocator);

    try std.testing.expect(!urls.local_alias_chain);
    try std.testing.expect(urls.public_alias_url == null);
    try std.testing.expectEqualStrings("http://192.168.1.50:22000", urls.browser_open_url);
    try std.testing.expectEqualStrings("http://192.168.1.50:22000", urls.direct_url);
}
