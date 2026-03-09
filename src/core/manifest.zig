const std = @import("std");

// ─── Schema types ────────────────────────────────────────────────────────────

pub const Manifest = struct {
    schema_version: u32,
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    icon: []const u8,
    repo: []const u8,
    platforms: std.json.ArrayHashMap(PlatformEntry),
    build_from_source: ?BuildFromSource = null,
    launch: LaunchSpec,
    health: HealthSpec,
    ports: []const PortSpec,
    wizard: WizardSpec,
    depends_on: []const []const u8,
    connects_to: []const ConnectionSpec,
};

pub const PlatformEntry = struct {
    asset: []const u8,
    binary: []const u8,
};

pub const BuildFromSource = struct {
    zig_version: []const u8,
    command: []const u8,
    output: []const u8,
};

pub const LaunchSpec = struct {
    command: []const u8,
    args: []const []const u8 = &.{},
    env: ?std.json.Value = null,
};

pub const HealthSpec = struct {
    endpoint: []const u8,
    port_from_config: []const u8,
    interval_ms: u32 = 15000,
};

pub const PortSpec = struct {
    name: []const u8,
    config_key: []const u8,
    default: u16,
    protocol: []const u8,
};

pub const WizardSpec = struct {
    steps: []const WizardStep,
};

pub const WizardStep = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    type: StepType,
    required: bool = true,
    options: []const StepOption = &.{},
    default_value: []const u8 = "",
    dynamic_source: ?DynamicSource = null,
    condition: ?StepCondition = null,
    advanced: bool = false,
    group: ?[]const u8 = null,
};

pub const StepType = enum {
    select,
    multi_select,
    secret,
    text,
    number,
    toggle,
    dynamic_select,
};

pub const DynamicSource = struct {
    command: []const u8,
    depends_on: []const []const u8 = &.{},
};

pub const StepOption = struct {
    value: []const u8,
    label: []const u8,
    description: []const u8 = "",
    recommended: bool = false,
};

pub const StepCondition = struct {
    step: []const u8,
    equals: ?[]const u8 = null,
    not_equals: ?[]const u8 = null,
    contains: ?[]const u8 = null,
    not_in: ?[]const u8 = null, // comma-separated list of values to exclude
};

pub const ConnectionSpec = struct {
    component: []const u8,
    role: []const u8 = "",
    description: []const u8 = "",
    auto_config: ?std.json.Value = null,
};

// ─── Parse functions ─────────────────────────────────────────────────────────

pub fn parseManifest(allocator: std.mem.Allocator, json_bytes: []const u8) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(
        Manifest,
        allocator,
        json_bytes,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
}

pub fn parseManifestFile(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Manifest) {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);
    return parseManifest(allocator, bytes);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "parse minimal manifest" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "name": "nullclaw",
        \\  "display_name": "NullClaw",
        \\  "description": "AI agent",
        \\  "icon": "agent",
        \\  "repo": "nullclaw/nullclaw",
        \\  "platforms": {
        \\    "aarch64-macos": { "asset": "nullclaw-macos-aarch64", "binary": "nullclaw" }
        \\  },
        \\  "launch": { "command": "gateway", "args": [] },
        \\  "health": { "endpoint": "/health", "port_from_config": "gateway.port", "interval_ms": 15000 },
        \\  "ports": [{ "name": "gateway", "config_key": "gateway.port", "default": 3000, "protocol": "http" }],
        \\  "wizard": { "steps": [] },
        \\  "depends_on": [],
        \\  "connects_to": []
        \\}
    ;

    const parsed = try parseManifest(std.testing.allocator, json);
    defer parsed.deinit();

    const m = parsed.value;
    try std.testing.expectEqualStrings("nullclaw", m.name);
    try std.testing.expectEqual(@as(u32, 1), m.schema_version);
    try std.testing.expectEqualStrings("gateway", m.launch.command);
    try std.testing.expectEqual(@as(u16, 3000), m.ports[0].default);
    try std.testing.expectEqual(@as(usize, 0), m.launch.args.len);
    try std.testing.expectEqualStrings("NullClaw", m.display_name);
    try std.testing.expectEqualStrings("/health", m.health.endpoint);
    try std.testing.expectEqual(@as(u32, 15000), m.health.interval_ms);

    // Verify platforms map
    const entry = m.platforms.map.get("aarch64-macos");
    try std.testing.expect(entry != null);
    try std.testing.expectEqualStrings("nullclaw-macos-aarch64", entry.?.asset);
    try std.testing.expectEqualStrings("nullclaw", entry.?.binary);
}

