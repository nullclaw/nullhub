const std = @import("std");
const std_compat = @import("compat");
const component_cli = @import("../core/component_cli.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");

pub fn supports(component: []const u8) bool {
    return std.mem.eql(u8, component, "nullclaw");
}

pub fn tryReadConfigJson(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    path: ?[]const u8,
) ?[]const u8 {
    if (!supports(component)) return null;
    return if (path) |value|
        tryRunJson(allocator, s, paths, component, name, &.{ "config", "get", value, "--json" })
    else
        tryRunJson(allocator, s, paths, component, name, &.{ "config", "show", "--json" });
}

pub fn tryReadModelsSummaryJson(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ?[]const u8 {
    if (!supports(component)) return null;
    return tryRunJson(allocator, s, paths, component, name, &.{ "models", "summary", "--json" });
}

pub fn tryReadStatusJson(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ?[]const u8 {
    if (!supports(component)) return null;
    return tryRunJson(allocator, s, paths, component, name, &.{ "status", "--json" });
}

pub fn tryReadCronListJson(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ?[]const u8 {
    if (!supports(component)) return null;
    return tryRunJson(allocator, s, paths, component, name, &.{ "cron", "list", "--json" });
}

pub fn tryReadChannelsJson(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    type_name: ?[]const u8,
) ?[]const u8 {
    if (!supports(component)) return null;
    return if (type_name) |value|
        tryRunJson(allocator, s, paths, component, name, &.{ "channel", "info", value, "--json" })
    else
        tryRunJson(allocator, s, paths, component, name, &.{ "channel", "list", "--json" });
}

pub fn readConfigBytes(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ![]u8 {
    const config_path = try paths.instanceConfig(allocator, component, name);
    defer allocator.free(config_path);

    const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close();

    return try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
}

pub fn buildModelsSummaryJsonFromConfig(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"default_provider\":");
    if (inferredDefaultProvider(parsed.value)) |value| {
        try buf.append('"');
        try appendEscaped(&buf, value);
        try buf.append('"');
    } else {
        try buf.appendSlice("null");
    }

    try buf.appendSlice(",\"default_model\":");
    if (jsonStringPath(parsed.value, &.{"default_model"}) orelse
        jsonStringPath(parsed.value, &.{ "agents", "defaults", "model", "primary" })) |value|
    {
        try buf.append('"');
        try appendEscaped(&buf, value);
        try buf.append('"');
    } else {
        try buf.appendSlice("null");
    }

    try buf.appendSlice(",\"providers\":[");
    if (jsonValuePath(parsed.value, &.{ "models", "providers" })) |value| {
        if (value == .object) {
            const ProviderSummary = struct {
                name: []const u8,
                has_key: bool,
            };

            var providers = std.ArrayListUnmanaged(ProviderSummary).empty;
            defer providers.deinit(allocator);

            var it = value.object.iterator();
            while (it.next()) |entry| {
                const has_key = if (entry.value_ptr.* == .object)
                    if (entry.value_ptr.object.get("api_key")) |api_key|
                        switch (api_key) {
                            .string => std.mem.trim(u8, api_key.string, " \t\r\n").len > 0,
                            else => api_key != .null,
                        }
                    else
                        false
                else
                    false;
                try providers.append(allocator, .{
                    .name = entry.key_ptr.*,
                    .has_key = has_key,
                });
            }

            std.mem.sort(ProviderSummary, providers.items, {}, struct {
                fn lessThan(_: void, lhs: ProviderSummary, rhs: ProviderSummary) bool {
                    return std.mem.order(u8, lhs.name, rhs.name) == .lt;
                }
            }.lessThan);

            for (providers.items, 0..) |provider, idx| {
                if (idx > 0) try buf.append(',');
                try buf.appendSlice("{\"name\":\"");
                try appendEscaped(&buf, provider.name);
                try buf.appendSlice("\",\"has_key\":");
                try buf.appendSlice(if (provider.has_key) "true" else "false");
                try buf.append('}');
            }
        }
    }
    try buf.appendSlice("]}");

    return try buf.toOwnedSlice();
}

const ChannelTypeEntry = struct {
    field: []const u8,
    type_name: []const u8,
};

const channel_types = [_]ChannelTypeEntry{
    .{ .field = "telegram", .type_name = "telegram" },
    .{ .field = "discord", .type_name = "discord" },
    .{ .field = "slack", .type_name = "slack" },
    .{ .field = "imessage", .type_name = "imessage" },
    .{ .field = "matrix", .type_name = "matrix" },
    .{ .field = "mattermost", .type_name = "mattermost" },
    .{ .field = "whatsapp", .type_name = "whatsapp" },
    .{ .field = "teams", .type_name = "teams" },
    .{ .field = "irc", .type_name = "irc" },
    .{ .field = "lark", .type_name = "lark" },
    .{ .field = "dingtalk", .type_name = "dingtalk" },
    .{ .field = "wechat", .type_name = "wechat" },
    .{ .field = "wecom", .type_name = "wecom" },
    .{ .field = "signal", .type_name = "signal" },
    .{ .field = "email", .type_name = "email" },
    .{ .field = "line", .type_name = "line" },
    .{ .field = "qq", .type_name = "qq" },
    .{ .field = "onebot", .type_name = "onebot" },
    .{ .field = "maixcam", .type_name = "maixcam" },
    .{ .field = "web", .type_name = "web" },
    .{ .field = "max", .type_name = "max" },
    .{ .field = "external", .type_name = "external" },
};

const ChannelAccountSummary = struct {
    type: []const u8,
    account_id: []const u8,
    configured: bool = true,
    status: []const u8 = "unknown",
};

const ChannelAccountDetail = struct {
    account_id: []const u8,
    configured: bool = true,
};

const ChannelTypeDetail = struct {
    type: []const u8,
    status: []const u8 = "unknown",
    accounts: []const ChannelAccountDetail,
};

pub fn buildChannelsJsonFromConfig(
    allocator: std.mem.Allocator,
    config_bytes: []const u8,
    type_name: ?[]const u8,
) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return if (type_name) |value|
        buildChannelDetailJson(allocator, parsed.value, value)
    else
        buildChannelListJson(allocator, parsed.value);
}

fn buildChannelListJson(allocator: std.mem.Allocator, root: std.json.Value) ![]u8 {
    var entries = std.ArrayListUnmanaged(ChannelAccountSummary).empty;
    defer entries.deinit(allocator);

    inline for (channel_types) |entry| {
        const account_ids = try accountIdsForType(allocator, root, entry.field);
        defer if (account_ids.len > 0) allocator.free(account_ids);

        for (account_ids) |account_id| {
            try entries.append(allocator, .{
                .type = entry.type_name,
                .account_id = account_id,
            });
        }
    }

    return try std.json.Stringify.valueAlloc(allocator, entries.items, .{
        .emit_null_optional_fields = false,
    });
}

fn buildChannelDetailJson(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    type_name: []const u8,
) ![]u8 {
    inline for (channel_types) |entry| {
        if (std.mem.eql(u8, entry.type_name, type_name)) {
            const account_ids = try accountIdsForType(allocator, root, entry.field);
            defer if (account_ids.len > 0) allocator.free(account_ids);

            var accounts = std.ArrayListUnmanaged(ChannelAccountDetail).empty;
            defer accounts.deinit(allocator);

            for (account_ids) |account_id| {
                try accounts.append(allocator, .{
                    .account_id = account_id,
                });
            }

            return try std.json.Stringify.valueAlloc(allocator, ChannelTypeDetail{
                .type = entry.type_name,
                .accounts = accounts.items,
            }, .{
                .emit_null_optional_fields = false,
            });
        }
    }

    return error.UnknownChannelType;
}

fn accountIdsForType(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    field_name: []const u8,
) ![]const []const u8 {
    var account_ids = std.ArrayListUnmanaged([]const u8).empty;
    errdefer account_ids.deinit(allocator);

    const channels_value = jsonValuePath(root, &.{"channels"}) orelse return &.{};
    if (channels_value != .object) return &.{};

    const channel_value = channels_value.object.get(field_name) orelse return &.{};
    if (channel_value != .object) return &.{};

    if (channel_value.object.get("accounts")) |accounts_value| {
        if (accounts_value == .object) {
            var it = accounts_value.object.iterator();
            while (it.next()) |account| {
                try account_ids.append(allocator, account.key_ptr.*);
            }
        }
    } else if (channelValueLooksConfigured(channel_value)) {
        try account_ids.append(allocator, "default");
    }

    if (account_ids.items.len > 1) {
        std.mem.sort([]const u8, account_ids.items, {}, struct {
            fn lessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
                return std.mem.order(u8, lhs, rhs) == .lt;
            }
        }.lessThan);
    }

    return try account_ids.toOwnedSlice(allocator);
}

fn channelValueLooksConfigured(value: std.json.Value) bool {
    return switch (value) {
        .object => |obj| obj.count() > 0,
        .string => |text| text.len > 0,
        .integer, .float, .bool => true,
        else => false,
    };
}

fn tryRunJson(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    args: []const []const u8,
) ?[]const u8 {
    const entry = s.getInstance(component, name) orelse return null;

    const bin_path = paths.binary(allocator, component, entry.version) catch return null;
    defer allocator.free(bin_path);
    std_compat.fs.accessAbsolute(bin_path, .{}) catch return null;

    const inst_dir = paths.instanceDir(allocator, component, name) catch return null;
    defer allocator.free(inst_dir);

    const result = component_cli.runWithComponentHome(
        allocator,
        component,
        bin_path,
        args,
        null,
        inst_dir,
    ) catch return null;
    defer allocator.free(result.stderr);

    if (!result.success or !isValidJsonPayload(allocator, result.stdout)) {
        allocator.free(result.stdout);
        return null;
    }

    return result.stdout;
}

fn isValidJsonPayload(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return false;
    parsed.deinit();
    return true;
}

fn jsonValuePath(root: std.json.Value, segments: []const []const u8) ?std.json.Value {
    var current = root;
    for (segments) |segment| {
        current = switch (current) {
            .object => |obj| obj.get(segment) orelse return null,
            else => return null,
        };
    }
    return current;
}

fn jsonStringPath(root: std.json.Value, segments: []const []const u8) ?[]const u8 {
    const value = jsonValuePath(root, segments) orelse return null;
    return if (value == .string) value.string else null;
}

fn inferredDefaultProvider(root: std.json.Value) ?[]const u8 {
    if (jsonStringPath(root, &.{"default_provider"})) |value| return value;
    if (jsonStringPath(root, &.{ "agents", "defaults", "model", "provider" })) |value| return value;

    const primary = jsonStringPath(root, &.{ "agents", "defaults", "model", "primary" }) orelse return null;
    if (jsonValuePath(root, &.{ "models", "providers" })) |value| {
        if (value == .object) {
            var longest_match: ?[]const u8 = null;
            var only_provider: ?[]const u8 = null;

            var it = value.object.iterator();
            while (it.next()) |entry| {
                const provider = entry.key_ptr.*;
                if (only_provider == null) {
                    only_provider = provider;
                } else {
                    only_provider = "";
                }

                if (std.mem.eql(u8, primary, provider)) {
                    if (longest_match == null or provider.len > longest_match.?.len) {
                        longest_match = provider;
                    }
                    continue;
                }
                if (primary.len <= provider.len) continue;
                if (!std.mem.startsWith(u8, primary, provider)) continue;
                if (primary[provider.len] != '/') continue;

                if (longest_match == null or provider.len > longest_match.?.len) {
                    longest_match = provider;
                }
            }

            if (longest_match) |provider| return provider;
            if (only_provider) |provider| {
                if (provider.len > 0) return provider;
            }
        }
    }

    const sep = std.mem.indexOfScalar(u8, primary, '/') orelse return null;
    if (sep == 0) return null;
    return primary[0..sep];
}

fn appendEscaped(buf: *std.array_list.Managed(u8), text: []const u8) !void {
    for (text) |ch| switch (ch) {
        '"' => try buf.appendSlice("\\\""),
        '\\' => try buf.appendSlice("\\\\"),
        '\n' => try buf.appendSlice("\\n"),
        '\r' => try buf.appendSlice("\\r"),
        '\t' => try buf.appendSlice("\\t"),
        else => {
            if (ch < 0x20) {
                var escape_buf: [6]u8 = undefined;
                const escape = try std.fmt.bufPrint(&escape_buf, "\\u{x:0>4}", .{ch});
                try buf.appendSlice(escape);
            } else {
                try buf.append(ch);
            }
        },
    };
}

test "buildModelsSummaryJsonFromConfig handles current config shape" {
    const allocator = std.testing.allocator;
    const config_bytes =
        \\{"agents":{"defaults":{"model":{"primary":"custom:https://gateway.example.com/api/qianfan/custom-model"}}},"models":{"providers":{"custom:https://gateway.example.com/api":{"api_key":"sk-test"}}}}
    ;

    const json = try buildModelsSummaryJsonFromConfig(allocator, config_bytes);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"default_provider\":\"custom:https://gateway.example.com/api\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"default_model\":\"custom:https://gateway.example.com/api/qianfan/custom-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"custom:https://gateway.example.com/api\",\"has_key\":true") != null);
}

test "buildModelsSummaryJsonFromConfig preserves provider ordering and hides secrets" {
    const allocator = std.testing.allocator;
    const config_bytes =
        \\{"default_provider":"openrouter","agents":{"defaults":{"model":{"primary":"openrouter/anthropic/claude-sonnet-4"}}},"models":{"providers":{"openrouter":{"api_key":"sk-test"},"ollama":{"api_key":"   "}}}}
    ;

    const json = try buildModelsSummaryJsonFromConfig(allocator, config_bytes);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"default_provider\":\"openrouter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"default_model\":\"openrouter/anthropic/claude-sonnet-4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"ollama\",\"has_key\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"openrouter\",\"has_key\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-test") == null);
}

