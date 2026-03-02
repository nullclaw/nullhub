const std = @import("std");
const registry = @import("../installer/registry.zig");
const paths_mod = @import("../core/paths.zig");

// ─── Display name derivation ─────────────────────────────────────────────────

/// Derive a display name from a component name by capitalizing the first letter.
/// Caller owns the returned memory.
pub fn deriveDisplayName(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (name.len == 0) return try allocator.dupe(u8, "");
    const buf = try allocator.alloc(u8, name.len);
    @memcpy(buf, name);
    buf[0] = std.ascii.toUpper(buf[0]);
    return buf;
}

// ─── Installation detection ─────────────────────────────────────────────────

/// Check if a component has a standalone installation at ~/.{component}/config.json
fn hasStandaloneInstall(allocator: std.mem.Allocator, component: []const u8) bool {
    const home = std.process.getEnvVarOwned(allocator, "HOME") catch return false;
    defer allocator.free(home);
    const dot_name = std.fmt.allocPrint(allocator, ".{s}", .{component}) catch return false;
    defer allocator.free(dot_name);
    const config_path = std.fs.path.join(allocator, &.{ home, dot_name, "config.json" }) catch return false;
    defer allocator.free(config_path);
    std.fs.accessAbsolute(config_path, .{}) catch return false;
    return true;
}

/// Count the number of instance subdirectories for a component.
/// Returns 0 if the instances directory doesn't exist.
fn countInstances(allocator: std.mem.Allocator, p: paths_mod.Paths, component: []const u8) !u32 {
    const inst_base = try std.fs.path.join(allocator, &.{ p.root, "instances", component });
    defer allocator.free(inst_base);

    var dir = std.fs.openDirAbsolute(inst_base, .{ .iterate = true }) catch return 0;
    defer dir.close();

    var count: u32 = 0;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory or entry.kind == .sym_link) {
            count += 1;
        }
    }
    return count;
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// Handle GET /api/components — returns list of all known components with metadata.
/// Caller owns the returned memory.
pub fn handleList(allocator: std.mem.Allocator) ![]const u8 {
    var p = paths_mod.Paths.init(allocator, null) catch |err| switch (err) {
        error.HomeNotSet => return try buildListJson(allocator, null),
        else => return err,
    };
    defer p.deinit(allocator);

    return buildListJson(allocator, p);
}

fn buildListJson(allocator: std.mem.Allocator, p: ?paths_mod.Paths) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    const writer = buf.writer();

    try writer.writeAll("{\"components\":[");

    for (registry.known_components, 0..) |comp, i| {
        if (i > 0) try writer.writeByte(',');

        // Count managed instances if paths are available
        var instance_count: u32 = 0;
        if (p) |pp| {
            instance_count = countInstances(allocator, pp, comp.name) catch 0;
        }

        // standalone = has dot-dir config but not yet imported into nullhub
        const has_dot_dir = hasStandaloneInstall(allocator, comp.name);
        const standalone = has_dot_dir and instance_count == 0;
        const installed = has_dot_dir or instance_count > 0;

        try writer.print(
            "{{\"name\":\"{s}\",\"display_name\":\"{s}\",\"description\":\"{s}\",\"repo\":\"{s}\",\"installed\":{s},\"standalone\":{s},\"instance_count\":{d}}}",
            .{
                comp.name,
                comp.display_name,
                comp.description,
                comp.repo,
                if (installed) "true" else "false",
                if (standalone) "true" else "false",
                instance_count,
            },
        );
    }

    try writer.writeAll("]}");
    return buf.toOwnedSlice();
}

/// Handle GET /api/components/{name}/manifest — returns cached manifest or 404.
/// Returns null if no cached manifest exists.
pub fn handleManifest(allocator: std.mem.Allocator, component_name: []const u8) !?[]const u8 {
    // Verify the component is known
    if (registry.findKnownComponent(component_name) == null) {
        return null;
    }

    // Try to find a cached manifest file
    var p = paths_mod.Paths.init(allocator, null) catch return null;
    defer p.deinit(allocator);

    const manifests_dir_path = try std.fs.path.join(allocator, &.{ p.root, "manifests" });
    defer allocator.free(manifests_dir_path);

    // Look for any manifest file matching "{component_name}@*.json"
    var dir = std.fs.openDirAbsolute(manifests_dir_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    const prefix = try std.fmt.allocPrint(allocator, "{s}@", .{component_name});
    defer allocator.free(prefix);

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and
            std.mem.startsWith(u8, entry.name, prefix) and
            std.mem.endsWith(u8, entry.name, ".json"))
        {
            // Read the manifest file
            const full_path = try std.fs.path.join(allocator, &.{ manifests_dir_path, entry.name });
            defer allocator.free(full_path);

            const file = std.fs.openFileAbsolute(full_path, .{}) catch return null;
            defer file.close();

            const contents = file.readToEndAlloc(allocator, 1024 * 1024) catch return null;
            return contents;
        }
    }

    return null;
}

