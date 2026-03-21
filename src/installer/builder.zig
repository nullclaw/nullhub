const std = @import("std");
const manifest = @import("../core/manifest.zig");
const paths_mod = @import("../core/paths.zig");

// ─── Errors ──────────────────────────────────────────────────────────────────

pub const BuildError = error{
    ZigNotFound,
    ZigVersionMismatch,
    GitNotFound,
    CloneFailed,
    BuildFailed,
    OutputNotFound,
};

// ─── Zig detection ───────────────────────────────────────────────────────────

/// Detect the installed Zig version by running `zig version`.
/// Returns the trimmed version string or null if Zig is not found.
/// Caller owns the returned memory.
pub fn detectZig(allocator: std.mem.Allocator) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "zig", "version" },
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    const trimmed = std.mem.trim(u8, result.stdout, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        allocator.free(result.stdout);
        return null;
    }

    // Return the original stdout buffer — caller must free it.
    // The trimmed slice points into result.stdout, but since the caller
    // needs a standalone copy, duplicate the trimmed portion.
    const version = allocator.dupe(u8, trimmed) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return version;
}

/// Check whether the installed Zig version is compatible with `required_version`.
/// Uses simple prefix matching: e.g. required "0.15" matches installed "0.15.2".
pub fn checkZigVersion(allocator: std.mem.Allocator, required_version: []const u8) !bool {
    const installed = detectZig(allocator) orelse return false;
    defer allocator.free(installed);
    return std.mem.startsWith(u8, installed, required_version);
}

// ─── Git clone ───────────────────────────────────────────────────────────────

/// Clone a git repository with `--depth 1` into `dest_dir`.
pub fn cloneRepo(allocator: std.mem.Allocator, repo_url: []const u8, dest_dir: []const u8) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "clone", "--depth", "1", repo_url, dest_dir },
    }) catch return error.GitNotFound;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.CloneFailed;
        },
        else => return error.CloneFailed,
    }
}

// ─── Build from source ───────────────────────────────────────────────────────

/// Build a component from source.
///
/// 1. Clones the repository into a temporary directory.
/// 2. Runs the build command inside the cloned directory.
/// 3. Copies the output binary to `dest_path`.
/// 4. Sets executable permissions on the result.
/// 5. Cleans up the temporary directory.
pub fn buildFromSource(
    allocator: std.mem.Allocator,
    repo_url: []const u8,
    build_spec: manifest.BuildFromSource,
    dest_path: []const u8,
) !void {
    // Create a temporary directory for the clone.
    const tmp_dir = try paths_mod.uniqueTempPathAlloc(allocator, "nullhub-build", "");
    defer allocator.free(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Clone the repo.
    try cloneRepo(allocator, repo_url, tmp_dir);

    // Split the build command by spaces and run it in the cloned dir.
    var argv_list = std.ArrayList([]const u8).init(allocator);
    defer argv_list.deinit();

    var iter = std.mem.splitScalar(u8, build_spec.command, ' ');
    while (iter.next()) |arg| {
        if (arg.len > 0) {
            try argv_list.append(arg);
        }
    }

    const tmp_dir_z = try allocator.dupeZ(u8, tmp_dir);
    defer allocator.free(tmp_dir_z);

    const build_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv_list.items,
        .cwd = tmp_dir_z,
    }) catch return error.BuildFailed;
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    switch (build_result.term) {
        .Exited => |code| {
            if (code != 0) return error.BuildFailed;
        },
        else => return error.BuildFailed,
    }

    // Copy output binary to dest_path.
    const output_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ tmp_dir, build_spec.output });
    defer allocator.free(output_path);

    // Ensure parent directory of dest_path exists.
    if (std.fs.path.dirnamePosix(dest_path)) |parent| {
        std.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    std.fs.copyFileAbsolute(output_path, dest_path, .{}) catch return error.OutputNotFound;

    if (comptime std.fs.has_executable_bit) {
        // Set executable permission (rwxr-xr-x) on platforms that support it.
        const dest_path_z = try allocator.dupeZ(u8, dest_path);
        defer allocator.free(dest_path_z);
        std.posix.chmod(dest_path_z, 0o755) catch {};
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "detectZig returns a version string" {
    const allocator = std.testing.allocator;
    const version = detectZig(allocator);
    try std.testing.expect(version != null);
    // We know zig is installed since we're building with it.
    try std.testing.expect(version.?.len > 0);
    allocator.free(version.?);
}

test "checkZigVersion returns true for 0.15" {
    const allocator = std.testing.allocator;
    const compatible = try checkZigVersion(allocator, "0.15");
    try std.testing.expect(compatible);
}

test "checkZigVersion returns false for 999.0" {
    const allocator = std.testing.allocator;
    const compatible = try checkZigVersion(allocator, "999.0");
    try std.testing.expect(!compatible);
}

test "cloneRepo with invalid URL returns error" {
    const allocator = std.testing.allocator;
    const result = cloneRepo(allocator, "https://invalid.example.com/nonexistent/repo.git", "/tmp/nullhub-test-clone-invalid");
    defer std.fs.deleteTreeAbsolute("/tmp/nullhub-test-clone-invalid") catch {};
    try std.testing.expectError(error.CloneFailed, result);
}
