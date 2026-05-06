const std = @import("std");
const std_compat = @import("compat");
const state_mod = @import("../core/state.zig");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");
const wizard_api = @import("wizard.zig");
const providers_api = @import("providers.zig");
const component_cli = @import("../core/component_cli.zig");
const test_helpers = @import("../test_helpers.zig");

const appendEscaped = helpers.appendEscaped;

// ─── Path Parsing ────────────────────────────────────────────────────────────

/// Check if path matches /api/channels or /api/channels/...
pub fn isChannelsPath(target: []const u8) bool {
    return std.mem.eql(u8, target, "/api/channels") or
        std.mem.startsWith(u8, target, "/api/channels?") or
        std.mem.startsWith(u8, target, "/api/channels/");
}

/// Extract channel ID from /api/channels/{id} or /api/channels/{id}/validate
pub fn extractChannelId(target: []const u8) ?u32 {
    const prefix = "/api/channels/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    // Get the segment before any slash
    const segment = if (std.mem.indexOfScalar(u8, rest, '/')) |slash_pos|
        rest[0..slash_pos]
    else
        rest;
    return std.fmt.parseInt(u32, segment, 10) catch null;
}

/// Check if path matches /api/channels/{id}/validate
pub fn isValidatePath(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "/api/channels/") and
        std.mem.endsWith(u8, target, "/validate");
}

/// Check if ?reveal=true is in the query string
pub fn hasRevealParam(target: []const u8) bool {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    return std.mem.indexOf(u8, target[query_start..], "reveal=true") != null;
}

// ─── Secret Masking ──────────────────────────────────────────────────────────

const secret_keys = [_][]const u8{
    "bot_token",
    "token",
    "access_token",
    "app_token",
    "signing_secret",
    "verify_token",
    "app_secret",
    "server_password",
    "nickserv_password",
    "sasl_password",
    "password",
    "encrypt_key",
    "verification_token",
    "client_secret",
    "channel_secret",
    "secret",
    "private_key",
    "auth_token",
    "relay_token",
};

fn isSecretKey(key: []const u8) bool {
    for (secret_keys) |sk| {
        if (std.mem.eql(u8, key, sk)) return true;
    }
    return false;
}

fn maskSecret(buf: *std.array_list.Managed(u8), value: []const u8) !void {
    if (value.len <= 8) {
        try buf.appendSlice("***");
    } else {
        try buf.appendSlice(value[0..4]);
        try buf.appendSlice("...");
        try buf.appendSlice(value[value.len - 4 ..]);
    }
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/channels — list all saved channels
pub fn handleList(allocator: std.mem.Allocator, state: *state_mod.State, reveal: bool) ![]const u8 {
    const channels = state.savedChannels();

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("{\"channels\":[");

    for (channels, 0..) |sc, idx| {
        if (idx > 0) try buf.append(',');
        try appendChannelJson(&buf, sc, reveal);
    }

    try buf.appendSlice("]}");
    return buf.toOwnedSlice();
}

/// POST /api/channels — validate and save a new channel
pub fn handleCreate(
    allocator: std.mem.Allocator,
    body: []const u8,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    // Parse as generic JSON to extract channel_type, account, and config object
    var tree = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    }) catch return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}");
    defer tree.deinit();

    const root_obj = switch (tree.value) {
        .object => |obj| obj,
        else => return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}"),
    };

    const channel_type = switch (root_obj.get("channel_type") orelse return try allocator.dupe(u8, "{\"error\":\"missing channel_type\"}")) {
        .string => |s| s,
        else => return try allocator.dupe(u8, "{\"error\":\"channel_type must be a string\"}"),
    };

    const account = switch (root_obj.get("account") orelse return try allocator.dupe(u8, "{\"error\":\"missing account\"}")) {
        .string => |s| s,
        else => return try allocator.dupe(u8, "{\"error\":\"account must be a string\"}"),
    };

    // Serialize config object to JSON string
    const config_val = root_obj.get("config");
    const config_json: []const u8 = if (config_val) |cv| switch (cv) {
        .object => try std.json.Stringify.valueAlloc(allocator, cv, .{}),
        else => return try allocator.dupe(u8, "{\"error\":\"config must be an object\"}"),
    } else "";
    defer if (config_json.len > 0) allocator.free(config_json);

    // Find an installed component binary
    const component_name = findProbeComponent(allocator, state) orelse
        return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate channels\"}");
    defer allocator.free(component_name);

    const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
        return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
    defer allocator.free(bin_path);

    // Validate via probe
    const probe_result = probeChannel(allocator, component_name, bin_path, channel_type, account, config_json);
    if (!probe_result.live_ok) {
        var buf = std.array_list.Managed(u8).init(allocator);
        errdefer buf.deinit();
        try buf.appendSlice("{\"error\":\"Channel validation failed: ");
        try appendEscaped(&buf, probe_result.reason);
        try buf.appendSlice("\"}");
        return buf.toOwnedSlice();
    }

    // Save to state
    try state.addSavedChannel(.{
        .channel_type = channel_type,
        .account = account,
        .config = config_json,
        .validated_with = component_name,
    });

    // Update validated_at on the just-added channel
    const channels = state.savedChannels();
    const new_id = channels[channels.len - 1].id;
    const now = try providers_api.nowIso8601(allocator);
    defer allocator.free(now);
    _ = try state.updateSavedChannel(new_id, .{ .validated_at = now });

    try state.save();

    // Return the saved channel
    const sc = state.getSavedChannel(new_id).?;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try appendChannelJson(&buf, sc, true);
    return buf.toOwnedSlice();
}

