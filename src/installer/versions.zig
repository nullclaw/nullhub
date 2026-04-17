const std = @import("std");
const std_compat = @import("compat");
const registry = @import("registry.zig");
const prereqs = @import("prereqs.zig");

pub const VersionInfo = struct {
    tag_name: []const u8,
    prerelease: bool = false,
};

/// Fetch all releases (non-draft) from GitHub.
/// Returns list of { tag_name, prerelease } sorted newest-first (GitHub default).
/// Caller owns the returned parsed result.
pub fn fetchReleases(allocator: std.mem.Allocator, repo: []const u8) !std.json.Parsed([]const VersionInfo) {
    prereqs.ensureTool(allocator, "curl") catch return error.FetchFailed;

    const url = try std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases?per_page=50", .{repo});
    defer allocator.free(url);

    const result = std_compat.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sfL", "-H", "Accept: application/vnd.github+json", url },
        .max_output_bytes = 2 * 1024 * 1024,
    }) catch return error.FetchFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) return error.FetchFailed;
        },
        else => return error.FetchFailed,
    }

    return std.json.parseFromSlice(
        []const VersionInfo,
        allocator,
        result.stdout,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "VersionInfo parses from JSON" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"tag_name":"v1.0.0","prerelease":false},{"tag_name":"v1.1.0-beta","prerelease":true}]
    ;
    var parsed = try std.json.parseFromSlice(
        []const VersionInfo,
        allocator,
        json,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.len);
    try std.testing.expectEqualStrings("v1.0.0", parsed.value[0].tag_name);
    try std.testing.expect(!parsed.value[0].prerelease);
    try std.testing.expectEqualStrings("v1.1.0-beta", parsed.value[1].tag_name);
    try std.testing.expect(parsed.value[1].prerelease);
}

test "VersionInfo ignores unknown fields" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"tag_name":"v2.0.0","prerelease":false,"id":123,"draft":false,"name":"Release v2"}]
    ;
    var parsed = try std.json.parseFromSlice(
        []const VersionInfo,
        allocator,
        json,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.len);
    try std.testing.expectEqualStrings("v2.0.0", parsed.value[0].tag_name);
}
