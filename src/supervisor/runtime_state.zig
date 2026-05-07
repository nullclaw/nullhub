const std = @import("std");
const std_compat = @import("compat");
const fs_compat = @import("../fs_compat.zig");
const paths_mod = @import("../core/paths.zig");
const test_helpers = @import("../test_helpers.zig");

pub const PersistedRuntimeView = struct {
    pid: u64,
    port: u16,
    health_endpoint: []const u8,
    binary_path: []const u8,
    working_dir: []const u8 = "",
    config_path: []const u8 = "",
    launch_command: []const u8,
    launch_args: []const []const u8,
    started_at: ?i64 = null,
    starting_since: ?i64 = null,
};

const PersistedRuntimeJson = struct {
    pid: u64 = 0,
    port: u16 = 0,
    health_endpoint: []const u8 = "",
    binary_path: []const u8 = "",
    working_dir: []const u8 = "",
    config_path: []const u8 = "",
    launch_command: []const u8 = "",
    launch_args: []const []const u8 = &.{},
    started_at: ?i64 = null,
    starting_since: ?i64 = null,
};

pub const PersistedRuntime = struct {
    pid: u64 = 0,
    port: u16 = 0,
    health_endpoint: []u8 = "",
    binary_path: []u8 = "",
    working_dir: []u8 = "",
    config_path: []u8 = "",
    launch_command: []u8 = "",
    launch_args: [][]u8 = &.{},
    started_at: ?i64 = null,
    starting_since: ?i64 = null,

    pub fn deinit(self: *PersistedRuntime, allocator: std.mem.Allocator) void {
        if (self.health_endpoint.len > 0) allocator.free(self.health_endpoint);
        if (self.binary_path.len > 0) allocator.free(self.binary_path);
        if (self.working_dir.len > 0) allocator.free(self.working_dir);
        if (self.config_path.len > 0) allocator.free(self.config_path);
        if (self.launch_command.len > 0) allocator.free(self.launch_command);
        if (self.launch_args.len > 0) {
            for (self.launch_args) |arg| allocator.free(arg);
            allocator.free(self.launch_args);
        }
        self.* = .{};
    }

    pub fn isValid(self: PersistedRuntime) bool {
        return self.pid != 0 and
            self.health_endpoint.len > 0 and
            self.binary_path.len > 0 and
            self.launch_command.len > 0 and
            self.launch_args.len > 0;
    }
};

