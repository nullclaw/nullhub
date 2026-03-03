const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

/// Options for spawning a child process.
pub const EnvEntry = struct { []const u8, []const u8 };

pub const SpawnOptions = struct {
    binary: []const u8,
    argv: []const []const u8 = &.{}, // additional args after binary
    cwd: ?[]const u8 = null,
    stdout_path: ?[]const u8 = null, // redirect stdout+stderr to this file
    stderr_path: ?[]const u8 = null, // if stdout_path is null, used as fallback log path
    env: ?*const std.process.EnvMap = null,
    /// Extra env vars merged into child environment before spawn.
    extra_env: []const EnvEntry = &.{},
};

/// Result of a successful process spawn.
pub const SpawnResult = struct {
    pid: std.process.Child.Id,
    child: std.process.Child,
};

const LogPumpContext = struct {
    allocator: std.mem.Allocator,
    stdout_pipe: std.fs.File,
    stderr_pipe: std.fs.File,
    log_path: []u8,
};

/// Spawn a child process with the given options.
///
/// Builds argv as `[binary] ++ options.argv`, sets cwd if provided,
/// and spawns the child process. Returns the PID and child handle.
///
/// When `stdout_path` (or `stderr_path`) is set, stdout and stderr are captured
/// and asynchronously appended to that log file.
pub fn spawn(allocator: std.mem.Allocator, options: SpawnOptions) !SpawnResult {
    var argv_list = std.array_list.Managed([]const u8).init(allocator);
    defer argv_list.deinit();

    try argv_list.append(options.binary);
    for (options.argv) |arg| {
        try argv_list.append(arg);
    }

    var child = std.process.Child.init(argv_list.items, allocator);

    if (options.cwd) |cwd| {
        child.cwd = cwd;
    }

    var merged_env: std.process.EnvMap = undefined;
    var has_merged_env = false;
    defer if (has_merged_env) merged_env.deinit();

    if (options.extra_env.len > 0) {
        merged_env = if (options.env) |env|
            try cloneEnvMap(allocator, env)
        else
            try std.process.getEnvMap(allocator);
        has_merged_env = true;
        for (options.extra_env) |entry| {
            try merged_env.put(entry[0], entry[1]);
        }
        child.env_map = &merged_env;
    } else if (options.env) |env| {
        child.env_map = env;
    }

    const log_path = options.stdout_path orelse options.stderr_path;
    if (log_path != null) {
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
    } else {
        child.stdout_behavior = .Inherit;
        child.stderr_behavior = .Inherit;
    }

    try child.spawn();

    if (log_path) |path| {
        const stdout_pipe = child.stdout orelse return error.Unexpected;
        const stderr_pipe = child.stderr orelse return error.Unexpected;
        try startLogPump(allocator, stdout_pipe, stderr_pipe, path);
        child.stdout = null;
        child.stderr = null;
    }

    return .{
        .pid = child.id,
        .child = child,
    };
}

