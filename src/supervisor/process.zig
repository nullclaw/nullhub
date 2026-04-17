const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const windows = std.os.windows;

const kernel32 = struct {
    extern "kernel32" fn GetProcessId(
        process: windows.HANDLE,
    ) callconv(std.builtin.CallingConvention.winapi) windows.DWORD;

    extern "kernel32" fn OpenProcess(
        desired_access: windows.ACCESS_MASK,
        inherit_handle: windows.BOOL,
        process_id: windows.DWORD,
    ) callconv(std.builtin.CallingConvention.winapi) ?windows.HANDLE;

    extern "kernel32" fn CloseHandle(
        object: windows.HANDLE,
    ) callconv(std.builtin.CallingConvention.winapi) windows.BOOL;
};

/// Options for spawning a child process.
pub const EnvEntry = struct { []const u8, []const u8 };

pub const SpawnOptions = struct {
    binary: []const u8,
    argv: []const []const u8 = &.{}, // additional args after binary
    cwd: ?[]const u8 = null,
    stdout_path: ?[]const u8 = null, // redirect stdout+stderr to this file
    stderr_path: ?[]const u8 = null, // if stdout_path is null, used as fallback log path
    env: ?*const std_compat.process.EnvMap = null,
    /// Extra env vars merged into child environment before spawn.
    extra_env: []const EnvEntry = &.{},
};

/// Result of a successful process spawn.
pub const SpawnResult = struct {
    pid: std_compat.process.Child.Id,
    child: std_compat.process.Child,
};

