const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const registry = @import("registry.zig");
const downloader = @import("downloader.zig");
const component_cli = @import("../core/component_cli.zig");
const manifest_mod = @import("../core/manifest.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");
const platform = @import("../core/platform.zig");
const local_binary = @import("../core/local_binary.zig");
const fs_compat = @import("../fs_compat.zig");
const launch_args_mod = @import("../core/launch_args.zig");
const nullclaw_web_channel = @import("../core/nullclaw_web_channel.zig");
const manager_mod = @import("../supervisor/manager.zig");
const ui_modules_mod = @import("ui_modules.zig");
const managed_skills = @import("../managed_skills.zig");
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
    std_compat.fs.makeDirAbsolute(comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // Create instances/{component}/{name}/
    const inst_dir = p.instanceDir(allocator, opts.component, opts.instance_name) catch
        return error.DirCreationFailed;
    defer allocator.free(inst_dir);
    if (std_compat.fs.openDirAbsolute(inst_dir, .{})) |existing_dir| {
        var dir = existing_dir;
        dir.close();
        setLastErrorDetail("instance name already exists");
        return error.InstanceExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return error.DirCreationFailed,
    }
    std_compat.fs.makeDirAbsolute(inst_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // Create data/ subdir
    const data_dir = p.instanceData(allocator, opts.component, opts.instance_name) catch
        return error.DirCreationFailed;
    defer allocator.free(data_dir);
    std_compat.fs.makeDirAbsolute(data_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return error.DirCreationFailed,
    };

    // Create logs/ subdir
    const logs_dir = p.instanceLogs(allocator, opts.component, opts.instance_name) catch
        return error.DirCreationFailed;
    defer allocator.free(logs_dir);
    std_compat.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
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
                downloader.downloadIfMissing(allocator, asset.browser_download_url, bin_path) catch {
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
    // If any selected provider is openai-compatible (has a base_url), strip only those
    // entries before passing answers to the binary. The binary only knows standard
    // provider names; custom credentials and fallback order are restored afterwards.
    const custom_provider_result = extractCustomProviders(allocator, opts.answers_json) catch |err| blk: {
        std.log.warn("extractCustomProviders failed: {s}", .{@errorName(err)});
        break :blk null;
    };
    defer if (custom_provider_result) |cp| cp.deinit(allocator);
    const answers_for_binary = if (custom_provider_result) |cp| cp.stripped_json else opts.answers_json;

    const answers_with_port = injectPortFields(allocator, answers_for_binary, port, managed_port) catch answers_for_binary;
    defer if (answers_with_port.ptr != answers_for_binary.ptr) allocator.free(answers_with_port);
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

    // If there were custom (openai-compatible) providers, patch their credentials
    // and the original provider order into the generated config now that the binary has written it.
    if (custom_provider_result) |cp| {
        const config_path = p.instanceConfig(allocator, opts.component, opts.instance_name) catch null;
        defer if (config_path) |path| allocator.free(path);
        if (config_path) |path| {
            patchCustomProvidersIntoConfig(allocator, path, cp.selections, cp.custom_providers) catch |err| {
                std.log.warn("failed to inject custom providers into config: {s}", .{@errorName(err)});
            };
        }
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

    if (std.mem.eql(u8, opts.component, "nullclaw")) {
        const workspace_dir = std.fs.path.join(allocator, &.{ inst_dir, "workspace" }) catch {
            setLastErrorDetail("failed to resolve nullclaw workspace directory");
            return error.ConfigGenerationFailed;
        };
        defer allocator.free(workspace_dir);
        const config_path = p.instanceConfig(allocator, opts.component, opts.instance_name) catch {
            setLastErrorDetail("failed to resolve nullclaw config path");
            return error.ConfigGenerationFailed;
        };
        defer allocator.free(config_path);

        _ = managed_skills.installAlwaysBundledSkills(
            allocator,
            opts.component,
            workspace_dir,
            config_path,
        ) catch {
            setLastErrorDetail("failed to seed managed nullclaw skills");
            return error.ConfigGenerationFailed;
        };
    }

    // Use the generated config as the source of truth for health checks and
    // supervisor state after the component has rendered its final config.
    const runtime_port = readConfiguredInstancePort(
        allocator,
        p,
        opts.component,
        opts.instance_name,
        version,
    ) orelse port;
    var launch = launch_args_mod.resolve(allocator, launch_command, false) catch return error.StartFailed;
    defer launch.deinit();
    const effective_port = launch.effectiveHealthPort(runtime_port);

    // 6. Register in state.json
    s.addInstance(opts.component, opts.instance_name, .{
        .version = version,
        .auto_start = true,
        .launch_mode = launch_command,
        .verbose = false,
    }) catch return error.StateError;
    s.save() catch return error.StateError;

    // 7. Start process via Manager
    mgr.startInstance(
        opts.component,
        opts.instance_name,
        bin_path,
        launch.argv,
        effective_port,
        health_endpoint,
        inst_dir,
        "",
        launch.primary_command,
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
    const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch return null;
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
        try root.put(allocator, "port", .{ .integer = @as(i64, port) });
    }
    if (overwrite or root.get("gateway_port") == null) {
        try root.put(allocator, "gateway_port", .{ .integer = @as(i64, port) });
    }
    if (root.getPtr("gateway")) |gateway_value| {
        if (gateway_value.* == .object and (overwrite or gateway_value.object.get("port") == null)) {
            try gateway_value.object.put(allocator, "port", .{ .integer = @as(i64, port) });
        }
    } else {
        var gateway_obj: std.json.ObjectMap = .empty;
        try gateway_obj.put(allocator, "port", .{ .integer = @as(i64, port) });
        try root.put(allocator, "gateway", .{ .object = gateway_obj });
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
    const addr = std_compat.net.Address.resolveIp("127.0.0.1", port) catch return false;
    var listener = addr.listen(.{}) catch return false;
    defer listener.deinit();
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

// ─── Custom provider handling ────────────────────────────────────────────────

/// Extracted custom-provider fields stripped from wizard answers before they
/// reach the component binary.  All slices are owned by the arena from the
/// parsed JSON value; callers must not free them individually.
const CustomProvider = struct {
    provider: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
};

const ProviderSelection = struct {
    provider: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
};

const CustomProvidersRewrite = struct {
    custom_providers: []CustomProvider,
    selections: []ProviderSelection,
    stripped_json: []const u8,

    fn deinit(self: CustomProvidersRewrite, allocator: std.mem.Allocator) void {
        freeCustomProviders(allocator, self.custom_providers);
        freeProviderSelections(allocator, self.selections);
        allocator.free(self.stripped_json);
    }
};

fn freeCustomProviders(allocator: std.mem.Allocator, providers: []CustomProvider) void {
    for (providers) |provider| {
        allocator.free(provider.provider);
        allocator.free(provider.api_key);
        allocator.free(provider.base_url);
        allocator.free(provider.model);
    }
    allocator.free(providers);
}

fn deinitCustomProviderList(allocator: std.mem.Allocator, providers: *std.array_list.Managed(CustomProvider)) void {
    for (providers.items) |provider| {
        allocator.free(provider.provider);
        allocator.free(provider.api_key);
        allocator.free(provider.base_url);
        allocator.free(provider.model);
    }
    providers.deinit();
}

fn freeProviderSelections(allocator: std.mem.Allocator, selections: []ProviderSelection) void {
    for (selections) |selection| {
        allocator.free(selection.provider);
        allocator.free(selection.api_key);
        allocator.free(selection.base_url);
        allocator.free(selection.model);
    }
    allocator.free(selections);
}

fn deinitProviderSelectionList(allocator: std.mem.Allocator, selections: *std.array_list.Managed(ProviderSelection)) void {
    for (selections.items) |selection| {
        allocator.free(selection.provider);
        allocator.free(selection.api_key);
        allocator.free(selection.base_url);
        allocator.free(selection.model);
    }
    selections.deinit();
}

fn stringField(obj: *std.json.ObjectMap, key: []const u8) []const u8 {
    return switch (obj.get(key) orelse .null) {
        .string => |s| s,
        else => "",
    };
}

fn appendProviderSelection(
    allocator: std.mem.Allocator,
    selections: *std.array_list.Managed(ProviderSelection),
    provider: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
) !void {
    if (provider.len == 0) return;
    const owned_provider = try allocator.dupe(u8, provider);
    errdefer allocator.free(owned_provider);
    const owned_api_key = try allocator.dupe(u8, api_key);
    errdefer allocator.free(owned_api_key);
    const owned_base_url = try allocator.dupe(u8, base_url);
    errdefer allocator.free(owned_base_url);
    const owned_model = try allocator.dupe(u8, model);
    errdefer allocator.free(owned_model);
    try selections.append(.{
        .provider = owned_provider,
        .api_key = owned_api_key,
        .base_url = owned_base_url,
        .model = owned_model,
    });
}

fn appendCustomProvider(
    allocator: std.mem.Allocator,
    providers: *std.array_list.Managed(CustomProvider),
    provider: []const u8,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
) !void {
    if (provider.len == 0 or base_url.len == 0) return;
    const owned_provider = try allocator.dupe(u8, provider);
    errdefer allocator.free(owned_provider);
    const owned_api_key = try allocator.dupe(u8, api_key);
    errdefer allocator.free(owned_api_key);
    const owned_base_url = try allocator.dupe(u8, base_url);
    errdefer allocator.free(owned_base_url);
    const owned_model = try allocator.dupe(u8, model);
    errdefer allocator.free(owned_model);
    try providers.append(.{
        .provider = owned_provider,
        .api_key = owned_api_key,
        .base_url = owned_base_url,
        .model = owned_model,
    });
}

fn neutralizeProviderObject(allocator: std.mem.Allocator, obj: *std.json.ObjectMap) !void {
    try obj.put(allocator, "provider", .{ .string = "openai" });
    try obj.put(allocator, "api_key", .{ .string = "" });
    try obj.put(allocator, "model", .{ .string = "" });
    try obj.put(allocator, "base_url", .{ .string = "" });
}

/// If the wizard answers contain any provider with a non-empty `base_url`
/// (indicating an OpenAI-compatible / custom endpoint), return all custom
/// provider fields, the original provider order, and a NEW answers JSON string
/// with only custom entries neutralized so the component binary does not see
/// unknown provider names.
///
/// Returns `null` when no custom provider is present (standard flow).
fn extractCustomProviders(allocator: std.mem.Allocator, json: []const u8) !?CustomProvidersRewrite {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const root = &parsed.value.object;

    var custom_providers = std.array_list.Managed(CustomProvider).init(allocator);
    errdefer deinitCustomProviderList(allocator, &custom_providers);
    var selections = std.array_list.Managed(ProviderSelection).init(allocator);
    errdefer deinitProviderSelectionList(allocator, &selections);

    var saw_providers_array = false;
    if (root.getPtr("providers")) |arr_val| {
        if (arr_val.* == .array) {
            saw_providers_array = true;
            for (arr_val.array.items) |*item| {
                if (item.* != .object) continue;
                const provider = stringField(&item.object, "provider");
                const api_key = stringField(&item.object, "api_key");
                const base_url = stringField(&item.object, "base_url");
                const model = stringField(&item.object, "model");

                try appendProviderSelection(allocator, &selections, provider, api_key, base_url, model);

                if (base_url.len > 0) {
                    try appendCustomProvider(allocator, &custom_providers, provider, api_key, base_url, model);
                    try neutralizeProviderObject(allocator, &item.object);
                }
            }
        }
    }

    const top_provider = stringField(root, "provider");
    const top_api_key = stringField(root, "api_key");
    const top_base_url = stringField(root, "base_url");
    const top_model = stringField(root, "model");

    if (!saw_providers_array) {
        try appendProviderSelection(allocator, &selections, top_provider, top_api_key, top_base_url, top_model);
        if (top_base_url.len > 0) {
            try appendCustomProvider(allocator, &custom_providers, top_provider, top_api_key, top_base_url, top_model);
        }
    }

    if (top_base_url.len > 0) {
        try neutralizeProviderObject(allocator, root);
    }

    if (custom_providers.items.len == 0) {
        deinitCustomProviderList(allocator, &custom_providers);
        deinitProviderSelectionList(allocator, &selections);
        return null;
    }

    const custom_slice = try custom_providers.toOwnedSlice();
    errdefer freeCustomProviders(allocator, custom_slice);
    const selection_slice = try selections.toOwnedSlice();
    errdefer freeProviderSelections(allocator, selection_slice);
    const stripped = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    return .{
        .custom_providers = custom_slice,
        .selections = selection_slice,
        .stripped_json = stripped,
    };
}

fn selectionContainsProvider(selections: []const ProviderSelection, provider: []const u8) bool {
    for (selections) |selection| {
        if (std.mem.eql(u8, selection.provider, provider)) return true;
    }
    return false;
}

fn putFallbackProviders(
    allocator: std.mem.Allocator,
    root: *std.json.ObjectMap,
    selections: []const ProviderSelection,
) !void {
    const reliability_obj = try ensureObjectInMap(allocator, root, "reliability");
    var fallbacks = std.json.Array.init(allocator);
    errdefer fallbacks.deinit();

    if (selections.len > 1) {
        for (selections[1..]) |selection| {
            if (selection.provider.len == 0) continue;
            try fallbacks.append(.{ .string = selection.provider });
        }
    }

    try reliability_obj.put(allocator, "fallback_providers", .{ .array = fallbacks });
}

/// Patch custom provider credentials and original provider order into an
/// existing instance config file after the component binary generates its base
/// config with placeholder OpenAI entries.
fn patchCustomProvidersIntoConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    selections: []const ProviderSelection,
    custom_providers: []const CustomProvider,
) !void {
    const contents = blk: {
        const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, "{}"),
            else => return err,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    };
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const ja = parsed.arena.allocator();

    if (parsed.value != .object) return error.InvalidConfig;
    const root = &parsed.value.object;

    const models_obj = try ensureObjectInMap(ja, root, "models");
    const providers_obj = try ensureObjectInMap(ja, models_obj, "providers");

    for (selections) |selection| {
        const provider_obj = try ensureObjectInMap(ja, providers_obj, selection.provider);
        try provider_obj.put(ja, "api_key", .{ .string = selection.api_key });
        if (selection.base_url.len > 0) {
            try provider_obj.put(ja, "base_url", .{ .string = selection.base_url });
        } else {
            _ = provider_obj.orderedRemove("base_url");
        }
    }

    // Remove the placeholder unless the user's actual provider order includes OpenAI.
    if (!selectionContainsProvider(selections, "openai")) {
        _ = providers_obj.orderedRemove("openai");
    }

    if (selections.len > 0 and selections[0].model.len > 0) {
        const primary = try std.fmt.allocPrint(ja, "{s}/{s}", .{ selections[0].provider, selections[0].model });
        const agents_obj = try ensureObjectInMap(ja, root, "agents");
        const defaults_obj = try ensureObjectInMap(ja, agents_obj, "defaults");
        const model_obj = try ensureObjectInMap(ja, defaults_obj, "model");
        try model_obj.put(ja, "primary", .{ .string = primary });
    }

    try putFallbackProviders(ja, root, selections);

    for (custom_providers) |custom| {
        if (custom.model.len > 0) {
            const agent_obj = try ensureObjectInMap(ja, root, "agent");
            const vd_gop = try agent_obj.getOrPut(ja, "vision_disabled_models");
            if (!vd_gop.found_existing) {
                vd_gop.value_ptr.* = .{ .array = std.json.Array.init(ja) };
            }
            if (vd_gop.value_ptr.* == .array) {
                var already_present = false;
                for (vd_gop.value_ptr.array.items) |item| {
                    if (item == .string and std.mem.eql(u8, item.string, custom.model)) {
                        already_present = true;
                        break;
                    }
                }
                if (!already_present) {
                    try vd_gop.value_ptr.array.append(.{ .string = custom.model });
                }
            }
        }
    }

    const rendered = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(rendered);

    const out = try std_compat.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(rendered);
    try out.writeAll("\n");
}

fn ensureObjectInMap(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.ObjectMap {
    const gop = try obj.getOrPut(allocator, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .object = .empty };
        return &gop.value_ptr.object;
    }
    if (gop.value_ptr.* != .object) {
        gop.value_ptr.* = .{ .object = .empty };
    }
    return &gop.value_ptr.object;
}

fn stageLocalBinary(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8) ?struct { version: []const u8, bin_path: []const u8 } {
    if (builtin.is_test) return null;
    const local_path = local_binary.find(allocator, component) orelse return null;
    defer allocator.free(local_path);

    const version = allocator.dupe(u8, "dev-local") catch return null;
    errdefer allocator.free(version);
    const bin_path = p.binary(allocator, component, version) catch return null;
    errdefer allocator.free(bin_path);

    std_compat.fs.deleteFileAbsolute(bin_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return null,
    };
    std_compat.fs.copyFileAbsolute(local_path, bin_path, .{}) catch return null;
    if (comptime std_compat.fs.has_executable_bit) {
        if (std_compat.fs.openFileAbsolute(bin_path, .{ .mode = .read_only })) |f| {
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
    if (!builtin.is_test) {
        if (findLocalUiModuleDir(allocator, ui_mod.name)) |module_dir| {
            defer allocator.free(module_dir);

            const dev_local_version = "dev-local";
            const dev_local_dest = try p.uiModule(allocator, ui_mod.name, dev_local_version);
            defer allocator.free(dev_local_dest);

            std_compat.fs.deleteTreeAbsolute(dev_local_dest) catch |err| switch (err) {
                error.FileNotFound => {},
                else => {},
            };

            if (buildLocalUiModuleFromDir(allocator, module_dir, dev_local_dest)) return;
            return error.DownloadFailed;
        }
    }

    const dest = try p.uiModule(allocator, ui_mod.name, version);
    defer allocator.free(dest);

    // Skip if already installed
    if (ui_modules_mod.isModuleInstalled(dest)) return;

    // Fall back to downloading from GitHub releases
    ui_modules_mod.downloadUiModule(allocator, ui_mod.repo, ui_mod.name, version, dest) catch {
        return error.DownloadFailed;
    };
}

/// Build a UI module from a local sibling repository.
/// Looks for ../{module_name}/ relative to CWD, runs `npm run build:module`,
/// and copies the dist/ output to dest_dir.
fn buildLocalUiModule(allocator: std.mem.Allocator, module_name: []const u8, dest_dir: []const u8) bool {
    const module_dir = findLocalUiModuleDir(allocator, module_name) orelse return false;
    defer allocator.free(module_dir);
    return buildLocalUiModuleFromDir(allocator, module_dir, dest_dir);
}

fn findLocalUiModuleDir(allocator: std.mem.Allocator, module_name: []const u8) ?[]const u8 {
    if (builtin.is_test) return null;

    const cwd = std_compat.fs.cwd().realpathAlloc(allocator, ".") catch return null;
    defer allocator.free(cwd);

    const parent = std.fs.path.dirname(cwd) orelse return null;
    const module_dir = std.fs.path.join(allocator, &.{ parent, module_name }) catch return null;

    var dir = std_compat.fs.openDirAbsolute(module_dir, .{}) catch {
        allocator.free(module_dir);
        return null;
    };
    dir.close();
    return module_dir;
}

fn npmCommand() []const u8 {
    return if (builtin.os.tag == .windows) "npm.cmd" else "npm";
}

fn copyDirectoryContents(allocator: std.mem.Allocator, source_dir_path: []const u8, dest_dir_path: []const u8) !void {
    try fs_compat.makePath(dest_dir_path);

    var source_dir = try std_compat.fs.openDirAbsolute(source_dir_path, .{ .iterate = true });
    defer source_dir.close();

    var walker = try source_dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        const dest_path = try std.fs.path.join(allocator, &.{ dest_dir_path, entry.path });
        defer allocator.free(dest_path);

        switch (entry.kind) {
            .directory => try fs_compat.makePath(dest_path),
            .file => {
                if (std.fs.path.dirname(dest_path)) |dest_parent| {
                    try fs_compat.makePath(dest_parent);
                }

                const source_path = try std.fs.path.join(allocator, &.{ source_dir_path, entry.path });
                defer allocator.free(source_path);
                try std_compat.fs.copyFileAbsolute(source_path, dest_path, .{});
            },
            else => return error.UnsupportedFileKind,
        }
    }
}

fn buildLocalUiModuleFromDir(allocator: std.mem.Allocator, module_dir: []const u8, dest_dir: []const u8) bool {
    std.debug.print("Building UI module from local source: {s}\n", .{module_dir});

    const module_dir_z = allocator.dupeZ(u8, module_dir) catch return false;
    defer allocator.free(module_dir_z);

    // Run npm run build:module
    const build_result = std_compat.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ npmCommand(), "run", "build:module" },
        .cwd = module_dir_z,
    }) catch return false;
    defer allocator.free(build_result.stdout);
    defer allocator.free(build_result.stderr);

    switch (build_result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("UI module build failed (exit {d}):\n{s}\n", .{ code, build_result.stderr });
            return false;
        },
        else => return false,
    }

    // Copy dist/ contents to dest_dir
    const dist_path = std.fs.path.join(allocator, &.{ module_dir, "dist" }) catch return false;
    defer allocator.free(dist_path);

    copyDirectoryContents(allocator, dist_path, dest_dir) catch |err| {
        std.debug.print("UI module copy failed ({s})\n", .{@errorName(err)});
        return false;
    };
    return true;
}

