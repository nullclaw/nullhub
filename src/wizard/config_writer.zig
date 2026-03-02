const std = @import("std");
const manifest_mod = @import("../core/manifest.zig");

// ─── JSON value tree ─────────────────────────────────────────────────────────

pub const JsonValue = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    object: std.StringArrayHashMap(JsonValue),
    array: std.array_list.Managed(JsonValue),
    null_val,
};

/// Recursively free all memory owned by a JsonValue tree.
pub fn deinitValue(allocator: std.mem.Allocator, value: *JsonValue) void {
    switch (value.*) {
        .object => |*map| {
            var it = map.iterator();
            while (it.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                deinitValue(allocator, entry.value_ptr);
            }
            map.deinit();
        },
        .array => |*list| {
            for (list.items) |*item| {
                deinitValue(allocator, item);
            }
            list.deinit();
        },
        .string => |s| {
            allocator.free(s);
        },
        .integer, .boolean, .null_val => {},
    }
}

// ─── Template resolution ─────────────────────────────────────────────────────

/// Resolve `{value}` and `{step_id.value}` placeholders in a writes_to template.
///
/// - `{value}` is replaced with the current step's answer.
/// - `{other_step.value}` is replaced with the answer of `other_step`.
///
/// Caller owns the returned slice.
pub fn resolveTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    current_step_id: []const u8,
    current_answer: []const u8,
    answers: *const std.StringHashMap([]const u8),
) ![]const u8 {
    _ = current_step_id; // reserved for future use

    var result = std.array_list.Managed(u8).init(allocator);
    errdefer result.deinit();

    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            const close = std.mem.indexOfScalarPos(u8, template, i + 1, '}') orelse {
                // No closing brace — treat as literal
                try result.append(template[i]);
                i += 1;
                continue;
            };
            const placeholder = template[i + 1 .. close];
            const replacement = resolveTemplatePlaceholder(placeholder, current_answer, answers);
            try result.appendSlice(replacement);
            i = close + 1;
        } else {
            try result.append(template[i]);
            i += 1;
        }
    }

    return result.toOwnedSlice();
}

fn resolveTemplatePlaceholder(
    placeholder: []const u8,
    current_answer: []const u8,
    answers: *const std.StringHashMap([]const u8),
) []const u8 {
    // {value} → current step's answer
    if (std.mem.eql(u8, placeholder, "value")) {
        return current_answer;
    }
    // {step_id.value} → answer of step_id
    if (std.mem.endsWith(u8, placeholder, ".value")) {
        const step_id = placeholder[0 .. placeholder.len - ".value".len];
        if (answers.get(step_id)) |ans| {
            return ans;
        }
    }
    // Unknown placeholder — return empty string
    return "";
}

// ─── Set nested value ────────────────────────────────────────────────────────

/// Set a value in a JsonValue tree at a dot-notation path.
/// Creates intermediate objects as needed. If an intermediate segment is
/// currently a non-object value, it is replaced with an object.
pub fn setNestedValue(
    allocator: std.mem.Allocator,
    root: *JsonValue,
    path: []const u8,
    value: JsonValue,
) !void {
    var segments_buf: [32][]const u8 = undefined;
    var seg_count: usize = 0;

    var splitter = std.mem.splitScalar(u8, path, '.');
    while (splitter.next()) |seg| {
        if (seg_count >= segments_buf.len) return error.PathTooDeep;
        segments_buf[seg_count] = seg;
        seg_count += 1;
    }
    const segments = segments_buf[0..seg_count];
    if (segments.len == 0) return;

    var current = root;

    // Navigate / create intermediate objects for all segments except the last.
    for (segments[0 .. segments.len - 1]) |seg| {
        current = try ensureObject(allocator, current, seg);
    }

    // Set the final value.
    const last_key = segments[segments.len - 1];
    // Ensure current is an object.
    if (current.* != .object) {
        // Replace with a new object, freeing the old value.
        deinitValue(allocator, current);
        current.* = .{ .object = std.StringArrayHashMap(JsonValue).init(allocator) };
    }

    // If the key already exists, free the old entry.
    if (current.object.fetchSwapRemove(last_key)) |old_entry| {
        var old_val = old_entry.value;
        deinitValue(allocator, &old_val);
        allocator.free(old_entry.key);
    }

    const owned_key = try allocator.dupe(u8, last_key);
    errdefer allocator.free(owned_key);

    const owned_value = try dupeValue(allocator, value);

    try current.object.put(owned_key, owned_value);
}