test "parse manifest with wizard steps and conditions" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "name": "testcomp",
        \\  "display_name": "Test Component",
        \\  "description": "A test component",
        \\  "icon": "test",
        \\  "repo": "test/testcomp",
        \\  "platforms": {},
        \\  "launch": { "command": "serve" },
        \\  "health": { "endpoint": "/health", "port_from_config": "port" },
        \\  "ports": [],
        \\  "wizard": {
        \\    "steps": [
        \\      {
        \\        "id": "provider",
        \\        "title": "Select provider",
        \\        "type": "select",
        \\        "options": [
        \\          { "value": "openai", "label": "OpenAI" },
        \\          { "value": "anthropic", "label": "Anthropic" }
        \\        ]
        \\      },
        \\      {
        \\        "id": "api_key",
        \\        "title": "Enter API key",
        \\        "description": "Your provider API key",
        \\        "type": "secret",
        \\        "condition": { "step": "provider", "not_equals": "local" }
        \\      }
        \\    ]
        \\  },
        \\  "depends_on": [],
        \\  "connects_to": []
        \\}
    ;

    const parsed = try parseManifest(std.testing.allocator, json);
    defer parsed.deinit();

    const m = parsed.value;
    try std.testing.expectEqual(@as(usize, 2), m.wizard.steps.len);

    const step0 = m.wizard.steps[0];
    try std.testing.expectEqualStrings("provider", step0.id);
    try std.testing.expectEqual(StepType.select, step0.type);
    try std.testing.expectEqual(@as(usize, 2), step0.options.len);
    try std.testing.expectEqualStrings("openai", step0.options[0].value);
    try std.testing.expect(step0.condition == null);

    const step1 = m.wizard.steps[1];
    try std.testing.expectEqualStrings("api_key", step1.id);
    try std.testing.expectEqual(StepType.secret, step1.type);
    try std.testing.expectEqualStrings("Your provider API key", step1.description);
    try std.testing.expect(step1.condition != null);
    try std.testing.expectEqualStrings("provider", step1.condition.?.step);
    try std.testing.expectEqualStrings("local", step1.condition.?.not_equals.?);
    try std.testing.expect(step1.condition.?.equals == null);
}

test "parse manifest with unknown fields succeeds" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "name": "testcomp",
        \\  "display_name": "Test",
        \\  "description": "desc",
        \\  "icon": "ic",
        \\  "repo": "r/r",
        \\  "platforms": {},
        \\  "launch": { "command": "run" },
        \\  "health": { "endpoint": "/h", "port_from_config": "p" },
        \\  "ports": [],
        \\  "wizard": { "steps": [] },
        \\  "depends_on": [],
        \\  "connects_to": [],
        \\  "unknown_field_1": "should be ignored",
        \\  "unknown_field_2": { "nested": true },
        \\  "unknown_field_3": [1, 2, 3]
        \\}
    ;

    const parsed = try parseManifest(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("testcomp", parsed.value.name);
    try std.testing.expectEqualStrings("run", parsed.value.launch.command);
}

test "parse manifest preserves advanced wizard metadata" {
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "name": "testcomp",
        \\  "display_name": "Test",
        \\  "description": "desc",
        \\  "icon": "ic",
        \\  "repo": "r/r",
        \\  "platforms": {},
        \\  "launch": { "command": "run" },
        \\  "health": { "endpoint": "/h", "port_from_config": "p" },
        \\  "ports": [],
        \\  "wizard": {
        \\    "steps": [
        \\      {
        \\        "id": "tracker_poll_interval_ms",
        \\        "title": "Tracker Poll Interval",
        \\        "type": "number",
        \\        "advanced": true,
        \\        "group": "tracker"
        \\      }
        \\    ]
        \\  },
        \\  "depends_on": [],
        \\  "connects_to": []
        \\}
    ;

    const parsed = try parseManifest(std.testing.allocator, json);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.wizard.steps.len);
    const step = parsed.value.wizard.steps[0];
    try std.testing.expect(step.advanced);
    try std.testing.expect(step.group != null);
    try std.testing.expectEqualStrings("tracker", step.group.?);
}