/// PUT /api/channels/{id} — update a saved channel
pub fn handleUpdate(
    allocator: std.mem.Allocator,
    id: u32,
    body: []const u8,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    const existing = state.getSavedChannel(id) orelse return try allocator.dupe(u8, "{\"error\":\"channel not found\"}");

    // Parse as generic JSON
    var tree = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
    }) catch return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}");
    defer tree.deinit();

    const root_obj = switch (tree.value) {
        .object => |obj| obj,
        else => return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}"),
    };

    const new_name: ?[]const u8 = if (root_obj.get("name")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    const new_account: ?[]const u8 = if (root_obj.get("account")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    // Serialize config object if present
    const config_val = root_obj.get("config");
    const new_config: ?[]const u8 = if (config_val) |cv| switch (cv) {
        .object => try std.json.Stringify.valueAlloc(allocator, cv, .{}),
        else => return try allocator.dupe(u8, "{\"error\":\"config must be an object\"}"),
    } else null;
    defer if (new_config) |c| if (c.len > 0) allocator.free(c);

    const credentials_changed = (new_account != null and
        !std.mem.eql(u8, new_account.?, existing.account)) or
        (new_config != null and
            !std.mem.eql(u8, new_config.?, existing.config));

    if (credentials_changed) {
        // Re-validate
        const component_name = findProbeComponent(allocator, state) orelse
            return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate channels\"}");
        defer allocator.free(component_name);

        const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
            return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
        defer allocator.free(bin_path);

        const effective_account = new_account orelse existing.account;
        const effective_config = new_config orelse existing.config;

        const probe_result = probeChannel(allocator, component_name, bin_path, existing.channel_type, effective_account, effective_config);
        if (!probe_result.live_ok) {
            var buf = std.array_list.Managed(u8).init(allocator);
            errdefer buf.deinit();
            try buf.appendSlice("{\"error\":\"Channel validation failed: ");
            try appendEscaped(&buf, probe_result.reason);
            try buf.appendSlice("\"}");
            return buf.toOwnedSlice();
        }

        const now = providers_api.nowIso8601(allocator) catch "";
        defer if (now.len > 0) allocator.free(now);

        _ = try state.updateSavedChannel(id, .{
            .name = new_name,
            .account = new_account,
            .config = new_config,
            .validated_at = now,
            .validated_with = component_name,
        });
    } else {
        // Name-only update
        _ = try state.updateSavedChannel(id, .{ .name = new_name });
    }

    try state.save();

    const sc = state.getSavedChannel(id).?;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try appendChannelJson(&buf, sc, true);
    return buf.toOwnedSlice();
}