pub fn syncLocalUiModules(allocator: std.mem.Allocator, p: paths_mod.Paths) void {
    if (builtin.is_test) return;

    for (&registry.known_components) |comp| {
        for (comp.ui_modules) |ui_mod| {
            if (findLocalUiModuleDir(allocator, ui_mod.name)) |module_dir| {
                allocator.free(module_dir);
                installUiModule(allocator, p, ui_mod, "latest") catch {};
            }
        }
    }
}

/// Write content to a file at an absolute path, creating the file if needed.
fn writeFile(path: []const u8, content: []const u8) !void {
    const file = try std_compat.fs.createFileAbsolute(path, .{});
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
    std_compat.fs.deleteTreeAbsolute(root) catch {};
    defer std_compat.fs.deleteTreeAbsolute(root) catch {};

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
    std_compat.fs.makeDirAbsolute(comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const inst_dir = try paths.instanceDir(allocator, "nullclaw", "instance-1");
    defer allocator.free(inst_dir);
    std_compat.fs.makeDirAbsolute(inst_dir) catch |err| switch (err) {
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
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const file_path = try std.fmt.allocPrint(allocator, "{s}/test.json", .{tmp_dir});
    defer allocator.free(file_path);

    try writeFile(file_path, "{\"hello\":\"world\"}");

    const file = try std_compat.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("{\"hello\":\"world\"}", buf[0..n]);
}

test "directory creation succeeds in temp directory" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/test-orchestrator-dirs";
    std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    // Create top-level dirs
    try p.ensureDirs();

    // Create component dir
    const comp_dir = try std.fs.path.join(allocator, &.{ p.root, "instances", "testcomp" });
    defer allocator.free(comp_dir);
    try std_compat.fs.makeDirAbsolute(comp_dir);

    // Create instance dir
    const inst_dir = try p.instanceDir(allocator, "testcomp", "myinst");
    defer allocator.free(inst_dir);
    try std_compat.fs.makeDirAbsolute(inst_dir);

    // Create data and logs subdirs
    const data_dir = try p.instanceData(allocator, "testcomp", "myinst");
    defer allocator.free(data_dir);
    try std_compat.fs.makeDirAbsolute(data_dir);

    const logs_dir = try p.instanceLogs(allocator, "testcomp", "myinst");
    defer allocator.free(logs_dir);
    try std_compat.fs.makeDirAbsolute(logs_dir);

    // Verify they all exist
    {
        var d = try std_compat.fs.openDirAbsolute(inst_dir, .{});
        d.close();
    }
    {
        var d = try std_compat.fs.openDirAbsolute(data_dir, .{});
        d.close();
    }
    {
        var d = try std_compat.fs.openDirAbsolute(logs_dir, .{});
        d.close();
    }
}

test "copyDirectoryContents recursively copies nested files" {
    if (builtin.os.tag == .wasi) return;

    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root = try std_compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
    defer allocator.free(root);

    const source_dir = try std.fs.path.join(allocator, &.{ root, "source" });
    defer allocator.free(source_dir);
    const nested_dir = try std.fs.path.join(allocator, &.{ source_dir, "nested", "deep" });
    defer allocator.free(nested_dir);
    const dest_dir = try std.fs.path.join(allocator, &.{ root, "dest" });
    defer allocator.free(dest_dir);

    try fs_compat.makePath(nested_dir);

    const top_level_file = try std.fs.path.join(allocator, &.{ source_dir, "index.js" });
    defer allocator.free(top_level_file);
    const nested_file = try std.fs.path.join(allocator, &.{ nested_dir, "chunk.js" });
    defer allocator.free(nested_file);

    try writeFile(top_level_file, "console.log('root');");
    try writeFile(nested_file, "console.log('nested');");

    try copyDirectoryContents(allocator, source_dir, dest_dir);

    const copied_top_level = try std.fs.path.join(allocator, &.{ dest_dir, "index.js" });
    defer allocator.free(copied_top_level);
    const copied_nested = try std.fs.path.join(allocator, &.{ dest_dir, "nested", "deep", "chunk.js" });
    defer allocator.free(copied_nested);

    const top_bytes = try fs_compat.readFileAlloc(std_compat.fs.cwd(), allocator, copied_top_level, 1024);
    defer allocator.free(top_bytes);
    const nested_bytes = try fs_compat.readFileAlloc(std_compat.fs.cwd(), allocator, copied_nested, 1024);
    defer allocator.free(nested_bytes);

    try std.testing.expectEqualStrings("console.log('root');", top_bytes);
    try std.testing.expectEqualStrings("console.log('nested');", nested_bytes);
}

test "injectHomeField adds home to JSON object" {
    const allocator = std.testing.allocator;
    const result = try injectHomeField(allocator, "{\"provider\":\"openrouter\"}", "/tmp/inst");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"home\":\"/tmp/inst\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"provider\":\"openrouter\"") != null);
}