/// Navigate into (or create) a child object at the given key.
/// Returns a pointer to the child JsonValue.
fn ensureObject(
    allocator: std.mem.Allocator,
    current: *JsonValue,
    key: []const u8,
) !*JsonValue {
    // Make sure current node is an object.
    if (current.* != .object) {
        deinitValue(allocator, current);
        current.* = .{ .object = std.StringArrayHashMap(JsonValue).init(allocator) };
    }

    if (current.object.getPtr(key)) |child_ptr| {
        // If the child is not an object, replace it.
        if (child_ptr.* != .object) {
            deinitValue(allocator, child_ptr);
            child_ptr.* = .{ .object = std.StringArrayHashMap(JsonValue).init(allocator) };
        }
        return child_ptr;
    }

    // Create new child object.
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);

    try current.object.put(owned_key, .{ .object = std.StringArrayHashMap(JsonValue).init(allocator) });
    return current.object.getPtr(key).?;
}

/// Deep-copy a JsonValue, duplicating all heap data with the allocator.
fn dupeValue(allocator: std.mem.Allocator, value: JsonValue) !JsonValue {
    return switch (value) {
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .integer => |n| .{ .integer = n },
        .boolean => |b| .{ .boolean = b },
        .null_val => .null_val,
        .object => |map| blk: {
            var new_map = std.StringArrayHashMap(JsonValue).init(allocator);
            errdefer {
                var it = new_map.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    deinitValue(allocator, entry.value_ptr);
                }
                new_map.deinit();
            }
            var it = map.iterator();
            while (it.next()) |entry| {
                const k = try allocator.dupe(u8, entry.key_ptr.*);
                errdefer allocator.free(k);
                const v = try dupeValue(allocator, entry.value_ptr.*);
                try new_map.put(k, v);
            }
            break :blk .{ .object = new_map };
        },
        .array => |list| blk: {
            var new_list = std.array_list.Managed(JsonValue).init(allocator);
            errdefer {
                for (new_list.items) |*item| {
                    deinitValue(allocator, item);
                }
                new_list.deinit();
            }
            for (list.items) |item| {
                try new_list.append(try dupeValue(allocator, item));
            }
            break :blk .{ .array = new_list };
        },
    };
}

// ─── Serialization ───────────────────────────────────────────────────────────

/// Serialize a JsonValue tree to a pretty-printed JSON string.
/// Caller owns the returned slice.
pub fn serializeJson(allocator: std.mem.Allocator, value: JsonValue, indent: usize) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try writeJsonValue(&buf, value, indent);
    try buf.append('\n');
    return buf.toOwnedSlice();
}

fn writeJsonValue(buf: *std.array_list.Managed(u8), value: JsonValue, indent: usize) !void {
    switch (value) {
        .string => |s| {
            try buf.append('"');
            try writeJsonEscaped(buf, s);
            try buf.append('"');
        },
        .integer => |n| {
            var tmp: [32]u8 = undefined;
            const len = std.fmt.formatIntBuf(&tmp, n, 10, .lower, .{});
            try buf.appendSlice(tmp[0..len]);
        },
        .boolean => |b| {
            try buf.appendSlice(if (b) "true" else "false");
        },
        .null_val => {
            try buf.appendSlice("null");
        },
        .object => |map| {
            if (map.count() == 0) {
                try buf.appendSlice("{}");
                return;
            }
            try buf.appendSlice("{\n");
            var it = map.iterator();
            var i: usize = 0;
            while (it.next()) |entry| : (i += 1) {
                if (i > 0) {
                    try buf.appendSlice(",\n");
                }
                try writeIndent(buf, indent + 1);
                try buf.append('"');
                try writeJsonEscaped(buf, entry.key_ptr.*);
                try buf.appendSlice("\": ");
                try writeJsonValue(buf, entry.value_ptr.*, indent + 1);
            }
            try buf.append('\n');
            try writeIndent(buf, indent);
            try buf.append('}');
        },
        .array => |list| {
            if (list.items.len == 0) {
                try buf.appendSlice("[]");
                return;
            }
            try buf.appendSlice("[\n");
            for (list.items, 0..) |item, i| {
                if (i > 0) {
                    try buf.appendSlice(",\n");
                }
                try writeIndent(buf, indent + 1);
                try writeJsonValue(buf, item, indent + 1);
            }
            try buf.append('\n');
            try writeIndent(buf, indent);
            try buf.append(']');
        },
    }
}