pub fn write(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    runtime: PersistedRuntimeView,
) !void {
    const inst_dir = try paths.instanceDir(allocator, component, name);
    defer allocator.free(inst_dir);
    try fs_compat.makePath(inst_dir);

    const meta_path = try paths.instanceMeta(allocator, component, name);
    defer allocator.free(meta_path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{meta_path});
    defer allocator.free(tmp_path);

    const body = try std.json.Stringify.valueAlloc(allocator, runtime, .{});
    defer allocator.free(body);

    {
        const file = try std_compat.fs.createFileAbsolute(tmp_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(body);
    }

    try std_compat.fs.renameAbsolute(tmp_path, meta_path);
}

pub fn load(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) !?PersistedRuntime {
    const meta_path = try paths.instanceMeta(allocator, component, name);
    defer allocator.free(meta_path);

    const file = std_compat.fs.openFileAbsolute(meta_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const raw = try file.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(raw);

    var parsed = try std.json.parseFromSlice(PersistedRuntimeJson, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    var runtime = PersistedRuntime{
        .pid = parsed.value.pid,
        .port = parsed.value.port,
        .health_endpoint = try allocator.dupe(u8, parsed.value.health_endpoint),
        .binary_path = try allocator.dupe(u8, parsed.value.binary_path),
        .working_dir = try allocator.dupe(u8, parsed.value.working_dir),
        .config_path = try allocator.dupe(u8, parsed.value.config_path),
        .launch_command = try allocator.dupe(u8, parsed.value.launch_command),
        .launch_args = if (parsed.value.launch_args.len == 0)
            &.{}
        else
            try allocator.alloc([]u8, parsed.value.launch_args.len),
        .started_at = parsed.value.started_at,
        .starting_since = parsed.value.starting_since,
    };
    errdefer runtime.deinit(allocator);

    for (parsed.value.launch_args, 0..) |arg, idx| {
        runtime.launch_args[idx] = try allocator.dupe(u8, arg);
    }

    if (!runtime.isValid()) {
        runtime.deinit(allocator);
        return error.InvalidRuntimeState;
    }
    return runtime;
}

pub fn delete(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) void {
    const meta_path = paths.instanceMeta(allocator, component, name) catch return;
    defer allocator.free(meta_path);
    std_compat.fs.deleteFileAbsolute(meta_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => {},
    };
}

test "runtime state round-trips through instance.json" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();

    try write(allocator, fixture.paths, "nullclaw", "demo", .{
        .pid = 42,
        .port = 8080,
        .health_endpoint = "/health",
        .binary_path = "/tmp/nullclaw",
        .working_dir = "/tmp/demo",
        .config_path = "/tmp/demo/config.json",
        .launch_command = "gateway",
        .launch_args = &.{ "gateway", "--verbose" },
        .started_at = 1000,
        .starting_since = 1000,
    });

    var loaded = (try load(allocator, fixture.paths, "nullclaw", "demo")).?;
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), loaded.pid);
    try std.testing.expectEqual(@as(u16, 8080), loaded.port);
    try std.testing.expectEqualStrings("/health", loaded.health_endpoint);
    try std.testing.expectEqualStrings("/tmp/nullclaw", loaded.binary_path);
    try std.testing.expectEqualStrings("gateway", loaded.launch_command);
    try std.testing.expectEqual(@as(usize, 2), loaded.launch_args.len);
    try std.testing.expectEqualStrings("--verbose", loaded.launch_args[1]);

    delete(allocator, fixture.paths, "nullclaw", "demo");
    try std.testing.expect((try load(allocator, fixture.paths, "nullclaw", "demo")) == null);
}

test "load accepts persisted runtime json written by supervisor" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/nullhub-test-runtime-state-load";
    std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp_root) catch {};

    var paths = try paths_mod.Paths.init(allocator, tmp_root);
    defer paths.deinit(allocator);
    try paths.ensureDirs();

    const meta_path = try paths.instanceMeta(allocator, "nullclaw", "demo");
    defer allocator.free(meta_path);
    const inst_dir = try paths.instanceDir(allocator, "nullclaw", "demo");
    defer allocator.free(inst_dir);
    try fs_compat.makePath(inst_dir);

    const body =
        "{\"pid\":39275,\"port\":0,\"health_endpoint\":\"/health\",\"binary_path\":\"/Users/vds/.nullhub/bin/nullclaw\",\"working_dir\":\"/Users/vds/.nullhub/instances/nullclaw/demo\",\"config_path\":\"\",\"launch_command\":\"gateway\",\"launch_args\":[\"gateway\"],\"started_at\":1777963594379,\"starting_since\":1777963594379}";

    const file = try std_compat.fs.createFileAbsolute(meta_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(body);

    var loaded = (try load(allocator, paths, "nullclaw", "demo")).?;
    defer loaded.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 39275), loaded.pid);
    try std.testing.expectEqual(@as(u16, 0), loaded.port);
    try std.testing.expectEqualStrings("/health", loaded.health_endpoint);
    try std.testing.expectEqualStrings("/Users/vds/.nullhub/bin/nullclaw", loaded.binary_path);
    try std.testing.expectEqualStrings("gateway", loaded.launch_command);
    try std.testing.expectEqual(@as(usize, 1), loaded.launch_args.len);
    try std.testing.expectEqualStrings("gateway", loaded.launch_args[0]);
}
