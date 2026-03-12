const std = @import("std");
const builtin = @import("builtin");
const state_mod = @import("../core/state.zig");
const manager_mod = @import("../supervisor/manager.zig");
const paths_mod = @import("../core/paths.zig");
const registry = @import("../installer/registry.zig");
const downloader = @import("../installer/downloader.zig");
const launch_args_mod = @import("../core/launch_args.zig");
const platform = @import("../core/platform.zig");
const helpers = @import("helpers.zig");

const ApiResponse = helpers.ApiResponse;
const appendEscaped = helpers.appendEscaped;
const jsonOk = helpers.jsonOk;
const notFound = helpers.notFound;
const serverError = helpers.serverError;

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

fn stripV(v: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, v, "v")) v[1..] else v;
}

fn versionsEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, stripV(a), stripV(b));
}

fn fetchLatestTagForComponent(allocator: std.mem.Allocator, component: []const u8) ?[]u8 {
    if (builtin.is_test) return null;

    const known = registry.findKnownComponent(component) orelse return null;
    var release = registry.fetchLatestRelease(allocator, known.repo) catch return null;
    defer release.deinit();

    return allocator.dupe(u8, release.value.tag_name) catch null;
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/updates — check for updates across all installed instances.
pub fn handleCheckUpdates(allocator: std.mem.Allocator, s: *state_mod.State) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);

    buildUpdatesJson(allocator, &buf, s) catch return serverError();

    return jsonOk(buf.items);
}

fn buildUpdatesJson(allocator: std.mem.Allocator, buf: *std.array_list.Managed(u8), s: *state_mod.State) !void {
    try buf.appendSlice("{\"updates\":[");

    var first = true;
    var comp_it = s.instances.iterator();
    while (comp_it.next()) |comp_entry| {
        var inst_it = comp_entry.value_ptr.iterator();
        while (inst_it.next()) |inst_entry| {
            if (!first) try buf.append(',');
            first = false;

            const current_version = inst_entry.value_ptr.version;
            const latest_owned = fetchLatestTagForComponent(allocator, comp_entry.key_ptr.*);
            defer if (latest_owned) |v| allocator.free(v);

            const latest_version = if (latest_owned) |v| v else "unknown";
            const update_available = if (latest_owned) |v|
                !versionsEqual(current_version, v)
            else
                false;

            try buf.appendSlice("{\"component\":\"");
            try appendEscaped(buf, comp_entry.key_ptr.*);
            try buf.appendSlice("\",\"instance\":\"");
            try appendEscaped(buf, inst_entry.key_ptr.*);
            try buf.appendSlice("\",\"current_version\":\"");
            try appendEscaped(buf, current_version);
            try buf.appendSlice("\",\"latest_version\":\"");
            try appendEscaped(buf, latest_version);
            try buf.appendSlice("\",\"update_available\":");
            try buf.appendSlice(if (update_available) "true" else "false");
            try buf.appendSlice("}");
        }
    }

    try buf.appendSlice("]}");
}

/// Compatibility wrapper used by tests and internal call sites that don't have
/// supervisor context yet.
pub fn handleApplyUpdate(allocator: std.mem.Allocator, s: *state_mod.State, component: []const u8, name: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();

    var buf = std.array_list.Managed(u8).init(allocator);
    buildApplyJson(&buf, component, name) catch return serverError();
    return jsonOk(buf.items);
}

