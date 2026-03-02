const std = @import("std");
const registry = @import("../installer/registry.zig");
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
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    if (rest.len == 0) return null;

    // Check for /models suffix
    if (std.mem.indexOf(u8, rest, "/models")) |idx| {
        if (idx == 0) return null;
        return rest[0..idx];
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
    return std.mem.endsWith(u8, target, "/models");
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// Handle GET /api/wizard/{component} — runs component --export-manifest.
/// Returns the manifest JSON directly (the component owns its wizard definition).
/// Returns null if the component is unknown or binary not found.
/// Caller owns the returned memory.
pub fn handleGetWizard(allocator: std.mem.Allocator, component_name: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    // Verify the component is known
    if (registry.findKnownComponent(component_name) == null) return null;

    // Find the component binary
    const bin_path = findComponentBinary(allocator, component_name, paths) orelse return null;
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

    const bin_path = findComponentBinary(allocator, component_name, paths) orelse return null;
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

/// Find the component binary in the bins/ directory.
fn findComponentBinary(allocator: std.mem.Allocator, component: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    // Look for binary in {root}/bins/{component}/ directory
    const bins_dir = std.fmt.allocPrint(allocator, "{s}/bins/{s}", .{ paths.root, component }) catch return null;
    defer allocator.free(bins_dir);

    var dir = std.fs.openDirAbsolute(bins_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    // Find any version directory with the binary
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .directory) {
            const bin = paths.binary(allocator, component, entry.name) catch continue;
            if (std.fs.openFileAbsolute(bin, .{})) |f| {
                f.close();
                return bin;
            } else |_| {
                allocator.free(bin);
            }
        }
    }
    return null;
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
    try std.testing.expect(!isWizardPath("/api/wizard/"));
    try std.testing.expect(!isWizardPath("/api/wizard"));
    try std.testing.expect(!isWizardPath("/api/components/nullclaw"));
    try std.testing.expect(!isWizardPath("/health"));
}

test "isModelsPath detects models suffix" {
    try std.testing.expect(isModelsPath("/api/wizard/nullclaw/models"));
    try std.testing.expect(!isModelsPath("/api/wizard/nullclaw"));
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
