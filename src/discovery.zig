const std = @import("std");
const manifest_mod = @import("core/manifest.zig");
const state_mod = @import("core/state.zig");
const test_helpers = @import("test_helpers.zig");

// ─── Types ───────────────────────────────────────────────────────────────────

pub const Connection = struct {
    component: []const u8, // e.g., "nullboiler"
    instance_name: []const u8, // e.g., "default"
    role: []const u8, // e.g., "worker"
};

// ─── Discovery ───────────────────────────────────────────────────────────────

/// Scan the state registry for instances that match the manifest's `connects_to`
/// specs. Returns a list of possible connections. Caller owns the returned slice
/// and must free it with the provided allocator.
pub fn findConnections(
    allocator: std.mem.Allocator,
    m: manifest_mod.Manifest,
    s: *state_mod.State,
) ![]Connection {
    var results = std.array_list.Managed(Connection).init(allocator);
    errdefer results.deinit();

    for (m.connects_to) |spec| {
        const names = try s.instanceNames(spec.component) orelse continue;
        defer allocator.free(names);

        for (names) |inst_name| {
            try results.append(.{
                .component = spec.component,
                .instance_name = inst_name,
                .role = spec.role,
            });
        }
    }

    return results.toOwnedSlice();
}

// ─── Template resolution ─────────────────────────────────────────────────────

/// Replace discovery placeholders in a connection template string:
///   - `{{target.instance_name}}` → actual instance name
///   - `{{target.port.gateway}}`  → actual port value (as decimal string)
///   - `{{target.host}}`          → "127.0.0.1"
///
/// Caller owns the returned slice.
pub fn resolveTemplate(
    allocator: std.mem.Allocator,
    template: []const u8,
    target_instance: []const u8,
    target_port: u16,
) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    // Format port once up front.
    var port_buf: [5]u8 = undefined;
    const port_len = std.fmt.formatIntBuf(&port_buf, target_port, 10, .lower, .{});
    const port_str = port_buf[0..port_len];

    var i: usize = 0;
    while (i < template.len) {
        // Look for opening `{{`
        if (i + 1 < template.len and template[i] == '{' and template[i + 1] == '{') {
            const start = i + 2;
            const close = findClosingBraces(template, start) orelse {
                // No closing `}}` — emit literal `{{`
                try buf.appendSlice("{{");
                i += 2;
                continue;
            };
            const placeholder = template[start..close];

            if (std.mem.eql(u8, placeholder, "target.instance_name")) {
                try buf.appendSlice(target_instance);
            } else if (std.mem.eql(u8, placeholder, "target.host")) {
                try buf.appendSlice("127.0.0.1");
            } else if (std.mem.startsWith(u8, placeholder, "target.port.")) {
                // Any target.port.<name> resolves to the provided port.
                try buf.appendSlice(port_str);
            } else {
                // Unknown placeholder — emit it verbatim.
                try buf.appendSlice("{{");
                try buf.appendSlice(placeholder);
                try buf.appendSlice("}}");
            }

            i = close + 2; // skip past `}}`
        } else {
            try buf.append(template[i]);
            i += 1;
        }
    }

    return buf.toOwnedSlice();
}

/// Find the position of the first `}}` starting from `start`.
/// Returns the index of the first `}` in the pair, or null.
fn findClosingBraces(template: []const u8, start: usize) ?usize {
    var j = start;
    while (j + 1 < template.len) : (j += 1) {
        if (template[j] == '}' and template[j + 1] == '}') {
            return j;
        }
    }
    return null;
}

// ─── Tests ───────────────────────────────────────────────────────────────────

fn testManifest(connects_to: []const manifest_mod.ConnectionSpec) manifest_mod.Manifest {
    return .{
        .schema_version = 1,
        .name = "nullclaw",
        .display_name = "NullClaw",
        .description = "AI agent",
        .icon = "agent",
        .repo = "nullclaw/nullclaw",
        .platforms = .{},
        .config = .{ .path = "config.json" },
        .launch = .{ .command = "gateway" },
        .health = .{ .endpoint = "/health", .port_from_config = "gateway.port" },
        .ports = &.{},
        .wizard = .{ .steps = &.{} },
        .ui_modules = &.{},
        .depends_on = &.{},
        .connects_to = connects_to,
    };
}

test "findConnections: empty state returns empty list" {
    const allocator = std.testing.allocator;

    const specs = [_]manifest_mod.ConnectionSpec{
        .{ .component = "nullboiler", .role = "worker" },
    };
    const m = testManifest(&specs);

    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const state_path = try fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    const connections = try findConnections(allocator, m, &s);
    defer allocator.free(connections);

    try std.testing.expectEqual(@as(usize, 0), connections.len);
}

test "findConnections: matching instance returns connection" {
    const allocator = std.testing.allocator;

    const specs = [_]manifest_mod.ConnectionSpec{
        .{ .component = "nullboiler", .role = "worker" },
    };
    const m = testManifest(&specs);

    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const state_path = try fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addInstance("nullboiler", "default", .{ .version = "1.0.0" });

    const connections = try findConnections(allocator, m, &s);
    defer allocator.free(connections);

    try std.testing.expectEqual(@as(usize, 1), connections.len);
    try std.testing.expectEqualStrings("nullboiler", connections[0].component);
    try std.testing.expectEqualStrings("default", connections[0].instance_name);
    try std.testing.expectEqualStrings("worker", connections[0].role);
}

test "findConnections: no matching component returns empty" {
    const allocator = std.testing.allocator;

    const specs = [_]manifest_mod.ConnectionSpec{
        .{ .component = "nullboiler", .role = "worker" },
    };
    const m = testManifest(&specs);

    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();
    const state_path = try fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    // Add an instance of a different component.
    try s.addInstance("nulltickets", "tracker", .{ .version = "0.1.0" });

    const connections = try findConnections(allocator, m, &s);
    defer allocator.free(connections);

    try std.testing.expectEqual(@as(usize, 0), connections.len);
}

test "resolveTemplate: replaces all placeholders" {
    const allocator = std.testing.allocator;

    const template = "http://{{target.host}}:{{target.port.gateway}}/api/{{target.instance_name}}";
    const result = try resolveTemplate(allocator, template, "my-boiler", 3000);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("http://127.0.0.1:3000/api/my-boiler", result);
}

test "resolveTemplate: no placeholders returns original string" {
    const allocator = std.testing.allocator;

    const template = "http://localhost:8080/api";
    const result = try resolveTemplate(allocator, template, "default", 3000);
    defer allocator.free(result);

    try std.testing.expectEqualStrings("http://localhost:8080/api", result);
}