/// POST /api/instances/{component}/{name}/update — apply a real binary update.
/// Stops running instance, downloads latest release binary for platform,
/// updates state version, and starts the instance again.
pub fn handleApplyUpdateRuntime(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ApiResponse {
    // Keep unit tests deterministic/offline.
    if (builtin.is_test) return handleApplyUpdate(allocator, s, component, name);

    const entry = s.getInstance(component, name) orelse return notFound();
    const previous_version = allocator.dupe(u8, entry.version) catch return serverError();
    defer allocator.free(previous_version);
    const known = registry.findKnownComponent(component) orelse return notFound();

    var release = registry.fetchLatestRelease(allocator, known.repo) catch return .{
        .status = "502 Bad Gateway",
        .content_type = "application/json",
        .body = "{\"error\":\"failed to fetch latest release\"}",
    };
    defer release.deinit();

    const latest_tag = release.value.tag_name;
    if (versionsEqual(entry.version, latest_tag)) {
        var up_to_date = std.array_list.Managed(u8).init(allocator);
        up_to_date.appendSlice("{\"status\":\"up_to_date\",\"component\":\"") catch return serverError();
        appendEscaped(&up_to_date, component) catch return serverError();
        up_to_date.appendSlice("\",\"instance\":\"") catch return serverError();
        appendEscaped(&up_to_date, name) catch return serverError();
        up_to_date.appendSlice("\",\"version\":\"") catch return serverError();
        appendEscaped(&up_to_date, latest_tag) catch return serverError();
        up_to_date.appendSlice("\"}") catch return serverError();
        return jsonOk(up_to_date.items);
    }

    const platform_key = comptime platform.detect().toString();
    const asset = registry.findAssetForComponentPlatform(allocator, release.value, component, platform_key) orelse return .{
        .status = "502 Bad Gateway",
        .content_type = "application/json",
        .body = "{\"error\":\"no platform asset for latest version\"}",
    };

    const new_bin_path = paths.binary(allocator, component, latest_tag) catch return serverError();
    defer allocator.free(new_bin_path);

    downloader.download(allocator, asset.browser_download_url, new_bin_path) catch return .{
        .status = "502 Bad Gateway",
        .content_type = "application/json",
        .body = "{\"error\":\"failed to download latest binary\"}",
    };

    const status_before = manager.getStatus(component, name);
    const was_running = if (status_before) |st|
        st.status == .running or st.status == .starting or st.status == .restarting
    else
        false;
    const port: u16 = if (status_before) |st|
        if (st.port > 0) st.port else known.default_port
    else
        known.default_port;

    if (was_running) {
        manager.stopInstance(component, name) catch return serverError();
    }

    const inst_dir = paths.instanceDir(allocator, component, name) catch return serverError();
    defer allocator.free(inst_dir);
    const launch_args = launch_args_mod.buildLaunchArgs(allocator, entry.launch_mode, entry.verbose) catch return serverError();
    defer allocator.free(launch_args);

    if (was_running) {
        manager.startInstance(
            component,
            name,
            new_bin_path,
            launch_args,
            port,
            known.default_health_endpoint,
            inst_dir,
            "",
            entry.launch_mode,
        ) catch {
            // Best-effort rollback: try to start previous binary.
            const prev_bin_path = paths.binary(allocator, component, previous_version) catch {
                return .{
                    .status = "500 Internal Server Error",
                    .content_type = "application/json",
                    .body = "{\"error\":\"update failed and rollback path resolution failed\"}",
                };
            };
            defer allocator.free(prev_bin_path);

            if (std.fs.accessAbsolute(prev_bin_path, .{})) |_| {
                manager.startInstance(
                    component,
                    name,
                    prev_bin_path,
                    launch_args,
                    port,
                    known.default_health_endpoint,
                    inst_dir,
                    "",
                    entry.launch_mode,
                ) catch {};
                return .{
                    .status = "500 Internal Server Error",
                    .content_type = "application/json",
                    .body = "{\"error\":\"update failed; rollback attempted\"}",
                };
            } else |_| {
                return .{
                    .status = "500 Internal Server Error",
                    .content_type = "application/json",
                    .body = "{\"error\":\"update failed; rollback binary missing\"}",
                };
            }
        };
    }

    const updated = s.updateInstance(component, name, .{
        .version = latest_tag,
        .auto_start = entry.auto_start,
        .launch_mode = entry.launch_mode,
        .verbose = entry.verbose,
    }) catch return serverError();
    if (!updated) return notFound();
    s.save() catch return serverError();

    var buf = std.array_list.Managed(u8).init(allocator);
    buf.appendSlice("{\"status\":\"updated\",\"component\":\"") catch return serverError();
    appendEscaped(&buf, component) catch return serverError();
    buf.appendSlice("\",\"instance\":\"") catch return serverError();
    appendEscaped(&buf, name) catch return serverError();
    buf.appendSlice("\",\"from_version\":\"") catch return serverError();
    appendEscaped(&buf, previous_version) catch return serverError();
    buf.appendSlice("\",\"to_version\":\"") catch return serverError();
    appendEscaped(&buf, latest_tag) catch return serverError();
    buf.appendSlice("\",\"restarted\":") catch return serverError();
    buf.appendSlice(if (was_running) "true" else "false") catch return serverError();
    buf.appendSlice("}") catch return serverError();

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
    // In unit tests network is disabled, so this remains unknown.
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
