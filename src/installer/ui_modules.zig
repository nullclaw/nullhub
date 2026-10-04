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
    StagingIncomplete,
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

/// True when **any** installed version of `module_name` under `ui_dir` has a
/// `module.js` entrypoint.
///
/// Startup runs two passes over the same components (local build, then release
/// download); this is the skip predicate that keeps the second pass from
/// rebuilding or re-downloading a module the first pass already produced.
pub fn isModuleInstalledAnywhere(
    allocator: std.mem.Allocator,
    ui_dir: []const u8,
    module_name: []const u8,
) bool {
    var dir = std_compat.fs.openDirAbsolute(ui_dir, .{ .iterate = true }) catch return false;
    defer dir.close();

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .directory) continue;
        const at = std.mem.indexOfScalar(u8, entry.name, '@') orelse continue;
        if (!std.mem.eql(u8, entry.name[0..at], module_name)) continue;

        const child = std.fs.path.join(allocator, &.{ ui_dir, entry.name }) catch continue;
        defer allocator.free(child);
        if (isModuleInstalled(child)) return true;
    }
    return false;
}

/// True when **any** installed version of `module_name` under `{root}/ui` has
/// a `module.js` entrypoint.
///
/// This is the skip predicate that keeps the two startup passes — local build
/// (`syncLocalUiModules`) and release download (`syncMissingUiModules`) — from
/// building or fetching the same module twice. Lives here rather than in the
/// orchestrator so it is reachable from the wired unit-test root (#88).
pub fn isInstalledUnderRoot(allocator: std.mem.Allocator, root: []const u8, module_name: []const u8) bool {
    const ui_dir = std.fs.path.join(allocator, &.{ root, "ui" }) catch return false;
    defer allocator.free(ui_dir);
    return isModuleInstalledAnywhere(allocator, ui_dir, module_name);
}

/// Clear and return the staging directory for `dest_dir`.
///
/// Deliberately touches **only** staging: the live `dest_dir` is never removed
/// here, so a build or download that fails afterwards cannot take down a
/// working module. (The previous implementation deleted `dest_dir` first.)
pub fn prepareStaging(allocator: std.mem.Allocator, dest_dir: []const u8) ![]u8 {
    const staging = try stagingPathFor(allocator, dest_dir);
    errdefer allocator.free(staging);

    std_compat.fs.deleteTreeAbsolute(staging) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    return staging;
}

/// `{ui_dir}/.{basename}{suffix}` — a dot-prefixed sibling of `dest_dir`.
///
/// Dot-prefixing matters: version enumeration and uninstall both split the
/// directory name at `@` and compare the prefix to the module name, so
/// `.nullclaw-chat-ui@latest.staging` is invisible to them while
/// `nullclaw-chat-ui@latest.staging` would be mistaken for a version.
fn siblingPath(allocator: std.mem.Allocator, dest_dir: []const u8, suffix: []const u8) ![]u8 {
    const parent = std.fs.path.dirname(dest_dir) orelse return error.FileNotFound;
    const base = std.fs.path.basename(dest_dir);
    return std.fmt.allocPrint(allocator, "{s}/.{s}{s}", .{ parent, base, suffix });
}

/// Staging directory used while building `dest_dir`.
pub fn stagingPathFor(allocator: std.mem.Allocator, dest_dir: []const u8) ![]u8 {
    return siblingPath(allocator, dest_dir, ".staging");
}

