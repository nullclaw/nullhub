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
const launch_args_mod = @import("../core/launch_args.zig");
const nullclaw_web_channel = @import("../core/nullclaw_web_channel.zig");
const manager_mod = @import("../supervisor/manager.zig");
const ui_modules_mod = @import("ui_modules.zig");
const MAX_CONFIG_BYTES = 4 * 1024 * 1024;

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
    InstanceExists,
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

    if (s.getInstance(opts.component, opts.instance_name) != null) {
        setLastErrorDetail("instance name already exists");
        return error.InstanceExists;
    }

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
    if (std.fs.openDirAbsolute(inst_dir, .{})) |existing_dir| {
        var dir = existing_dir;
        dir.close();
        setLastErrorDetail("instance name already exists");
        return error.InstanceExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.DirCreationFailed,
    }
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

    const managed_port = std.mem.eql(u8, opts.component, "nullclaw");
    const port = if (managed_port)
        findNextAvailablePort(allocator, default_port, p, s)
    else
        resolveConfiguredPort(allocator, opts.answers_json, default_port, p, s);

    // 5. Run --from-json to generate config (component owns its config generation)
    // Inject the resolved port and instance home so generated configs align with supervisor state.
    const answers_with_port = injectPortFields(allocator, opts.answers_json, port, managed_port) catch opts.answers_json;
    defer if (answers_with_port.ptr != opts.answers_json.ptr) allocator.free(answers_with_port);
    const answers_with_home = injectHomeField(allocator, answers_with_port, inst_dir) catch answers_with_port;
    defer if (answers_with_home.ptr != answers_with_port.ptr) allocator.free(answers_with_home);

    clearLastErrorDetail();
    const from_json_result = component_cli.fromJson(
        allocator,
        opts.component,
        bin_path,
        answers_with_home,
        null,
        inst_dir,
    ) catch {
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

    _ = nullclaw_web_channel.ensureNullclawWebChannelConfig(
        allocator,
        p,
        s,
        opts.component,
        opts.instance_name,
    ) catch {
        setLastErrorDetail("failed to ensure nullclaw web channel config");
        return error.ConfigGenerationFailed;
    };

    // Use the generated config as the source of truth for health checks and
    // supervisor state after the component has rendered its final config.
    const runtime_port = readConfiguredInstancePort(
        allocator,
        p,
        opts.component,
        opts.instance_name,
        version,
    ) orelse port;

    // 6. Register in state.json
    s.addInstance(opts.component, opts.instance_name, .{
        .version = version,
        .auto_start = true,
        .launch_mode = launch_command,
        .verbose = false,
    }) catch return error.StateError;
    s.save() catch return error.StateError;

    // 7. Start process via Manager
    const launch_args = launch_args_mod.buildLaunchArgs(allocator, launch_command, false) catch return error.StartFailed;
    defer allocator.free(launch_args);
    mgr.startInstance(
        opts.component,
        opts.instance_name,
        bin_path,
        launch_args,
        runtime_port,
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

fn resolveConfiguredPort(
    allocator: std.mem.Allocator,
    answers_json: []const u8,
    default_port: u16,
    paths: paths_mod.Paths,
    state: *state_mod.State,
) u16 {
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
    ) catch return findNextAvailablePort(allocator, default_port, paths, state);
    defer parsed.deinit();

    if (parsed.value.port) |v| return v;
    if (parsed.value.gateway_port) |v| return v;
    if (parsed.value.answers) |a| {
        if (a.port) |v| return v;
        if (a.gateway_port) |v| return v;
    }
    return findNextAvailablePort(allocator, default_port, paths, state);
}

fn findNextAvailablePort(
    allocator: std.mem.Allocator,
    start: u16,
    paths: paths_mod.Paths,
    state: *state_mod.State,
) u16 {
    var used_ports = collectConfiguredPorts(allocator, paths, state) catch return findFreePort(start);
    defer used_ports.deinit();

    var candidate: u16 = start;
    while (candidate < 65535) : (candidate += 1) {
        if (used_ports.contains(candidate)) continue;
        if (isPortFree(candidate)) return candidate;
    }

    return start;
}

fn collectConfiguredPorts(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    state: *state_mod.State,
) !std.AutoHashMap(u16, void) {
    var ports = std.AutoHashMap(u16, void).init(allocator);
    errdefer ports.deinit();

    var comp_it = state.instances.iterator();
    while (comp_it.next()) |comp_entry| {
        const component = comp_entry.key_ptr.*;
        var inst_it = comp_entry.value_ptr.iterator();
        while (inst_it.next()) |inst_entry| {
            if (readConfiguredInstancePort(
                allocator,
                paths,
                component,
                inst_entry.key_ptr.*,
                inst_entry.value_ptr.version,
            )) |port| {
                try ports.put(port, {});
            }
        }
    }

    return ports;
}

fn readConfiguredInstancePort(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    instance_name: []const u8,
    version: []const u8,
) ?u16 {
    const config_path = paths.instanceConfig(allocator, component, instance_name) catch return null;
    defer allocator.free(config_path);

    const manifest_info = readManifestPortInfo(allocator, paths, component, version);
    if (manifest_info.port_from_config.len > 0) {
        if (readPortFromConfigPath(allocator, config_path, manifest_info.port_from_config)) |port| {
            return port;
        }
    }

    if (readPortFromConfigPath(allocator, config_path, "gateway.port")) |port| return port;
    if (readPortFromConfigPath(allocator, config_path, "port")) |port| return port;
    return manifest_info.default_port;
}

const ManifestPortInfo = struct {
    port_from_config: []const u8 = "",
    default_port: ?u16 = null,
};

fn readManifestPortInfo(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    version: []const u8,
) ManifestPortInfo {
    const bin_path = paths.binary(allocator, component, version) catch {
        return .{ .default_port = if (registry.findKnownComponent(component)) |known| known.default_port else null };
    };
    defer allocator.free(bin_path);

    const manifest_json = component_cli.exportManifest(allocator, bin_path) catch {
        return .{ .default_port = if (registry.findKnownComponent(component)) |known| known.default_port else null };
    };
    defer allocator.free(manifest_json);

    const parsed_manifest = manifest_mod.parseManifest(allocator, manifest_json) catch {
        return .{ .default_port = if (registry.findKnownComponent(component)) |known| known.default_port else null };
    };
    defer parsed_manifest.deinit();

    return .{
        .port_from_config = parsed_manifest.value.health.port_from_config,
        .default_port = if (parsed_manifest.value.ports.len > 0) parsed_manifest.value.ports[0].default else null,
    };
}

fn readPortFromConfigPath(allocator: std.mem.Allocator, config_path: []const u8, dot_key: []const u8) ?u16 {
    const file = std.fs.openFileAbsolute(config_path, .{}) catch return null;
    defer file.close();

    const contents = file.readToEndAlloc(allocator, MAX_CONFIG_BYTES) catch return null;
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    var current = parsed.value;
    var it = std.mem.splitScalar(u8, dot_key, '.');
    while (it.next()) |segment| {
        switch (current) {
            .object => |obj| current = obj.get(segment) orelse return null,
            else => return null,
        }
    }

    return switch (current) {
        .integer => |value| if (value >= 0 and value <= 65535) @intCast(value) else null,
        else => null,
    };
}

fn injectPortFields(
    allocator: std.mem.Allocator,
    json: []const u8,
    port: u16,
    overwrite: bool,
) ![]const u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    var root = &parsed.value.object;
    if (overwrite or root.get("port") == null) {
        try root.put("port", .{ .integer = @as(i64, port) });
    }
    if (overwrite or root.get("gateway_port") == null) {
        try root.put("gateway_port", .{ .integer = @as(i64, port) });
    }
    if (root.getPtr("gateway")) |gateway_value| {
        if (gateway_value.* == .object and (overwrite or gateway_value.object.get("port") == null)) {
            try gateway_value.object.put("port", .{ .integer = @as(i64, port) });
        }
    } else {
        var gateway_obj = std.json.ObjectMap.init(allocator);
        try gateway_obj.put("port", .{ .integer = @as(i64, port) });
        try root.put("gateway", .{ .object = gateway_obj });
    }

    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
}

