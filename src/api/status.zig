const std = @import("std");
const state_mod = @import("../core/state.zig");
const platform = @import("../core/platform.zig");

const version = "0.1.0";

// ─── Response types ──────────────────────────────────────────────────────────

pub const ApiResponse = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

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

fn appendInstanceJson(buf: *std.array_list.Managed(u8), entry: state_mod.InstanceEntry) !void {
    try buf.appendSlice("{\"version\":\"");
    try appendEscaped(buf, entry.version);
    try buf.appendSlice("\",\"auto_start\":");
    try buf.appendSlice(if (entry.auto_start) "true" else "false");
    try buf.appendSlice(",\"status\":\"stopped\"}");
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/status — aggregated dashboard data.
pub fn handleStatus(allocator: std.mem.Allocator, s: *state_mod.State, uptime_seconds: u64) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);

    buildStatusJson(&buf, s, uptime_seconds) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    return .{ .status = "200 OK", .content_type = "application/json", .body = buf.items };
}

fn buildStatusJson(buf: *std.array_list.Managed(u8), s: *state_mod.State, uptime_seconds: u64) !void {
    // Hub info
    try buf.appendSlice("{\"hub\":{\"version\":\"");
    try buf.appendSlice(version);
    try buf.appendSlice("\",\"platform\":\"");
    try buf.appendSlice(comptime platform.detect().toString());
    try buf.appendSlice("\",\"uptime_seconds\":");

    var num_buf: [20]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{uptime_seconds});
    try buf.appendSlice(num_str);

    try buf.appendSlice("},\"instances\":{");

    // Instances grouped by component
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
            try appendInstanceJson(buf, inst_entry.value_ptr.*);
        }

        try buf.append('}');
    }

    try buf.appendSlice("}}");
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "handleStatus returns valid JSON with hub version" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-status-api.json");
    defer s.deinit();

    const resp = handleStatus(allocator, &s, 3600);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);

    // Parse and verify JSON.
    const parsed = try std.json.parseFromSlice(
        struct {
            hub: struct {
                version: []const u8,
                platform: []const u8,
                uptime_seconds: u64,
            },
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

    try std.testing.expectEqualStrings("0.1.0", parsed.value.hub.version);
    try std.testing.expect(parsed.value.hub.platform.len > 0);
    try std.testing.expectEqual(@as(u64, 3600), parsed.value.hub.uptime_seconds);
}

test "handleStatus includes instances" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-status-api.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });

    const resp = handleStatus(allocator, &s, 0);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);

    const parsed = try std.json.parseFromSlice(
        struct {
            hub: struct {
                version: []const u8,
                platform: []const u8,
                uptime_seconds: u64,
            },
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

    const nullclaw = parsed.value.instances.map.get("nullclaw").?;
    const agent = nullclaw.map.get("my-agent").?;
    try std.testing.expectEqualStrings("2026.3.1", agent.version);
    try std.testing.expect(agent.auto_start == true);
    try std.testing.expectEqualStrings("stopped", agent.status);
}

test "handleStatus with empty state returns empty instances" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-status-api.json");
    defer s.deinit();

    const resp = handleStatus(allocator, &s, 42);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"instances\":{}") != null);
}
