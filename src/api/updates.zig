const std = @import("std");
const state_mod = @import("../core/state.zig");

// ─── Response helpers ────────────────────────────────────────────────────────

pub const ApiResponse = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

fn jsonOk(body: []const u8) ApiResponse {
    return .{ .status = "200 OK", .content_type = "application/json", .body = body };
}

fn notFound() ApiResponse {
    return .{
        .status = "404 Not Found",
        .content_type = "application/json",
        .body = "{\"error\":\"not found\"}",
    };
}

fn serverError() ApiResponse {
    return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
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

// ─── Path Parsing ────────────────────────────────────────────────────────────

pub const ParsedUpdatePath = struct {
    component: []const u8,
    name: []const u8,
};

/// Parse `/api/instances/{component}/{name}/update` from a request target.
/// Returns `null` if the path does not match.
pub fn parseUpdatePath(target: []const u8) ?ParsedUpdatePath {
    const prefix = "/api/instances/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;

    const rest = target[prefix.len..];
    if (rest.len == 0) return null;

    var it = std.mem.splitScalar(u8, rest, '/');
    const component = it.next() orelse return null;
    if (component.len == 0) return null;

    const name = it.next() orelse return null;
    if (name.len == 0) return null;

    const action = it.next() orelse return null;
    if (!std.mem.eql(u8, action, "update")) return null;

    // No extra segments allowed.
    if (it.next() != null) return null;

    return .{ .component = component, .name = name };
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/updates — check for updates across all installed instances.
/// For now, returns latest_version as "unknown" and update_available as false.
/// Real version checking will be wired in later.
pub fn handleCheckUpdates(allocator: std.mem.Allocator, s: *state_mod.State) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);

    buildUpdatesJson(&buf, s) catch return serverError();

    return jsonOk(buf.items);
}

fn buildUpdatesJson(buf: *std.array_list.Managed(u8), s: *state_mod.State) !void {
    try buf.appendSlice("{\"updates\":[");

    var first = true;
    var comp_it = s.instances.iterator();
    while (comp_it.next()) |comp_entry| {
        var inst_it = comp_entry.value_ptr.iterator();
        while (inst_it.next()) |inst_entry| {
            if (!first) try buf.append(',');
            first = false;

            try buf.appendSlice("{\"component\":\"");
            try appendEscaped(buf, comp_entry.key_ptr.*);
            try buf.appendSlice("\",\"instance\":\"");
            try appendEscaped(buf, inst_entry.key_ptr.*);
            try buf.appendSlice("\",\"current_version\":\"");
            try appendEscaped(buf, inst_entry.value_ptr.version);
            try buf.appendSlice("\",\"latest_version\":\"unknown\",\"update_available\":false}");
        }
    }

    try buf.appendSlice("]}");
}

/// POST /api/instances/{component}/{name}/update — apply an update to a
/// specific instance. For now, returns a stub success response. Later this
/// will become an SSE endpoint that streams progress.
pub fn handleApplyUpdate(allocator: std.mem.Allocator, s: *state_mod.State, component: []const u8, name: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();

    var buf = std.array_list.Managed(u8).init(allocator);

    buildApplyJson(&buf, component, name) catch return serverError();

    return jsonOk(buf.items);
}

fn buildApplyJson(buf: *std.array_list.Managed(u8), component: []const u8, name: []const u8) !void {
    try buf.appendSlice("{\"status\":\"ok\",\"component\":\"");
    try appendEscaped(buf, component);
    try buf.appendSlice("\",\"instance\":\"");
    try appendEscaped(buf, name);
    try buf.appendSlice("\",\"message\":\"Update initiated\"}");
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "handleCheckUpdates with empty state returns empty updates array" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-updates-api.json");
    defer s.deinit();

    const resp = handleCheckUpdates(allocator, &s);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"updates\":[]}", resp.body);
}

test "handleCheckUpdates with instances returns correct structure" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-updates-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });

    const resp = handleCheckUpdates(allocator, &s);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);

    // Verify it is valid JSON by parsing it.
    const parsed = try std.json.parseFromSlice(
        struct {
            updates: []const struct {
                component: []const u8,
                instance: []const u8,
                current_version: []const u8,
                latest_version: []const u8,
                update_available: bool,
            },
        },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.updates.len);
    try std.testing.expectEqualStrings("nullclaw", parsed.value.updates[0].component);
    try std.testing.expectEqualStrings("my-agent", parsed.value.updates[0].instance);
    try std.testing.expectEqualStrings("2026.3.1", parsed.value.updates[0].current_version);
    try std.testing.expectEqualStrings("unknown", parsed.value.updates[0].latest_version);
    try std.testing.expect(parsed.value.updates[0].update_available == false);
}

test "handleApplyUpdate returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-updates-api.json");
    defer s.deinit();

    const resp = handleApplyUpdate(allocator, &s, "nonexistent", "nope");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", resp.body);
}

test "handleApplyUpdate returns success for existing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-updates-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = false });

    const resp = handleApplyUpdate(allocator, &s, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);

    // Verify it is valid JSON by parsing it.
    const parsed = try std.json.parseFromSlice(
        struct {
            status: []const u8,
            component: []const u8,
            instance: []const u8,
            message: []const u8,
        },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("ok", parsed.value.status);
    try std.testing.expectEqualStrings("nullclaw", parsed.value.component);
    try std.testing.expectEqualStrings("my-agent", parsed.value.instance);
    try std.testing.expectEqualStrings("Update initiated", parsed.value.message);
}

test "parseUpdatePath extracts component and name correctly" {
    const p = parseUpdatePath("/api/instances/nullclaw/my-agent/update").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
}

test "parseUpdatePath rejects wrong action" {
    try std.testing.expect(parseUpdatePath("/api/instances/nullclaw/my-agent/start") == null);
}

test "parseUpdatePath rejects missing action" {
    try std.testing.expect(parseUpdatePath("/api/instances/nullclaw/my-agent") == null);
}

test "parseUpdatePath rejects extra segments" {
    try std.testing.expect(parseUpdatePath("/api/instances/nullclaw/my-agent/update/extra") == null);
}

test "parseUpdatePath rejects wrong prefix" {
    try std.testing.expect(parseUpdatePath("/api/other/nullclaw/my-agent/update") == null);
}

test "parseUpdatePath rejects bare prefix" {
    try std.testing.expect(parseUpdatePath("/api/instances/") == null);
}