fn findFreePort(start: u16) u16 {
    var port: u16 = start;
    while (port < 65535) : (port += 1) {
        if (!isPortFree(port)) continue;
        return port;
    }
    return start;
}

fn isPortFree(port: u16) bool {
    const addr = std.net.Address.resolveIp("127.0.0.1", port) catch return false;
    const sock = std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch return false;
    defer std.posix.close(sock);
    std.posix.bind(sock, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
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
    if (comptime std.fs.has_executable_bit) {
        if (std.fs.openFileAbsolute(bin_path, .{ .mode = .read_only })) |f| {
            defer f.close();
            f.chmod(0o755) catch {};
        } else |_| {}
    }

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

test "install returns InstanceExists for duplicate instance name" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-orchestrator-duplicate");
    defer p.deinit(allocator);
    var s = state_mod.State.init(allocator, "/tmp/test-orchestrator-duplicate/state.json");
    defer s.deinit();
    var mgr = manager_mod.Manager.init(allocator, p);
    defer mgr.deinit();

    try s.addInstance("nullclaw", "instance-1", .{
        .version = "v2026.3.8",
        .auto_start = true,
        .launch_mode = "gateway",
    });

    const result = install(allocator, .{
        .component = "nullclaw",
        .instance_name = "instance-1",
        .version = "latest",
        .answers_json = "{}",
    }, p, &s, &mgr);
    try std.testing.expectError(error.InstanceExists, result);
}

test "resolveConfiguredPort reads top-level port" {
    var paths = try paths_mod.Paths.init(std.testing.allocator, "/tmp/test-orchestrator-port-top");
    defer paths.deinit(std.testing.allocator);
    var state = state_mod.State.init(std.testing.allocator, "/tmp/test-orchestrator-port-top-state.json");
    defer state.deinit();

    const port = resolveConfiguredPort(std.testing.allocator, "{\"port\":9001}", 8080, paths, &state);
    try std.testing.expectEqual(@as(u16, 9001), port);
}

test "resolveConfiguredPort reads nested answers port" {
    var paths = try paths_mod.Paths.init(std.testing.allocator, "/tmp/test-orchestrator-port-nested");
    defer paths.deinit(std.testing.allocator);
    var state = state_mod.State.init(std.testing.allocator, "/tmp/test-orchestrator-port-nested-state.json");
    defer state.deinit();

    const port = resolveConfiguredPort(std.testing.allocator, "{\"answers\":{\"port\":9101}}", 8080, paths, &state);
    try std.testing.expectEqual(@as(u16, 9101), port);
}

test "resolveConfiguredPort skips configured instance ports" {
    const allocator = std.testing.allocator;
    const root = "/tmp/test-orchestrator-port-used";
    std.fs.deleteTreeAbsolute(root) catch {};
    defer std.fs.deleteTreeAbsolute(root) catch {};

    var paths = try paths_mod.Paths.init(allocator, root);
    defer paths.deinit(allocator);
    try paths.ensureDirs();

    var state = state_mod.State.init(allocator, "/tmp/test-orchestrator-port-used-state.json");
    defer state.deinit();
    try state.addInstance("nullclaw", "instance-1", .{
        .version = "v2026.3.8",
        .auto_start = true,
        .launch_mode = "gateway",
    });

    const comp_dir = try std.fs.path.join(allocator, &.{ root, "instances", "nullclaw" });
    defer allocator.free(comp_dir);
    std.fs.makeDirAbsolute(comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const inst_dir = try paths.instanceDir(allocator, "nullclaw", "instance-1");
    defer allocator.free(inst_dir);
    std.fs.makeDirAbsolute(inst_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const config_path = try paths.instanceConfig(allocator, "nullclaw", "instance-1");
    defer allocator.free(config_path);
    try writeFile(config_path, "{\"gateway\":{\"port\":43000}}");

    const port = resolveConfiguredPort(allocator, "{\"foo\":\"bar\"}", 43000, paths, &state);
    try std.testing.expect(port > 43000);
}

test "injectPortFields fills missing port fields" {
    const allocator = std.testing.allocator;
    const rendered = try injectPortFields(allocator, "{\"instance_name\":\"instance-2\"}", 3002, false);
    defer allocator.free(rendered);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 3002), parsed.value.object.get("port").?.integer);
    try std.testing.expectEqual(@as(i64, 3002), parsed.value.object.get("gateway_port").?.integer);
    try std.testing.expectEqual(@as(i64, 3002), parsed.value.object.get("gateway").?.object.get("port").?.integer);
}

test "injectPortFields overwrites existing port fields when requested" {
    const allocator = std.testing.allocator;
    const rendered = try injectPortFields(
        allocator,
        "{\"instance_name\":\"instance-2\",\"port\":3000,\"gateway_port\":3000,\"gateway\":{\"port\":3000}}",
        3002,
        true,
    );
    defer allocator.free(rendered);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, rendered, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqual(@as(i64, 3002), parsed.value.object.get("port").?.integer);
    try std.testing.expectEqual(@as(i64, 3002), parsed.value.object.get("gateway_port").?.integer);
    try std.testing.expectEqual(@as(i64, 3002), parsed.value.object.get("gateway").?.object.get("port").?.integer);
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
