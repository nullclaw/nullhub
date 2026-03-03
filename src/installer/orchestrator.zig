const std = @import("std");
const builtin = @import("builtin");
const registry = @import("registry.zig");
const downloader = @import("downloader.zig");
const component_cli = @import("../core/component_cli.zig");
const manifest_mod = @import("../core/manifest.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");
const platform = @import("../core/platform.zig");
const local_binary = @import("../core/local_binary.zig");
const manager_mod = @import("../supervisor/manager.zig");
const ui_modules_mod = @import("ui_modules.zig");

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

/// Last error detail (for diagnostics in API responses).
var last_error_detail: [512]u8 = undefined;
var last_error_detail_len: usize = 0;

pub fn getLastErrorDetail() []const u8 {
    return last_error_detail[0..last_error_detail_len];
}

fn setLastErrorDetail(msg: []const u8) void {
    const n = @min(msg.len, last_error_detail.len);
    @memcpy(last_error_detail[0..n], msg[0..n]);
    last_error_detail_len = n;
}

fn clearLastErrorDetail() void {
    last_error_detail_len = 0;
}

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

    // 2. Create instance directories
    p.ensureDirs() catch return error.DirCreationFailed;

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

    // 3. Resolve binary source: GitHub release asset first, then local dev binary.
    var resolved_version: ?[]const u8 = null;
    errdefer if (resolved_version) |v| allocator.free(v);
    var resolved_bin_path: ?[]const u8 = null;
    errdefer if (resolved_bin_path) |b| allocator.free(b);

    var release_fetched = false;
    const platform_key = comptime platform.detect().toString();
    // Development-first: for "latest" use local sibling binary when available.
    if (std.mem.eql(u8, opts.version, "latest")) {
        if (stageLocalBinary(allocator, p, opts.component)) |staged| {
            resolved_version = staged.version;
            resolved_bin_path = staged.bin_path;
        }
    }

    if (resolved_bin_path == null or resolved_version == null) {
        const release_result = if (std.mem.eql(u8, opts.version, "latest"))
            registry.fetchLatestRelease(allocator, comp.repo)
        else
            registry.fetchReleaseByTag(allocator, comp.repo, opts.version);
        if (release_result) |release| {
            defer release.deinit();
            release_fetched = true;

            if (registry.findAssetForComponentPlatform(allocator, release.value, opts.component, platform_key)) |asset| {
                resolved_version = allocator.dupe(u8, release.value.tag_name) catch return error.FetchFailed;
                const bin_path = p.binary(allocator, opts.component, resolved_version.?) catch return error.DownloadFailed;
                resolved_bin_path = bin_path;
                downloader.download(allocator, asset.browser_download_url, bin_path) catch {
                    allocator.free(bin_path);
                    resolved_bin_path = null;
                    allocator.free(resolved_version.?);
                    resolved_version = null;
                };
            }
        } else |_| {}
    }

    if (resolved_bin_path == null or resolved_version == null) {
        if (stageLocalBinary(allocator, p, opts.component)) |staged| {
            resolved_version = staged.version;
            resolved_bin_path = staged.bin_path;
        } else if (!release_fetched) {
            return error.FetchFailed;
        } else {
            return error.NoPlatformAsset;
        }
    }

    const version = resolved_version.?;
    const bin_path = resolved_bin_path.?;
    defer allocator.free(bin_path);

    // 4. Run --export-manifest to get launch/health/port info
    var parsed_manifest: ?std.json.Parsed(manifest_mod.Manifest) = null;
    if (component_cli.exportManifest(allocator, bin_path)) |json| {
        defer allocator.free(json);
        parsed_manifest = manifest_mod.parseManifest(allocator, json) catch null;
    } else |_| {}

    // Use parsed manifest values or fall back to registry defaults
    const launch_command = if (parsed_manifest) |pm| pm.value.launch.command else comp.default_launch_command;
    const health_endpoint = if (parsed_manifest) |pm| pm.value.health.endpoint else comp.default_health_endpoint;
    const default_port = if (parsed_manifest) |pm| (if (pm.value.ports.len > 0) pm.value.ports[0].default else comp.default_port) else comp.default_port;
    defer if (parsed_manifest) |pm| pm.deinit();

    // 5. Run --from-json to generate config (component owns its config generation)
    // Inject "home" field so the component writes config into the instance directory.
    const answers_with_home = injectHomeField(allocator, opts.answers_json, inst_dir) catch opts.answers_json;
    defer if (answers_with_home.ptr != opts.answers_json.ptr) allocator.free(answers_with_home);

    clearLastErrorDetail();
    const from_json_result = component_cli.fromJson(allocator, bin_path, answers_with_home, null) catch {
        setLastErrorDetail("failed to execute binary");
        return error.ConfigGenerationFailed;
    };
    defer allocator.free(from_json_result.stdout);
    defer allocator.free(from_json_result.stderr);
    if (!from_json_result.success) {
        if (from_json_result.stderr.len > 0) {
            std.debug.print("--from-json stderr: {s}\n", .{from_json_result.stderr});
            setLastErrorDetail(from_json_result.stderr);
        }
        return error.ConfigGenerationFailed;
    }

    // 6. Register in state.json
    s.addInstance(opts.component, opts.instance_name, .{
        .version = version,
        .auto_start = true,
        .launch_mode = launch_command,
    }) catch return error.StateError;
    s.save() catch return error.StateError;

    // 7. Start process via Manager
    const port = resolveConfiguredPort(allocator, opts.answers_json, default_port);
    mgr.startInstance(
        opts.component,
        opts.instance_name,
        bin_path,
        &.{},
        port,
        health_endpoint,
        inst_dir,
        "",
        launch_command,
    ) catch return error.StartFailed;

    return .{
        .version = version,
        .instance_name = opts.instance_name,
    };
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn resolveConfiguredPort(allocator: std.mem.Allocator, answers_json: []const u8, default_port: u16) u16 {
    const parsed = std.json.parseFromSlice(
        struct {
            port: ?u16 = null,
            gateway_port: ?u16 = null,
            answers: ?struct {
                port: ?u16 = null,
                gateway_port: ?u16 = null,
            } = null,
        },
        allocator,
        answers_json,
        .{ .allocate = .alloc_if_needed, .ignore_unknown_fields = true },
    ) catch return findFreePort(default_port);
    defer parsed.deinit();

    if (parsed.value.port) |v| return v;
    if (parsed.value.gateway_port) |v| return v;
    if (parsed.value.answers) |a| {
        if (a.port) |v| return v;
        if (a.gateway_port) |v| return v;
    }
    return findFreePort(default_port);
}

