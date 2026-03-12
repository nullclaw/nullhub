const std = @import("std");
const state_mod = @import("../core/state.zig");
const platform = @import("../core/platform.zig");
const manager_mod = @import("../supervisor/manager.zig");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");
const access = @import("../access.zig");
const version = @import("../version.zig");

const ApiResponse = helpers.ApiResponse;
const appendEscaped = helpers.appendEscaped;

fn pidToU64(pid: std.process.Child.Id) u64 {
    return switch (@typeInfo(@TypeOf(pid))) {
        .int => @intCast(pid),
        .pointer => @intFromPtr(pid),
        else => 0,
    };
}

fn appendInstanceJson(buf: *std.array_list.Managed(u8), entry: state_mod.InstanceEntry, status_str: []const u8, pid: ?std.process.Child.Id, instance_uptime: ?u64, restart_count: u32, port: u16) !void {
    try buf.appendSlice("{\"version\":\"");
    try appendEscaped(buf, entry.version);
    try buf.appendSlice("\",\"auto_start\":");
    try buf.appendSlice(if (entry.auto_start) "true" else "false");
    try buf.appendSlice(",\"launch_mode\":\"");
    try appendEscaped(buf, entry.launch_mode);
    try buf.appendSlice("\",\"verbose\":");
    try buf.appendSlice(if (entry.verbose) "true" else "false");
    try buf.appendSlice(",\"status\":\"");
    try buf.appendSlice(status_str);
    try buf.appendSlice("\"");
    // PID
    if (pid) |p| {
        try buf.appendSlice(",\"pid\":");
        var num_buf: [20]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{pidToU64(p)});
        try buf.appendSlice(num_str);
    }
    // Instance uptime
    if (instance_uptime) |ut| {
        try buf.appendSlice(",\"uptime_seconds\":");
        var num_buf: [20]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{ut});
        try buf.appendSlice(num_str);
    }
    // Restart count (only if > 0)
    if (restart_count > 0) {
        try buf.appendSlice(",\"restart_count\":");
        var num_buf: [20]u8 = undefined;
        const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{restart_count});
        try buf.appendSlice(num_str);
    }
    // Port (only if > 0)
    if (port > 0) {
        try buf.appendSlice(",\"port\":");
        var num_buf2: [10]u8 = undefined;
        const port_str = try std.fmt.bufPrint(&num_buf2, "{d}", .{port});
        try buf.appendSlice(port_str);
    }
    try buf.append('}');
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/status — aggregated dashboard data.
pub fn handleStatus(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, uptime_seconds: u64, host: []const u8, port: u16, access_options: access.Options) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);

    buildStatusJson(&buf, s, manager, uptime_seconds, host, port, access_options) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    return .{ .status = "200 OK", .content_type = "application/json", .body = buf.items };
}