/// DELETE /api/channels/{id}
pub fn handleDelete(allocator: std.mem.Allocator, id: u32, state: *state_mod.State) ![]const u8 {
    if (!state.removeSavedChannel(id)) {
        return try allocator.dupe(u8, "{\"error\":\"channel not found\"}");
    }
    try state.save();
    return allocator.dupe(u8, "{\"status\":\"ok\"}");
}

/// POST /api/channels/{id}/validate — re-validate existing channel
pub fn handleValidate(
    allocator: std.mem.Allocator,
    id: u32,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    const existing = state.getSavedChannel(id) orelse return try allocator.dupe(u8, "{\"error\":\"channel not found\"}");

    const component_name = findProbeComponent(allocator, state) orelse
        return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate channels\"}");
    defer allocator.free(component_name);

    const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
        return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
    defer allocator.free(bin_path);

    const probe_result = probeChannel(allocator, component_name, bin_path, existing.channel_type, existing.account, existing.config);

    if (probe_result.live_ok) {
        const now = try providers_api.nowIso8601(allocator);
        defer allocator.free(now);
        _ = try state.updateSavedChannel(id, .{ .validated_at = now, .validated_with = component_name });
        try state.save();
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("{\"live_ok\":");
    try buf.appendSlice(if (probe_result.live_ok) "true" else "false");
    try buf.appendSlice(",\"reason\":\"");
    try appendEscaped(&buf, probe_result.reason);
    try buf.appendSlice("\"}");
    return buf.toOwnedSlice();
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn findProbeComponent(allocator: std.mem.Allocator, state: *state_mod.State) ?[]const u8 {
    const names = state.instanceNames("nullclaw") catch return null;
    defer if (names) |list| allocator.free(list);
    if (names) |list| {
        if (list.len > 0) {
            return allocator.dupe(u8, "nullclaw") catch null;
        }
    }
    return null;
}

const ProbeResult = struct { live_ok: bool, reason: []const u8 };

fn probeChannel(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    channel_type: []const u8,
    account: []const u8,
    config_json: []const u8,
) ProbeResult {
    // Create temp dir for minimal config
    const tmp_dir = paths_mod.uniqueTempPathAlloc(allocator, "nullhub-channel-validate", "") catch
        return .{ .live_ok = false, .reason = "tmp_dir_failed" };
    defer {
        std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
        allocator.free(tmp_dir);
    }
    std_compat.fs.makeDirAbsolute(tmp_dir) catch return .{ .live_ok = false, .reason = "tmp_dir_failed" };

    // Write config as {"channels":{"{type}":{"{account}":{config}}}}
    writeChannelConfig(allocator, tmp_dir, channel_type, account, config_json) catch
        return .{ .live_ok = false, .reason = "config_write_failed" };

    // Run --probe-channel-health
    const result = component_cli.runWithComponentHome(
        allocator,
        component_name,
        binary_path,
        &.{ "--probe-channel-health", "--channel", channel_type, "--account", account, "--timeout-secs", "10" },
        null,
        tmp_dir,
    ) catch return .{ .live_ok = false, .reason = "probe_exec_failed" };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const probe_parsed = std.json.parseFromSlice(struct {
        live_ok: bool = false,
        reason: ?[]const u8 = null,
    }, allocator, result.stdout, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return .{ .live_ok = false, .reason = "invalid_probe_response" };
    defer probe_parsed.deinit();

    const reason = probe_parsed.value.reason orelse (if (probe_parsed.value.live_ok) "ok" else "probe_failed");
    return .{ .live_ok = probe_parsed.value.live_ok, .reason = reason };
}

fn writeChannelConfig(
    allocator: std.mem.Allocator,
    dir: []const u8,
    channel_type: []const u8,
    account: []const u8,
    config_json: []const u8,
) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{dir});
    defer allocator.free(config_path);

    // Build: {"channels":{"{type}":{"{account}": <config>}}}
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try buf.appendSlice("{\"channels\":{\"");
    try appendEscaped(&buf, channel_type);
    try buf.appendSlice("\":{\"");
    try appendEscaped(&buf, account);
    try buf.appendSlice("\":");
    if (config_json.len > 0) {
        try buf.appendSlice(config_json);
    } else {
        try buf.appendSlice("{}");
    }
    try buf.appendSlice("}}}");

    const file = try std_compat.fs.createFileAbsolute(config_path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

fn appendChannelJson(buf: *std.array_list.Managed(u8), sc: state_mod.SavedChannel, reveal: bool) !void {
    try buf.appendSlice("{\"id\":\"sc_");
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{sc.id}) catch "0";
    try buf.appendSlice(id_str);
    try buf.appendSlice("\"");
    try buf.appendSlice(",\"name\":\"");
    try appendEscaped(buf, sc.name);
    try buf.appendSlice("\",\"channel_type\":\"");
    try appendEscaped(buf, sc.channel_type);
    try buf.appendSlice("\",\"account\":\"");
    try appendEscaped(buf, sc.account);
    try buf.appendSlice("\",\"config\":");
    if (sc.config.len > 0) {
        if (reveal) {
            // Output config as raw JSON
            try buf.appendSlice(sc.config);
        } else {
            try appendMaskedConfig(buf, sc.config);
        }
    } else {
        try buf.appendSlice("{}");
    }
    try buf.appendSlice(",\"validated_at\":\"");
    try appendEscaped(buf, sc.validated_at);
    try buf.appendSlice("\",\"validated_with\":\"");
    try appendEscaped(buf, sc.validated_with);
    try buf.appendSlice("\"}");
}

fn appendMaskedConfig(buf: *std.array_list.Managed(u8), config_json: []const u8) !void {
    const allocator = buf.allocator;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{
        .allocate = .alloc_always,
    }) catch {
        // If we can't parse, output as-is
        try buf.appendSlice(config_json);
        return;
    };
    defer parsed.deinit();

    const obj = switch (parsed.value) {
        .object => |o| o,
        else => {
            // Not an object, output as-is
            try buf.appendSlice(config_json);
            return;
        },
    };

    try buf.append('{');
    var first = true;
    var it = obj.iterator();
    while (it.next()) |entry| {
        if (!first) try buf.append(',');
        first = false;

        // Output key
        try buf.append('"');
        try appendEscaped(buf, entry.key_ptr.*);
        try buf.appendSlice("\":");

        if (isSecretKey(entry.key_ptr.*)) {
            // Mask string values of secret keys
            switch (entry.value_ptr.*) {
                .string => |s| {
                    try buf.append('"');
                    try maskSecret(buf, s);
                    try buf.append('"');
                },
                else => {
                    // Non-string secret key: serialize as-is
                    const val_str = std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{}) catch {
                        try buf.appendSlice("null");
                        continue;
                    };
                    defer allocator.free(val_str);
                    try buf.appendSlice(val_str);
                },
            }
        } else {
            // Non-secret key: serialize value as-is
            const val_str = std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{}) catch {
                try buf.appendSlice("null");
                continue;
            };
            defer allocator.free(val_str);
            try buf.appendSlice(val_str);
        }
    }
    try buf.append('}');
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "isChannelsPath matches correct paths" {
    try std.testing.expect(isChannelsPath("/api/channels"));
    try std.testing.expect(isChannelsPath("/api/channels?reveal=true"));
    try std.testing.expect(isChannelsPath("/api/channels/1"));
    try std.testing.expect(isChannelsPath("/api/channels/1/validate"));
    try std.testing.expect(!isChannelsPath("/api/wizard"));
    try std.testing.expect(!isChannelsPath("/api/channel"));
}

