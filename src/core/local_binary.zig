const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const paths_mod = @import("paths.zig");

pub const dev_local_version = "dev-local";

pub fn isDevLocal(version: []const u8) bool {
    return std.mem.eql(u8, version, dev_local_version);
}

/// Best-effort discovery of a locally built component binary in nearby
/// workspaces. Useful for development when GitHub releases are unavailable.
pub fn find(allocator: std.mem.Allocator, component: []const u8) ?[]const u8 {
    const cwd = std_compat.fs.cwd().realpathAlloc(allocator, ".") catch return null;
    defer allocator.free(cwd);

    const native_name = if (builtin.os.tag == .windows)
        std.fmt.allocPrint(allocator, "{s}-native.exe", .{component}) catch return null
    else
        std.fmt.allocPrint(allocator, "{s}-native", .{component}) catch return null;
    defer allocator.free(native_name);
    const component_name = if (builtin.os.tag == .windows)
        std.fmt.allocPrint(allocator, "{s}.exe", .{component}) catch return null
    else
        allocator.dupe(u8, component) catch return null;
    defer allocator.free(component_name);

    const candidate_dirs = [_][]const []const u8{
        &.{ cwd, "zig-out", "bin" },
        &.{ cwd, component, "zig-out", "bin" },
        &.{ cwd, "..", component, "zig-out", "bin" },
    };
    const candidate_names = [_][]const u8{ native_name, component_name };

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

/// Stage the current local build at NullHub's canonical dev-local binary path.
/// Returns the owned staged path on success.
pub fn stageDevLocal(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8) ?[]const u8 {
    if (builtin.is_test) return null;

    const src_path = find(allocator, component) orelse return null;
    defer allocator.free(src_path);

    const dest_path = paths.binary(allocator, component, dev_local_version) catch return null;
    installExecutable(src_path, dest_path) catch {
        allocator.free(dest_path);
        return null;
    };
    return dest_path;
}

/// Refresh an existing dev-local stage before launching. Best-effort by design:
/// release and standalone versions must not fail to start just because no local
/// development binary is present.
pub fn refreshStagedDevLocal(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8, version: []const u8) void {
    if (!isDevLocal(version)) return;
    const staged_path = stageDevLocal(allocator, paths, component) orelse return;
    allocator.free(staged_path);
}

fn installExecutable(src_path: []const u8, dest_path: []const u8) !void {
    std_compat.fs.deleteFileAbsolute(dest_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try std_compat.fs.copyFileAbsolute(src_path, dest_path, .{});
    if (comptime std_compat.fs.has_executable_bit) {
        if (std_compat.fs.openFileAbsolute(dest_path, .{ .mode = .read_only })) |file| {
            defer file.close();
            file.chmod(0o755) catch {};
        } else |_| {}
    }
}

test "find returns null when component binary is missing" {
    const result = find(std.testing.allocator, "definitely-not-a-real-component-12345");
    try std.testing.expect(result == null);
}

test "isDevLocal recognizes only the dev-local version" {
    try std.testing.expect(isDevLocal(dev_local_version));
    try std.testing.expect(!isDevLocal("v1.2.3"));
}