fn writeIndent(buf: *std.array_list.Managed(u8), level: usize) !void {
    for (0..level) |_| {
        try buf.appendSlice("  ");
    }
}

fn writeJsonEscaped(buf: *std.array_list.Managed(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice("\\\""),
            '\\' => try buf.appendSlice("\\\\"),
            '\n' => try buf.appendSlice("\\n"),
            '\r' => try buf.appendSlice("\\r"),
            '\t' => try buf.appendSlice("\\t"),
            else => {
                if (c < 0x20) {
                    try buf.appendSlice("\\u00");
                    const hex = "0123456789abcdef";
                    try buf.append(hex[c >> 4]);
                    try buf.append(hex[c & 0x0f]);
                } else {
                    try buf.append(c);
                }
            },
        }
    }
}

// ─── Config generation ───────────────────────────────────────────────────────

/// Main entry point: take wizard steps and answers, produce a JSON config string.
/// Caller owns the returned slice.
pub fn generateConfig(
    allocator: std.mem.Allocator,
    steps: []const manifest_mod.WizardStep,
    answers: *const std.StringHashMap([]const u8),
) ![]const u8 {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(allocator) };
    defer deinitValue(allocator, &root);

    for (steps) |step| {
        const answer = answers.get(step.id) orelse continue;
        if (answer.len == 0) continue;

        // Skip invisible steps (condition not met).
        if (step.condition) |cond| {
            const cond_answer = answers.get(cond.step) orelse continue;
            var visible = true;
            if (cond.equals) |expected| {
                visible = std.mem.eql(u8, cond_answer, expected);
            }
            if (cond.not_equals) |unexpected| {
                visible = !std.mem.eql(u8, cond_answer, unexpected);
            }
            if (cond.contains) |needle| {
                visible = std.mem.indexOf(u8, cond_answer, needle) != null;
            }
            if (!visible) continue;
        }

        // Resolve template in writes_to
        const resolved_path = try resolveTemplate(
            allocator,
            step.writes_to,
            step.id,
            answer,
            answers,
        );
        defer allocator.free(resolved_path);

        // Convert answer to appropriate JsonValue type.
        const value: JsonValue = switch (step.@"type") {
            .number => if (std.fmt.parseInt(i64, answer, 10)) |n|
                .{ .integer = n }
            else |_|
                .{ .string = answer },
            .toggle => .{ .boolean = std.mem.eql(u8, answer, "true") },
            else => .{ .string = answer },
        };

        try setNestedValue(allocator, &root, resolved_path, value);
    }

    return serializeJson(allocator, root, 0);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "resolveTemplate: plain path without placeholders" {
    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();

    const result = try resolveTemplate(std.testing.allocator, "gateway.port", "port", "3000", &answers);
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("gateway.port", result);
}

test "resolveTemplate: {value} replaced with current answer" {
    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();

    const result = try resolveTemplate(
        std.testing.allocator,
        "models.providers.{value}",
        "provider",
        "anthropic",
        &answers,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("models.providers.anthropic", result);
}

test "resolveTemplate: {step.value} cross-step reference" {
    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "anthropic");

    const result = try resolveTemplate(
        std.testing.allocator,
        "models.providers.{provider.value}.api_key",
        "api_key",
        "sk-123",
        &answers,
    );
    defer std.testing.allocator.free(result);

    try std.testing.expectEqualStrings("models.providers.anthropic.api_key", result);
}

test "setNestedValue: simple one-level path" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    try setNestedValue(std.testing.allocator, &root, "port", .{ .integer = 3000 });

    const port = root.object.get("port") orelse return error.MissingKey;
    try std.testing.expectEqual(@as(i64, 3000), port.integer);
}

test "setNestedValue: two-level path creates intermediate object" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    try setNestedValue(std.testing.allocator, &root, "gateway.port", .{ .integer = 3000 });

    const gateway = root.object.get("gateway") orelse return error.MissingKey;
    try std.testing.expect(gateway == .object);
    const port = gateway.object.get("port") orelse return error.MissingKey;
    try std.testing.expectEqual(@as(i64, 3000), port.integer);
}

