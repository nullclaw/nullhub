const std = @import("std");
const paths_mod = @import("paths.zig");
const state_mod = @import("state.zig");

const MAX_CONFIG_BYTES = 8 * 1024 * 1024;
const DEFAULT_WEB_PORT_START: u16 = 32123;

pub const EnsureWebChannelResult = struct {
    changed: bool = false,
    web_port: ?u16 = null,
};

pub fn ensureNullclawWebChannelConfig(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    state: *const state_mod.State,
    component: []const u8,
    name: []const u8,
) !EnsureWebChannelResult {
    if (!std.mem.eql(u8, component, "nullclaw")) return .{};

    const config_path = paths.instanceConfig(allocator, component, name) catch return .{};
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, MAX_CONFIG_BYTES);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return .{};
    const root = &parsed.value.object;

    if (extractConfiguredWebPort(root.*)) |existing_port| {
        return .{ .web_port = existing_port };
    }

    var used_ports = try collectUsedNullclawWebPorts(allocator, paths, state, name);
    defer used_ports.deinit();
    const web_port = pickAvailableWebPort(used_ports);

    var changed = false;
    const channels_obj = (try ensureObjectField(allocator, root, "channels", &changed)) orelse return .{};
    const web_obj = (try ensureObjectField(allocator, channels_obj, "web", &changed)) orelse return .{};
    const accounts_obj = (try ensureObjectField(allocator, web_obj, "accounts", &changed)) orelse return .{};
    const default_obj = (try ensureObjectField(allocator, accounts_obj, "default", &changed)) orelse return .{};

    try setStringFieldIfMissing(default_obj, "account_id", "default", &changed);
    try setStringFieldIfMissing(default_obj, "transport", "local", &changed);
    try setIntegerFieldIfMissing(default_obj, "port", web_port, &changed);
    try setStringFieldIfMissing(default_obj, "listen", "127.0.0.1", &changed);
    try setStringFieldIfMissing(default_obj, "path", "/ws", &changed);
    try setIntegerFieldIfMissing(default_obj, "max_connections", 10, &changed);
    try setStringFieldIfMissing(default_obj, "message_auth_mode", "pairing", &changed);
    try setOriginsIfMissing(allocator, default_obj, &changed);

    if (!changed) {
        return .{ .web_port = web_port };
    }

    const rendered = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(rendered);

    var out = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(rendered);
    try out.writeAll("\n");

    return .{
        .changed = true,
        .web_port = web_port,
    };
}

pub fn assignFreshNullclawWebChannelPort(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    state: *const state_mod.State,
    component: []const u8,
    name: []const u8,
) !EnsureWebChannelResult {
    if (!std.mem.eql(u8, component, "nullclaw")) return .{};

    const config_path = paths.instanceConfig(allocator, component, name) catch return .{};
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, MAX_CONFIG_BYTES);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return .{};
    const root = &parsed.value.object;

    var used_ports = try collectUsedNullclawWebPorts(allocator, paths, state, name);
    defer used_ports.deinit();
    const web_port = pickAvailableWebPort(used_ports);

    var changed = false;
    const channels_obj = (try ensureObjectField(allocator, root, "channels", &changed)) orelse return .{};
    const web_obj = (try ensureObjectField(allocator, channels_obj, "web", &changed)) orelse return .{};
    const accounts_obj = (try ensureObjectField(allocator, web_obj, "accounts", &changed)) orelse return .{};
    const default_obj = (try ensureObjectField(allocator, accounts_obj, "default", &changed)) orelse return .{};

    try setStringFieldIfMissing(default_obj, "account_id", "default", &changed);
    try setStringFieldIfMissing(default_obj, "transport", "local", &changed);
    try setIntegerField(default_obj, "port", web_port, &changed);
    try setStringFieldIfMissing(default_obj, "listen", "127.0.0.1", &changed);
    try setStringFieldIfMissing(default_obj, "path", "/ws", &changed);
    try setIntegerFieldIfMissing(default_obj, "max_connections", 10, &changed);
    try setStringFieldIfMissing(default_obj, "message_auth_mode", "pairing", &changed);
    try setOriginsIfMissing(allocator, default_obj, &changed);

    const rendered = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
    });
    defer allocator.free(rendered);

    var out = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(rendered);
    try out.writeAll("\n");

    return .{
        .changed = true,
        .web_port = web_port,
    };
}

