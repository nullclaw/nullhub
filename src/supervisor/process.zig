const std = @import("std");
const builtin = @import("builtin");

/// Options for spawning a child process.
pub const SpawnOptions = struct {
    binary: []const u8,
    argv: []const []const u8 = &.{}, // additional args after binary
    cwd: ?[]const u8 = null,
    stdout_path: ?[]const u8 = null, // redirect stdout to this file (reserved for future use)
    stderr_path: ?[]const u8 = null, // redirect stderr to this file (reserved for future use)
    env: ?*const std.process.EnvMap = null,
};

/// Result of a successful process spawn.
pub const SpawnResult = struct {
    pid: std.process.Child.Id,
    child: std.process.Child,
};

/// Spawn a child process with the given options.
///
/// Builds argv as `[binary] ++ options.argv`, sets cwd if provided,
/// and spawns the child process. Returns the PID and child handle.
///
/// For MVP, stdout/stderr inherit from the parent process.
/// Log file redirect (stdout_path/stderr_path) will be added in a future iteration.
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

    if (options.env) |env| {
        child.env_map = env;
    }

    // MVP: inherit parent stdout/stderr. Log file redirect to be added later.
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;

    try child.spawn();

    return .{
        .pid = child.id,
        .child = child,
    };
}

/// Check whether a process with the given PID is still alive.
///
/// On POSIX systems, sends signal 0 to the process. If the call succeeds,
/// the process exists. If it returns an error, the process is dead or
/// inaccessible.
pub fn isAlive(pid: std.process.Child.Id) bool {
    if (comptime builtin.os.tag == .windows) {
        return false; // TODO: Windows support via OpenProcess
    }
    if (std.posix.kill(pid, 0)) {
        return true;
    } else |_| {
        return false;
    }
}

/// Send SIGTERM to a process, requesting graceful termination.
pub fn terminate(pid: std.process.Child.Id) !void {
    if (comptime builtin.os.tag == .windows) {
        return; // TODO: Windows support via TerminateProcess
    }
    std.posix.kill(pid, std.posix.SIG.TERM) catch |err| switch (err) {
        error.ProcessNotFound => return, // already dead
        else => return err,
    };
}

/// Send SIGKILL to a process, forcing immediate termination.
pub fn forceKill(pid: std.process.Child.Id) !void {
    if (comptime builtin.os.tag == .windows) {
        return; // TODO: Windows support via TerminateProcess
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