test "setNestedValue: deep nesting" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    try setNestedValue(std.testing.allocator, &root, "channels.telegram.accounts.default.bot_token", .{ .string = "tok123" });

    const channels = root.object.get("channels") orelse return error.MissingKey;
    const telegram = channels.object.get("telegram") orelse return error.MissingKey;
    const accounts = telegram.object.get("accounts") orelse return error.MissingKey;
    const default_acct = accounts.object.get("default") orelse return error.MissingKey;
    const bot_token = default_acct.object.get("bot_token") orelse return error.MissingKey;
    try std.testing.expectEqualStrings("tok123", bot_token.string);
}

test "setNestedValue: string replaced by object when deeper path is set" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    // First, set "models.providers.anthropic" as a string
    try setNestedValue(std.testing.allocator, &root, "models.providers.anthropic", .{ .string = "anthropic" });

    // Then set a deeper path — this should convert the string to an object
    try setNestedValue(std.testing.allocator, &root, "models.providers.anthropic.api_key", .{ .string = "sk-123" });

    const models = root.object.get("models") orelse return error.MissingKey;
    const providers = models.object.get("providers") orelse return error.MissingKey;
    const anthropic = providers.object.get("anthropic") orelse return error.MissingKey;
    try std.testing.expect(anthropic == .object);
    const api_key = anthropic.object.get("api_key") orelse return error.MissingKey;
    try std.testing.expectEqualStrings("sk-123", api_key.string);
}

test "setNestedValue: overwrite existing value" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    try setNestedValue(std.testing.allocator, &root, "gateway.port", .{ .integer = 3000 });
    try setNestedValue(std.testing.allocator, &root, "gateway.port", .{ .integer = 8080 });

    const gateway = root.object.get("gateway") orelse return error.MissingKey;
    const port = gateway.object.get("port") orelse return error.MissingKey;
    try std.testing.expectEqual(@as(i64, 8080), port.integer);
}

test "serializeJson: simple object" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    try setNestedValue(std.testing.allocator, &root, "name", .{ .string = "test" });
    try setNestedValue(std.testing.allocator, &root, "port", .{ .integer = 3000 });

    const json = try serializeJson(std.testing.allocator, root, 0);
    defer std.testing.allocator.free(json);

    const expected =
        \\{
        \\  "name": "test",
        \\  "port": 3000
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, json);
}

test "serializeJson: nested object" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    try setNestedValue(std.testing.allocator, &root, "gateway.port", .{ .integer = 3000 });

    const json = try serializeJson(std.testing.allocator, root, 0);
    defer std.testing.allocator.free(json);

    const expected =
        \\{
        \\  "gateway": {
        \\    "port": 3000
        \\  }
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, json);
}

test "serializeJson: boolean and null" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    try setNestedValue(std.testing.allocator, &root, "auto_start", .{ .boolean = true });
    try setNestedValue(std.testing.allocator, &root, "debug", .{ .boolean = false });

    const json = try serializeJson(std.testing.allocator, root, 0);
    defer std.testing.allocator.free(json);

    const expected =
        \\{
        \\  "auto_start": true,
        \\  "debug": false
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, json);
}

test "serializeJson: string escaping" {
    var root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    defer deinitValue(std.testing.allocator, &root);

    try setNestedValue(std.testing.allocator, &root, "msg", .{ .string = "hello \"world\"\nline2" });

    const json = try serializeJson(std.testing.allocator, root, 0);
    defer std.testing.allocator.free(json);

    const expected =
        \\{
        \\  "msg": "hello \"world\"\nline2"
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, json);
}

test "serializeJson: empty object" {
    const root = JsonValue{ .object = std.StringArrayHashMap(JsonValue).init(std.testing.allocator) };
    // no deinit needed — nothing to free in an empty map, but let's be safe
    var root_copy = root;
    defer deinitValue(std.testing.allocator, &root_copy);

    const json = try serializeJson(std.testing.allocator, root, 0);
    defer std.testing.allocator.free(json);

    try std.testing.expectEqualStrings("{}\n", json);
}

test "generateConfig: simple port" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "port",
            .title = "Gateway port",
            .@"type" = .number,
            .required = true,
            .writes_to = "gateway.port",
        },
    };

    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("port", "3000");

    const json = try generateConfig(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(json);

    const expected =
        \\{
        \\  "gateway": {
        \\    "port": 3000
        \\  }
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, json);
}

