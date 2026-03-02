const std = @import("std");

pub const CliError = error{
    CommandFailed,
};

pub const RunResult = struct {
    stdout: []const u8,
    success: bool,
};

/// Run a component binary with the given arguments and capture stdout.
/// Caller owns the returned stdout slice.
pub fn run(allocator: std.mem.Allocator, binary_path: []const u8, args: []const []const u8) !RunResult {
    // Build argv: binary + args
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(binary_path);
    for (args) |arg| try argv.append(arg);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
    }) catch return error.CommandFailed;
    defer allocator.free(result.stderr);

    return .{
        .stdout = result.stdout,
        .success = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        },
    };
}

/// Run --export-manifest on a component binary and return the raw JSON.
pub fn exportManifest(allocator: std.mem.Allocator, binary_path: []const u8) ![]const u8 {
    const result = try run(allocator, binary_path, &.{"--export-manifest"});
    if (!result.success) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

/// Run --list-models on a component binary and return the raw JSON array.
pub fn listModels(allocator: std.mem.Allocator, binary_path: []const u8, provider: []const u8, api_key: []const u8) ![]const u8 {
    const result = try run(allocator, binary_path, &.{ "--list-models", "--provider", provider, "--api-key", api_key });
    if (!result.success) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

/// Run --from-json on a component binary with the given JSON answers.
pub fn fromJson(allocator: std.mem.Allocator, binary_path: []const u8, json_answers: []const u8) ![]const u8 {
    const result = try run(allocator, binary_path, &.{ "--from-json", json_answers });
    if (!result.success) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}
