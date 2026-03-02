const std = @import("std");
const registry = @import("../installer/registry.zig");

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
/// For now returns a stub with empty steps and versions: ["latest"].
/// Returns null if the component is unknown (caller should return 404).
/// Caller owns the returned memory.
pub fn handleGetWizard(allocator: std.mem.Allocator, component_name: []const u8) ?[]const u8 {
    // Verify the component is known
    if (registry.findKnownComponent(component_name) == null) return null;

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    buildGetResponse(&buf, component_name) catch return null;
    return buf.toOwnedSlice() catch null;
}

fn buildGetResponse(buf: *std.array_list.Managed(u8), component_name: []const u8) !void {
    try buf.appendSlice("{\"component\":\"");
    try buf.appendSlice(component_name);
    try buf.appendSlice("\",\"steps\":[],\"versions\":[\"latest\"]}");
}

/// Handle POST /api/wizard/{component} — accepts wizard answers and initiates install.
/// For now, validates the body is JSON and returns a success response.
/// Returns null if the component is unknown (caller should return 404).
/// Caller owns the returned memory on success.
pub fn handlePostWizard(allocator: std.mem.Allocator, component_name: []const u8, body: []const u8) ?[]const u8 {
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

    const instance_name = parsed.value.instance_name;

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    buildPostResponse(&buf, component_name, instance_name) catch return null;
    return buf.toOwnedSlice() catch null;
}

fn buildPostResponse(buf: *std.array_list.Managed(u8), component_name: []const u8, instance_name: []const u8) !void {
    try buf.appendSlice("{\"status\":\"ok\",\"component\":\"");
    try appendEscaped(buf, component_name);
    try buf.appendSlice("\",\"instance\":\"");
    try appendEscaped(buf, instance_name);
    try buf.appendSlice("\",\"message\":\"Installation started\"}");
}

// ─── JSON helpers ────────────────────────────────────────────────────────────

fn appendEscaped(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => try buf.append(c),
        }
    }
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

test "handleGetWizard returns valid JSON with component name" {
    const allocator = std.testing.allocator;

    const json = handleGetWizard(allocator, "nullclaw");
    try std.testing.expect(json != null);
    defer allocator.free(json.?);

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"component\":\"nullclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"steps\":[]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"versions\":[\"latest\"]") != null);
}

test "handleGetWizard returns null for unknown component" {
    const allocator = std.testing.allocator;
    const result = handleGetWizard(allocator, "nonexistent");
    try std.testing.expect(result == null);
}

test "handlePostWizard returns success JSON" {
    const allocator = std.testing.allocator;

    const body = "{\"instance_name\":\"my-agent\",\"version\":\"latest\",\"answers\":{\"provider\":\"openrouter\"}}";
    const json = handlePostWizard(allocator, "nullclaw", body);
    try std.testing.expect(json != null);
    defer allocator.free(json.?);

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"component\":\"nullclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"instance\":\"my-agent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "\"message\":\"Installation started\"") != null);
}

test "handlePostWizard returns null for unknown component" {
    const allocator = std.testing.allocator;
    const body = "{\"instance_name\":\"my-agent\",\"version\":\"latest\",\"answers\":{}}";
    const result = handlePostWizard(allocator, "nonexistent", body);
    try std.testing.expect(result == null);
}
