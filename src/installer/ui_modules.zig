const std = @import("std");
const registry = @import("registry.zig");
const downloader = @import("downloader.zig");

// ─── Errors ──────────────────────────────────────────────────────────────────

pub const UiModuleError = error{
    ExtractionFailed,
    AssetNotFound,
};

// ─── URL building ────────────────────────────────────────────────────────────

/// Build the download URL for a UI module bundle asset from a GitHub release.
/// The asset name follows the convention `{module-name}-bundle.tar.gz`.
/// Caller owns the returned memory.
pub fn buildBundleAssetUrl(
    allocator: std.mem.Allocator,
    repo: []const u8,
    version: []const u8,
    module_name: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "https://github.com/{s}/releases/download/{s}/{s}-bundle.tar.gz",
        .{ repo, version, module_name },
    );
}

// ─── Extraction ──────────────────────────────────────────────────────────────

/// Extract a `.tar.gz` archive to the specified destination directory.
///
/// Creates `dest_dir` if it does not already exist, then runs
/// `tar -xzf {archive_path} -C {dest_dir}` as a subprocess.
pub fn extractTarGz(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    // Create dest_dir if it doesn't exist.
    std.fs.makeDirAbsolute(dest_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            // Parent directory missing — create the full path.
            if (std.fs.path.dirnamePosix(dest_dir)) |parent| {
                try std.fs.makeDirAbsolute(parent);
                try std.fs.makeDirAbsolute(dest_dir);
            } else {
                return err;
            }
        },
        else => return err,
    };

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xzf", archive_path, "-C", dest_dir },
    }) catch return error.ExtractionFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.ExtractionFailed;
        },
        else => return error.ExtractionFailed,
    }
}

// ─── Module status ───────────────────────────────────────────────────────────

/// Check whether a UI module is installed at the given directory.
///
/// Returns `true` if `dest_dir` exists and is accessible as a directory.
pub fn isModuleInstalled(dest_dir: []const u8) bool {
    var dir = std.fs.openDirAbsolute(dest_dir, .{}) catch return false;
    dir.close();
    return true;
}

// ─── Download ────────────────────────────────────────────────────────────────

/// Download and extract a UI module bundle.
///
/// 1. Builds the GitHub release download URL for the module's tarball.
/// 2. Downloads the tarball to a temporary path under `dest_dir`.
/// 3. Extracts the tarball into `dest_dir`.
/// 4. Removes the temporary tarball after extraction.
pub fn downloadUiModule(
    allocator: std.mem.Allocator,
    repo: []const u8,
    module_name: []const u8,
    version: []const u8,
    dest_dir: []const u8,
) !void {
    const url = try buildBundleAssetUrl(allocator, repo, version, module_name);
    defer allocator.free(url);

    // Ensure dest_dir exists before downloading into it.
    std.fs.makeDirAbsolute(dest_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            if (std.fs.path.dirnamePosix(dest_dir)) |parent| {
                try std.fs.makeDirAbsolute(parent);
                try std.fs.makeDirAbsolute(dest_dir);
            } else {
                return err;
            }
        },
        else => return err,
    };

    const archive_path = try std.fmt.allocPrint(allocator, "{s}/{s}-bundle.tar.gz", .{ dest_dir, module_name });
    defer allocator.free(archive_path);

    try downloader.download(allocator, url, archive_path);
    defer std.fs.deleteFileAbsolute(archive_path) catch {};

    try extractTarGz(allocator, archive_path, dest_dir);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "buildBundleAssetUrl produces correct URL" {
    const allocator = std.testing.allocator;
    const url = try buildBundleAssetUrl(allocator, "nullclaw/chat-ui", "v1.2.0", "chat-ui");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://github.com/nullclaw/chat-ui/releases/download/v1.2.0/chat-ui-bundle.tar.gz",
        url,
    );
}

test "buildBundleAssetUrl with different module" {
    const allocator = std.testing.allocator;
    const url = try buildBundleAssetUrl(allocator, "nullclaw/dashboard", "v3.0.0", "dashboard");
    defer allocator.free(url);
    try std.testing.expectEqualStrings(
        "https://github.com/nullclaw/dashboard/releases/download/v3.0.0/dashboard-bundle.tar.gz",
        url,
    );
}

test "extractTarGz creates dest_dir and extracts contents" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/test-nullhub-ui-extract";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create a test file to put in the tarball.
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp_dir});
    defer allocator.free(src_dir);
    try std.fs.makeDirAbsolute(src_dir);

    const test_file = try std.fmt.allocPrint(allocator, "{s}/index.html", .{src_dir});
    defer allocator.free(test_file);
    {
        var file = try std.fs.createFileAbsolute(test_file, .{});
        defer file.close();
        try file.writeAll("<html><body>Hello</body></html>");
    }

    // Create a tarball from the source directory.
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/test-bundle.tar.gz", .{tmp_dir});
    defer allocator.free(archive_path);

    const tar_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-czf", archive_path, "-C", src_dir, "." },
    }) catch return;
    defer allocator.free(tar_result.stdout);
    defer allocator.free(tar_result.stderr);

    // Extract to a new directory.
    const dest_dir = try std.fmt.allocPrint(allocator, "{s}/extracted", .{tmp_dir});
    defer allocator.free(dest_dir);

    try extractTarGz(allocator, archive_path, dest_dir);

    // Verify the extracted file exists with correct content.
    const extracted_file = try std.fmt.allocPrint(allocator, "{s}/index.html", .{dest_dir});
    defer allocator.free(extracted_file);

    var file = try std.fs.openFileAbsolute(extracted_file, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("<html><body>Hello</body></html>", buf[0..n]);
}

test "isModuleInstalled returns true for existing directory" {
    const tmp_dir = "/tmp/test-nullhub-ui-installed";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    try std.testing.expect(isModuleInstalled(tmp_dir));
}

test "isModuleInstalled returns false for non-existing directory" {
    try std.testing.expect(!isModuleInstalled("/tmp/test-nullhub-ui-nonexistent-dir-xyz"));
}
