const std = @import("std");
const state_mod = @import("../core/state.zig");

// ─── Path Parsing ────────────────────────────────────────────────────────────

pub const ParsedPath = struct {
    component: []const u8,
    name: []const u8,
    action: ?[]const u8,
};

/// Parse `/api/instances/{component}/{name}` or
/// `/api/instances/{component}/{name}/{action}` from a request target.
/// Returns `null` if the path does not match the expected prefix or has
/// too few / too many segments.
pub fn parsePath(target: []const u8) ?ParsedPath {
    const prefix = "/api/instances/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;

    const rest = target[prefix.len..];
    if (rest.len == 0) return null;

    var it = std.mem.splitScalar(u8, rest, '/');
    const component = it.next() orelse return null;
    if (component.len == 0) return null;

    const name = it.next() orelse return null;
    if (name.len == 0) return null;

    const action_raw = it.next();
    // If there is a fourth segment the path is invalid.
    if (it.next() != null) return null;

    const action: ?[]const u8 = if (action_raw) |a| (if (a.len == 0) null else a) else null;

    return .{ .component = component, .name = name, .action = action };
}

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

fn badRequest(msg: []const u8) ApiResponse {
    return .{
        .status = "400 Bad Request",
        .content_type = "application/json",
        .body = msg,
    };
}

fn methodNotAllowed() ApiResponse {
    return .{
        .status = "405 Method Not Allowed",
        .content_type = "application/json",
        .body = "{\"error\":\"method not allowed\"}",
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

fn appendInstanceJson(buf: *std.array_list.Managed(u8), entry: state_mod.InstanceEntry, status_str: []const u8) !void {
    try buf.appendSlice("{\"version\":\"");
    try appendEscaped(buf, entry.version);
    try buf.appendSlice("\",\"auto_start\":");
    try buf.appendSlice(if (entry.auto_start) "true" else "false");
    try buf.appendSlice(",\"status\":\"");
    try buf.appendSlice(status_str);
    try buf.appendSlice("\"}");
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/instances — list all instances grouped by component.
pub fn handleList(allocator: std.mem.Allocator, s: *state_mod.State) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);

    buildListJson(&buf, s) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    return jsonOk(buf.items);
}

fn buildListJson(buf: *std.array_list.Managed(u8), s: *state_mod.State) !void {
    try buf.appendSlice("{\"instances\":{");

    var comp_it = s.instances.iterator();
    var first_comp = true;
    while (comp_it.next()) |comp_entry| {
        if (!first_comp) try buf.append(',');
        first_comp = false;

        try buf.append('"');
        try appendEscaped(buf, comp_entry.key_ptr.*);
        try buf.appendSlice("\":{");

        var inst_it = comp_entry.value_ptr.iterator();
        var first_inst = true;
        while (inst_it.next()) |inst_entry| {
            if (!first_inst) try buf.append(',');
            first_inst = false;

            try buf.append('"');
            try appendEscaped(buf, inst_entry.key_ptr.*);
            try buf.appendSlice("\":");
            try appendInstanceJson(buf, inst_entry.value_ptr.*, "stopped");
        }

        try buf.append('}');
    }

    try buf.appendSlice("}}");
}

/// GET /api/instances/{component}/{name} — detail for one instance.
pub fn handleGet(allocator: std.mem.Allocator, s: *state_mod.State, component: []const u8, name: []const u8) ApiResponse {
    const entry = s.getInstance(component, name) orelse return notFound();

    var buf = std.array_list.Managed(u8).init(allocator);
    appendInstanceJson(&buf, entry, "stopped") catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    return jsonOk(buf.items);
}

/// POST /api/instances/{component}/{name}/start
pub fn handleStart(s: *state_mod.State, component: []const u8, name: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();
    // Lifecycle integration with manager.zig is deferred — for now just
    // acknowledge the request.
    return jsonOk("{\"status\":\"started\"}");
}

/// POST /api/instances/{component}/{name}/stop
pub fn handleStop(s: *state_mod.State, component: []const u8, name: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();
    return jsonOk("{\"status\":\"stopped\"}");
}

/// POST /api/instances/{component}/{name}/restart
pub fn handleRestart(s: *state_mod.State, component: []const u8, name: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();
    return jsonOk("{\"status\":\"restarted\"}");
}

/// DELETE /api/instances/{component}/{name}
pub fn handleDelete(s: *state_mod.State, component: []const u8, name: []const u8) ApiResponse {
    if (!s.removeInstance(component, name)) return notFound();
    return jsonOk("{\"status\":\"deleted\"}");
}

/// PATCH /api/instances/{component}/{name} — update settings (auto_start).
pub fn handlePatch(s: *state_mod.State, component: []const u8, name: []const u8, body: []const u8) ApiResponse {
    const entry = s.getInstance(component, name) orelse return notFound();

    // Parse the JSON body to extract auto_start.
    const parsed = std.json.parseFromSlice(
        struct { auto_start: ?bool = null },
        s.allocator,
        body,
        .{ .allocate = .alloc_always },
    ) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const new_auto_start = parsed.value.auto_start orelse entry.auto_start;

    _ = s.updateInstance(component, name, .{
        .version = entry.version,
        .auto_start = new_auto_start,
    }) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    return jsonOk("{\"status\":\"updated\"}");
}

// ─── Top-level dispatcher ────────────────────────────────────────────────────

/// Route an `/api/instances` request. Called from server.zig.
/// `method` is the HTTP verb, `target` is the full request path,
/// `body` is the (possibly empty) request body.
pub fn dispatch(allocator: std.mem.Allocator, s: *state_mod.State, method: []const u8, target: []const u8, body: []const u8) ?ApiResponse {
    // Exact match for the collection endpoint.
    if (std.mem.eql(u8, target, "/api/instances")) {
        if (std.mem.eql(u8, method, "GET")) return handleList(allocator, s);
        return methodNotAllowed();
    }

    const parsed = parsePath(target) orelse return null;

    if (parsed.action) |action| {
        // Only POST is valid for actions.
        if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();

        if (std.mem.eql(u8, action, "start")) return handleStart(s, parsed.component, parsed.name);
        if (std.mem.eql(u8, action, "stop")) return handleStop(s, parsed.component, parsed.name);
        if (std.mem.eql(u8, action, "restart")) return handleRestart(s, parsed.component, parsed.name);

        return notFound();
    }

    // No action — CRUD on the instance itself.
    if (std.mem.eql(u8, method, "GET")) return handleGet(allocator, s, parsed.component, parsed.name);
    if (std.mem.eql(u8, method, "DELETE")) return handleDelete(s, parsed.component, parsed.name);
    if (std.mem.eql(u8, method, "PATCH")) return handlePatch(s, parsed.component, parsed.name, body);

    return methodNotAllowed();
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "parsePath: component and name" {
    const p = parsePath("/api/instances/nullclaw/my-agent").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
    try std.testing.expect(p.action == null);
}

test "parsePath: component, name, and action" {
    const p = parsePath("/api/instances/nullclaw/my-agent/start").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
    try std.testing.expectEqualStrings("start", p.action.?);
}

test "parsePath: rejects bare /api/instances/" {
    try std.testing.expect(parsePath("/api/instances/") == null);
}

test "parsePath: rejects wrong prefix" {
    try std.testing.expect(parsePath("/api/other/foo/bar") == null);
}

test "parsePath: rejects too many segments" {
    try std.testing.expect(parsePath("/api/instances/a/b/c/d") == null);
}

test "parsePath: component only (no name) returns null" {
    try std.testing.expect(parsePath("/api/instances/nullclaw") == null);
}

test "handleList returns valid JSON structure" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });
    try s.addInstance("nullclaw", "staging", .{ .version = "2026.3.1", .auto_start = false });

    const resp = handleList(allocator, &s);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);

    // Verify it is valid JSON by parsing it.
    const parsed = try std.json.parseFromSlice(
        struct {
            instances: std.json.ArrayHashMap(std.json.ArrayHashMap(struct {
                version: []const u8,
                auto_start: bool,
                status: []const u8,
            })),
        },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Check the nullclaw component exists with two instances.
    const nullclaw = parsed.value.instances.map.get("nullclaw").?;
    try std.testing.expectEqual(@as(usize, 2), nullclaw.map.count());

    const agent = nullclaw.map.get("my-agent").?;
    try std.testing.expectEqualStrings("2026.3.1", agent.version);
    try std.testing.expect(agent.auto_start == true);
}

