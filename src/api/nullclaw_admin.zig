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