test "extractChannelId parses correctly" {
    try std.testing.expectEqual(@as(?u32, 1), extractChannelId("/api/channels/1"));
    try std.testing.expectEqual(@as(?u32, 42), extractChannelId("/api/channels/42"));
    try std.testing.expectEqual(@as(?u32, 5), extractChannelId("/api/channels/5/validate"));
    try std.testing.expectEqual(@as(?u32, null), extractChannelId("/api/channels"));
    try std.testing.expectEqual(@as(?u32, null), extractChannelId("/api/channels/abc"));
}

test "isValidatePath matches only validate suffix" {
    try std.testing.expect(isValidatePath("/api/channels/1/validate"));
    try std.testing.expect(!isValidatePath("/api/channels/1"));
    try std.testing.expect(!isValidatePath("/api/channels"));
}

test "hasRevealParam detects reveal query param" {
    try std.testing.expect(hasRevealParam("/api/channels?reveal=true"));
    try std.testing.expect(!hasRevealParam("/api/channels"));
    try std.testing.expect(!hasRevealParam("/api/channels?reveal=false"));
}

test "handleList returns empty array for no channels" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const path = try fixture.paths.state(allocator);
    defer allocator.free(path);
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    const json = try handleList(allocator, &s, false);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"channels\":[]}", json);
}