/// Promote a fully built `staging_dir` over `dest_dir`.
///
/// Refuses to touch `dest_dir` unless staging contains `module.js`, so a failed
/// or partial build/download can never destroy an already working module. The
/// old directory is moved aside first and restored if the rename fails.
pub fn promoteStagedModule(allocator: std.mem.Allocator, staging_dir: []const u8, dest_dir: []const u8) !void {
    if (!isModuleInstalled(staging_dir)) return error.StagingIncomplete;

    if (std.fs.path.dirname(dest_dir)) |parent| {
        fs_compat.makePath(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const previous = try siblingPath(allocator, dest_dir, ".previous");
    defer allocator.free(previous);
    std_compat.fs.deleteTreeAbsolute(previous) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const dest_existed = blk: {
        var existing = std_compat.fs.openDirAbsolute(dest_dir, .{}) catch break :blk false;
        existing.close();
        break :blk true;
    };
    if (dest_existed) try std_compat.fs.renameAbsolute(dest_dir, previous);

    std_compat.fs.renameAbsolute(staging_dir, dest_dir) catch |err| {
        // Put the working module back before surfacing the failure.
        if (dest_existed) std_compat.fs.renameAbsolute(previous, dest_dir) catch {};
        return err;
    };

    if (dest_existed) std_compat.fs.deleteTreeAbsolute(previous) catch {};
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
/// 4. Extracts and normalizes the archive layout into a staging directory.
/// 5. Promotes staging over `dest_dir` only once staging is complete, so a
///    failed download or extract never removes an already working module.
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

    // Build in staging; `dest_dir` is only replaced after staging holds a
    // complete module.js (promoteStagedModule enforces that).
    const staging = try stagingPathFor(allocator, dest_dir);
    defer allocator.free(staging);

    std_compat.fs.deleteTreeAbsolute(staging) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    try fs_compat.makePath(staging);

    const archive_path = try std.fmt.allocPrint(allocator, "{s}.download.tar.gz", .{staging});
    defer allocator.free(archive_path);

    try downloader.download(allocator, asset.browser_download_url, archive_path);
    defer std_compat.fs.deleteFileAbsolute(archive_path) catch {};

    const extract_dir = try std.fmt.allocPrint(allocator, "{s}.extract", .{staging});
    defer allocator.free(extract_dir);
    std_compat.fs.deleteTreeAbsolute(extract_dir) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    defer std_compat.fs.deleteTreeAbsolute(extract_dir) catch {};

    try extractTarGz(allocator, archive_path, extract_dir);
    try installExtractedUiModule(allocator, extract_dir, staging);
    try promoteStagedModule(allocator, staging, dest_dir);
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

    // A per-test scratch dir: hardcoded /tmp paths do not exist on Windows.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_dir);

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

    // Building the fixture needs a working `tar`. Its CLI differs across
    // environments (GNU tar vs the bsdtar shipped with Windows), so an
    // unusable archive tool is a skip rather than a failure — otherwise the
    // extraction assertion below would fail on the fixture, not the code.
    const tar_result = std_compat.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tar", "-czf", archive_path, "-C", src_dir, "." },
    }) catch return error.SkipZigTest;
    defer allocator.free(tar_result.stdout);
    defer allocator.free(tar_result.stderr);

    switch (tar_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("tar -czf unavailable here (exit {d}): {s}\n", .{ code, tar_result.stderr });
            return error.SkipZigTest;
        },
        else => return error.SkipZigTest,
    }

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

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_dir);

    const extract_dir = try std.fmt.allocPrint(allocator, "{s}/extract", .{tmp_dir});
    defer allocator.free(extract_dir);
    const nested_dir = try std.fmt.allocPrint(allocator, "{s}/nullclaw-chat-ui", .{extract_dir});
    defer allocator.free(nested_dir);
    const dest_dir = try std.fmt.allocPrint(allocator, "{s}/dest", .{tmp_dir});
    defer allocator.free(dest_dir);

    // `nested_dir` lives under `extract_dir`, which does not exist yet.
    try fs_compat.makePath(nested_dir);
    try fs_compat.makePath(dest_dir);

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
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_dir);

    const module_path = try std.fmt.allocPrint(allocator, "{s}/module.js", .{tmp_dir});
    defer allocator.free(module_path);
    {
        var file = try std_compat.fs.createFileAbsolute(module_path, .{});
        defer file.close();
        try file.writeAll("export {};\n");
    }

    try std.testing.expect(isModuleInstalled(tmp_dir));
}

test "isModuleInstalled returns false without module entrypoint" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(tmp_dir);

    try std.testing.expect(!isModuleInstalled(tmp_dir));
}

