const std = @import("std");
const registry = @import("registry.zig");
const downloader = @import("downloader.zig");
const component_cli = @import("../core/component_cli.zig");
const manifest_mod = @import("../core/manifest.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");
const platform = @import("../core/platform.zig");
const manager_mod = @import("../supervisor/manager.zig");

// ─── Types ───────────────────────────────────────────────────────────────────

pub const InstallOptions = struct {
    component: []const u8,
    instance_name: []const u8,
    version: []const u8, // "latest" or specific tag
    answers_json: []const u8, // raw JSON body from wizard POST
};

pub const InstallResult = struct {
    version: []const u8,
    instance_name: []const u8,
};

pub const InstallError = error{
    UnknownComponent,
    ManifestNotFound,
    ManifestParseError,
    FetchFailed,
    NoPlatformAsset,
    DownloadFailed,
    DirCreationFailed,
    ConfigGenerationFailed,
    StateError,
    StartFailed,
};

// ─── Install orchestrator ────────────────────────────────────────────────────

/// End-to-end install flow: validate inputs, resolve version, download binary,
/// create instance dirs, run component --from-json for config, register in
/// state.json, and start process via Manager.
pub fn install(
    allocator: std.mem.Allocator,
    opts: InstallOptions,
    p: paths_mod.Paths,
    s: *state_mod.State,
    mgr: *manager_mod.Manager,
) InstallError!InstallResult {
    // 1. Look up component in registry
    const comp = registry.findKnownComponent(opts.component) orelse
        return error.UnknownComponent;

    // 2. Resolve version — fetch release info from GitHub
    var release = if (std.mem.eql(u8, opts.version, "latest"))
        registry.fetchLatestRelease(allocator, comp.repo) catch return error.FetchFailed
    else
        registry.fetchReleaseByTag(allocator, comp.repo, opts.version) catch return error.FetchFailed;
    defer release.deinit();

    // 3. We need the manifest to find the platform asset. Download binary first,
    //    then run --export-manifest on it.
    //    But we need the manifest to find the right asset name...
    //    So we download by convention: asset name = "{component}-{platform}"
    //    Then run --export-manifest for launch/health/port info.

    // 4. Find asset for current platform by name convention
    const platform_key = comptime platform.detect().toString();
    const asset_name = std.fmt.allocPrint(allocator, "{s}-{s}", .{ opts.component, platform_key }) catch
        return error.NoPlatformAsset;
    defer allocator.free(asset_name);
    const asset = registry.findAssetByName(release.value, asset_name) orelse
        return error.NoPlatformAsset;

    // 5. Create instance directories
    p.ensureDirs() catch return error.DirCreationFailed;

    // Create bins/{component}/ directory
    const bins_comp_dir = std.fs.path.join(allocator, &.{ p.root, "bins", opts.component }) catch
        return error.DirCreationFailed;
    defer allocator.free(bins_comp_dir);
    std.fs.makeDirAbsolute(bins_comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // Create bins/{component}/{version}/ directory
    const bins_ver_dir = std.fs.path.join(allocator, &.{ bins_comp_dir, release.value.tag_name }) catch
        return error.DirCreationFailed;
    defer allocator.free(bins_ver_dir);
    std.fs.makeDirAbsolute(bins_ver_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // Create instances/{component}/ directory
    const comp_dir = std.fs.path.join(allocator, &.{ p.root, "instances", opts.component }) catch
        return error.DirCreationFailed;
    defer allocator.free(comp_dir);
    std.fs.makeDirAbsolute(comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // Create instances/{component}/{name}/
    const inst_dir = p.instanceDir(allocator, opts.component, opts.instance_name) catch
        return error.DirCreationFailed;
    defer allocator.free(inst_dir);
    std.fs.makeDirAbsolute(inst_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // Create data/ subdir
    const data_dir = p.instanceData(allocator, opts.component, opts.instance_name) catch
        return error.DirCreationFailed;
    defer allocator.free(data_dir);
    std.fs.makeDirAbsolute(data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // Create logs/ subdir
    const logs_dir = p.instanceLogs(allocator, opts.component, opts.instance_name) catch
        return error.DirCreationFailed;
    defer allocator.free(logs_dir);
    std.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // 6. Download binary
    const bin_path = p.binary(allocator, opts.component, release.value.tag_name) catch
        return error.DownloadFailed;
    defer allocator.free(bin_path);
    downloader.download(allocator, asset.browser_download_url, bin_path) catch
        return error.DownloadFailed;

    // 7. Run --export-manifest to get launch/health/port info
    const manifest_json = component_cli.exportManifest(allocator, bin_path) catch
        return error.ManifestNotFound;
    defer allocator.free(manifest_json);
    const parsed_manifest = manifest_mod.parseManifest(allocator, manifest_json) catch
        return error.ManifestParseError;
    defer parsed_manifest.deinit();
    const m = parsed_manifest.value;

    // 8. Run --from-json to generate config (component owns its config generation)
    const from_json_result = component_cli.fromJson(allocator, bin_path, opts.answers_json) catch
        return error.ConfigGenerationFailed;
    defer allocator.free(from_json_result);

    // 9. Register in state.json
    s.addInstance(opts.component, opts.instance_name, .{
        .version = release.value.tag_name,
        .auto_start = true,
    }) catch return error.StateError;
    s.save() catch return error.StateError;

    // 10. Start process via Manager
    const port: u16 = if (m.ports.len > 0) m.ports[0].default else 0;
    mgr.startInstance(
        opts.component,
        opts.instance_name,
        bin_path,
        &.{},
        port,
        m.health.endpoint,
        inst_dir,
        "",
        m.launch.command,
    ) catch return error.StartFailed;

    return .{
        .version = allocator.dupe(u8, release.value.tag_name) catch return error.FetchFailed,
        .instance_name = opts.instance_name,
    };
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Write content to a file at an absolute path, creating the file if needed.
fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std.fs.createFileAbsolute(path, .{});
    defer file.close();
    try file.writeAll(content);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "install returns UnknownComponent for unknown component" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-orchestrator");
    defer p.deinit(allocator);
    var s = state_mod.State.init(allocator, "/tmp/test-orchestrator/state.json");
    defer s.deinit();
    var mgr = manager_mod.Manager.init(allocator, p);
    defer mgr.deinit();

    const result = install(allocator, .{
        .component = "nonexistent",
        .instance_name = "test",
        .version = "latest",
        .answers_json = "{}",
    }, p, &s, &mgr);
    try std.testing.expectError(error.UnknownComponent, result);
}

test "install returns FetchFailed for known component (no network)" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-orchestrator-fetch");
    defer p.deinit(allocator);
    var s = state_mod.State.init(allocator, "/tmp/test-orchestrator-fetch/state.json");
    defer s.deinit();
    var mgr = manager_mod.Manager.init(allocator, p);
    defer mgr.deinit();

    const result = install(allocator, .{
        .component = "nullclaw",
        .instance_name = "test",
        .version = "latest",
        .answers_json = "{}",
    }, p, &s, &mgr);
    // In test env, GitHub fetch will fail
    try std.testing.expectError(error.FetchFailed, result);
}

test "writeFile creates file with correct content" {
    const allocator = std.testing.allocator;
    const tmp_dir = "/tmp/test-orchestrator-write";
    std.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std.fs.makeDirAbsolute(tmp_dir);
    defer std.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const file_path = try std.fmt.allocPrint(allocator, "{s}/test.json", .{tmp_dir});
    defer allocator.free(file_path);

    try writeFile(file_path, "{\"hello\":\"world\"}");

    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("{\"hello\":\"world\"}", buf[0..n]);
}

test "directory creation succeeds in temp directory" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/test-orchestrator-dirs";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    // Create top-level dirs
    try p.ensureDirs();

    // Create component dir
    const comp_dir = try std.fs.path.join(allocator, &.{ p.root, "instances", "testcomp" });
    defer allocator.free(comp_dir);
    try std.fs.makeDirAbsolute(comp_dir);

    // Create instance dir
    const inst_dir = try p.instanceDir(allocator, "testcomp", "myinst");
    defer allocator.free(inst_dir);
    try std.fs.makeDirAbsolute(inst_dir);

    // Create data and logs subdirs
    const data_dir = try p.instanceData(allocator, "testcomp", "myinst");
    defer allocator.free(data_dir);
    try std.fs.makeDirAbsolute(data_dir);

    const logs_dir = try p.instanceLogs(allocator, "testcomp", "myinst");
    defer allocator.free(logs_dir);
    try std.fs.makeDirAbsolute(logs_dir);

    // Verify they all exist
    {
        var d = try std.fs.openDirAbsolute(inst_dir, .{});
        d.close();
    }
    {
        var d = try std.fs.openDirAbsolute(data_dir, .{});
        d.close();
    }
    {
        var d = try std.fs.openDirAbsolute(logs_dir, .{});
        d.close();
    }
}