test "extractCustomProviders neutralizes custom fallback while preserving standard primary" {
    const allocator = std.testing.allocator;
    const json =
        \\{"provider":"openrouter","api_key":"sk-or","model":"openrouter/auto","providers":[{"provider":"openrouter","api_key":"sk-or","model":"openrouter/auto"},{"provider":"local-llm","api_key":"sk-local","model":"llama3","base_url":"http://127.0.0.1:5801/v1"}]}
    ;

    const rewrite = (try extractCustomProviders(allocator, json)).?;
    defer rewrite.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), rewrite.custom_providers.len);
    try std.testing.expectEqualStrings("local-llm", rewrite.custom_providers[0].provider);
    try std.testing.expectEqual(@as(usize, 2), rewrite.selections.len);
    try std.testing.expectEqualStrings("openrouter", rewrite.selections[0].provider);
    try std.testing.expectEqualStrings("local-llm", rewrite.selections[1].provider);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, rewrite.stripped_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const providers = parsed.value.object.get("providers").?.array.items;
    try std.testing.expectEqualStrings("openrouter", providers[0].object.get("provider").?.string);
    try std.testing.expectEqualStrings("openai", providers[1].object.get("provider").?.string);
    try std.testing.expectEqualStrings("", providers[1].object.get("base_url").?.string);
}

