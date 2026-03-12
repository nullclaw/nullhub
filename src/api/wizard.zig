const std = @import("std");
const builtin = @import("builtin");
const registry = @import("../installer/registry.zig");
const downloader = @import("../installer/downloader.zig");
const versions = @import("../installer/versions.zig");
const platform = @import("../core/platform.zig");
const local_binary = @import("../core/local_binary.zig");
const helpers = @import("helpers.zig");
const component_cli = @import("../core/component_cli.zig");
const manifest_mod = @import("../core/manifest.zig");
const orchestrator = @import("../installer/orchestrator.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");
const manager_mod = @import("../supervisor/manager.zig");
const integration_mod = @import("../core/integration.zig");
const providers_api = @import("providers.zig");

const appendEscaped = helpers.appendEscaped;
pub const ProviderProbeResult = struct { live_ok: bool, reason: []const u8 };

// ─── Path Parsing ────────────────────────────────────────────────────────────

/// Extract the component name from a wizard API path.
/// Matches `/api/wizard/{component}` or `/api/wizard/{component}/models`.
/// Returns null if the path doesn't match the expected prefix or is empty.
pub fn extractComponentName(target: []const u8) ?[]const u8 {
    const prefix = "/api/wizard/";
    const path = stripQuery(target);
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const rest = path[prefix.len..];
    if (rest.len == 0) return null;

    const versions_suffix = "/versions";
    if (std.mem.endsWith(u8, rest, versions_suffix)) {
        const component = rest[0 .. rest.len - versions_suffix.len];
        if (component.len == 0) return null;
        if (std.mem.indexOfScalar(u8, component, '/') != null) return null;
        return component;
    }

    const models_suffix = "/models";
    if (std.mem.endsWith(u8, rest, models_suffix)) {
        const component = rest[0 .. rest.len - models_suffix.len];
        if (component.len == 0) return null;
        if (std.mem.indexOfScalar(u8, component, '/') != null) return null;
        return component;
    }

    const validate_providers_suffix = "/validate-providers";
    if (std.mem.endsWith(u8, rest, validate_providers_suffix)) {
        const component = rest[0 .. rest.len - validate_providers_suffix.len];
        if (component.len == 0) return null;
        if (std.mem.indexOfScalar(u8, component, '/') != null) return null;
        return component;
    }

    const validate_channels_suffix = "/validate-channels";
    if (std.mem.endsWith(u8, rest, validate_channels_suffix)) {
        const component = rest[0 .. rest.len - validate_channels_suffix.len];
        if (component.len == 0) return null;
        if (std.mem.indexOfScalar(u8, component, '/') != null) return null;
        return component;
    }

    // Reject paths with other additional segments
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;

    return rest;
}

/// Check if a target path matches `/api/wizard/{component}` or `/api/wizard/{component}/models`.
pub fn isWizardPath(target: []const u8) bool {
    return extractComponentName(target) != null;
}

/// Check if this is a models request path.
pub fn isModelsPath(target: []const u8) bool {
    return std.mem.endsWith(u8, stripQuery(target), "/models");
}

/// Check if this is a versions request path.
pub fn isVersionsPath(target: []const u8) bool {
    return std.mem.endsWith(u8, stripQuery(target), "/versions");
}

/// Check if this is a validate-providers request path.
pub fn isValidateProvidersPath(target: []const u8) bool {
    return std.mem.endsWith(u8, stripQuery(target), "/validate-providers");
}

/// Check if this is a validate-channels request path.
pub fn isValidateChannelsPath(target: []const u8) bool {
    return std.mem.endsWith(u8, stripQuery(target), "/validate-channels");
}

fn stripVersionPrefix(tag: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, tag, "v")) tag[1..] else tag;
}

fn parseVersionSegmentOrZero(segment: ?[]const u8) ?u64 {
    const value = segment orelse return 0;
    if (value.len == 0) return 0;
    return std.fmt.parseUnsigned(u64, value, 10) catch null;
}

fn compareVersionTags(a: []const u8, b: []const u8) std.math.Order {
    var a_it = std.mem.splitScalar(u8, stripVersionPrefix(a), '.');
    var b_it = std.mem.splitScalar(u8, stripVersionPrefix(b), '.');

    while (true) {
        const a_seg = a_it.next();
        const b_seg = b_it.next();
        if (a_seg == null and b_seg == null) return .eq;

        const a_num = parseVersionSegmentOrZero(a_seg);
        const b_num = parseVersionSegmentOrZero(b_seg);
        if (a_num != null and b_num != null) {
            if (a_num.? < b_num.?) return .lt;
            if (a_num.? > b_num.?) return .gt;
            continue;
        }

        const order = std.mem.order(u8, a_seg orelse "", b_seg orelse "");
        if (order != .eq) return order;
    }
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// Handle GET /api/wizard/{component} — runs component --export-manifest.
/// Returns the manifest JSON directly (the component owns its wizard definition).
/// Returns null if the component is unknown or binary not found.
/// Caller owns the returned memory.
pub fn handleGetWizard(allocator: std.mem.Allocator, component_name: []const u8, paths: paths_mod.Paths, state: *state_mod.State) ?[]const u8 {
    // Verify the component is known
    if (registry.findKnownComponent(component_name) == null) return null;

    // Try existing binary first
    if (findOrFetchComponentBinary(allocator, component_name, paths)) |bin_path| {
        defer allocator.free(bin_path);
        if (component_cli.exportManifest(allocator, bin_path)) |json| {
            return augmentWizardManifest(allocator, component_name, json, state, paths) orelse json;
        } else |_| {}
        // Existing binary doesn't support --export-manifest, try fetching latest
    }

    // Download latest release and retry
    if (fetchLatestComponentBinary(allocator, component_name, paths)) |bin_path| {
        defer allocator.free(bin_path);
        if (component_cli.exportManifest(allocator, bin_path)) |json| {
            return augmentWizardManifest(allocator, component_name, json, state, paths) orelse json;
        } else |_| {}
    }

    return allocator.dupe(u8, "{\"error\":\"no compatible version found, check GitHub releases\"}") catch null;
}

fn listModelsForProvider(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    paths: paths_mod.Paths,
    provider: []const u8,
    api_key: []const u8,
) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    const bin_path = findOrFetchComponentBinary(allocator, component_name, paths) orelse return null;
    defer allocator.free(bin_path);

    return component_cli.listModels(allocator, bin_path, provider, api_key) catch null;
}