test "handleGet returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    const resp = handleGet(allocator, &s, "nonexistent", "nope");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", resp.body);
}

test "handleGet returns instance detail JSON" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });

    const resp = handleGet(allocator, &s, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);

    // Parse and verify JSON content.
    const parsed = try std.json.parseFromSlice(
        struct { version: []const u8, auto_start: bool, status: []const u8 },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("2026.3.1", parsed.value.version);
    try std.testing.expect(parsed.value.auto_start == true);
    try std.testing.expectEqualStrings("stopped", parsed.value.status);
}

test "handleStart returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    const resp = handleStart(&s, "nope", "nope");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "handleStart returns 200 for existing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handleStart(&s, "nullclaw", "my-agent");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"started\"}", resp.body);
}

test "handleStop returns 200 for existing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handleStop(&s, "nullclaw", "my-agent");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"stopped\"}", resp.body);
}

test "handleRestart returns 200 for existing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handleRestart(&s, "nullclaw", "my-agent");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"restarted\"}", resp.body);
}

test "handleDelete removes instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handleDelete(&s, "nullclaw", "my-agent");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"deleted\"}", resp.body);

    // Verify it was actually removed.
    try std.testing.expect(s.getInstance("nullclaw", "my-agent") == null);
}

test "handleDelete returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    const resp = handleDelete(&s, "nope", "nope");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "handlePatch updates auto_start" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .auto_start = false });

    const resp = handlePatch(&s, "nullclaw", "my-agent", "{\"auto_start\":true}");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const entry = s.getInstance("nullclaw", "my-agent").?;
    try std.testing.expect(entry.auto_start == true);
}

test "handlePatch returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    const resp = handlePatch(&s, "nope", "nope", "{\"auto_start\":true}");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "handlePatch returns 400 for invalid JSON" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handlePatch(&s, "nullclaw", "my-agent", "not-json");
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
}

test "dispatch routes GET /api/instances" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = dispatch(allocator, &s, "GET", "/api/instances", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "nullclaw") != null);
}

test "dispatch routes POST start action" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = dispatch(allocator, &s, "POST", "/api/instances/nullclaw/my-agent/start", "").?;
    try std.testing.expectEqualStrings("200 OK", resp.status);
}

test "dispatch returns null for non-matching path" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-instances-api.json");
    defer s.deinit();

    try std.testing.expect(dispatch(allocator, &s, "GET", "/api/other", "") == null);
}