test "generateConfig: toggle writes boolean" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "auto_start",
            .title = "Auto-start?",
            .@"type" = .toggle,
            .required = false,
            .writes_to = "auto_start",
        },
    };

    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("auto_start", "true");

    const json = try generateConfig(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(json);

    const expected =
        \\{
        \\  "auto_start": true
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, json);
}

test "generateConfig: template with cross-step reference" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "provider",
            .title = "Select provider",
            .@"type" = .select,
            .required = true,
            .writes_to = "models.providers.{value}",
            .options = &.{
                .{ .value = "anthropic", .label = "Anthropic" },
                .{ .value = "openai", .label = "OpenAI" },
            },
        },
        .{
            .id = "api_key",
            .title = "API Key",
            .@"type" = .secret,
            .required = true,
            .writes_to = "models.providers.{provider.value}.api_key",
        },
    };

    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "anthropic");
    try answers.put("api_key", "sk-123");

    const json = try generateConfig(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(json);

    const expected =
        \\{
        \\  "models": {
        \\    "providers": {
        \\      "anthropic": {
        \\        "api_key": "sk-123"
        \\      }
        \\    }
        \\  }
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, json);
}

test "generateConfig: multiple steps build config tree" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "provider",
            .title = "Provider",
            .@"type" = .select,
            .required = true,
            .writes_to = "provider",
            .options = &.{
                .{ .value = "anthropic", .label = "Anthropic" },
            },
        },
        .{
            .id = "port",
            .title = "Port",
            .@"type" = .number,
            .required = true,
            .writes_to = "gateway.port",
        },
        .{
            .id = "debug",
            .title = "Debug mode",
            .@"type" = .toggle,
            .required = false,
            .writes_to = "debug",
        },
    };

    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "anthropic");
    try answers.put("port", "8080");
    try answers.put("debug", "false");

    const json = try generateConfig(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(json);

    // Verify individual values by parsing the tree directly, since key order in
    // StringArrayHashMap follows insertion order which matches our step order.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\": \"anthropic\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"port\": 8080") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"debug\": false") != null);
}

test "generateConfig: skips steps with no answer" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "port",
            .title = "Port",
            .@"type" = .number,
            .required = false,
            .writes_to = "gateway.port",
        },
        .{
            .id = "name",
            .title = "Name",
            .@"type" = .text,
            .required = false,
            .writes_to = "name",
        },
    };

    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();
    // Only answer port, skip name
    try answers.put("port", "3000");

    const json = try generateConfig(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"port\": 3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\"") == null);
}

test "generateConfig: skips invisible conditional steps" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "provider",
            .title = "Provider",
            .@"type" = .select,
            .required = true,
            .writes_to = "provider",
            .options = &.{
                .{ .value = "local", .label = "Local" },
                .{ .value = "cloud", .label = "Cloud" },
            },
        },
        .{
            .id = "api_key",
            .title = "API Key",
            .@"type" = .secret,
            .required = true,
            .writes_to = "api_key",
            .condition = .{ .step = "provider", .equals = "cloud" },
        },
    };

    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("provider", "local");
    try answers.put("api_key", "should-be-skipped");

    const json = try generateConfig(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(json);

    // api_key should be absent because condition requires provider == "cloud"
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\": \"local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "api_key") == null);
}

test "generateConfig: deep nesting with telegram bot token" {
    const steps = [_]manifest_mod.WizardStep{
        .{
            .id = "bot_token",
            .title = "Bot token",
            .@"type" = .secret,
            .required = true,
            .writes_to = "channels.telegram.accounts.default.bot_token",
        },
    };

    var answers = std.StringHashMap([]const u8).init(std.testing.allocator);
    defer answers.deinit();
    try answers.put("bot_token", "tok");

    const json = try generateConfig(std.testing.allocator, &steps, &answers);
    defer std.testing.allocator.free(json);

    const expected =
        \\{
        \\  "channels": {
        \\    "telegram": {
        \\      "accounts": {
        \\        "default": {
        \\          "bot_token": "tok"
        \\        }
        \\      }
        \\    }
        \\  }
        \\}
        \\
    ;
    try std.testing.expectEqualStrings(expected, json);
}