/// Handle GET /api/wizard/{component}/models — runs component --list-models.
/// Expects query params: provider and api_key.
/// Returns the JSON model array directly.
pub fn handleGetModels(allocator: std.mem.Allocator, component_name: []const u8, paths: paths_mod.Paths, target: []const u8) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    // Parse query string for provider and api_key
    const query_start = std.mem.indexOf(u8, target, "?") orelse return null;
    const query = target[query_start + 1 ..];

    var provider: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;

    var pairs = std.mem.splitScalar(u8, query, '&');
    while (pairs.next()) |pair| {
        if (std.mem.indexOf(u8, pair, "=")) |eq| {
            const key = pair[0..eq];
            const val = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, "provider")) provider = val;
            if (std.mem.eql(u8, key, "api_key")) api_key = val;
        }
    }

    const prov = provider orelse return null;
    const key = api_key orelse "";

    return listModelsForProvider(allocator, component_name, paths, prov, key);
}

/// Handle POST /api/wizard/{component}/models — runs component --list-models.
/// Expects JSON body: {"provider":"...", "api_key":"..."}.
/// Returns the JSON model array directly.
pub fn handlePostModels(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    paths: paths_mod.Paths,
    body: []const u8,
) ?[]const u8 {
    const parsed = std.json.parseFromSlice(struct {
        provider: []const u8,
        api_key: []const u8 = "",
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;
    defer parsed.deinit();

    if (parsed.value.provider.len == 0) {
        return allocator.dupe(u8, "{\"error\":\"provider is required\"}") catch null;
    }

    return listModelsForProvider(
        allocator,
        component_name,
        paths,
        parsed.value.provider,
        parsed.value.api_key,
    );
}

/// Handle GET /api/wizard/{component}/versions — fetch available releases from GitHub.
/// Returns a JSON array of version options: [{"value":"v1.0.0","label":"v1.0.0","recommended":true}, ...]
/// Falls back to [{"value":"latest","label":"latest","recommended":true}] on fetch failure.
/// Returns null if the component is unknown.
/// Caller owns the returned memory.
pub fn handleGetVersions(allocator: std.mem.Allocator, component_name: []const u8) ?[]const u8 {
    const known = registry.findKnownComponent(component_name) orelse return null;

    const releases = versions.fetchReleases(allocator, known.repo) catch
        return allocator.dupe(u8, "[{\"value\":\"latest\",\"label\":\"latest\",\"recommended\":true}]") catch null;
    defer releases.deinit();

    // Build JSON array of version options, filtering by min_version
    var buf = std.array_list.Managed(u8).init(allocator);
    buf.appendSlice("[") catch return null;
    var count: usize = 0;
    for (releases.value) |rel| {
        if (rel.prerelease) continue;
        // Skip versions older than min_version
        if (known.min_version.len > 0 and compareVersionTags(rel.tag_name, known.min_version) == .lt) continue;
        if (count > 0) buf.append(',') catch return null;
        buf.appendSlice("{\"value\":\"") catch return null;
        buf.appendSlice(rel.tag_name) catch return null;
        buf.appendSlice("\",\"label\":\"") catch return null;
        buf.appendSlice(rel.tag_name) catch return null;
        buf.appendSlice("\"") catch return null;
        if (count == 0) buf.appendSlice(",\"recommended\":true") catch return null;
        buf.appendSlice("}") catch return null;
        count += 1;
    }
    buf.appendSlice("]") catch return null;
    return buf.toOwnedSlice() catch null;
}

/// Handle GET /api/free-port — find a free TCP port starting from 3000.
/// Returns JSON like {"port":3000}.
/// Caller owns the returned memory.
pub fn handleFreePort(allocator: std.mem.Allocator) ![]const u8 {
    const start_port: u16 = 3000;
    var port: u16 = start_port;
    while (port < 65535) : (port += 1) {
        if (isPortFree(port)) {
            return std.fmt.allocPrint(allocator, "{{\"port\":{d}}}", .{port});
        }
    }
    // Fallback to default
    return try allocator.dupe(u8, "{\"port\":3000}");
}

fn isPortFree(port: u16) bool {
    const addr = std.net.Address.resolveIp("127.0.0.1", port) catch return false;
    const sock = std.posix.socket(addr.any.family, std.posix.SOCK.STREAM, std.posix.IPPROTO.TCP) catch return false;
    defer std.posix.close(sock);
    std.posix.bind(sock, &addr.any, addr.getOsSockLen()) catch return false;
    return true;
}

fn augmentWizardManifest(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    manifest_json: []const u8,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ?[]const u8 {
    if (!std.mem.eql(u8, component_name, "nullboiler")) return null;

    const trackers = integration_mod.listNullTickets(allocator, state, paths) catch return null;
    defer integration_mod.deinitNullTicketsConfigs(allocator, trackers);
    if (trackers.len == 0) return null;

    const parsed = manifest_mod.parseManifest(allocator, manifest_json) catch return null;
    defer parsed.deinit();

    const base = parsed.value;
    const options = allocator.alloc(manifest_mod.StepOption, trackers.len + 1) catch return null;
    defer allocator.free(options);
    options[0] = .{
        .value = "",
        .label = "No Link",
        .description = "Configure NullTickets later",
    };
    for (trackers, 0..) |tracker, idx| {
        const desc = std.fmt.allocPrint(allocator, "Use local NullTickets on port {d}", .{tracker.port}) catch return null;
        options[idx + 1] = .{
            .value = tracker.name,
            .label = tracker.name,
            .description = desc,
            .recommended = idx == 0,
        };
    }
    defer {
        for (options[1..]) |option| allocator.free(option.description);
    }

    const steps = allocator.alloc(manifest_mod.WizardStep, base.wizard.steps.len + 1) catch return null;
    defer allocator.free(steps);
    @memcpy(steps[0..base.wizard.steps.len], base.wizard.steps);
    steps[base.wizard.steps.len] = .{
        .id = "tracker_instance",
        .title = "Link NullTickets",
        .description = "Auto-connect this NullBoiler instance to a local NullTickets tracker",
        .type = .select,
        .required = false,
        .options = options,
        .default_value = if (trackers.len == 1) trackers[0].name else "",
    };

    var manifest = base;
    manifest.wizard.steps = steps;
    return std.json.Stringify.valueAlloc(allocator, manifest, .{}) catch return null;
}

fn prepareWizardBody(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
) ?[]const u8 {
    if (!std.mem.eql(u8, component_name, "nullboiler")) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    const tracker_instance = if (parsed.value.object.get("tracker_instance")) |value|
        if (value == .string and value.string.len > 0) value.string else null
    else
        null;
    if (tracker_instance == null) return null;

    var tracker_cfg = (integration_mod.loadNullTicketsConfig(allocator, paths, tracker_instance.?) catch return null) orelse return null;
    defer integration_mod.deinitNullTicketsConfig(allocator, &tracker_cfg);

    var root = parsed.value.object;
    const tracker_url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{tracker_cfg.port}) catch return null;
    root.put("tracker_enabled", .{ .string = "true" }) catch return null;
    root.put("tracker_url", .{ .string = tracker_url }) catch return null;
    if (tracker_cfg.api_token) |token| {
        root.put("tracker_api_token", .{ .string = token }) catch return null;
    }
    if (!root.contains("tracker_claim_role")) {
        root.put("tracker_claim_role", .{ .string = "coder" }) catch return null;
    }

    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch return null;
}

fn validateWizardBodyForInstall(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
) ?[]const u8 {
    if (!std.mem.eql(u8, component_name, "nullboiler")) return null;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;

    const tracker_enabled = if (parsed.value.object.get("tracker_enabled")) |value|
        value == .string and std.mem.eql(u8, value.string, "true")
    else
        false;
    if (!tracker_enabled) return null;

    const pipeline_id = if (parsed.value.object.get("tracker_pipeline_id")) |value|
        value == .string and value.string.len > 0
    else
        false;
    if (pipeline_id) return null;

    return allocator.dupe(u8, "{\"error\":\"tracker_pipeline_id is required when tracker mode is enabled\"}") catch null;
}

fn stripQuery(target: []const u8) []const u8 {
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return target;
    return target[0..qmark];
}

/// Find a previously downloaded binary for the component under {root}/bin/.
/// Returns the lexicographically latest version if multiple binaries exist.
fn findInstalledComponentBinary(allocator: std.mem.Allocator, component: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    const bin_dir = std.fmt.allocPrint(allocator, "{s}/bin", .{paths.root}) catch return null;
    defer allocator.free(bin_dir);

    var dir = std.fs.openDirAbsolute(bin_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    const prefix = std.fmt.allocPrint(allocator, "{s}-", .{component}) catch return null;
    defer allocator.free(prefix);

    var best_name: ?[]const u8 = null;
    defer if (best_name) |n| allocator.free(n);
    var best_path: ?[]const u8 = null;

    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

        const candidate = std.fmt.allocPrint(allocator, "{s}/{s}", .{ bin_dir, entry.name }) catch continue;
        if (std.fs.openFileAbsolute(candidate, .{})) |f| {
            f.close();
        } else |_| {
            allocator.free(candidate);
            continue;
        }

        if (best_name == null or std.mem.order(u8, entry.name, best_name.?) == .gt) {
            if (best_name) |n| allocator.free(n);
            if (best_path) |p| allocator.free(p);
            best_name = allocator.dupe(u8, entry.name) catch {
                allocator.free(candidate);
                continue;
            };
            best_path = candidate;
        } else {
            allocator.free(candidate);
        }
    }

    return best_path;
}

fn findOrFetchComponentBinary(allocator: std.mem.Allocator, component: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    if (findInstalledComponentBinary(allocator, component, paths)) |bin| {
        return bin;
    }
    if (builtin.is_test) return null;
    if (local_binary.find(allocator, component)) |bin| {
        return bin;
    }
    return fetchLatestComponentBinary(allocator, component, paths);
}

fn fetchLatestComponentBinary(allocator: std.mem.Allocator, component: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    const known = registry.findKnownComponent(component) orelse return null;
    var release = registry.fetchLatestRelease(allocator, known.repo) catch return null;
    defer release.deinit();

    const platform_key = comptime platform.detect().toString();
    const asset = registry.findAssetForComponentPlatform(allocator, release.value, component, platform_key) orelse return null;

    paths.ensureDirs() catch return null;
    const bin_path = paths.binary(allocator, component, release.value.tag_name) catch return null;

    if (std.fs.openFileAbsolute(bin_path, .{})) |f| {
        f.close();
        return bin_path;
    } else |_| {}

    downloader.download(allocator, asset.browser_download_url, bin_path) catch {
        allocator.free(bin_path);
        return null;
    };
    return bin_path;
}

/// Handle POST /api/wizard/{component} — accepts wizard answers and initiates install.
/// Calls orchestrator.install() to perform the full install flow.
/// Returns null if the component is unknown (caller should return 404).
/// Caller owns the returned memory on success.
pub fn handlePostWizard(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
    state: *state_mod.State,
    manager: *manager_mod.Manager,
) ?[]const u8 {
    // Verify the component is known
    if (registry.findKnownComponent(component_name) == null) return null;

    // Validate the body is parseable JSON
    const parsed = std.json.parseFromSlice(
        struct {
            instance_name: []const u8,
            version: []const u8 = "latest",
        },
        allocator,
        body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;
    defer parsed.deinit();

    const effective_body = prepareWizardBody(allocator, component_name, body, paths) orelse body;
    defer if (effective_body.ptr != body.ptr) allocator.free(effective_body);

    if (validateWizardBodyForInstall(allocator, component_name, effective_body)) |json| {
        return json;
    }

    // Call orchestrator to perform the install
    const result = orchestrator.install(allocator, .{
        .component = component_name,
        .instance_name = parsed.value.instance_name,
        .version = parsed.value.version,
        .answers_json = effective_body,
    }, paths, state, manager) catch |err| {
        return buildErrorResponse(allocator, err);
    };
    defer allocator.free(result.version);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    buildPostResponse(&buf, component_name, result.instance_name, result.version) catch return null;
    return buf.toOwnedSlice() catch null;
}

fn buildPostResponse(buf: *std.array_list.Managed(u8), component_name: []const u8, instance_name: []const u8, ver: []const u8) !void {
    try buf.appendSlice("{\"status\":\"ok\",\"component\":\"");
    try appendEscaped(buf, component_name);
    try buf.appendSlice("\",\"instance\":\"");
    try appendEscaped(buf, instance_name);
    try buf.appendSlice("\",\"version\":\"");
    try appendEscaped(buf, ver);
    try buf.appendSlice("\"}");
}

/// Build a JSON error response string for an InstallError.
fn buildErrorResponse(allocator: std.mem.Allocator, err: orchestrator.InstallError) ?[]const u8 {
    const msg = switch (err) {
        error.UnknownComponent => "unknown component",
        error.InstanceExists => "instance name already exists",
        error.ManifestNotFound => "manifest not found",
        error.ManifestParseError => "manifest parse error",
        error.FetchFailed => "failed to fetch release info",
        error.NoPlatformAsset => "no binary available for this platform",
        error.DownloadFailed => "binary download failed",
        error.DirCreationFailed => "failed to create instance directories",
        error.ConfigGenerationFailed => "config generation failed",
        error.StateError => "failed to update state",
        error.StartFailed => "failed to start instance",
    };
    const detail = orchestrator.getLastErrorDetail();
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice("{\"error\":\"") catch return null;
    buf.appendSlice(msg) catch return null;
    if (detail.len > 0) {
        buf.appendSlice(": ") catch return null;
        appendEscaped(&buf, detail) catch return null;
    }
    buf.appendSlice("\"}") catch return null;
    return buf.toOwnedSlice() catch null;
}

/// Handle POST /api/wizard/{component}/validate-providers
pub fn handleValidateProviders(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
    state: *state_mod.State,
) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    const bin_path = findOrFetchComponentBinary(allocator, component_name, paths) orelse
        return allocator.dupe(u8, "{\"error\":\"component binary not found\"}") catch null;
    defer allocator.free(bin_path);

    const parsed = std.json.parseFromSlice(struct {
        providers: []const struct {
            provider: []const u8,
            api_key: []const u8 = "",
            model: []const u8 = "",
            base_url: []const u8 = "",
        },
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;
    defer parsed.deinit();

    // Create temp directory for probes
    const timestamp = @abs(std.time.milliTimestamp());
    const tmp_dir = std.fmt.allocPrint(allocator, "/tmp/nullhub-wizard-validate-{d}", .{timestamp}) catch return null;
    defer {
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        allocator.free(tmp_dir);
    }
    std.fs.makeDirAbsolute(tmp_dir) catch return null;

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice("{\"results\":[") catch return null;

    // Track validation results for auto-save
    const ProbeResult = struct { live_ok: bool };
    var probe_results = std.array_list.Managed(ProbeResult).init(allocator);
    defer probe_results.deinit();
    var saved_providers_warning: ?[]const u8 = null;

    for (parsed.value.providers, 0..) |prov, idx| {
        if (idx > 0) buf.append(',') catch return null;

        writeMinimalProviderConfig(allocator, tmp_dir, prov.provider, prov.api_key, prov.base_url) catch {
            appendProviderResult(&buf, prov.provider, false, "config_write_failed") catch return null;
            probe_results.append(.{ .live_ok = false }) catch return null;
            continue;
        };

        const result = probeProviderViaComponentBinary(allocator, component_name, bin_path, tmp_dir, prov.provider, prov.model);
        appendProviderResult(&buf, prov.provider, result.live_ok, result.reason) catch return null;
        probe_results.append(.{ .live_ok = result.live_ok }) catch return null;
    }

    buf.appendSlice("]") catch return null;

    // Auto-save validated providers
    var did_save = false;
    for (parsed.value.providers, 0..) |prov, idx| {
        if (idx < probe_results.items.len and probe_results.items[idx].live_ok) {
            if (!state.hasSavedProvider(prov.provider, prov.api_key, prov.model)) {
                state.addSavedProvider(.{
                    .provider = prov.provider,
                    .api_key = prov.api_key,
                    .model = prov.model,
                    .validated_with = component_name,
                }) catch {
                    saved_providers_warning = "validated providers could not be saved";
                    continue;
                };
                // Set validated_at on the just-added provider
                const providers_list = state.savedProviders();
                if (providers_list.len > 0) {
                    const new_id = providers_list[providers_list.len - 1].id;
                    const now = providers_api.nowIso8601(allocator) catch "";
                    if (now.len > 0) {
                        _ = state.updateSavedProvider(new_id, .{ .validated_at = now }) catch {
                            saved_providers_warning = "validated providers could not be fully saved";
                            allocator.free(now);
                            continue;
                        };
                        allocator.free(now);
                    }
                }
                did_save = true;
            }
        }
    }
    if (did_save) {
        state.save() catch {
            saved_providers_warning = "validated providers could not be persisted";
        };
    }

    if (saved_providers_warning) |warning| {
        buf.appendSlice(",\"saved_providers_warning\":\"") catch return null;
        appendEscaped(&buf, warning) catch return null;
        buf.appendSlice("\"") catch return null;
    }
    buf.appendSlice("}") catch return null;

    return buf.toOwnedSlice() catch null;
}

fn writeMinimalProviderConfig(
    allocator: std.mem.Allocator,
    dir: []const u8,
    provider: []const u8,
    api_key: []const u8,
    base_url: []const u8,
) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{dir});
    defer allocator.free(config_path);

    var cfg_buf = std.array_list.Managed(u8).init(allocator);
    defer cfg_buf.deinit();

    try cfg_buf.appendSlice("{\"models\":{\"providers\":{\"");
    try appendEscaped(&cfg_buf, provider);
    try cfg_buf.appendSlice("\":{\"api_key\":\"");
    try appendEscaped(&cfg_buf, api_key);
    try cfg_buf.appendSlice("\"");
    if (base_url.len > 0) {
        try cfg_buf.appendSlice(",\"base_url\":\"");
        try appendEscaped(&cfg_buf, base_url);
        try cfg_buf.appendSlice("\"");
    }
    try cfg_buf.appendSlice("}}}}");

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();
    try file.writeAll(cfg_buf.items);
}

fn probeProviderViaComponentBinary(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    instance_home: []const u8,
    provider: []const u8,
    model: []const u8,
) ProviderProbeResult {
    const args: []const []const u8 = if (model.len > 0)
        &.{ "--probe-provider-health", "--provider", provider, "--model", model, "--timeout-secs", "10" }
    else
        &.{ "--probe-provider-health", "--provider", provider, "--timeout-secs", "10" };

    const result = component_cli.runWithComponentHome(
        allocator,
        component_name,
        binary_path,
        args,
        null,
        instance_home,
    ) catch return .{ .live_ok = false, .reason = "probe_exec_failed" };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const probe_parsed = std.json.parseFromSlice(struct {
        live_ok: bool = false,
        reason: ?[]const u8 = null,
    }, allocator, result.stdout, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return .{
        .live_ok = false,
        .reason = if (result.success) "invalid_probe_response" else "probe_exec_failed",
    };
    defer probe_parsed.deinit();

    const reason = probe_parsed.value.reason orelse (if (probe_parsed.value.live_ok) "ok" else "auth_check_failed");
    return .{ .live_ok = probe_parsed.value.live_ok, .reason = reason };
}

fn appendProviderResult(buf: *std.array_list.Managed(u8), provider: []const u8, live_ok: bool, reason: []const u8) !void {
    try buf.appendSlice("{\"provider\":\"");
    try appendEscaped(buf, provider);
    try buf.appendSlice("\",\"live_ok\":");
    try buf.appendSlice(if (live_ok) "true" else "false");
    try buf.appendSlice(",\"reason\":\"");
    try appendEscaped(buf, reason);
    try buf.appendSlice("\"}");
}

/// Handle POST /api/wizard/{component}/validate-channels
pub fn handleValidateChannels(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
    state: *state_mod.State,
) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    const bin_path = findOrFetchComponentBinary(allocator, component_name, paths) orelse
        return allocator.dupe(u8, "{\"error\":\"component binary not found\"}") catch null;
    defer allocator.free(bin_path);

    const timestamp = @abs(std.time.milliTimestamp());
    const tmp_dir = std.fmt.allocPrint(allocator, "/tmp/nullhub-wizard-validate-ch-{d}", .{timestamp}) catch return null;
    defer {
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        allocator.free(tmp_dir);
    }
    std.fs.makeDirAbsolute(tmp_dir) catch return null;

    // Write the full body as config (it contains {"channels": {...}})
    const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{tmp_dir}) catch return null;
    defer allocator.free(config_path);
    {
        const file = std.fs.createFileAbsolute(config_path, .{}) catch return null;
        defer file.close();
        file.writeAll(body) catch return null;
    }

    // Parse body to iterate channels and accounts
    var tree = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch
        return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;
    defer tree.deinit();

    const channels_val = switch (tree.value) {
        .object => |obj| obj.get("channels") orelse return allocator.dupe(u8, "{\"error\":\"missing channels field\"}") catch null,
        else => return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null,
    };
    const channels_map = switch (channels_val) {
        .object => |obj| obj,
        else => return allocator.dupe(u8, "{\"error\":\"channels must be an object\"}") catch null,
    };

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice("{\"results\":[") catch return null;

    const ValidatedPair = struct { channel_type: []const u8, account: []const u8 };
    var validated_pairs = std.array_list.Managed(ValidatedPair).init(allocator);
    defer validated_pairs.deinit();
    var saved_channels_warning: ?[]const u8 = null;

    var first = true;
    var ch_it = channels_map.iterator();
    while (ch_it.next()) |ch_entry| {
        const channel_type = ch_entry.key_ptr.*;
        const accounts = switch (ch_entry.value_ptr.*) {
            .object => |obj| obj,
            else => continue,
        };

        var acc_it = accounts.iterator();
        while (acc_it.next()) |acc_entry| {
            const account_name = acc_entry.key_ptr.*;
            if (!first) buf.append(',') catch return null;
            first = false;

            const ch_result = component_cli.runWithComponentHome(
                allocator,
                component_name,
                bin_path,
                &.{ "--probe-channel-health", "--channel", channel_type, "--account", account_name, "--timeout-secs", "10" },
                null,
                tmp_dir,
            ) catch {
                appendChannelResult(&buf, channel_type, account_name, false, "probe_exec_failed") catch return null;
                continue;
            };
            defer allocator.free(ch_result.stdout);
            defer allocator.free(ch_result.stderr);

            const probe_parsed = std.json.parseFromSlice(struct {
                live_ok: bool = false,
                reason: ?[]const u8 = null,
            }, allocator, ch_result.stdout, .{
                .allocate = .alloc_if_needed,
                .ignore_unknown_fields = true,
            }) catch {
                appendChannelResult(&buf, channel_type, account_name, false, "invalid_probe_response") catch return null;
                continue;
            };
            defer probe_parsed.deinit();

            const reason = probe_parsed.value.reason orelse (if (probe_parsed.value.live_ok) "ok" else "probe_failed");
            if (probe_parsed.value.live_ok) {
                validated_pairs.append(.{ .channel_type = channel_type, .account = account_name }) catch {};
            }
            appendChannelResult(&buf, channel_type, account_name, probe_parsed.value.live_ok, reason) catch return null;
        }
    }

    // Auto-save validated channels
    var did_save = false;
    for (validated_pairs.items) |pair| {
        const accs = switch (channels_map.get(pair.channel_type) orelse continue) {
            .object => |obj| obj,
            else => continue,
        };
        const acc_val = accs.get(pair.account) orelse continue;
        const config_str = std.json.Stringify.valueAlloc(allocator, acc_val, .{}) catch continue;
        defer allocator.free(config_str);

        if (!state.hasSavedChannel(pair.channel_type, pair.account, config_str)) {
            const now = providers_api.nowIso8601(allocator) catch "";
            defer if (now.len > 0) allocator.free(now);
            state.addSavedChannel(.{
                .channel_type = pair.channel_type,
                .account = pair.account,
                .config = config_str,
                .validated_with = component_name,
                .validated_at = now,
            }) catch {
                saved_channels_warning = "validated channels could not be saved";
                continue;
            };
            did_save = true;
        }
    }
    if (did_save) {
        state.save() catch {
            saved_channels_warning = "validated channels could not be persisted";
        };
    }

    buf.appendSlice("]") catch return null;
    if (saved_channels_warning) |warning| {
        buf.appendSlice(",\"saved_channels_warning\":\"") catch return null;
        appendEscaped(&buf, warning) catch return null;
        buf.appendSlice("\"") catch return null;
    }
    buf.appendSlice("}") catch return null;
    return buf.toOwnedSlice() catch null;
}

fn appendChannelResult(buf: *std.array_list.Managed(u8), channel: []const u8, account: []const u8, live_ok: bool, reason: []const u8) !void {
    try buf.appendSlice("{\"channel\":\"");
    try appendEscaped(buf, channel);
    try buf.appendSlice("\",\"account\":\"");
    try appendEscaped(buf, account);
    try buf.appendSlice("\",\"live_ok\":");
    try buf.appendSlice(if (live_ok) "true" else "false");
    try buf.appendSlice(",\"reason\":\"");
    try appendEscaped(buf, reason);
    try buf.appendSlice("\"}");
}

// ─── Public wrappers for providers API ───────────────────────────────────────

pub fn findOrFetchComponentBinaryPub(allocator: std.mem.Allocator, component: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    return findOrFetchComponentBinary(allocator, component, paths);
}

pub fn writeMinimalProviderConfigPub(allocator: std.mem.Allocator, dir: []const u8, provider: []const u8, api_key: []const u8, base_url: []const u8) !void {
    return writeMinimalProviderConfig(allocator, dir, provider, api_key, base_url);
}

pub fn probeProviderViaComponentBinaryPub(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    instance_home: []const u8,
    provider: []const u8,
    model: []const u8,
) ProviderProbeResult {
    return probeProviderViaComponentBinary(allocator, component_name, binary_path, instance_home, provider, model);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "extractComponentName parses wizard paths correctly" {
    // Valid paths
    const name1 = extractComponentName("/api/wizard/nullclaw");
    try std.testing.expect(name1 != null);
    try std.testing.expectEqualStrings("nullclaw", name1.?);

    const name2 = extractComponentName("/api/wizard/nullboiler");
    try std.testing.expect(name2 != null);
    try std.testing.expectEqualStrings("nullboiler", name2.?);

    // Models sub-path
    const name3 = extractComponentName("/api/wizard/nullclaw/models");
    try std.testing.expect(name3 != null);
    try std.testing.expectEqualStrings("nullclaw", name3.?);

    const name4 = extractComponentName("/api/wizard/nullclaw/models?provider=openai");
    try std.testing.expect(name4 != null);
    try std.testing.expectEqualStrings("nullclaw", name4.?);

    // Versions sub-path
    const name5 = extractComponentName("/api/wizard/nullclaw/versions");
    try std.testing.expect(name5 != null);
    try std.testing.expectEqualStrings("nullclaw", name5.?);

    // Invalid paths
    try std.testing.expect(extractComponentName("/api/wizard/") == null);
    try std.testing.expect(extractComponentName("/api/wizard") == null);
    try std.testing.expect(extractComponentName("/api/components/nullclaw") == null);
    try std.testing.expect(extractComponentName("/api/wizard/nullclaw/extra") == null);
}

test "isWizardPath identifies wizard paths" {
    try std.testing.expect(isWizardPath("/api/wizard/nullclaw"));
    try std.testing.expect(isWizardPath("/api/wizard/nullboiler"));
    try std.testing.expect(isWizardPath("/api/wizard/nullclaw/models"));
    try std.testing.expect(isWizardPath("/api/wizard/nullclaw/versions"));
    try std.testing.expect(isWizardPath("/api/wizard/nullclaw/validate-providers"));
    try std.testing.expect(isWizardPath("/api/wizard/nullclaw/validate-channels"));
    try std.testing.expect(!isWizardPath("/api/wizard/"));
    try std.testing.expect(!isWizardPath("/api/wizard"));
    try std.testing.expect(!isWizardPath("/api/components/nullclaw"));
    try std.testing.expect(!isWizardPath("/health"));
}

test "isModelsPath detects models suffix" {
    try std.testing.expect(isModelsPath("/api/wizard/nullclaw/models"));
    try std.testing.expect(isModelsPath("/api/wizard/nullclaw/models?provider=openai"));
    try std.testing.expect(!isModelsPath("/api/wizard/nullclaw"));
}

test "isVersionsPath detects versions suffix" {
    try std.testing.expect(isVersionsPath("/api/wizard/nullclaw/versions"));
    try std.testing.expect(!isVersionsPath("/api/wizard/nullclaw"));
    try std.testing.expect(!isVersionsPath("/api/wizard/nullclaw/models"));
}

test "handleGetVersions returns null for unknown component" {
    const allocator = std.testing.allocator;
    const result = handleGetVersions(allocator, "nonexistent");
    try std.testing.expect(result == null);
}

test "compareVersionTags compares numeric version segments" {
    try std.testing.expect(compareVersionTags("v2026.3.10", "v2026.3.2") == .gt);
    try std.testing.expect(compareVersionTags("v2026.3.11", "v2026.3.10") == .gt);
    try std.testing.expect(compareVersionTags("v2026.3.2", "v2026.3.2") == .eq);
    try std.testing.expect(compareVersionTags("2026.3.2", "v2026.3.2") == .eq);
}

test "findInstalledComponentBinary finds binary in bin directory" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-find-installed-binary";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var paths = try paths_mod.Paths.init(allocator, tmp_root);
    defer paths.deinit(allocator);
    try paths.ensureDirs();

    const bin_path = try paths.binary(allocator, "nullboiler", "v1.2.3");
    defer allocator.free(bin_path);

    {
        const file = try std.fs.createFileAbsolute(bin_path, .{});
        defer file.close();
        try file.writeAll("#!/bin/sh\n");
    }

    const found = findInstalledComponentBinary(allocator, "nullboiler", paths);
    try std.testing.expect(found != null);
    defer allocator.free(found.?);
    try std.testing.expectEqualStrings(bin_path, found.?);
}

test "handleGetWizard returns null for unknown component" {
    const allocator = std.testing.allocator;
    const paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-wizard-get") catch @panic("Paths.init");
    defer paths.deinit(allocator);
    var state = state_mod.State.init(allocator, "/tmp/nullhub-test-wizard-get/state.json");
    defer state.deinit();
    const result = handleGetWizard(allocator, "nonexistent", paths, &state);
    try std.testing.expect(result == null);
}

test "handleGetWizard returns null when no binary found" {
    const allocator = std.testing.allocator;
    const paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-wizard-nobin") catch @panic("Paths.init");
    defer paths.deinit(allocator);
    var state = state_mod.State.init(allocator, "/tmp/nullhub-test-wizard-nobin/state.json");
    defer state.deinit();
    // nullclaw is a known component but there's no binary in test dirs
    const result = handleGetWizard(allocator, "nullclaw", paths, &state);
    try std.testing.expect(result == null);
}

test "prepareWizardBody injects tracker settings for nullboiler" {
    const allocator = std.testing.allocator;
    var paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-wizard-prepare") catch @panic("Paths.init");
    defer paths.deinit(allocator);

    std.fs.deleteTreeAbsolute(paths.root) catch {};
    paths.ensureDirs() catch @panic("ensureDirs");

    const inst_dir = paths.instanceDir(allocator, "nulltickets", "tracker-a") catch @panic("instanceDir");
    defer allocator.free(inst_dir);
    std.fs.makePathAbsolute(inst_dir) catch @panic("makePathAbsolute");

    const config_path = paths.instanceConfig(allocator, "nulltickets", "tracker-a") catch @panic("instanceConfig");
    defer allocator.free(config_path);
    {
        const file = std.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch @panic("createFileAbsolute");
        defer file.close();
        file.writeAll("{\"port\":7711,\"api_token\":\"secret-token\"}\n") catch @panic("writeAll");
    }

    const rendered = prepareWizardBody(
        allocator,
        "nullboiler",
        "{\"instance_name\":\"worker-a\",\"tracker_instance\":\"tracker-a\"}",
        paths,
    ) orelse @panic("prepareWizardBody");
    defer allocator.free(rendered);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, rendered, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch @panic("parseFromSlice");
    defer parsed.deinit();

    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("true", obj.get("tracker_enabled").?.string);
    try std.testing.expectEqualStrings("http://127.0.0.1:7711", obj.get("tracker_url").?.string);
    try std.testing.expectEqualStrings("secret-token", obj.get("tracker_api_token").?.string);
    try std.testing.expectEqualStrings("coder", obj.get("tracker_claim_role").?.string);
}

test "handlePostWizard returns null for unknown component" {
    const allocator = std.testing.allocator;
    var paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-wizard-post2") catch @panic("Paths.init");
    defer paths.deinit(allocator);
    var state = state_mod.State.init(allocator, "/tmp/nullhub-test-wizard-post2/state.json");
    defer state.deinit();
    var mgr = manager_mod.Manager.init(allocator, paths);
    defer mgr.deinit();

    const body = "{\"instance_name\":\"my-agent\",\"version\":\"latest\"}";
    const result = handlePostWizard(allocator, "nonexistent", body, paths, &state, &mgr);
    try std.testing.expect(result == null);
}

test "handlePostWizard returns error for known component without binary" {
    const allocator = std.testing.allocator;
    var paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-wizard-post3") catch @panic("Paths.init");
    defer paths.deinit(allocator);
    var state = state_mod.State.init(allocator, "/tmp/nullhub-test-wizard-post3/state.json");
    defer state.deinit();
    var mgr = manager_mod.Manager.init(allocator, paths);
    defer mgr.deinit();

    const body = "{\"instance_name\":\"my-agent\",\"version\":\"latest\"}";
    const json = handlePostWizard(allocator, "nullclaw", body, paths, &state, &mgr);
    // In test environment, orchestrator.install will fail, so we get an error JSON
    try std.testing.expect(json != null);
    defer allocator.free(json.?);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"error\":\"") != null);
}

test "isValidateProvidersPath detects validate-providers suffix" {
    try std.testing.expect(isValidateProvidersPath("/api/wizard/nullclaw/validate-providers"));
    try std.testing.expect(!isValidateProvidersPath("/api/wizard/nullclaw"));
    try std.testing.expect(!isValidateProvidersPath("/api/wizard/nullclaw/models"));
}

test "isValidateChannelsPath detects validate-channels suffix" {
    try std.testing.expect(isValidateChannelsPath("/api/wizard/nullclaw/validate-channels"));
    try std.testing.expect(!isValidateChannelsPath("/api/wizard/nullclaw"));
    try std.testing.expect(!isValidateChannelsPath("/api/wizard/nullclaw/models"));
}

test "extractComponentName parses validate-providers path" {
    const name = extractComponentName("/api/wizard/nullclaw/validate-providers");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("nullclaw", name.?);
}

test "extractComponentName parses validate-channels path" {
    const name = extractComponentName("/api/wizard/nullclaw/validate-channels");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("nullclaw", name.?);
}