const LogPumpContext = struct {
    allocator: std.mem.Allocator,
    stdout_pipe: std_compat.fs.File,
    stderr_pipe: std_compat.fs.File,
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

    var child = std_compat.process.Child.init(argv_list.items, allocator);

    if (options.cwd) |cwd| {
        child.cwd = cwd;
    }

    var merged_env: std_compat.process.EnvMap = undefined;
    var has_merged_env = false;
    defer if (has_merged_env) merged_env.deinit();

    if (options.extra_env.len > 0) {
        merged_env = if (options.env) |env|
            try cloneEnvMap(allocator, env)
        else
            try std_compat.process.getEnvMap(allocator);
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

fn cloneEnvMap(allocator: std.mem.Allocator, source: *const std_compat.process.EnvMap) !std_compat.process.EnvMap {
    var dst = std_compat.process.EnvMap.init(allocator);
    errdefer dst.deinit();
    var it = source.iterator();
    while (it.next()) |entry| {
        try dst.put(entry.key_ptr.*, entry.value_ptr.*);
    }
    return dst;
}

fn startLogPump(
    allocator: std.mem.Allocator,
    stdout_pipe: std_compat.fs.File,
    stderr_pipe: std_compat.fs.File,
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

    var log_file = std_compat.fs.createFileAbsolute(ctx.log_path, .{ .truncate = false }) catch return;
    defer log_file.close();
    log_file.seekFromEnd(0) catch return;

    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(ctx.allocator, std_compat.io(), multi_reader_buffer.toStreams(), &.{
        ctx.stdout_pipe.toInner(),
        ctx.stderr_pipe.toInner(),
    });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);

    while (multi_reader.fill(64, .none)) |_| {
        if (!flushBufferedToLog(&log_file, stdout_reader)) return;
        if (!flushBufferedToLog(&log_file, stderr_reader)) return;
    } else |err| switch (err) {
        error.EndOfStream => {},
        else => return,
    }

    multi_reader.checkAnyError() catch return;
    _ = flushBufferedToLog(&log_file, stdout_reader);
    _ = flushBufferedToLog(&log_file, stderr_reader);
}

fn flushBufferedToLog(log_file: *std_compat.fs.File, reader: *std.Io.Reader) bool {
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
pub fn isAlive(pid: std_compat.process.Child.Id) bool {
    if (comptime builtin.os.tag == .windows) {
        const minimal_timeout: windows.LARGE_INTEGER = -1;
        return switch (windows.ntdll.NtWaitForSingleObject(pid, .FALSE, &minimal_timeout)) {
            windows.NTSTATUS.WAIT_0 => false,
            .TIMEOUT, .USER_APC, .ALERTED => true,
            else => false,
        };
    }
    return switch (std.posix.errno(std.posix.system.kill(pid, @as(std.posix.SIG, @enumFromInt(0))))) {
        .SUCCESS => true,
        else => false,
    };
}

pub fn persistedPidValue(pid: std_compat.process.Child.Id) ?u64 {
    if (comptime builtin.os.tag == .windows) {
        const process_id = kernel32.GetProcessId(pid);
        if (process_id == 0) return null;
        return process_id;
    }
    return @as(u64, @intCast(pid));
}

pub fn reopenPersistedPid(pid_value: u64) ?std_compat.process.Child.Id {
    if (comptime builtin.os.tag == .windows) {
        const process_id: windows.DWORD = std.math.cast(windows.DWORD, pid_value) orelse return null;
        const desired_access: windows.ACCESS_MASK = .{
            .STANDARD = .{ .SYNCHRONIZE = true },
            .SPECIFIC = .{ .PROCESS = .{
                .TERMINATE = true,
                .QUERY_LIMITED_INFORMATION = true,
            } },
        };
        return kernel32.OpenProcess(desired_access, windows.BOOL.fromBool(false), process_id);
    }
    return std.math.cast(std_compat.process.Child.Id, pid_value);
}

pub fn releasePidHandle(pid: std_compat.process.Child.Id) void {
    if (comptime builtin.os.tag == .windows) {
        _ = kernel32.CloseHandle(pid);
    }
}

/// Send SIGTERM to a process, requesting graceful termination.
pub fn terminate(pid: std_compat.process.Child.Id) !void {
    if (comptime builtin.os.tag == .windows) {
        switch (windows.ntdll.NtTerminateProcess(pid, @enumFromInt(@as(windows.UINT, 15)))) {
            .SUCCESS, .PROCESS_IS_TERMINATING => return,
            .ACCESS_DENIED => {
                if (!isAlive(pid)) return;
                return error.AccessDenied;
            },
            else => |status| return windows.unexpectedStatus(status),
        }
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => return, // already dead
        else => return err,
    };
}

/// Send SIGKILL to a process, forcing immediate termination.
pub fn forceKill(pid: std_compat.process.Child.Id) !void {
    if (comptime builtin.os.tag == .windows) {
        switch (windows.ntdll.NtTerminateProcess(pid, @enumFromInt(@as(windows.UINT, 9)))) {
            .SUCCESS, .PROCESS_IS_TERMINATING => return,
            .ACCESS_DENIED => {
                if (!isAlive(pid)) return;
                return error.AccessDenied;
            },
            else => |status| return windows.unexpectedStatus(status),
        }
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
pub fn getMemoryRss(pid: std_compat.process.Child.Id) ?u64 {
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
    std_compat.fs.deleteFileAbsolute(log_path) catch {};
    defer std_compat.fs.deleteFileAbsolute(log_path) catch {};

    const result = try spawn(allocator, .{
        .binary = "/bin/sh",
        .argv = &.{ "-c", "printf 'out\\n'; printf 'err\\n' 1>&2" },
        .stdout_path = log_path,
    });
    var child = result.child;
    _ = try child.wait();

    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const file = std_compat.fs.openFileAbsolute(log_path, .{}) catch {
            std_compat.thread.sleep(10 * std.time.ns_per_ms);
            continue;
        };
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 4096);
        defer allocator.free(contents);

        const has_out = std.mem.indexOf(u8, contents, "out\n") != null;
        const has_err = std.mem.indexOf(u8, contents, "err\n") != null;
        if (has_out and has_err) return;
        std_compat.thread.sleep(10 * std.time.ns_per_ms);
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