test "extractCustomProviders neutralizes primary custom without dropping standard fallback" {
    const allocator = std.testing.allocator;
    const json =
        \\{"provider":"local-llm","api_key":"sk-local","model":"llama3","base_url":"http://127.0.0.1:5801/v1","providers":[{"provider":"local-llm","api_key":"sk-local","model":"llama3","base_url":"http://127.0.0.1:5801/v1"},{"provider":"openrouter","api_key":"sk-or","model":"openrouter/auto"}]}
    ;

    const rewrite = (try extractCustomProviders(allocator, json)).?;
    defer rewrite.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), rewrite.custom_providers.len);
    try std.testing.expectEqualStrings("local-llm", rewrite.custom_providers[0].provider);
    try std.testing.expectEqual(@as(usize, 2), rewrite.selections.len);
    try std.testing.expectEqualStrings("local-llm", rewrite.selections[0].provider);
    try std.testing.expectEqualStrings("openrouter", rewrite.selections[1].provider);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, rewrite.stripped_json, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("openai", parsed.value.object.get("provider").?.string);
    try std.testing.expectEqualStrings("", parsed.value.object.get("base_url").?.string);
    const providers = parsed.value.object.get("providers").?.array.items;
    try std.testing.expectEqualStrings("openai", providers[0].object.get("provider").?.string);
    try std.testing.expectEqualStrings("openrouter", providers[1].object.get("provider").?.string);
}