test "isModuleInstalled returns false for non-existing directory" {
    try std.testing.expect(!isModuleInstalled("/tmp/test-nullhub-ui-nonexistent-dir-xyz"));
}

// ─── Staging / promotion tests ───────────────────────────────────────────────

fn testWriteFile(path: []const u8, contents: []const u8) !void {
    const file = try std_compat.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(contents);
}

fn testReadFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const file = try std_compat.fs.openFileAbsolute(path, .{});
    defer file.close();
    return file.readToEndAlloc(allocator, 4096);
}

fn testDirExists(path: []const u8) bool {
    var dir = std_compat.fs.openDirAbsolute(path, .{}) catch return false;
    dir.close();
    return true;
}

test "promoteStagedModule installs a complete staging directory" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const dest = try std.fs.path.join(allocator, &.{ root, "mod@v1" });
    defer allocator.free(dest);
    const staging = try stagingPathFor(allocator, dest);
    defer allocator.free(staging);

    try fs_compat.makePath(staging);
    const staged_entry = try std.fs.path.join(allocator, &.{ staging, "module.js" });
    defer allocator.free(staged_entry);
    try testWriteFile(staged_entry, "new");

    try promoteStagedModule(allocator, staging, dest);
    try std.testing.expect(isModuleInstalled(dest));
    try std.testing.expect(!testDirExists(staging));
}

test "promoteStagedModule refuses incomplete staging and leaves dest untouched" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const dest = try std.fs.path.join(allocator, &.{ root, "mod@v1" });
    defer allocator.free(dest);
    const staging = try stagingPathFor(allocator, dest);
    defer allocator.free(staging);

    // A working install already exists…
    try fs_compat.makePath(dest);
    const dest_entry = try std.fs.path.join(allocator, &.{ dest, "module.js" });
    defer allocator.free(dest_entry);
    try testWriteFile(dest_entry, "working");

    // …and staging is a partial/failed build with no entrypoint.
    try fs_compat.makePath(staging);
    const partial = try std.fs.path.join(allocator, &.{ staging, "partial.txt" });
    defer allocator.free(partial);
    try testWriteFile(partial, "incomplete");

    try std.testing.expectError(error.StagingIncomplete, promoteStagedModule(allocator, staging, dest));

    // The working module was not removed.
    try std.testing.expect(isModuleInstalled(dest));
    const contents = try testReadFile(allocator, dest_entry);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("working", contents);
}

test "promoteStagedModule replaces an existing install only on success" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const dest = try std.fs.path.join(allocator, &.{ root, "mod@v1" });
    defer allocator.free(dest);
    const staging = try stagingPathFor(allocator, dest);
    defer allocator.free(staging);

    try fs_compat.makePath(dest);
    const old_entry = try std.fs.path.join(allocator, &.{ dest, "module.js" });
    defer allocator.free(old_entry);
    try testWriteFile(old_entry, "old");

    try fs_compat.makePath(staging);
    const new_entry = try std.fs.path.join(allocator, &.{ staging, "module.js" });
    defer allocator.free(new_entry);
    try testWriteFile(new_entry, "new");

    try promoteStagedModule(allocator, staging, dest);

    const contents = try testReadFile(allocator, old_entry);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("new", contents);

    // No leftover backup directory.
    const previous = try siblingPath(allocator, dest, ".previous");
    defer allocator.free(previous);
    try std.testing.expect(!testDirExists(previous));
}

