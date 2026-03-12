const std = @import("std");

pub fn buildLaunchArgs(
    allocator: std.mem.Allocator,
    launch_mode: []const u8,
    verbose: bool,
) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, launch_mode, " \t\r\n");
    while (it.next()) |token| {
        try list.append(allocator, token);
    }

    if (verbose) {
        try list.append(allocator, "--verbose");
    }

    return list.toOwnedSlice(allocator);
}

test "buildLaunchArgs appends verbose flag when enabled" {
    const allocator = std.testing.allocator;
    const args = try buildLaunchArgs(allocator, "gateway", true);
    defer allocator.free(args);

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("gateway", args[0]);
    try std.testing.expectEqualStrings("--verbose", args[1]);
}

test "buildLaunchArgs preserves tokenized launch mode when verbose disabled" {
    const allocator = std.testing.allocator;
    const args = try buildLaunchArgs(allocator, "agent --foo bar", false);
    defer allocator.free(args);

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("agent", args[0]);
    try std.testing.expectEqualStrings("--foo", args[1]);
    try std.testing.expectEqualStrings("bar", args[2]);
}
