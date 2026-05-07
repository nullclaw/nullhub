const std = @import("std");
const std_compat = @import("compat");

pub const CliError = error{
    CommandFailed,
};

pub const RunResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    success: bool,
};

/// Run a component binary with the given arguments and capture stdout.
/// Caller owns the returned stdout and stderr slices.
pub fn run(allocator: std.mem.Allocator, binary_path: []const u8, args: []const []const u8, cwd: ?[]const u8) !RunResult {
    return runWithComponentHome(allocator, "", binary_path, args, cwd, null);
}

pub fn homeEnvVarForComponent(component_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, component_name, "nullclaw")) return "NULLCLAW_HOME";
    if (std.mem.eql(u8, component_name, "nullboiler")) return "NULLBOILER_HOME";
    if (std.mem.eql(u8, component_name, "nulltickets")) return "NULLTICKETS_HOME";
    if (std.mem.eql(u8, component_name, "nullwatch")) return "NULLWATCH_HOME";
    return null;
}

/// Run a component binary with an optional component-specific HOME override.
/// Caller owns the returned stdout and stderr slices.
pub fn runWithComponentHome(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8,
    component_home: ?[]const u8,
) !RunResult {
    return runWithComponentHomeLimited(allocator, component_name, binary_path, args, cwd, component_home, 50 * 1024);
}

pub fn runWithComponentHomeLimited(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    args: []const []const u8,
    cwd: ?[]const u8,
    component_home: ?[]const u8,
    max_output_bytes: usize,
) !RunResult {
    // Build argv: binary + args
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(binary_path);
    for (args) |arg| try argv.append(arg);

    var env_map_opt: ?std_compat.process.EnvMap = null;
    defer {
        if (env_map_opt) |*env_map| env_map.deinit();
    }
    if (component_home) |home| {
        const env_name = homeEnvVarForComponent(component_name) orelse "";
        if (env_name.len > 0) {
            var env_map = try std_compat.process.getEnvMap(allocator);
            try env_map.put(env_name, home);
            env_map_opt = env_map;
        }
    }

    const result = std_compat.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .cwd = cwd,
        .env_map = if (env_map_opt) |*env_map| env_map else null,
        .max_output_bytes = max_output_bytes,
    }) catch return error.CommandFailed;

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .success = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        },
    };
}

/// Run --export-manifest on a component binary and return the raw JSON.
pub fn exportManifest(allocator: std.mem.Allocator, binary_path: []const u8) ![]const u8 {
    const result = try run(allocator, binary_path, &.{"--export-manifest"}, null);
    defer allocator.free(result.stderr);
    if (!result.success) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

/// Run --list-models on a component binary and return the raw JSON array.
pub fn listModels(allocator: std.mem.Allocator, binary_path: []const u8, provider: []const u8, api_key: []const u8) ![]const u8 {
    const result = try run(allocator, binary_path, &.{ "--list-models", "--provider", provider, "--api-key", api_key }, null);
    defer allocator.free(result.stderr);
    if (!result.success) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

pub const FromJsonResult = struct {
    stdout: []const u8,
    stderr: []const u8,
    success: bool,
};

/// Run --from-json on a component binary with the given JSON answers.
/// The JSON should include a "home" field for instance isolation (injected by orchestrator).
pub fn fromJson(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    json_answers: []const u8,
    cwd: ?[]const u8,
    component_home: ?[]const u8,
) !FromJsonResult {
    const result = try runWithComponentHome(
        allocator,
        component_name,
        binary_path,
        &.{ "--from-json", json_answers },
        cwd,
        component_home,
    );
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .success = result.success,
    };
}

test "home env var includes managed components" {
    try std.testing.expectEqualStrings("NULLCLAW_HOME", homeEnvVarForComponent("nullclaw").?);
    try std.testing.expectEqualStrings("NULLBOILER_HOME", homeEnvVarForComponent("nullboiler").?);
    try std.testing.expectEqualStrings("NULLTICKETS_HOME", homeEnvVarForComponent("nulltickets").?);
    try std.testing.expectEqualStrings("NULLWATCH_HOME", homeEnvVarForComponent("nullwatch").?);
    try std.testing.expect(homeEnvVarForComponent("unknown") == null);
}