fn findFreePort(start: u16) u16 {
    var port: u16 = start;
    while (port < 65535) : (port += 1) {
        const addr = std.net.Address.resolveIp("127.0.0.1", port) catch continue;
        const sock = std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch continue;
        defer std.posix.close(sock);
        std.posix.bind(sock, &addr.any, addr.getOsSockLen()) catch continue;
        return port;
    }
    return start;
}

/// Inject a "home" key into a JSON object string. Returns a new string with the field added.
/// If the input isn't a valid JSON object (doesn't start with '{'), returns error.
fn injectHomeField(allocator: std.mem.Allocator, json: []const u8, home: []const u8) ![]const u8 {
    // Find the opening brace
    const start = std.mem.indexOfScalar(u8, json, '{') orelse return error.InvalidJson;
    // Build: { "home": "<home>", <rest of original object>
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("{\"home\":\"");
    // Escape the home path (backslashes on Windows, though unlikely)
    for (home) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            else => try buf.append(c),
        }
    }
    try buf.appendSlice("\",");
    // Append everything after the opening brace
    try buf.appendSlice(json[start + 1 ..]);
    return buf.toOwnedSlice();
}

fn stageLocalBinary(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8) ?struct { version: []const u8, bin_path: []const u8 } {
    if (builtin.is_test) return null;
    const local_path = local_binary.find(allocator, component) orelse return null;
    defer allocator.free(local_path);

    const version = allocator.dupe(u8, "dev-local") catch return null;
    errdefer allocator.free(version);
    const bin_path = p.binary(allocator, component, version) catch return null;
    errdefer allocator.free(bin_path);

    if (std.fs.openFileAbsolute(bin_path, .{})) |f| {
        f.close();
        return .{ .version = version, .bin_path = bin_path };
    } else |_| {}

    std.fs.copyFileAbsolute(local_path, bin_path, .{}) catch return null;
    if (std.fs.openFileAbsolute(bin_path, .{ .mode = .read_only })) |f| {
        defer f.close();
        f.chmod(0o755) catch {};
    } else |_| {}

    return .{ .version = version, .bin_path = bin_path };
}

