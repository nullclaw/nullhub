const std = @import("std");
const builtin = @import("builtin");
const state_mod = @import("../core/state.zig");
const manager_mod = @import("../supervisor/manager.zig");
const paths_mod = @import("../core/paths.zig");
const registry = @import("../installer/registry.zig");
const downloader = @import("../installer/downloader.zig");
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

const UpdateFilters = struct {
    component: ?[]u8 = null,
    instance: ?[]u8 = null,

    fn deinit(self: UpdateFilters, allocator: std.mem.Allocator) void {
        if (self.component) |component| allocator.free(component);
        if (self.instance) |instance| allocator.free(instance);
    }
};

const CachedLatestInfo = struct {
    component: []const u8,
    latest_version: []const u8,
    owns_latest_version: bool,
    has_platform_asset: bool,
};

/// Parse `/api/instances/{component}/{name}/update` from a request target.
/// Returns `null` if the path does not match.
pub fn parseUpdatePath(target: []const u8) ?ParsedUpdatePath {
    const prefix = "/api/instances/";
    const clean = stripQuery(target);
    if (!std.mem.startsWith(u8, clean, prefix)) return null;

    const rest = clean[prefix.len..];
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

fn stripQuery(target: []const u8) []const u8 {
    return if (std.mem.indexOfScalar(u8, target, '?')) |qmark| target[0..qmark] else target;
}

fn queryParamRaw(target: []const u8, key: []const u8) ?[]const u8 {
    const qmark = std.mem.indexOfScalar(u8, target, '?') orelse return null;
    const query = target[qmark + 1 ..];

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (!std.mem.eql(u8, pair[0..eq], key)) continue;
        return pair[eq + 1 ..];
    }

    return null;
}

fn decodeQueryValueAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const encoded = try allocator.dupe(u8, raw);
    for (encoded) |*ch| {
        if (ch.* == '+') ch.* = ' ';
    }
    const decoded = std.Uri.percentDecodeInPlace(encoded);
    if (decoded.ptr == encoded.ptr and decoded.len == encoded.len) return encoded;
    const out = try allocator.dupe(u8, decoded);
    allocator.free(encoded);
    return out;
}

fn queryParamValueAlloc(allocator: std.mem.Allocator, target: []const u8, key: []const u8) !?[]u8 {
    const raw = queryParamRaw(target, key) orelse return null;
    return try decodeQueryValueAlloc(allocator, raw);
}

fn parseUpdateFiltersAlloc(allocator: std.mem.Allocator, target: []const u8) !UpdateFilters {
    return .{
        .component = try queryParamValueAlloc(allocator, target, "component"),
        .instance = try queryParamValueAlloc(allocator, target, "instance"),
    };
}

fn unknownLatestInfo(component: []const u8) CachedLatestInfo {
    return .{
        .component = component,
        .latest_version = "unknown",
        .owns_latest_version = false,
        .has_platform_asset = false,
    };
}

fn stripV(v: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, v, "v")) v[1..] else v;
}

fn versionsEqual(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, stripV(a), stripV(b));
}

fn matchesFilters(filters: UpdateFilters, component: []const u8, instance: []const u8) bool {
    if (filters.component) |filtered_component| {
        if (!std.mem.eql(u8, filtered_component, component)) return false;
    }
    if (filters.instance) |filtered_instance| {
        if (!std.mem.eql(u8, filtered_instance, instance)) return false;
    }
    return true;
}

fn fetchLatestInfoForComponent(allocator: std.mem.Allocator, component: []const u8) CachedLatestInfo {
    if (builtin.is_test) return unknownLatestInfo(component);

    const known = registry.findKnownComponent(component) orelse return unknownLatestInfo(component);
    var release = registry.fetchLatestRelease(allocator, known.repo) catch return unknownLatestInfo(component);
    defer release.deinit();

    const latest_version = allocator.dupe(u8, release.value.tag_name) catch return unknownLatestInfo(component);

    return .{
        .component = component,
        .latest_version = latest_version,
        .owns_latest_version = true,
        .has_platform_asset = registry.findAssetForComponentPlatform(
            allocator,
            release.value,
            component,
            comptime platform.detect().toString(),
        ) != null,
    };
}

fn getOrFetchCachedLatestInfo(
    allocator: std.mem.Allocator,
    cache: *std.ArrayListUnmanaged(CachedLatestInfo),
    component: []const u8,
) !CachedLatestInfo {
    for (cache.items) |entry| {
        if (std.mem.eql(u8, entry.component, component)) return entry;
    }

    const fetched = fetchLatestInfoForComponent(allocator, component);
    try cache.append(allocator, fetched);
    return fetched;
}

