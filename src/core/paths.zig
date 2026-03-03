const std = @import("std");
const builtin = @import("builtin");

/// Directory resolution for all paths under `~/.nullhub/`.
///
/// Layout:
/// ```
/// ~/.nullhub/
/// ├── config.json
/// ├── state.json
/// ├── manifests/{component}@{version}.json
/// ├── bin/{component}-{version}
/// ├── instances/{component}/{name}/
/// │   ├── instance.json
/// │   ├── config.json
/// │   ├── data/
/// │   └── logs/
/// ├── ui/{module}@{version}/
/// └── cache/downloads/
/// ```
pub const Paths = struct {
    root: []const u8,

    /// Initialize a Paths struct. If `custom_root` is null, resolves from
    /// the HOME environment variable (producing `$HOME/.nullhub`).
    /// The returned root string is owned by the allocator.
    pub fn init(allocator: std.mem.Allocator, custom_root: ?[]const u8) !Paths {
        if (custom_root) |cr| {
            return .{ .root = try allocator.dupe(u8, cr) };
        }
        const home = try getHomeDirOwned(allocator);
        defer allocator.free(home);
        const root = try std.fs.path.join(allocator, &.{ home, ".nullhub" });
        return .{ .root = root };
    }

    /// Free the root string.
    pub fn deinit(self: *Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
        self.* = undefined;
    }

    // ── Singleton paths ──────────────────────────────────────────────

    /// `{root}/config.json`
    pub fn config(self: Paths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "config.json" });
    }

    /// `{root}/state.json`
    pub fn state(self: Paths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "state.json" });
    }

    // ── Component paths ──────────────────────────────────────────────

    /// `{root}/manifests/{component}@{version}.json`
    pub fn manifest(self: Paths, allocator: std.mem.Allocator, component: []const u8, version: []const u8) ![]const u8 {
        const filename = try std.fmt.allocPrint(allocator, "{s}@{s}.json", .{ component, version });
        defer allocator.free(filename);
        return std.fs.path.join(allocator, &.{ self.root, "manifests", filename });
    }

    /// `{root}/bin/{component}-{version}`
    pub fn binary(self: Paths, allocator: std.mem.Allocator, component: []const u8, version: []const u8) ![]const u8 {
        const filename = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ component, version });
        defer allocator.free(filename);
        return std.fs.path.join(allocator, &.{ self.root, "bin", filename });
    }

    // ── Instance paths ───────────────────────────────────────────────

    /// `{root}/instances/{component}/{name}`
    pub fn instanceDir(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name });
    }

    /// `{root}/instances/{component}/{name}/config.json`
    pub fn instanceConfig(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name, "config.json" });
    }

    /// `{root}/instances/{component}/{name}/data`
    pub fn instanceData(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name, "data" });
    }

    /// `{root}/instances/{component}/{name}/logs`
    pub fn instanceLogs(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name, "logs" });
    }

    /// `{root}/instances/{component}/{name}/instance.json`
    pub fn instanceMeta(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name, "instance.json" });
    }

    // ── UI module paths ──────────────────────────────────────────────

    /// `{root}/ui/{module_name}@{version}`
    pub fn uiModule(self: Paths, allocator: std.mem.Allocator, module_name: []const u8, version: []const u8) ![]const u8 {
        const dirname = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ module_name, version });
        defer allocator.free(dirname);
        return std.fs.path.join(allocator, &.{ self.root, "ui", dirname });
    }

    // ── Cache paths ──────────────────────────────────────────────────

    /// `{root}/cache/downloads`
    pub fn cacheDownloads(self: Paths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "cache", "downloads" });
    }

    // ── Directory creation ───────────────────────────────────────────

    /// Create all required subdirectories under root.
    pub fn ensureDirs(self: Paths) !void {
        const dirs = [_][]const u8{
            "manifests",
            "bin",
            "instances",
            "ui",
            "cache/downloads",
        };
        for (dirs) |sub| {
            // Use makePath on an absolute directory via cwd handle.
            // std.fs.path.join would need an allocator; instead we open root
            // and create the sub-path relative to it.
            try makeAbsSubpath(self.root, sub);
        }
    }
};