test "patchCustomProvidersIntoConfig restores custom fallback provider order" {
    const allocator = std.testing.allocator;
    const tmp_dir = "/tmp/test-orchestrator-custom-fallback-patch";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const config_path = try std.fs.path.join(allocator, &.{ tmp_dir, "config.json" });
    defer allocator.free(config_path);
    try writeFile(config_path,
        \\{"models":{"providers":{"openrouter":{"api_key":"sk-or"},"openai":{"api_key":""}}},"agents":{"defaults":{"model":{"primary":"openrouter/openrouter-auto"}}},"reliability":{"fallback_providers":["openai"]}}
    );

    const selections = [_]ProviderSelection{
        .{ .provider = "openrouter", .api_key = "sk-or", .base_url = "", .model = "openrouter-auto" },
        .{ .provider = "local-llm", .api_key = "sk-local", .base_url = "http://127.0.0.1:5801/v1", .model = "llama3" },
    };
    const custom_providers = [_]CustomProvider{
        .{ .provider = "local-llm", .api_key = "sk-local", .base_url = "http://127.0.0.1:5801/v1", .model = "llama3" },
    };

    try patchCustomProvidersIntoConfig(allocator, config_path, &selections, &custom_providers);

    const file = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(contents);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const providers = parsed.value.object.get("models").?.object.get("providers").?.object;
    try std.testing.expect(providers.get("openai") == null);
    try std.testing.expect(providers.get("openrouter") != null);
    const local = providers.get("local-llm").?.object;
    try std.testing.expectEqualStrings("sk-local", local.get("api_key").?.string);
    try std.testing.expectEqualStrings("http://127.0.0.1:5801/v1", local.get("base_url").?.string);

    const primary = parsed.value.object.get("agents").?.object.get("defaults").?.object.get("model").?.object.get("primary").?.string;
    try std.testing.expectEqualStrings("openrouter/openrouter-auto", primary);
    const fallbacks = parsed.value.object.get("reliability").?.object.get("fallback_providers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), fallbacks.len);
    try std.testing.expectEqualStrings("local-llm", fallbacks[0].string);
}

test "patchCustomProvidersIntoConfig restores primary custom and keeps standard fallback" {
    const allocator = std.testing.allocator;
    const tmp_dir = "/tmp/test-orchestrator-primary-custom-patch";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const config_path = try std.fs.path.join(allocator, &.{ tmp_dir, "config.json" });
    defer allocator.free(config_path);
    try writeFile(config_path,
        \\{"models":{"providers":{"openai":{"api_key":""},"openrouter":{"api_key":"sk-or"}}},"agents":{"defaults":{"model":{"primary":"openai/"}}},"reliability":{"fallback_providers":["openrouter"]}}
    );

    const selections = [_]ProviderSelection{
        .{ .provider = "local-llm", .api_key = "sk-local", .base_url = "http://127.0.0.1:5801/v1", .model = "llama3" },
        .{ .provider = "openrouter", .api_key = "sk-or", .base_url = "", .model = "openrouter-auto" },
    };
    const custom_providers = [_]CustomProvider{
        .{ .provider = "local-llm", .api_key = "sk-local", .base_url = "http://127.0.0.1:5801/v1", .model = "llama3" },
    };

    try patchCustomProvidersIntoConfig(allocator, config_path, &selections, &custom_providers);

    const file = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(contents);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const providers = parsed.value.object.get("models").?.object.get("providers").?.object;
    try std.testing.expect(providers.get("openai") == null);
    try std.testing.expect(providers.get("openrouter") != null);
    try std.testing.expect(providers.get("local-llm") != null);
    const primary = parsed.value.object.get("agents").?.object.get("defaults").?.object.get("model").?.object.get("primary").?.string;
    try std.testing.expectEqualStrings("local-llm/llama3", primary);
    const fallbacks = parsed.value.object.get("reliability").?.object.get("fallback_providers").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), fallbacks.len);
    try std.testing.expectEqualStrings("openrouter", fallbacks[0].string);
}