test "isValidJsonPayload rejects malformed cli output" {
    const allocator = std.testing.allocator;
    try std.testing.expect(!isValidJsonPayload(allocator, "\n\"default_provider\":\"openrouter\"}"));
    try std.testing.expect(isValidJsonPayload(allocator, "{\"default_provider\":\"openrouter\"}"));
}

test "buildChannelsJsonFromConfig lists configured accounts without secrets" {
    const allocator = std.testing.allocator;
    const config_bytes =
        \\{"channels":{"telegram":{"accounts":{"main":{"bot_token":"secret"},"backup":{"bot_token":"hidden"}}},"discord":{"accounts":{"guild":{"token":"discord-secret"}}}}}
    ;

    const json = try buildChannelsJsonFromConfig(allocator, config_bytes, null);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"account_id\":\"backup\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"discord\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "secret") == null);
}

test "buildChannelsJsonFromConfig returns detail for known type with empty accounts" {
    const allocator = std.testing.allocator;
    const config_bytes =
        \\{"channels":{"telegram":{"accounts":{"main":{"bot_token":"secret"}}}}}
    ;

    const json = try buildChannelsJsonFromConfig(allocator, config_bytes, "discord");
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"discord\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"accounts\":[]") != null);
}

test "buildChannelsJsonFromConfig rejects unknown type" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.UnknownChannelType,
        buildChannelsJsonFromConfig(allocator, "{\"channels\":{}}", "nonexistent"),
    );
}