fn ensureObjectField(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    key: []const u8,
    changed: *bool,
) !?*std.json.ObjectMap {
    const gop = try obj.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .object = std.json.ObjectMap.init(allocator) };
        changed.* = true;
        return &gop.value_ptr.object;
    }
    if (gop.value_ptr.* != .object) return null;
    return &gop.value_ptr.object;
}

fn setStringFieldIfMissing(
    obj: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
    changed: *bool,
) !void {
    if (obj.get(key) != null) return;
    try obj.put(key, .{ .string = value });
    changed.* = true;
}

fn setIntegerFieldIfMissing(
    obj: *std.json.ObjectMap,
    key: []const u8,
    value: u16,
    changed: *bool,
) !void {
    if (obj.get(key) != null) return;
    try obj.put(key, .{ .integer = value });
    changed.* = true;
}

fn setIntegerField(
    obj: *std.json.ObjectMap,
    key: []const u8,
    value: u16,
    changed: *bool,
) !void {
    if (obj.get(key)) |existing| {
        if (existing == .integer and existing.integer == value) return;
    }
    try obj.put(key, .{ .integer = value });
    changed.* = true;
}

fn setOriginsIfMissing(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    changed: *bool,
) !void {
    if (obj.get("allowed_origins") != null) return;

    var origins = std.json.Array.init(allocator);
    try origins.append(.{ .string = "*" });
    try obj.put("allowed_origins", .{ .array = origins });
    changed.* = true;
}

fn extractConfiguredWebPort(root: std.json.ObjectMap) ?u16 {
    if (root.get("channels")) |channels_value| {
        if (channels_value == .object) {
            const channels = channels_value.object;
            if (channels.get("web")) |web_value| {
                if (web_value == .object) {
                    if (extractWebPortFromWebObject(web_value.object)) |port| return port;
                }
            }
        }
    }

    if (root.get("web_port")) |web_port_value| {
        if (valueAsPort(web_port_value)) |port| return port;
    }

    return null;
}

fn extractWebPortFromWebObject(web_obj: std.json.ObjectMap) ?u16 {
    if (web_obj.get("accounts")) |accounts_value| {
        if (accounts_value == .object) {
            if (extractPortFromAccounts(accounts_value.object)) |port| return port;
        }
    }

    if (web_obj.get("port")) |port_value| {
        if (valueAsPort(port_value)) |port| return port;
    }
    return null;
}

fn extractPortFromAccounts(accounts_obj: std.json.ObjectMap) ?u16 {
    if (accounts_obj.get("default")) |default_value| {
        if (default_value == .object) {
            if (default_value.object.get("port")) |port_value| {
                if (valueAsPort(port_value)) |port| return port;
            }
        }
    }
    if (accounts_obj.get("main")) |main_value| {
        if (main_value == .object) {
            if (main_value.object.get("port")) |port_value| {
                if (valueAsPort(port_value)) |port| return port;
            }
        }
    }

    var it = accounts_obj.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        if (entry.value_ptr.object.get("port")) |port_value| {
            if (valueAsPort(port_value)) |port| return port;
        }
    }
    return null;
}

fn valueAsPort(value: std.json.Value) ?u16 {
    return switch (value) {
        .integer => |v| if (v > 0 and v <= 65535) @intCast(v) else null,
        else => null,
    };
}

fn collectUsedNullclawWebPorts(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    state: *const state_mod.State,
    skip_instance_name: []const u8,
) !std.AutoHashMap(u16, void) {
    var ports = std.AutoHashMap(u16, void).init(allocator);
    errdefer ports.deinit();

    const nullclaw_instances = state.instances.get("nullclaw") orelse return ports;
    var it = nullclaw_instances.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, skip_instance_name)) continue;
        const config_path = paths.instanceConfig(allocator, "nullclaw", entry.key_ptr.*) catch continue;
        defer allocator.free(config_path);
        const maybe_port = readConfiguredWebPortFromFile(allocator, config_path) catch continue;
        if (maybe_port) |port| {
            try ports.put(port, {});
        }
    }

    return ports;
}

fn readConfiguredWebPortFromFile(allocator: std.mem.Allocator, config_path: []const u8) !?u16 {
    const file = std.fs.openFileAbsolute(config_path, .{}) catch return null;
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, MAX_CONFIG_BYTES);
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    if (parsed.value != .object) return null;
    return extractConfiguredWebPort(parsed.value.object);
}