fn splitLaunchCommand(allocator: std.mem.Allocator, launch_cmd: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.tokenizeAny(u8, launch_cmd, " \t\r\n");
    while (it.next()) |token| {
        try list.append(allocator, token);
    }

    return list.toOwnedSlice(allocator);
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/updates — check for updates across all installed instances.
pub fn handleCheckUpdates(allocator: std.mem.Allocator, s: *state_mod.State) ApiResponse {
    return handleCheckUpdatesTarget(allocator, s, "/api/updates");
}

pub fn handleCheckUpdatesTarget(allocator: std.mem.Allocator, s: *state_mod.State, target: []const u8) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);

    buildUpdatesJson(allocator, &buf, s, target) catch return serverError();

    return jsonOk(buf.items);
}

fn buildUpdatesJson(
    allocator: std.mem.Allocator,
    buf: *std.array_list.Managed(u8),
    s: *state_mod.State,
    target: []const u8,
) !void {
    const filters = try parseUpdateFiltersAlloc(allocator, target);
    defer filters.deinit(allocator);
    var latest_cache: std.ArrayListUnmanaged(CachedLatestInfo) = .empty;
    defer {
        for (latest_cache.items) |entry| {
            if (entry.owns_latest_version) allocator.free(entry.latest_version);
        }
        latest_cache.deinit(allocator);
    }

    try buf.appendSlice("{\"updates\":[");

    var first = true;
    var comp_it = s.instances.iterator();
    while (comp_it.next()) |comp_entry| {
        var inst_it = comp_entry.value_ptr.iterator();
        while (inst_it.next()) |inst_entry| {
            if (!matchesFilters(filters, comp_entry.key_ptr.*, inst_entry.key_ptr.*)) continue;
            if (!first) try buf.append(',');
            first = false;

            const current_version = inst_entry.value_ptr.version;
            const latest_info = try getOrFetchCachedLatestInfo(allocator, &latest_cache, comp_entry.key_ptr.*);
            const update_available = latest_info.has_platform_asset and !versionsEqual(current_version, latest_info.latest_version);

            try buf.appendSlice("{\"component\":\"");
            try appendEscaped(buf, comp_entry.key_ptr.*);
            try buf.appendSlice("\",\"instance\":\"");
            try appendEscaped(buf, inst_entry.key_ptr.*);
            try buf.appendSlice("\",\"current_version\":\"");
            try appendEscaped(buf, current_version);
            try buf.appendSlice("\",\"latest_version\":\"");
            try appendEscaped(buf, latest_info.latest_version);
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
    const launch_args = splitLaunchCommand(allocator, entry.launch_mode) catch return serverError();
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

test "parseUpdateFilters extracts component and instance filters" {
    const allocator = std.testing.allocator;
    const filters = try parseUpdateFiltersAlloc(allocator, "/api/updates?component=nullclaw&instance=my-agent");
    defer filters.deinit(allocator);
    try std.testing.expect(filters.component != null);
    try std.testing.expect(filters.instance != null);
    try std.testing.expectEqualStrings("nullclaw", filters.component.?);
    try std.testing.expectEqualStrings("my-agent", filters.instance.?);
}

test "parseUpdateFilters decodes percent-encoded values" {
    const allocator = std.testing.allocator;
    const filters = try parseUpdateFiltersAlloc(
        allocator,
        "/api/updates?component=nullclaw&instance=my+agent%2Fdev",
    );
    defer filters.deinit(allocator);
    try std.testing.expect(filters.instance != null);
    try std.testing.expectEqualStrings("my agent/dev", filters.instance.?);
}

test "handleCheckUpdatesTarget filters updates by component and instance" {
    const allocator = std.testing.allocator;
    var s = state_mod.State.init(allocator, "/tmp/nullhub-test-updates-api-filtered.json");
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });
    try s.addInstance("nullclaw", "other-agent", .{ .version = "2026.3.1", .auto_start = false });
    try s.addInstance("nulltickets", "tracker", .{ .version = "2026.3.1", .auto_start = false });

    const resp = handleCheckUpdatesTarget(
        allocator,
        &s,
        "/api/updates?component=nullclaw&instance=my-agent",
    );
    defer allocator.free(resp.body);

    const parsed = try std.json.parseFromSlice(
        struct {
            updates: []const struct {
                component: []const u8,
                instance: []const u8,
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