fn getHomeDirOwned(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch |err| switch (err) {
        error.EnvironmentVariableNotFound => {
            if (builtin.os.tag == .windows) {
                return std.process.getEnvVarOwned(allocator, "USERPROFILE") catch error.HomeNotSet;
            }
            return error.HomeNotSet;
        },
        else => return err,
    };
}

/// Helper: create `{base}/{sub}` as an absolute directory tree.
fn makeAbsSubpath(base: []const u8, sub: []const u8) !void {
    // Open the root directory (create it first if needed).
    var root_dir = std.fs.openDirAbsolute(base, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            // Root doesn't exist — create it then retry.
            try std.fs.makeDirAbsolute(base);
            return makeAbsSubpath(base, sub);
        },
        else => return err,
    };
    defer root_dir.close();
    root_dir.makePath(sub) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "paths resolve under custom root" {
    const allocator = std.testing.allocator;
    var p = try Paths.init(allocator, "/tmp/test-nullhub");
    defer p.deinit(allocator);

    const cfg = try p.config(allocator);
    defer allocator.free(cfg);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/config.json", cfg);

    const st = try p.state(allocator);
    defer allocator.free(st);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/state.json", st);

    const mf = try p.manifest(allocator, "nullclaw", "2026.3.1");
    defer allocator.free(mf);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/manifests/nullclaw@2026.3.1.json", mf);

    const bin = try p.binary(allocator, "nullclaw", "2026.3.1");
    defer allocator.free(bin);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/bin/nullclaw-2026.3.1", bin);

    const inst_dir = try p.instanceDir(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst_dir);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/instances/nullclaw/my-agent", inst_dir);

    const inst = try p.instanceConfig(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/instances/nullclaw/my-agent/config.json", inst);

    const data = try p.instanceData(allocator, "nullclaw", "my-agent");
    defer allocator.free(data);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/instances/nullclaw/my-agent/data", data);

    const logs = try p.instanceLogs(allocator, "nullclaw", "my-agent");
    defer allocator.free(logs);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/instances/nullclaw/my-agent/logs", logs);

    const meta = try p.instanceMeta(allocator, "nullclaw", "my-agent");
    defer allocator.free(meta);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/instances/nullclaw/my-agent/instance.json", meta);

    const ui = try p.uiModule(allocator, "nullclaw-chat-ui", "1.2.0");
    defer allocator.free(ui);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/ui/nullclaw-chat-ui@1.2.0", ui);

    const dl = try p.cacheDownloads(allocator);
    defer allocator.free(dl);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/cache/downloads", dl);
}

test "ensureDirs creates all subdirectories" {
    const allocator = std.testing.allocator;

    // Use a unique temp directory to avoid interference.
    const tmp_root = "/tmp/test-nullhub-ensure-dirs";

    // Clean up from any previous run.
    std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    try p.ensureDirs();

    // Verify every expected subdirectory exists.
    const expected = [_][]const u8{
        "/tmp/test-nullhub-ensure-dirs/manifests",
        "/tmp/test-nullhub-ensure-dirs/bin",
        "/tmp/test-nullhub-ensure-dirs/instances",
        "/tmp/test-nullhub-ensure-dirs/ui",
        "/tmp/test-nullhub-ensure-dirs/cache/downloads",
    };
    for (expected) |dir| {
        var d = try std.fs.openDirAbsolute(dir, .{});
        d.close();
    }

    // Clean up.
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
}

test "init without custom root reads HOME" {
    const allocator = std.testing.allocator;

    const home = getHomeDirOwned(allocator) catch return; // skip if no HOME/USERPROFILE
    defer allocator.free(home);
    const expected_root = try std.fs.path.join(allocator, &.{ home, ".nullhub" });
    defer allocator.free(expected_root);

    var p = try Paths.init(allocator, null);
    defer p.deinit(allocator);

    try std.testing.expectEqualStrings(expected_root, p.root);
}