/// Handle POST /api/components/refresh — placeholder for future manifest refresh.
/// Returns a success response body.
pub fn handleRefresh(allocator: std.mem.Allocator) ![]const u8 {
    return try allocator.dupe(u8, "{\"status\":\"ok\"}");
}

// ─── Route extraction helper ─────────────────────────────────────────────────

/// Extract a component name from a path like "/api/components/{name}/manifest".
/// Returns null if the path doesn't match the expected pattern.
pub fn extractComponentName(target: []const u8) ?[]const u8 {
    const prefix = "/api/components/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    if (rest.len == 0) return null;

    // Find the end of the component name (next '/' or end of string)
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash_pos| {
        if (slash_pos == 0) return null;
        return rest[0..slash_pos];
    }
    return rest;
}

/// Check if a target path matches "/api/components/{name}/manifest".
pub fn isManifestPath(target: []const u8) bool {
    const prefix = "/api/components/";
    if (!std.mem.startsWith(u8, target, prefix)) return false;
    const rest = target[prefix.len..];
    if (std.mem.indexOfScalar(u8, rest, '/')) |slash_pos| {
        return std.mem.eql(u8, rest[slash_pos..], "/manifest");
    }
    return false;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "deriveDisplayName capitalizes first letter" {
    const allocator = std.testing.allocator;

    const name1 = try deriveDisplayName(allocator, "nullclaw");
    defer allocator.free(name1);
    try std.testing.expectEqualStrings("Nullclaw", name1);

    const name2 = try deriveDisplayName(allocator, "nullboiler");
    defer allocator.free(name2);
    try std.testing.expectEqualStrings("Nullboiler", name2);

    const name3 = try deriveDisplayName(allocator, "");
    defer allocator.free(name3);
    try std.testing.expectEqualStrings("", name3);
}

test "handleList returns valid JSON with all 3 known components" {
    const allocator = std.testing.allocator;

    const json = try handleList(allocator);
    defer allocator.free(json);

    // Verify it starts and ends correctly
    try std.testing.expect(std.mem.startsWith(u8, json, "{\"components\":["));
    try std.testing.expect(std.mem.endsWith(u8, json, "]}"));

    // Verify all 3 components are present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nullclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nullboiler\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nulltickets\"") != null);

    // Verify display names
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NullClaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NullBoiler\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"NullTickets\"") != null);

    // Verify descriptions are present
    try std.testing.expect(std.mem.indexOf(u8, json, "Autonomous AI agent runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "DAG-based workflow orchestrator") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "Task and issue tracker") != null);

    // Verify repo fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nullclaw/nullclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nullclaw/NullBoiler\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"nullclaw/nulltickets\"") != null);

    // Verify structural fields
    try std.testing.expect(std.mem.indexOf(u8, json, "\"installed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"instance_count\"") != null);
}

test "handleManifest returns null for non-cached manifest" {
    const allocator = std.testing.allocator;

    // This should return null since there's no cached manifest on disk
    const result = try handleManifest(allocator, "nullclaw");
    try std.testing.expect(result == null);
}

test "handleManifest returns null for unknown component" {
    const allocator = std.testing.allocator;

    const result = try handleManifest(allocator, "nonexistent");
    try std.testing.expect(result == null);
}

test "handleRefresh returns ok status" {
    const allocator = std.testing.allocator;

    const json = try handleRefresh(allocator);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", json);
}

test "extractComponentName parses paths correctly" {
    // Valid component name extraction
    const name1 = extractComponentName("/api/components/nullclaw/manifest");
    try std.testing.expect(name1 != null);
    try std.testing.expectEqualStrings("nullclaw", name1.?);

    const name2 = extractComponentName("/api/components/nullboiler/manifest");
    try std.testing.expect(name2 != null);
    try std.testing.expectEqualStrings("nullboiler", name2.?);

    // Path without sub-resource
    const name3 = extractComponentName("/api/components/nullclaw");
    try std.testing.expect(name3 != null);
    try std.testing.expectEqualStrings("nullclaw", name3.?);

    // Invalid paths
    try std.testing.expect(extractComponentName("/api/components/") == null);
    try std.testing.expect(extractComponentName("/api/components") == null);
    try std.testing.expect(extractComponentName("/api/other") == null);
}

test "isManifestPath identifies manifest paths" {
    try std.testing.expect(isManifestPath("/api/components/nullclaw/manifest"));
    try std.testing.expect(isManifestPath("/api/components/nullboiler/manifest"));
    try std.testing.expect(!isManifestPath("/api/components/nullclaw"));
    try std.testing.expect(!isManifestPath("/api/components/nullclaw/other"));
    try std.testing.expect(!isManifestPath("/api/components"));
    try std.testing.expect(!isManifestPath("/health"));
}