test "handleList masks secrets in config" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const path = try fixture.paths.state(allocator);
    defer allocator.free(path);
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{
        .channel_type = "telegram",
        .account = "mybot",
        .config = "{\"bot_token\":\"123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11\",\"chat_id\":\"@mychannel\"}",
    });

    const json = try handleList(allocator, &s, false);
    defer allocator.free(json);
    // bot_token should be masked
    try std.testing.expect(std.mem.indexOf(u8, json, "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1234...ew11") != null);
    // chat_id should NOT be masked
    try std.testing.expect(std.mem.indexOf(u8, json, "@mychannel") != null);
}

test "handleList reveals secrets when requested" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const path = try fixture.paths.state(allocator);
    defer allocator.free(path);
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{
        .channel_type = "telegram",
        .account = "mybot",
        .config = "{\"bot_token\":\"123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11\",\"chat_id\":\"@mychannel\"}",
    });

    const json = try handleList(allocator, &s, true);
    defer allocator.free(json);
    // bot_token should be revealed
    try std.testing.expect(std.mem.indexOf(u8, json, "123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11") != null);
}

test "handleDelete removes channel" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const path = try fixture.paths.state(allocator);
    defer allocator.free(path);

    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "mybot", .config = "{\"bot_token\":\"test\"}" });

    const json = try handleDelete(allocator, 1, &s);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", json);
    try std.testing.expectEqual(@as(usize, 0), s.savedChannels().len);
}

test "handleDelete returns error for unknown id" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const path = try fixture.paths.state(allocator);
    defer allocator.free(path);
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    const json = try handleDelete(allocator, 99, &s);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"error\":\"channel not found\"}", json);
}

test "handleCreate rejects non-object config" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const path = try fixture.paths.state(allocator);
    defer allocator.free(path);
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    const json = try handleCreate(
        allocator,
        "{\"channel_type\":\"telegram\",\"account\":\"default\",\"config\":null}",
        &s,
        fixture.paths,
    );
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"error\":\"config must be an object\"}", json);
}

test "handleUpdate rejects non-object config" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const path = try fixture.paths.state(allocator);
    defer allocator.free(path);

    var s = state_mod.State.init(allocator, path);
    defer s.deinit();
    try s.addSavedChannel(.{
        .channel_type = "telegram",
        .account = "default",
        .config = "{\"bot_token\":\"abc\"}",
    });

    const json = try handleUpdate(
        allocator,
        1,
        "{\"config\":false}",
        &s,
        fixture.paths,
    );
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"error\":\"config must be an object\"}", json);
}

test "writeChannelConfig escapes channel type and account" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();

    try writeChannelConfig(allocator, fixture.root, "telegram", "acct\"name\\slash", "{\"token\":\"abc\"}");

    const config_path = try fixture.path(allocator, "config.json");
    defer allocator.free(config_path);
    const bytes = try std_compat.fs.cwd().readFileAlloc(allocator, config_path, 4096);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();

    const channels = parsed.value.object.get("channels").?.object;
    const telegram = channels.get("telegram").?.object;
    const account_cfg = telegram.get("acct\"name\\slash").?.object;
    try std.testing.expectEqualStrings("abc", account_cfg.get("token").?.string);
}
