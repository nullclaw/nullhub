const std = @import("std");
const std_compat = @import("compat");
const registry = @import("registry.zig");
const downloader = @import("downloader.zig");
const prereqs = @import("prereqs.zig");
const fs_compat = @import("../fs_compat.zig");

// ─── Errors ──────────────────────────────────────────────────────────────────

pub const UiModuleError = error{
    ExtractionFailed,
    AssetNotFound,
};

fn findUiModuleArchiveAsset(
    allocator: std.mem.Allocator,
    release: registry.ReleaseInfo,
    module_name: []const u8,
) ?registry.AssetInfo {
    const preferred_bundle = std.fmt.allocPrint(allocator, "{s}-bundle.tar.gz", .{module_name}) catch return null;
    defer allocator.free(preferred_bundle);
    if (registry.findAssetByName(release, preferred_bundle)) |asset| return asset;

    const release_archive = std.fmt.allocPrint(allocator, "{s}-{s}.tar.gz", .{ module_name, release.tag_name }) catch return null;
    defer allocator.free(release_archive);
    if (registry.findAssetByName(release, release_archive)) |asset| return asset;

    for (release.assets) |asset| {
        if (isUiModuleArchiveAssetName(asset.name, module_name)) {
            return asset;
        }
    }

    return null;
}

fn isUiModuleArchiveAssetName(asset_name: []const u8, module_name: []const u8) bool {
    if (!std.mem.startsWith(u8, asset_name, module_name)) return false;
    if (!std.mem.endsWith(u8, asset_name, ".tar.gz")) return false;

    const suffix = asset_name[module_name.len..];
    return std.mem.eql(u8, suffix, ".tar.gz") or std.mem.startsWith(u8, suffix, "-");
}

// ─── Extraction ──────────────────────────────────────────────────────────────

/// Extract a `.tar.gz` archive to the specified destination directory.
///
/// Creates `dest_dir` if it does not already exist, then runs
/// `tar -xzf {archive_path} -C {dest_dir}` as a subprocess.
pub fn extractTarGz(allocator: std.mem.Allocator, archive_path: []const u8, dest_dir: []const u8) !void {
    prereqs.ensureTool(allocator, "tar") catch return error.ExtractionFailed;

    try fs_compat.makePath(dest_dir);

    const result = std_compat.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-xzf", archive_path, "-C", dest_dir },
    }) catch return error.ExtractionFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) return error.ExtractionFailed;
        },
        else => return error.ExtractionFailed,
    }
}

// ─── Module status ───────────────────────────────────────────────────────────

/// Check whether a UI module entrypoint is installed at the given directory.
///
/// Returns `true` only when `module.js` exists where the frontend imports it.
pub fn isModuleInstalled(dest_dir: []const u8) bool {
    var dir = std_compat.fs.openDirAbsolute(dest_dir, .{}) catch return false;
    defer dir.close();

    const file = dir.openFile("module.js", .{}) catch return false;
    file.close();
    return true;
}

fn resolveExtractedModuleRoot(allocator: std.mem.Allocator, extract_dir: []const u8) ![]const u8 {
    var dir = try std_compat.fs.openDirAbsolute(extract_dir, .{ .iterate = true });
    defer dir.close();

    var it = dir.iterate();
    var entry_count: usize = 0;
    var single_dir_name: ?[]u8 = null;
    defer if (single_dir_name) |name| allocator.free(name);

    while (try it.next()) |entry| {
        entry_count += 1;
        if (entry_count != 1 or entry.kind != .directory) continue;
        single_dir_name = try allocator.dupe(u8, entry.name);
    }

    if (entry_count == 1 and single_dir_name != null) {
        return std.fs.path.join(allocator, &.{ extract_dir, single_dir_name.? });
    }
    return allocator.dupe(u8, extract_dir);
}

fn installExtractedUiModule(allocator: std.mem.Allocator, extract_dir: []const u8, dest_dir: []const u8) !void {
    const source_root = try resolveExtractedModuleRoot(allocator, extract_dir);
    defer allocator.free(source_root);

    try fs_compat.copyDirectoryContents(allocator, source_root, dest_dir);
}

// ─── Download ────────────────────────────────────────────────────────────────