fn cloneEnvMap(allocator: std.mem.Allocator, source: *const std.process.EnvMap) !std.process.EnvMap {
    var dst = std.process.EnvMap.init(allocator);
    errdefer dst.deinit();
    var it = source.iterator();
    while (it.next()) |entry| {
        try dst.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return dst;
}

fn startLogPump(
    allocator: std.mem.Allocator,
    stdout_pipe: std.fs.File,
    stderr_pipe: std.fs.File,
    log_path: []const u8,
) !void {
    const ctx = try allocator.create(LogPumpContext);
    errdefer allocator.destroy(ctx);
    const owned_log_path = try allocator.dupe(u8, log_path);
    errdefer allocator.free(owned_log_path);

    ctx.* = .{
        .allocator = allocator,
        .stdout_pipe = stdout_pipe,
        .stderr_pipe = stderr_pipe,
        .log_path = owned_log_path,
    };

    const thread = std.Thread.spawn(.{}, pumpChildOutputToLog, .{ctx}) catch |err| {
        ctx.stdout_pipe.close();
        ctx.stderr_pipe.close();
        allocator.free(ctx.log_path);
        allocator.destroy(ctx);
        return err;
    };
    thread.detach();
}

fn pumpChildOutputToLog(ctx: *LogPumpContext) void {
    defer {
        ctx.stdout_pipe.close();
        ctx.stderr_pipe.close();
        ctx.allocator.free(ctx.log_path);
        ctx.allocator.destroy(ctx);
    }

    var log_file = std.fs.createFileAbsolute(ctx.log_path, .{ .truncate = false }) catch return;
    defer log_file.close();
    log_file.seekFromEnd(0) catch return;

    const Streams = enum { stdout, stderr };
    var poller = std.Io.poll(ctx.allocator, Streams, .{
        .stdout = ctx.stdout_pipe,
        .stderr = ctx.stderr_pipe,
    });
    defer poller.deinit();

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;

    const stdout_reader = poller.reader(.stdout);
    stdout_reader.buffer = stdout_buf[0..];
    stdout_reader.seek = 0;
    stdout_reader.end = 0;

    const stderr_reader = poller.reader(.stderr);
    stderr_reader.buffer = stderr_buf[0..];
    stderr_reader.seek = 0;
    stderr_reader.end = 0;

    while (poller.poll() catch false) {
        if (!flushBufferedToLog(&log_file, stdout_reader)) return;
        if (!flushBufferedToLog(&log_file, stderr_reader)) return;
    }

    _ = flushBufferedToLog(&log_file, stdout_reader);
    _ = flushBufferedToLog(&log_file, stderr_reader);
}

fn flushBufferedToLog(log_file: *std.fs.File, reader: *std.Io.Reader) bool {
    const buffered = reader.buffered();
    if (buffered.len == 0) return true;
    log_file.writeAll(buffered) catch return false;
    reader.tossBuffered();
    if (reader.seek == reader.end) {
        reader.seek = 0;
        reader.end = 0;
    }
    return true;
}

/// Check whether a process with the given PID is still alive.
///
/// On POSIX systems, first tries a non-blocking waitpid to reap zombies,
/// then sends signal 0. A zombie process has exited but not been waited on —
/// `kill(pid, 0)` succeeds for zombies, giving a false positive. By calling
/// `waitpid(WNOHANG)` first, we reap any zombie and correctly report it dead.
pub fn isAlive(pid: std.process.Child.Id) bool {
    if (comptime builtin.os.tag == .windows) {
        windows.WaitForSingleObjectEx(pid, 0, false) catch |err| switch (err) {
            error.WaitTimeOut => return true,
            else => return false,
        };
        return false;
    }
    // Try to reap zombie — WNOHANG returns immediately.
    // If waitpid returns the pid, the process has exited (zombie reaped).
    const wait_result = std.posix.waitpid(pid, std.c.W.NOHANG);
    if (wait_result.pid == pid) return false; // reaped zombie or exited child

    if (std.posix.kill(pid, 0)) {
        return true;
    } else |_| {
        return false;
    }
}

/// Send SIGTERM to a process, requesting graceful termination.
pub fn terminate(pid: std.process.Child.Id) !void {
    if (comptime builtin.os.tag == .windows) {
        windows.TerminateProcess(pid, 15) catch |err| switch (err) {
            error.AccessDenied => {
                if (!isAlive(pid)) return;
                return err;
            },
            else => return err,
        };
        return;
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => return, // already dead
        else => return err,
    };
}

/// Send SIGKILL to a process, forcing immediate termination.
pub fn forceKill(pid: std.process.Child.Id) !void {
    if (comptime builtin.os.tag == .windows) {
        windows.TerminateProcess(pid, 9) catch |err| switch (err) {
            error.AccessDenied => {
                if (!isAlive(pid)) return;
                return err;
            },
            else => return err,
        };
        return;
    }
    std.posix.kill(pid, std.posix.SIG.KILL) catch |err| switch (err) {
        error.ProcessNotFound => return, // already dead
        else => return err,
    };
}

/// Get the resident set size (RSS) of a process in bytes.
///
/// Returns null if the information is unavailable or not yet implemented
/// for the current platform.
pub fn getMemoryRss(pid: std.process.Child.Id) ?u64 {
    _ = pid;
    // TODO: platform-specific RSS reading
    // Linux: read /proc/{pid}/status and parse VmRSS line
    // macOS: proc_pid_rusage or similar
    return null;
}

// ── Tests ───────────────────────────────────────────────────────────

test "spawn returns nonzero pid" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try spawn(std.testing.allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"10"},
    });
    var child = result.child;
    defer {
        // Clean up: kill the child and wait to reap it
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    }

    try std.testing.expect(result.pid != 0);
}

test "isAlive returns true for running process" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try spawn(std.testing.allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"10"},
    });
    var child = result.child;
    defer {
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    }

    try std.testing.expect(isAlive(result.pid));
}

test "terminate kills process and isAlive returns false" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try spawn(std.testing.allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"10"},
    });
    var child = result.child;

    try terminate(result.pid);
    // Wait for the child to actually exit so the PID is reaped
    _ = child.wait() catch {};

    try std.testing.expect(!isAlive(result.pid));
}

test "forceKill kills process" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try spawn(std.testing.allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"10"},
    });
    var child = result.child;

    try forceKill(result.pid);
    _ = child.wait() catch {};

    try std.testing.expect(!isAlive(result.pid));
}

test "isAlive returns false for non-existent pid" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    // PID 99999999 is almost certainly not a running process
    try std.testing.expect(!isAlive(99999999));
}

test "terminate non-existent pid does not error" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    // Should not error — ProcessNotFound is handled gracefully
    try terminate(99999999);
}

test "forceKill non-existent pid does not error" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    try forceKill(99999999);
}

test "getMemoryRss returns null for now" {
    try std.testing.expect(getMemoryRss(1) == null);
}

test "spawn with stdout_path captures stdout and stderr" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    const log_path = "/tmp/nullhub-test-process-log.txt";
    std.fs.deleteFileAbsolute(log_path) catch {};
    defer std.fs.deleteFileAbsolute(log_path) catch {};

    const result = try spawn(allocator, .{
        .binary = "/bin/sh",
        .argv = &.{ "-c", "printf 'out\\n'; printf 'err\\n' 1>&2" },
        .stdout_path = log_path,
    });
    var child = result.child;
    _ = try child.wait();

    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const file = std.fs.openFileAbsolute(log_path, .{}) catch {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 4096);
        defer allocator.free(contents);

        const has_out = std.mem.indexOf(u8, contents, "out\n") != null;
        const has_err = std.mem.indexOf(u8, contents, "err\n") != null;
        if (has_out and has_err) return;
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }

    return error.TestUnexpectedResult;
}

test "spawn with cwd" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const result = try spawn(std.testing.allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"10"},
        .cwd = "/tmp",
    });
    var child = result.child;
    defer {
        std.posix.kill(child.id, std.posix.SIG.KILL) catch {};
        _ = child.wait() catch {};
    }

    try std.testing.expect(result.pid != 0);
    try std.testing.expect(isAlive(result.pid));
}
