const std = @import("std");
const cli = @import("cli.zig");
const paths_mod = @import("core/paths.zig");
const state_mod = @import("core/state.zig");
const service_mod = @import("service.zig");
const version = @import("version.zig");

const LiveInstance = struct {
    version: []const u8,
    auto_start: bool = false,
    launch_mode: []const u8 = "gateway",
    verbose: bool = false,
    status: []const u8,
    pid: ?u64 = null,
    port: ?u16 = null,
    uptime_seconds: ?u64 = null,
    restart_count: ?u32 = null,
};

const LiveStatus = struct {
    hub: struct {
        version: []const u8,
        uptime_seconds: u64,
        access: struct {
            browser_open_url: []const u8,
        },
    },
    instances: std.json.ArrayHashMap(std.json.ArrayHashMap(LiveInstance)),
};

pub fn run(allocator: std.mem.Allocator, opts: cli.StatusOptions) !void {
    var stdout_buf: [4096]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &bw.interface;

    try w.print("nullhub Status\n", .{});
    try w.print("Version: {s}\n", .{version.string});

    if (service_mod.queryStatus(allocator) catch null) |status| {
        var service_status = status;
        defer service_status.deinit(allocator);
        try w.print("Service: {s} ({s})\n", .{
            if (service_status.running) "running" else if (service_status.registered) "installed" else "not installed",
            service_status.service_type,
        });
    }

    if (fetchLiveStatus(allocator, opts.host, opts.port)) |parsed| {
        var live = parsed;
        defer live.deinit();
        try printLiveStatus(w, live.value, opts);
    } else {
        try printFallbackStatus(allocator, w, opts);
    }

    try w.flush();
}

fn fetchLiveStatus(allocator: std.mem.Allocator, host: []const u8, port: u16) ?std.json.Parsed(LiveStatus) {
    const url = std.fmt.allocPrint(allocator, "http://{s}:{d}/api/status", .{ host, port }) catch return null;
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
    }) catch return null;
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) return null;

    const bytes = response_body.toOwnedSlice() catch return null;
    defer allocator.free(bytes);

    return std.json.parseFromSlice(LiveStatus, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch null;
}

fn printLiveStatus(w: anytype, live: LiveStatus, opts: cli.StatusOptions) !void {
    try w.print("Hub: running on http://{s}:{d} (uptime {d}s)\n", .{ opts.host, opts.port, live.hub.uptime_seconds });
    try w.print("UI: {s}\n", .{live.hub.access.browser_open_url});

    if (opts.instance) |ref| {
        if (live.instances.map.get(ref.component)) |instances| {
            if (instances.map.get(ref.name)) |instance| {
                try printLiveInstance(w, ref.component, ref.name, instance);
                return;
            }
        }
        try w.print("Instance {s}/{s} not found.\n", .{ ref.component, ref.name });
        return;
    }

    if (live.instances.map.count() == 0) {
        try w.print("Instances: none\n", .{});
        return;
    }

    try w.print("Instances:\n", .{});
    var comp_it = live.instances.map.iterator();
    while (comp_it.next()) |comp_entry| {
        var inst_it = comp_entry.value_ptr.map.iterator();
        while (inst_it.next()) |inst_entry| {
            try printLiveInstance(w, comp_entry.key_ptr.*, inst_entry.key_ptr.*, inst_entry.value_ptr.*);
        }
    }
}

fn printFallbackStatus(allocator: std.mem.Allocator, w: anytype, opts: cli.StatusOptions) !void {
    try w.print("Hub: not running or unreachable at http://{s}:{d}\n", .{ opts.host, opts.port });

    var paths = try paths_mod.Paths.init(allocator, null);
    defer paths.deinit(allocator);

    const state_path = try paths.state(allocator);
    defer allocator.free(state_path);

    var state = state_mod.State.load(allocator, state_path) catch state_mod.State.init(allocator, state_path);
    defer state.deinit();

    if (opts.instance) |ref| {
        if (state.getInstance(ref.component, ref.name)) |entry| {
            try w.print(
                "Instance {s}/{s}\n  version: {s}\n  auto_start: {s}\n  launch_mode: {s}\n  verbose: {s}\n  status: offline\n",
                .{
                    ref.component,
                    ref.name,
                    entry.version,
                    if (entry.auto_start) "yes" else "no",
                    entry.launch_mode,
                    if (entry.verbose) "yes" else "no",
                },
            );
        } else {
            try w.print("Instance {s}/{s} not found.\n", .{ ref.component, ref.name });
        }
        return;
    }

    if (state.instances.count() == 0) {
        try w.print("Instances: none\n", .{});
        return;
    }

    try w.print("Configured instances:\n", .{});
    var comp_it = state.instances.iterator();
    while (comp_it.next()) |comp_entry| {
        var inst_it = comp_entry.value_ptr.iterator();
        while (inst_it.next()) |inst_entry| {
            const entry = inst_entry.value_ptr.*;
            try w.print(
                "  {s}/{s}  offline  version={s} auto_start={s} launch_mode={s} verbose={s}\n",
                .{
                    comp_entry.key_ptr.*,
                    inst_entry.key_ptr.*,
                    entry.version,
                    if (entry.auto_start) "yes" else "no",
                    entry.launch_mode,
                    if (entry.verbose) "yes" else "no",
                },
            );
        }
    }
}

fn printLiveInstance(w: anytype, component: []const u8, name: []const u8, instance: LiveInstance) !void {
    try w.print("  {s}/{s}  {s}  version={s}", .{ component, name, instance.status, instance.version });
    try w.print(" auto_start={s}", .{if (instance.auto_start) "yes" else "no"});
    try w.print(" launch_mode={s}", .{instance.launch_mode});
    try w.print(" verbose={s}", .{if (instance.verbose) "yes" else "no"});
    if (instance.port) |port| try w.print(" port={d}", .{port});
    if (instance.uptime_seconds) |uptime| try w.print(" uptime={d}s", .{uptime});
    if (instance.restart_count) |restarts| try w.print(" restarts={d}", .{restarts});
    try w.print("\n", .{});
}