/// Download and extract a UI module release archive.
///
/// 1. Resolves GitHub release metadata for `version`.
/// 2. Selects a compatible `.tar.gz` release asset.
/// 3. Downloads the tarball to a temporary path next to `dest_dir`.
/// 4. Extracts and normalizes the archive layout into `dest_dir`.
pub fn downloadUiModule(
    allocator: std.mem.Allocator,
    repo: []const u8,
    module_name: []const u8,
    version: []const u8,
    dest_dir: []const u8,
) !void {
    var release = if (std.mem.eql(u8, version, "latest"))
        try registry.fetchLatestRelease(allocator, repo)
    else
        try registry.fetchReleaseByTag(allocator, repo, version);
    defer release.deinit();

    const asset = findUiModuleArchiveAsset(allocator, release.value, module_name) orelse return error.AssetNotFound;

    std_compat.fs.deleteTreeAbsolute(dest_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try fs_compat.makePath(dest_dir);

    const archive_path = try std.fmt.allocPrint(allocator, "{s}.download.tar.gz", .{dest_dir});
    defer allocator.free(archive_path);

    try downloader.download(allocator, asset.browser_download_url, archive_path);
    defer std_compat.fs.deleteFileAbsolute(archive_path) catch {};

    const extract_dir = try std.fmt.allocPrint(allocator, "{s}.extract", .{dest_dir});
    defer allocator.free(extract_dir);
    std_compat.fs.deleteTreeAbsolute(extract_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std_compat.fs.deleteTreeAbsolute(extract_dir) catch {};

    try extractTarGz(allocator, archive_path, extract_dir);
    try installExtractedUiModule(allocator, extract_dir, dest_dir);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "findUiModuleArchiveAsset prefers bundle asset" {
    const allocator = std.testing.allocator;
    const release = registry.ReleaseInfo{
        .tag_name = "v2026.3.4",
        .assets = &.{
            .{ .name = "nullclaw-chat-ui-v2026.3.4.tar.gz", .browser_download_url = "https://example.com/release.tar.gz" },
            .{ .name = "nullclaw-chat-ui-bundle.tar.gz", .browser_download_url = "https://example.com/bundle.tar.gz" },
        },
    };

    const asset = findUiModuleArchiveAsset(allocator, release, "nullclaw-chat-ui") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("nullclaw-chat-ui-bundle.tar.gz", asset.name);
}

test "findUiModuleArchiveAsset falls back to versioned release tarball" {
    const allocator = std.testing.allocator;
    const release = registry.ReleaseInfo{
        .tag_name = "v2026.3.4",
        .assets = &.{
            .{ .name = "nullclaw-chat-ui-v2026.3.4.tar.gz", .browser_download_url = "https://example.com/release.tar.gz" },
            .{ .name = "nullclaw-chat-ui-v2026.3.4.zip", .browser_download_url = "https://example.com/release.zip" },
        },
    };

    const asset = findUiModuleArchiveAsset(allocator, release, "nullclaw-chat-ui") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("nullclaw-chat-ui-v2026.3.4.tar.gz", asset.name);
}

test "findUiModuleArchiveAsset does not match a different module prefix" {
    const allocator = std.testing.allocator;
    const release = registry.ReleaseInfo{
        .tag_name = "v2026.3.4",
        .assets = &.{
            .{ .name = "nullclaw-chat-uikit-v2026.3.4.tar.gz", .browser_download_url = "https://example.com/uikit.tar.gz" },
        },
    };

    try std.testing.expect(findUiModuleArchiveAsset(allocator, release, "nullclaw-chat-ui") == null);
}

test "extractTarGz creates dest_dir and extracts contents" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/test-nullhub-ui-extract";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    // Create a test file to put in the tarball.
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{tmp_dir});
    defer allocator.free(src_dir);
    try std_compat.fs.makeDirAbsolute(src_dir);

    const test_file = try std.fmt.allocPrint(allocator, "{s}/index.html", .{src_dir});
    defer allocator.free(test_file);
    {
        var file = try std_compat.fs.createFileAbsolute(test_file, .{});
        defer file.close();
        try file.writeAll("<html><body>Hello</body></html>");
    }

    // Create a tarball from the source directory.
    const archive_path = try std.fmt.allocPrint(allocator, "{s}/test-bundle.tar.gz", .{tmp_dir});
    defer allocator.free(archive_path);

    const tar_result = std_compat.process.Child.run(.{
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

    var file = try std_compat.fs.openFileAbsolute(extracted_file, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("<html><body>Hello</body></html>", buf[0..n]);
}

test "installExtractedUiModule flattens single top-level archive directory" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/test-nullhub-ui-install-extracted";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const extract_dir = try std.fmt.allocPrint(allocator, "{s}/extract", .{tmp_dir});
    defer allocator.free(extract_dir);
    const nested_dir = try std.fmt.allocPrint(allocator, "{s}/nullclaw-chat-ui", .{extract_dir});
    defer allocator.free(nested_dir);
    const dest_dir = try std.fmt.allocPrint(allocator, "{s}/dest", .{tmp_dir});
    defer allocator.free(dest_dir);

    try std_compat.fs.makeDirAbsolute(nested_dir);
    try std_compat.fs.makeDirAbsolute(dest_dir);

    const module_path = try std.fmt.allocPrint(allocator, "{s}/module.js", .{nested_dir});
    defer allocator.free(module_path);
    {
        var file = try std_compat.fs.createFileAbsolute(module_path, .{});
        defer file.close();
        try file.writeAll("export const ok = true;\n");
    }

    try installExtractedUiModule(allocator, extract_dir, dest_dir);

    const installed_path = try std.fmt.allocPrint(allocator, "{s}/module.js", .{dest_dir});
    defer allocator.free(installed_path);
    var file = try std_compat.fs.openFileAbsolute(installed_path, .{});
    defer file.close();
    var buf: [64]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("export const ok = true;\n", buf[0..n]);
}

test "isModuleInstalled returns true when module entrypoint exists" {
    const tmp_dir = "/tmp/test-nullhub-ui-installed";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const module_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/module.js", .{tmp_dir});
    defer std.testing.allocator.free(module_path);
    {
        var file = try std_compat.fs.createFileAbsolute(module_path, .{});
        defer file.close();
        try file.writeAll("export {};\n");
    }

    try std.testing.expect(isModuleInstalled(tmp_dir));
}

test "isModuleInstalled returns false without module entrypoint" {
    const tmp_dir = "/tmp/test-nullhub-ui-installed-no-entrypoint";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    try std.testing.expect(!isModuleInstalled(tmp_dir));
}

test "isModuleInstalled returns false for non-existing directory" {
    try std.testing.expect(!isModuleInstalled("/tmp/test-nullhub-ui-nonexistent-dir-xyz"));
}