test "isModuleInstalledAnywhere matches the module name without prefix bleed" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const ui_dir = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(ui_dir);

    for ([_][]const u8{ "moda@v1", "modb@v2" }) |entry_name| {
        const dir_path = try std.fs.path.join(allocator, &.{ ui_dir, entry_name });
        defer allocator.free(dir_path);
        try fs_compat.makePath(dir_path);
        const entry = try std.fs.path.join(allocator, &.{ dir_path, "module.js" });
        defer allocator.free(entry);
        try testWriteFile(entry, "x");
    }

    try std.testing.expect(isModuleInstalledAnywhere(allocator, ui_dir, "moda"));
    try std.testing.expect(isModuleInstalledAnywhere(allocator, ui_dir, "modb"));
    try std.testing.expect(!isModuleInstalledAnywhere(allocator, ui_dir, "modc"));
    // "mod" is a prefix of "moda" but is a different module.
    try std.testing.expect(!isModuleInstalledAnywhere(allocator, ui_dir, "mod"));
    // A directory without a module.js does not count as installed.
    const empty = try std.fs.path.join(allocator, &.{ ui_dir, "modd@v1" });
    defer allocator.free(empty);
    try fs_compat.makePath(empty);
    try std.testing.expect(!isModuleInstalledAnywhere(allocator, ui_dir, "modd"));
}

test "stagingPathFor is dot-prefixed so version scans ignore it" {
    const allocator = std.testing.allocator;
    const staging = try stagingPathFor(allocator, "/tmp/ui/nullclaw-chat-ui@latest");
    defer allocator.free(staging);
    try std.testing.expectEqualStrings("/tmp/ui/.nullclaw-chat-ui@latest.staging", staging);

    // The dot prefix keeps `@`-splitting enumeration from treating it as
    // `{module}@{version}`: name prefix becomes ".nullclaw-chat-ui".
    const slash = std.mem.lastIndexOfScalar(u8, staging, '/').?;
    const base = staging[slash + 1 ..];
    try std.testing.expect(base[0] == '.');
    const at = std.mem.indexOfScalar(u8, base, '@').?;
    // Enumeration splits at '@' and compares the whole prefix (dot included),
    // so the staging dir does not resolve as this module.
    try std.testing.expect(!std.mem.eql(u8, base[0..at], "nullclaw-chat-ui"));
    try std.testing.expectEqualStrings(".nullclaw-chat-ui", base[0..at]);
}

test "isInstalledUnderRoot finds a dev-local install under {root}/ui" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    // Nothing installed: the release-download pass is justified.
    try std.testing.expect(!isInstalledUnderRoot(allocator, root, "nullclaw-chat-ui"));

    // Seed the dev-local install the local-build pass produces. The download
    // pass must then skip instead of building/downloading it a second time.
    const dest = try std.fs.path.join(allocator, &.{ root, "ui", "nullclaw-chat-ui@dev-local" });
    defer allocator.free(dest);
    try fs_compat.makePath(dest);
    const entry = try std.fs.path.join(allocator, &.{ dest, "module.js" });
    defer allocator.free(entry);
    try testWriteFile(entry, "x");

    try std.testing.expect(isInstalledUnderRoot(allocator, root, "nullclaw-chat-ui"));
    // A different module name is still not installed.
    try std.testing.expect(!isInstalledUnderRoot(allocator, root, "other-ui"));
}

test "prepareStaging never touches an installed module" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std_compat.fs.Dir.wrap(tmp.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const dest = try std.fs.path.join(allocator, &.{ root, "ui", "nullclaw-chat-ui@dev-local" });
    defer allocator.free(dest);
    try fs_compat.makePath(dest);
    const entry = try std.fs.path.join(allocator, &.{ dest, "module.js" });
    defer allocator.free(entry);
    try testWriteFile(entry, "working");

    // Simulate a leftover half-written staging dir from an earlier failed
    // build, then clear it.
    const staging_path = try stagingPathFor(allocator, dest);
    defer allocator.free(staging_path);
    try fs_compat.makePath(staging_path);
    const junk = try std.fs.path.join(allocator, &.{ staging_path, "junk.txt" });
    defer allocator.free(junk);
    try testWriteFile(junk, "partial");

    const staging = try prepareStaging(allocator, dest);
    defer allocator.free(staging);

    // Staging is gone; the live module is untouched.
    try std.testing.expectEqualStrings(staging_path, staging);
    try std.testing.expect(!testDirExists(staging));
    try std.testing.expect(isModuleInstalled(dest));
    const contents = try testReadFile(allocator, entry);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("working", contents);
}
