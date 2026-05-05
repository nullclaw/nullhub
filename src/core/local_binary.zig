const std = @import("std");
const std_compat = @import("compat");

/// Best-effort discovery of a locally built component binary in nearby
/// workspaces. Useful for development when GitHub releases are unavailable.
pub fn find(allocator: std.mem.Allocator, component: []const u8) ?[]const u8 {
    const cwd = std_compat.fs.cwd().realpathAlloc(allocator, ".") catch return null;
    defer allocator.free(cwd);

    const native_name = std.fmt.allocPrint(allocator, "{s}-native", .{component}) catch return null;
    defer allocator.free(native_name);

    const candidate_dirs = [_][]const []const u8{
        &.{ cwd, "zig-out", "bin" },
        &.{ cwd, component, "zig-out", "bin" },
        &.{ cwd, "..", component, "zig-out", "bin" },
    };
    const candidate_names = [_][]const u8{ native_name, component };

    for (candidate_dirs) |parts| {
        const dir_path = std.fs.path.join(allocator, parts) catch continue;
        defer allocator.free(dir_path);

        for (candidate_names) |name| {
            const path = std.fs.path.join(allocator, &.{ dir_path, name }) catch continue;
            if (std_compat.fs.openFileAbsolute(path, .{})) |f| {
                f.close();
                return path;
            } else |_| {
                allocator.free(path);
            }
        }
    }

    return null;
}

test "find returns null when component binary is missing" {
    const result = find(std.testing.allocator, "definitely-not-a-real-component-12345");
    try std.testing.expect(result == null);
}
