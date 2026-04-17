const std = @import("std");
const std_compat = @import("compat");
const component_cli = @import("../core/component_cli.zig");
const paths_mod = @import("../core/paths.zig");
const state_mod = @import("../core/state.zig");
const helpers = @import("helpers.zig");

pub const ApiResponse = helpers.ApiResponse;

pub const JsonOptions = struct {
    null_is_not_found: bool = false,
    not_found_error_codes: []const []const u8 = &.{},
};

pub const Captured = union(enum) {
    response: ApiResponse,
    result: component_cli.RunResult,
};

pub const JsonCapture = union(enum) {
    response: ApiResponse,
    body: []const u8,
};

pub fn supports(component: []const u8) bool {
    return std.mem.eql(u8, component, "nullclaw");
}

pub fn capture(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    args: []const []const u8,
) Captured {
    const entry = s.getInstance(component, name) orelse return .{ .response = helpers.notFound() };

    const bin_path = paths.binary(allocator, component, entry.version) catch return .{ .response = helpers.serverError() };
    defer allocator.free(bin_path);
    std_compat.fs.accessAbsolute(bin_path, .{}) catch {
        return .{ .response = jsonError(
            allocator,
            "component_binary_missing",
            "Component binary is missing for this instance version",
            null,
            null,
        ) };
    };

    const inst_dir = paths.instanceDir(allocator, component, name) catch return .{ .response = helpers.serverError() };
    defer allocator.free(inst_dir);

    const result = component_cli.runWithComponentHome(
        allocator,
        component,
        bin_path,
        args,
        null,
        inst_dir,
    ) catch {
        return .{ .response = jsonError(
            allocator,
            "cli_exec_failed",
            "Failed to execute component CLI",
            null,
            null,
        ) };
    };

    return .{ .result = result };
}

pub fn captureJson(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    args: []const []const u8,
    options: JsonOptions,
) JsonCapture {
    const captured = capture(allocator, s, paths, component, name, args);
    const result = switch (captured) {
        .response => |resp| return .{ .response = resp },
        .result => |value| value,
    };
    defer allocator.free(result.stderr);

    if (result.success and isValidJsonPayload(allocator, result.stdout)) {
        const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (options.null_is_not_found and std.mem.eql(u8, trimmed, "null")) {
            allocator.free(result.stdout);
            return .{ .response = helpers.notFound() };
        }
        return .{ .body = result.stdout };
    }

    if (!result.success and isValidJsonPayload(allocator, result.stdout)) {
        for (options.not_found_error_codes) |code| {
            if (jsonErrorMatches(result.stdout, code)) {
                return .{ .response = .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = result.stdout,
                } };
            }
        }
        return .{ .response = .{
            .status = "400 Bad Request",
            .content_type = "application/json",
            .body = result.stdout,
        } };
    }

    defer allocator.free(result.stdout);

    const stderr_line = firstMeaningfulLine(result.stderr);
    const stdout_line = firstMeaningfulLine(result.stdout);
    const message = if (stderr_line.len > 0)
        stderr_line
    else if (stdout_line.len > 0)
        stdout_line
    else if (result.success)
        "CLI returned a non-JSON response"
    else
        "CLI command failed";

    return .{ .response = jsonError(
        allocator,
        if (result.success) "invalid_cli_response" else "cli_command_failed",
        message,
        result.stderr,
        result.stdout,
    ) };
}

pub fn runJson(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    args: []const []const u8,
) ApiResponse {
    return runJsonAdvanced(allocator, s, paths, component, name, args, .{});
}

pub fn runJsonAdvanced(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    args: []const []const u8,
    options: JsonOptions,
) ApiResponse {
    const captured = captureJson(allocator, s, paths, component, name, args, options);
    return switch (captured) {
        .response => |resp| resp,
        .body => |body| helpers.jsonOk(body),
    };
}

pub fn tryRunJsonSuccess(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    args: []const []const u8,
) ?[]const u8 {
    const captured = capture(allocator, s, paths, component, name, args);
    const result = switch (captured) {
        .response => |resp| {
            if (std.mem.eql(u8, resp.status, "502 Bad Gateway")) allocator.free(resp.body);
            return null;
        },
        .result => |value| value,
    };
    defer allocator.free(result.stderr);

    if (!result.success or !isValidJsonPayload(allocator, result.stdout)) {
        allocator.free(result.stdout);
        return null;
    }

    return result.stdout;
}

pub fn isValidJsonPayload(allocator: std.mem.Allocator, bytes: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return false;
    parsed.deinit();
    return true;
}

pub fn buildJsonErrorBody(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
    stderr: ?[]const u8,
    stdout: ?[]const u8,
) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"error\":\"");
    try helpers.appendEscaped(&buf, code);
    try buf.appendSlice("\",\"message\":\"");
    try helpers.appendEscaped(&buf, message);
    try buf.append('"');

    if (stderr) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            try buf.appendSlice(",\"stderr\":\"");
            try helpers.appendEscaped(&buf, trimmed);
            try buf.append('"');
        }
    }

    if (stdout) |value| {
        const trimmed = std.mem.trim(u8, value, " \t\r\n");
        if (trimmed.len > 0) {
            try buf.appendSlice(",\"stdout\":\"");
            try helpers.appendEscaped(&buf, trimmed);
            try buf.append('"');
        }
    }

    try buf.append('}');
    return try buf.toOwnedSlice();
}

pub fn jsonError(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
    stderr: ?[]const u8,
    stdout: ?[]const u8,
) ApiResponse {
    const body = buildJsonErrorBody(allocator, code, message, stderr, stdout) catch return helpers.serverError();
    return .{
        .status = "502 Bad Gateway",
        .content_type = "application/json",
        .body = body,
    };
}

pub fn firstMeaningfulLine(text: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return "";
    if (std.mem.indexOfScalar(u8, trimmed, '\n')) |idx| {
        return std.mem.trim(u8, trimmed[0..idx], " \t\r");
    }
    return trimmed;
}

fn jsonErrorMatches(payload: []const u8, expected_code: []const u8) bool {
    const parsed = std.json.parseFromSlice(struct {
        @"error": ?[]const u8 = null,
    }, std.heap.page_allocator, payload, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();
    return if (parsed.value.@"error") |value| std.mem.eql(u8, value, expected_code) else false;
}

test "isValidJsonPayload rejects malformed output" {
    const allocator = std.testing.allocator;

    try std.testing.expect(!isValidJsonPayload(allocator, "\n\"broken\":true}"));
    try std.testing.expect(isValidJsonPayload(allocator, "{\"ok\":true}"));
}

test "jsonError returns gateway status" {
    const allocator = std.testing.allocator;
    const resp = jsonError(allocator, "cli_command_failed", "boom", "stderr", "stdout");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("502 Bad Gateway", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"cli_command_failed\"") != null);
}

test "buildJsonErrorBody omits empty stderr and stdout" {
    const allocator = std.testing.allocator;
    const body = try buildJsonErrorBody(allocator, "bad", "broken", "   ", "");
    defer allocator.free(body);

    try std.testing.expectEqualStrings("{\"error\":\"bad\",\"message\":\"broken\"}", body);
}