fn pickAvailableWebPort(used_ports: std.AutoHashMap(u16, void)) u16 {
    var candidate = DEFAULT_WEB_PORT_START;
    while (candidate < 65535) : (candidate += 1) {
        if (!used_ports.contains(candidate)) return candidate;
    }
    return DEFAULT_WEB_PORT_START;
}

fn writeAbsolute(path: []const u8, content: []const u8) !void {
    var file = try std.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(content);
}

test "ensureNullclawWebChannelConfig injects web channel when missing" {
    const allocator = std.testing.allocator;
    const root = "/tmp/nullhub-test-web-channel-missing";
    std.fs.deleteTreeAbsolute(root) catch {};
    defer std.fs.deleteTreeAbsolute(root) catch {};

    var paths = try paths_mod.Paths.init(allocator, root);
    defer paths.deinit();
    try paths.ensureDirs();

    var state = state_mod.State.init(allocator, "/tmp/nullhub-test-web-channel-missing/state.json");
    defer state.deinit();

    try state.addInstance("nullclaw", "instance-1", .{
        .version = "v2026.3.3",
        .auto_start = true,
        .launch_mode = "gateway",
    });

    const inst_dir = try paths.instanceDir(allocator, "nullclaw", "instance-1");
    defer allocator.free(inst_dir);
    try std.fs.makeDirAbsolute(inst_dir);

    const cfg_path = try paths.instanceConfig(allocator, "nullclaw", "instance-1");
    defer allocator.free(cfg_path);
    try writeAbsolute(cfg_path,
        \\{
        \\  "gateway": { "port": 3000 },
        \\  "channels": {
        \\    "webhook": { "port": 3000 }
        \\  }
        \\}
    );

    const result = try ensureNullclawWebChannelConfig(allocator, paths, &state, "nullclaw", "instance-1");
    try std.testing.expect(result.changed);
    try std.testing.expect(result.web_port != null);

    const contents = try std.fs.cwd().readFileAlloc(allocator, cfg_path, MAX_CONFIG_BYTES);
    defer allocator.free(contents);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
    });
    defer parsed.deinit();
    const root_obj = parsed.value.object;
    const web_port = extractConfiguredWebPort(root_obj) orelse 0;
    try std.testing.expect(web_port >= DEFAULT_WEB_PORT_START);
}

test "ensureNullclawWebChannelConfig picks next free port among instances" {
    const allocator = std.testing.allocator;
    const root = "/tmp/nullhub-test-web-channel-port-pick";
    std.fs.deleteTreeAbsolute(root) catch {};
    defer std.fs.deleteTreeAbsolute(root) catch {};

    var paths = try paths_mod.Paths.init(allocator, root);
    defer paths.deinit();
    try paths.ensureDirs();

    var state = state_mod.State.init(allocator, "/tmp/nullhub-test-web-channel-port-pick/state.json");
    defer state.deinit();

    try state.addInstance("nullclaw", "default", .{
        .version = "v2026.3.3",
        .auto_start = true,
        .launch_mode = "gateway",
    });
    try state.addInstance("nullclaw", "instance-2", .{
        .version = "v2026.3.3",
        .auto_start = true,
        .launch_mode = "gateway",
    });

    const default_dir = try paths.instanceDir(allocator, "nullclaw", "default");
    defer allocator.free(default_dir);
    try std.fs.makeDirAbsolute(default_dir);

    const default_cfg = try paths.instanceConfig(allocator, "nullclaw", "default");
    defer allocator.free(default_cfg);
    try writeAbsolute(default_cfg,
        \\{
        \\  "channels": {
        \\    "web": {
        \\      "accounts": {
        \\        "default": {
        \\          "port": 32123
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
    );

    const inst_dir = try paths.instanceDir(allocator, "nullclaw", "instance-2");
    defer allocator.free(inst_dir);
    try std.fs.makeDirAbsolute(inst_dir);

    const inst_cfg = try paths.instanceConfig(allocator, "nullclaw", "instance-2");
    defer allocator.free(inst_cfg);
    try writeAbsolute(inst_cfg,
        \\{
        \\  "channels": {
        \\    "webhook": { "port": 3000 }
        \\  }
        \\}
    );

    const result = try ensureNullclawWebChannelConfig(allocator, paths, &state, "nullclaw", "instance-2");
    try std.testing.expect(result.changed);
    try std.testing.expectEqual(@as(?u16, 32124), result.web_port);
}