fn buildStatusJson(buf: *std.array_list.Managed(u8), s: *state_mod.State, manager: *manager_mod.Manager, uptime_seconds: u64, host: []const u8, port: u16, access_options: access.Options) !void {
    var urls = try access.buildAccessUrlsWithOptions(buf.allocator, host, port, access_options);
    defer urls.deinit(buf.allocator);

    // Hub info
    try buf.appendSlice("{\"hub\":{\"version\":\"");
    try buf.appendSlice(version.string);
    try buf.appendSlice("\",\"platform\":\"");
    try buf.appendSlice(comptime platform.detect().toString());
    try buf.appendSlice("\",\"uptime_seconds\":");

    var num_buf: [20]u8 = undefined;
    const num_str = try std.fmt.bufPrint(&num_buf, "{d}", .{uptime_seconds});
    try buf.appendSlice(num_str);
    try buf.appendSlice(",\"access\":{");
    try buf.appendSlice("\"browser_open_url\":\"");
    try buf.appendSlice(urls.browser_open_url);
    try buf.appendSlice("\",\"direct_url\":\"");
    try buf.appendSlice(urls.direct_url);
    try buf.appendSlice("\",\"canonical_url\":\"");
    try buf.appendSlice(urls.canonical_url);
    try buf.appendSlice("\",\"fallback_url\":\"");
    try buf.appendSlice(urls.fallback_url);
    try buf.appendSlice("\",\"local_alias_chain\":");
    try buf.appendSlice(if (urls.local_alias_chain) "true" else "false");
    try buf.appendSlice(",\"public_alias_active\":");
    try buf.appendSlice(if (urls.public_alias_active) "true" else "false");
    try buf.appendSlice(",\"public_alias_provider\":\"");
    try buf.appendSlice(urls.public_alias_provider);
    try buf.append('"');
    try buf.appendSlice(",\"public_alias_url\":");
    if (urls.public_alias_url) |url| {
        try buf.append('"');
        try buf.appendSlice(url);
        try buf.append('"');
    } else {
        try buf.appendSlice("null");
    }
    try buf.append('}');

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

            const comp_name = comp_entry.key_ptr.*;
            const inst_name = inst_entry.key_ptr.*;
            const mgr_status = manager.getStatus(comp_name, inst_name);
            const status_str = if (mgr_status) |st| @tagName(st.status) else "stopped";
            const pid = if (mgr_status) |st| st.pid else null;
            const instance_uptime = if (mgr_status) |st| st.uptime_seconds else null;
            const restart_count: u32 = if (mgr_status) |st| st.restart_count else 0;
            const instance_port: u16 = if (mgr_status) |st| st.port else 0;

            try buf.append('"');
            try appendEscaped(buf, inst_name);
            try buf.appendSlice("\":");
            try appendInstanceJson(buf, inst_entry.value_ptr.*, status_str, pid, instance_uptime, restart_count, instance_port);
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
    var p = try paths_mod.Paths.init(allocator, "/tmp/nullhub-test-status-api");
    defer p.deinit(allocator);
    var mgr = manager_mod.Manager.init(allocator, p);
    defer mgr.deinit();

    const resp = handleStatus(allocator, &s, &mgr, 3600, access.default_bind_host, access.default_port, .{});
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
                access: struct {
                    browser_open_url: []const u8,
                    public_alias_active: bool,
                    public_alias_provider: []const u8,
                },
            },
            instances: std.json.ArrayHashMap(std.json.ArrayHashMap(struct {
                version: []const u8,
                auto_start: bool,
                launch_mode: []const u8 = "gateway",
                verbose: bool = false,
                status: []const u8,
            })),
        },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings(version.string, parsed.value.hub.version);
    try std.testing.expect(parsed.value.hub.platform.len > 0);
    try std.testing.expectEqual(@as(u64, 3600), parsed.value.hub.uptime_seconds);
    try std.testing.expect(!parsed.value.hub.access.public_alias_active);
    try std.testing.expectEqualStrings("none", parsed.value.hub.access.public_alias_provider);
    try std.testing.expectEqualStrings("http://nullhub.localhost:19800", parsed.value.hub.access.browser_open_url);
}

test "handleStatus includes instances" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-status-api.json");
    defer s.deinit();
    var p = try paths_mod.Paths.init(allocator, "/tmp/nullhub-test-status-api");
    defer p.deinit(allocator);
    var mgr = manager_mod.Manager.init(allocator, p);
    defer mgr.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });

    const resp = handleStatus(allocator, &s, &mgr, 0, access.default_bind_host, access.default_port, .{});
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);

    const parsed = try std.json.parseFromSlice(
        struct {
            hub: struct {
                version: []const u8,
                platform: []const u8,
                uptime_seconds: u64,
                access: struct {
                    browser_open_url: []const u8,
                },
            },
            instances: std.json.ArrayHashMap(std.json.ArrayHashMap(struct {
                version: []const u8,
                auto_start: bool,
                launch_mode: []const u8 = "gateway",
                verbose: bool = false,
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

test "handleStatus includes launch_mode" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-status-api.json");
    defer s.deinit();
    var p = try paths_mod.Paths.init(allocator, "/tmp/nullhub-test-status-api");
    defer p.deinit(allocator);
    var mgr = manager_mod.Manager.init(allocator, p);
    defer mgr.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .launch_mode = "agent" });

    const resp = handleStatus(allocator, &s, &mgr, 0, access.default_bind_host, access.default_port, .{});
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"launch_mode\":\"agent\"") != null);
}

test "handleStatus includes verbose flag" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-status-api.json");
    defer s.deinit();
    var p = try paths_mod.Paths.init(allocator, "/tmp/nullhub-test-status-api");
    defer p.deinit(allocator);
    var mgr = manager_mod.Manager.init(allocator, p);
    defer mgr.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .verbose = true });

    const resp = handleStatus(allocator, &s, &mgr, 0, access.default_bind_host, access.default_port, .{});
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"verbose\":true") != null);
}

test "handleStatus with empty state returns empty instances" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-status-api.json");
    defer s.deinit();
    var p = try paths_mod.Paths.init(allocator, "/tmp/nullhub-test-status-api");
    defer p.deinit(allocator);
    var mgr = manager_mod.Manager.init(allocator, p);
    defer mgr.deinit();

    const resp = handleStatus(allocator, &s, &mgr, 42, access.default_bind_host, access.default_port, .{});
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"instances\":{}") != null);
}
