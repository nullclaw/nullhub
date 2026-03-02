const std = @import("std");
const builtin = @import("builtin");
const registry = @import("../installer/registry.zig");
const downloader = @import("../installer/downloader.zig");
const versions = @import("../installer/versions.zig");
const platform = @import("../core/platform.zig");
const local_binary = @import("../core/local_binary.zig");
const helpers = @import("helpers.zig");
const component_cli = @import("../core/component_cli.zig");
const orchestrator = @import("../installer/orchestrator.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");
const manager_mod = @import("../supervisor/manager.zig");

const appendEscaped = helpers.appendEscaped;

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

// ─── Handlers ────────────────────────────────────────────────────────────────

/// Handle GET /api/wizard/{component} — runs component --export-manifest.
/// Returns the manifest JSON directly (the component owns its wizard definition).
/// Returns null if the component is unknown or binary not found.
/// Caller owns the returned memory.
pub fn handleGetWizard(allocator: std.mem.Allocator, component_name: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    // Verify the component is known
    if (registry.findKnownComponent(component_name) == null) return null;

    // Find or download the component binary
    const bin_path = findOrFetchComponentBinary(allocator, component_name, paths) orelse return null;
    defer allocator.free(bin_path);

    // Run --export-manifest
    const manifest_json = component_cli.exportManifest(allocator, bin_path) catch return null;
    return manifest_json;
}

/// Handle GET /api/wizard/{component}/models — runs component --list-models.
/// Expects query params: provider and api_key.
/// Returns the JSON model array directly.
pub fn handleGetModels(allocator: std.mem.Allocator, component_name: []const u8, paths: paths_mod.Paths, target: []const u8) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    const bin_path = findOrFetchComponentBinary(allocator, component_name, paths) orelse return null;
    defer allocator.free(bin_path);

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

    return component_cli.listModels(allocator, bin_path, prov, key) catch null;
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

    // Build JSON array of version options
    var buf = std.array_list.Managed(u8).init(allocator);
    buf.appendSlice("[") catch return null;
    var count: usize = 0;
    for (releases.value) |rel| {
        if (rel.prerelease) continue;
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

    // Call orchestrator to perform the install
    const result = orchestrator.install(allocator, .{
        .component = component_name,
        .instance_name = parsed.value.instance_name,
        .version = parsed.value.version,
        .answers_json = body,
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
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice("{\"error\":\"") catch return null;
    buf.appendSlice(msg) catch return null;
    buf.appendSlice("\"}") catch return null;
    return buf.toOwnedSlice() catch null;
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
    const result = handleGetWizard(allocator, "nonexistent", paths);
    try std.testing.expect(result == null);
}

test "handleGetWizard returns null when no binary found" {
    const allocator = std.testing.allocator;
    const paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-wizard-nobin") catch @panic("Paths.init");
    defer paths.deinit(allocator);
    // nullclaw is a known component but there's no binary in test dirs
    const result = handleGetWizard(allocator, "nullclaw", paths);
    try std.testing.expect(result == null);
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