/// Install a UI module: try local dev build first, then GitHub download.
pub fn installUiModule(
    allocator: std.mem.Allocator,
    p: paths_mod.Paths,
    ui_mod: registry.UiModuleRef,
    version: []const u8,
) !void {
    const dest = try p.uiModule(allocator, ui_mod.name, version);
    defer allocator.free(dest);

    // Skip if already installed
    if (ui_modules_mod.isModuleInstalled(dest)) return;

    // Try local dev build first (look for sibling repo)
    if (!builtin.is_test) {
        if (buildLocalUiModule(allocator, ui_mod.name, dest)) return;
    }

    // Fall back to downloading from GitHub releases
    ui_modules_mod.downloadUiModule(allocator, ui_mod.repo, ui_mod.name, version, dest) catch {
        return error.DownloadFailed;
    };
}

/// Build a UI module from a local sibling repository.
/// Looks for ../{module_name}/ relative to CWD, runs `npm run build:module`,
/// and copies the dist/ output to dest_dir.
fn buildLocalUiModule(allocator: std.mem.Allocator, module_name: []const u8, dest_dir: []const u8) bool {
    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch return false;
    defer allocator.free(cwd);

    const parent = std.fs.path.dirname(cwd) orelse return false;
    const module_dir = std.fs.path.join(allocator, &.{ parent, module_name }) catch return false;
    defer allocator.free(module_dir);

    // Check if the module repo exists locally
    {
        var dir = std.fs.openDirAbsolute(module_dir, .{}) catch return false;
        dir.close();
    }

    std.debug.print("Building UI module '{s}' from local source: {s}\n", .{ module_name, module_dir });

    const module_dir_z = allocator.dupeZ(u8, module_dir) catch return false;
    defer allocator.free(module_dir_z);

    // Run npm run build:module
    const build_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "npm", "run", "build:module" },
        .cwd = module_dir_z,
    }) catch return false;
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    switch (build_result.term) {
        .Exited => |code| if (code != 0) {
            std.debug.print("UI module build failed (exit {d}):\n{s}\n", .{ code, build_result.stderr });
            return false;
        },
        else => return false,
    }

    // Create dest_dir
    std.fs.makeDirAbsolute(dest_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        error.FileNotFound => {
            if (std.fs.path.dirname(dest_dir)) |p| {
                std.fs.makeDirAbsolute(p) catch return false;
                std.fs.makeDirAbsolute(dest_dir) catch return false;
            } else return false;
        },
        else => return false,
    };

    // Copy dist/ contents to dest_dir
    const dist_path = std.fs.path.join(allocator, &.{ module_dir, "dist" }) catch return false;
    defer allocator.free(dist_path);

    const copy_cmd = std.fmt.allocPrint(allocator, "cp -r {s}/. {s}/", .{ dist_path, dest_dir }) catch return false;
    defer allocator.free(copy_cmd);

    const cp_result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "sh", "-c", copy_cmd },
    }) catch return false;
    defer allocator.free(cp_result.stdout);
    defer allocator.free(cp_result.stderr);

    return switch (cp_result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}

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

test "resolveConfiguredPort reads top-level port" {
    const port = resolveConfiguredPort(std.testing.allocator, "{\"port\":9001}", 8080);
    try std.testing.expectEqual(@as(u16, 9001), port);
}

test "resolveConfiguredPort reads nested answers port" {
    const port = resolveConfiguredPort(std.testing.allocator, "{\"answers\":{\"port\":9101}}", 8080);
    try std.testing.expectEqual(@as(u16, 9101), port);
}

test "resolveConfiguredPort falls back to default" {
    const port = resolveConfiguredPort(std.testing.allocator, "{\"foo\":\"bar\"}", 8080);
    try std.testing.expectEqual(@as(u16, 8080), port);
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

test "injectHomeField adds home to JSON object" {
    const allocator = std.testing.allocator;
    const result = try injectHomeField(allocator, "{\"provider\":\"openrouter\"}", "/tmp/inst");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"home\":\"/tmp/inst\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"provider\":\"openrouter\"") != null);
}
