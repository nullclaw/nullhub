const std = @import("std");
const registry = @import("../installer/registry.zig");
const helpers = @import("helpers.zig");
const manifest_mod = @import("../core/manifest.zig");
const orchestrator = @import("../installer/orchestrator.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");
const manager_mod = @import("../supervisor/manager.zig");

const appendEscaped = helpers.appendEscaped;

// ─── Path Parsing ────────────────────────────────────────────────────────────

/// Extract the component name from a wizard API path.
/// Matches `/api/wizard/{component}`.
/// Returns null if the path doesn't match the expected prefix or is empty.
pub fn extractComponentName(target: []const u8) ?[]const u8 {
    const prefix = "/api/wizard/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    if (rest.len == 0) return null;

    // Reject paths with additional segments (e.g. /api/wizard/foo/bar)
    if (std.mem.indexOfScalar(u8, rest, '/') != null) return null;

    return rest;
}

/// Check if a target path matches `/api/wizard/{component}`.
pub fn isWizardPath(target: []const u8) bool {
    return extractComponentName(target) != null;
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// Handle GET /api/wizard/{component} — returns wizard steps and available versions.
/// Reads the bundled manifest from manifests/{component}.json to get real wizard steps.
/// Returns null if the component is unknown (caller should return 404).
/// Caller owns the returned memory.
pub fn handleGetWizard(allocator: std.mem.Allocator, component_name: []const u8) ?[]const u8 {
    // Verify the component is known
    if (registry.findKnownComponent(component_name) == null) return null;

    // Read the manifest file from manifests/{component_name}.json
    const manifest_bytes = readManifestFile(allocator, component_name) orelse return null;
    defer allocator.free(manifest_bytes);

    // Parse the manifest
    const parsed = manifest_mod.parseManifest(allocator, manifest_bytes) catch return null;
    defer parsed.deinit();

    // Serialize the wizard steps to JSON
    const steps_json = std.json.Stringify.valueAlloc(
        allocator,
        parsed.value.wizard.steps,
        .{ .emit_null_optional_fields = false },
    ) catch return null;
    defer allocator.free(steps_json);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    buildGetResponse(&buf, component_name, steps_json) catch return null;
    return buf.toOwnedSlice() catch null;
}

/// Read the manifest file for a component from the manifests/ directory.
fn readManifestFile(allocator: std.mem.Allocator, component_name: []const u8) ?[]const u8 {
    // Build path: manifests/{component_name}.json
    const path = std.fmt.allocPrint(allocator, "manifests/{s}.json", .{component_name}) catch return null;
    defer allocator.free(path);

    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();

    return file.readToEndAlloc(allocator, 1024 * 1024) catch null;
}

fn buildGetResponse(buf: *std.array_list.Managed(u8), component_name: []const u8, steps_json: []const u8) !void {
    try buf.appendSlice("{\"component\":\"");
    try buf.appendSlice(component_name);
    try buf.appendSlice("\",\"steps\":");
    try buf.appendSlice(steps_json);
    try buf.appendSlice(",\"versions\":[\"latest\"]}");
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
            answers: std.json.ArrayHashMap(std.json.Value) = .{ .map = .{} },
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
        .answers = parsed.value.answers,
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

    // Invalid paths
    try std.testing.expect(extractComponentName("/api/wizard/") == null);
    try std.testing.expect(extractComponentName("/api/wizard") == null);
    try std.testing.expect(extractComponentName("/api/components/nullclaw") == null);
    try std.testing.expect(extractComponentName("/api/wizard/nullclaw/extra") == null);
}

test "isWizardPath identifies wizard paths" {
    try std.testing.expect(isWizardPath("/api/wizard/nullclaw"));
    try std.testing.expect(isWizardPath("/api/wizard/nullboiler"));
    try std.testing.expect(!isWizardPath("/api/wizard/"));
    try std.testing.expect(!isWizardPath("/api/wizard"));
    try std.testing.expect(!isWizardPath("/api/components/nullclaw"));
    try std.testing.expect(!isWizardPath("/health"));
}

test "handleGetWizard returns valid JSON with component name and real steps" {
    const allocator = std.testing.allocator;

    const json = handleGetWizard(allocator, "nullclaw");
    try std.testing.expect(json != null);
    defer allocator.free(json.?);

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"component\":\"nullclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"versions\":[\"latest\"]") != null);

    // Verify real wizard steps are present (from manifests/nullclaw.json)
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"steps\":[{") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"id\":\"provider\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"id\":\"api_key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"id\":\"channels\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"id\":\"gateway_port\"") != null);

    // Verify the response is valid JSON by parsing it
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json.?, .{}) catch |err| {
        std.debug.print("Failed to parse response JSON: {}\n", .{err});
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit();
}

test "handleGetWizard returns null for unknown component" {
    const allocator = std.testing.allocator;
    const result = handleGetWizard(allocator, "nonexistent");
    try std.testing.expect(result == null);
}

test "handlePostWizard returns error JSON for known component (no GitHub in test env)" {
    const allocator = std.testing.allocator;
    var paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-wizard-post") catch @panic("Paths.init");
    defer paths.deinit(allocator);
    var state = state_mod.State.init(allocator, "/tmp/nullhub-test-wizard-post/state.json");
    defer state.deinit();
    var mgr = manager_mod.Manager.init(allocator, paths);
    defer mgr.deinit();

    const body = "{\"instance_name\":\"my-agent\",\"version\":\"latest\",\"answers\":{\"provider\":\"openrouter\"}}";
    const json = handlePostWizard(allocator, "nullclaw", body, paths, &state, &mgr);
    // In test environment, orchestrator.install will fail (no GitHub/binary), so we get an error JSON
    try std.testing.expect(json != null);
    defer allocator.free(json.?);

    // Should contain an error field (e.g. fetch failed or manifest not found)
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"error\":\"") != null);
}

test "handlePostWizard returns null for unknown component" {
    const allocator = std.testing.allocator;
    var paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-wizard-post2") catch @panic("Paths.init");
    defer paths.deinit(allocator);
    var state = state_mod.State.init(allocator, "/tmp/nullhub-test-wizard-post2/state.json");
    defer state.deinit();
    var mgr = manager_mod.Manager.init(allocator, paths);
    defer mgr.deinit();

    const body = "{\"instance_name\":\"my-agent\",\"version\":\"latest\",\"answers\":{}}";
    const result = handlePostWizard(allocator, "nonexistent", body, paths, &state, &mgr);
    try std.testing.expect(result == null);
}
