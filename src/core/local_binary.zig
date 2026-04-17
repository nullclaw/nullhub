const std = @import("std");
const std_compat = @import("compat");

/// Best-effort discovery of a locally built component binary in nearby
/// workspaces. Useful for development when GitHub releases are unavailable.
pub fn find(allocator: std.mem.Allocator, component: []const u8) ?[]const u8 {
    const cwd = std_compat.fs.cwd().realpathAlloc(allocator, ".") catch return null;
    defer allocator.free(cwd);

    const candidates = [_][]const []const u8{
        &.{ cwd, "zig-out", "bin", component },
        &.{ cwd, component, "zig-out", "bin", component },
        &.{ cwd, "..", component, "zig-out", "bin", component },
    };

    for (candidates) |parts| {
        const path = std.fs.path.join(allocator, parts) catch continue;
        if (std_compat.fs.openFileAbsolute(path, .{})) |f| {
            f.close();
            return path;
        } else |_| {
            allocator.free(path);
        }
    }

    return null;
}

test "find returns null when component binary is missing" {
    const result = find(std.testing.allocator, "definitely-not-a-real-component-12345");
    try std.testing.expect(result == null);
}
