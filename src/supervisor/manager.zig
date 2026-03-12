const std = @import("std");
const process = @import("process.zig");
const health = @import("health.zig");
const paths_mod = @import("../core/paths.zig");
const component_cli = @import("../core/component_cli.zig");

pub const Status = enum {
    stopped,
    starting,
    running,
    failed,
    restarting,
    stopping,
};

pub const ManagedInstance = struct {
    component: []const u8,
    name: []const u8,
    owns_memory: bool = false,
    status: Status = .stopped,
    pid: ?std.process.Child.Id = null,
    child: ?std.process.Child = null,
    port: u16 = 0,
    health_endpoint: []const u8 = "/health",

    // Launch config (needed for restart)
    binary_path: []const u8 = "",
    working_dir: []const u8 = "",
    config_path: []const u8 = "",
    launch_command: []const u8 = "",
    // NOTE: Arguments containing spaces won't round-trip correctly through
    // this space-separated representation. Prefer arguments without spaces.
    launch_args_str: []const u8 = "", // space-separated additional args

    // Timing
    started_at: ?i64 = null,
    last_health_check: ?i64 = null,
    last_health_ok: ?i64 = null,
    health_interval_ms: i64 = 15_000,
    health_consecutive_failures: u32 = 0,

    // Restart backoff
    restart_count: u32 = 0,
    max_restarts: u32 = 5,
    last_restart_attempt: ?i64 = null,

    // Start timeout
    start_timeout_ms: i64 = 30_000,
    starting_since: ?i64 = null,
};

pub const InstanceStatus = struct {
    component: []const u8,
    name: []const u8,
    status: Status,
    pid: ?std.process.Child.Id,
    port: u16,
    uptime_seconds: ?u64,
    memory_rss_bytes: ?u64,
    restart_count: u32,
    last_health_ok: ?i64,
    health_consecutive_failures: u32,
};

pub const Manager = struct {
    allocator: std.mem.Allocator,
    instances: std.StringHashMap(ManagedInstance),
    p: paths_mod.Paths,

    pub fn init(allocator: std.mem.Allocator, p: paths_mod.Paths) Manager {
        return .{
            .allocator = allocator,
            .instances = std.StringHashMap(ManagedInstance).init(allocator),
            .p = p,
        };
    }

    pub fn deinit(self: *Manager) void {
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            self.shutdownInstance(entry.value_ptr, "manager deinit");
            self.freeInstanceOwned(entry.value_ptr);
            self.allocator.free(entry.key_ptr.*);
        }
        self.instances.deinit();
    }

    fn freeInstanceOwned(self: *Manager, inst: *ManagedInstance) void {
        if (!inst.owns_memory) return;
        self.allocator.free(inst.component);
        self.allocator.free(inst.name);
        self.allocator.free(inst.health_endpoint);
        self.allocator.free(inst.binary_path);
        if (inst.working_dir.len > 0) self.allocator.free(inst.working_dir);
        if (inst.config_path.len > 0) self.allocator.free(inst.config_path);
        if (inst.launch_command.len > 0) self.allocator.free(inst.launch_command);
        if (inst.launch_args_str.len > 0) self.allocator.free(inst.launch_args_str);
        inst.owns_memory = false;
    }

    fn pidToU64(pid: std.process.Child.Id) u64 {
        return switch (@typeInfo(std.process.Child.Id)) {
            .pointer => @as(u64, @intCast(@intFromPtr(pid))),
            else => @as(u64, @intCast(pid)),
        };
    }

    fn logSupervisor(
        self: *Manager,
        component: []const u8,
        name: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) void {
        const logs_dir = self.p.instanceLogs(self.allocator, component, name) catch return;
        defer self.allocator.free(logs_dir);
        std.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };

        const nullhub_log = std.fs.path.join(self.allocator, &.{ logs_dir, "nullhub.log" }) catch return;
        defer self.allocator.free(nullhub_log);

        var file = std.fs.createFileAbsolute(nullhub_log, .{ .truncate = false }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;

        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(msg);

        const line = std.fmt.allocPrint(
            self.allocator,
            "[nullhub/supervisor][{d}] {s}\n",
            .{ std.time.milliTimestamp(), msg },
        ) catch return;
        defer self.allocator.free(line);

        file.writeAll(line) catch {};
    }

    fn logHealthFailure(
        self: *Manager,
        inst: *ManagedInstance,
        prefix: []const u8,
        result: health.HealthCheckResult,
        failures: u32,
    ) void {
        if (result.status_code) |code| {
            self.logSupervisor(
                inst.component,
                inst.name,
                "{s}: HTTP {d} (consecutive failures: {d})",
                .{ prefix, code, failures },
            );
            return;
        }
        if (result.error_message) |msg| {
            self.logSupervisor(
                inst.component,
                inst.name,
                "{s}: {s} (consecutive failures: {d})",
                .{ prefix, msg, failures },
            );
            return;
        }
        self.logSupervisor(
            inst.component,
            inst.name,
            "{s}: unknown error (consecutive failures: {d})",
            .{ prefix, failures },
        );
    }

    fn waitChildAndLog(
        self: *Manager,
        inst: *ManagedInstance,
        child: *std.process.Child,
        context: []const u8,
    ) void {
        const term = child.wait() catch |err| {
            self.logSupervisor(inst.component, inst.name, "{s}: wait() failed: {s}", .{ context, @errorName(err) });
            return;
        };
        switch (term) {
            .Exited => |code| self.logSupervisor(inst.component, inst.name, "{s}: exited with code {d}", .{ context, code }),
            .Signal => |signal| self.logSupervisor(inst.component, inst.name, "{s}: terminated by signal {d}", .{ context, signal }),
            .Stopped => |signal| self.logSupervisor(inst.component, inst.name, "{s}: stopped by signal {d}", .{ context, signal }),
            .Unknown => |value| self.logSupervisor(inst.component, inst.name, "{s}: unknown termination value {d}", .{ context, value }),
        }
    }

    fn shutdownInstance(self: *Manager, inst: *ManagedInstance, context: []const u8) void {
        if (inst.pid) |pid| {
            inst.status = .stopping;
            self.logSupervisor(inst.component, inst.name, "{s}: terminating pid={d}", .{ context, pidToU64(pid) });
            process.terminate(pid) catch |err| {
                self.logSupervisor(inst.component, inst.name, "{s}: terminate failed for pid={d}: {s}", .{ context, pidToU64(pid), @errorName(err) });
            };
        }
        if (inst.child) |*child| {
            self.waitChildAndLog(inst, child, context);
            inst.child = null;
        }
        inst.status = .stopped;
        inst.pid = null;
    }

    /// Start an instance. binary_path is the path to the component binary.
    pub fn startInstance(
        self: *Manager,
        component: []const u8,
        name: []const u8,
        binary_path: []const u8,
        launch_args: []const []const u8,
        port: u16,
        health_endpoint: []const u8,
        working_dir: []const u8,
        config_path: []const u8,
        launch_command: []const u8,
    ) !void {
        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ component, name });
        errdefer self.allocator.free(key);

        const component_owned = try self.allocator.dupe(u8, component);
        errdefer self.allocator.free(component_owned);
        const name_owned = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_owned);
        const health_endpoint_owned = try self.allocator.dupe(u8, health_endpoint);
        errdefer self.allocator.free(health_endpoint_owned);
        const binary_path_owned = try self.allocator.dupe(u8, binary_path);
        errdefer self.allocator.free(binary_path_owned);
        const working_dir_owned = if (working_dir.len > 0) try self.allocator.dupe(u8, working_dir) else "";
        errdefer if (working_dir_owned.len > 0) self.allocator.free(working_dir_owned);
        const config_path_owned = if (config_path.len > 0) try self.allocator.dupe(u8, config_path) else "";
        errdefer if (config_path_owned.len > 0) self.allocator.free(config_path_owned);
        const launch_command_owned = if (launch_command.len > 0) try self.allocator.dupe(u8, launch_command) else "";
        errdefer if (launch_command_owned.len > 0) self.allocator.free(launch_command_owned);

        // Build space-separated args string for restart.
        var launch_args_str: []const u8 = "";
        if (launch_args.len > 0) {
            var args_buf = std.array_list.Managed(u8).init(self.allocator);
            defer args_buf.deinit();
            for (launch_args, 0..) |arg, i| {
                if (i > 0) try args_buf.append(' ');
                try args_buf.appendSlice(arg);
            }
            launch_args_str = try args_buf.toOwnedSlice();
        }
        errdefer if (launch_args_str.len > 0) self.allocator.free(launch_args_str);

        // Ensure logs directory exists and compute log file path
        const logs_dir = try self.p.instanceLogs(self.allocator, component, name);
        defer self.allocator.free(logs_dir);
        std.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
        const stdout_log = try std.fs.path.join(self.allocator, &.{ logs_dir, "stdout.log" });
        defer self.allocator.free(stdout_log);

        const cwd: ?[]const u8 = if (working_dir.len > 0) working_dir else null;
        var home_env_buf: [1]process.EnvEntry = undefined;
        const extra_env: []const process.EnvEntry = if (working_dir.len > 0)
            if (component_cli.homeEnvVarForComponent(component)) |env_name| blk: {
                home_env_buf[0] = .{ env_name, working_dir };
                break :blk home_env_buf[0..1];
            } else &.{}
        else
            &.{};
        var result = process.spawn(self.allocator, .{
            .binary = binary_path,
            .argv = launch_args,
            .cwd = cwd,
            .stdout_path = stdout_log,
            .extra_env = extra_env,
        }) catch |err| {
            self.logSupervisor(component, name, "start failed: spawn error: {s} (binary={s})", .{ @errorName(err), binary_path });
            return err;
        };
        errdefer {
            process.forceKill(result.pid) catch {};
            _ = result.child.wait() catch {};
        }

        if (self.instances.fetchRemove(key)) |old_entry| {
            var old_value = old_entry.value;
            if (old_value.pid) |pid| {
                self.logSupervisor(old_value.component, old_value.name, "replacing existing process pid={d}", .{pidToU64(pid)});
                process.terminate(pid) catch |err| {
                    self.logSupervisor(old_value.component, old_value.name, "replace: terminate failed for pid={d}: {s}", .{ pidToU64(pid), @errorName(err) });
                };
            }
            if (old_value.child) |*child| {
                self.waitChildAndLog(&old_value, child, "replace: previous process exit");
            }
            self.freeInstanceOwned(&old_value);
            self.allocator.free(old_entry.key);
        }

        const now = std.time.milliTimestamp();
        try self.instances.put(key, .{
            .component = component_owned,
            .name = name_owned,
            .owns_memory = true,
            .status = .starting,
            .pid = result.pid,
            .child = result.child,
            .port = port,
            .health_endpoint = health_endpoint_owned,
            .binary_path = binary_path_owned,
            .working_dir = working_dir_owned,
            .config_path = config_path_owned,
            .launch_command = launch_command_owned,
            .launch_args_str = launch_args_str,
            .started_at = now,
            .starting_since = now,
        });
        self.logSupervisor(component_owned, name_owned, "spawned pid={d}; status=starting; port={d}", .{ pidToU64(result.pid), port });
    }

    /// Stop an instance gracefully (SIGTERM, wait, SIGKILL if needed).
    pub fn stopInstance(self: *Manager, component: []const u8, name: []const u8) !void {
        const key_buf = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ component, name });
        defer self.allocator.free(key_buf);

        if (self.instances.getPtr(key_buf)) |inst| {
            if (inst.pid) |pid| {
                self.logSupervisor(inst.component, inst.name, "stop requested for pid={d}", .{pidToU64(pid)});
                self.shutdownInstance(inst, "stop request");
                self.logSupervisor(inst.component, inst.name, "instance stopped", .{});
            } else {
                inst.status = .stopped;
                self.logSupervisor(inst.component, inst.name, "stop requested while pid is null; marking stopped", .{});
            }
        }
    }

    /// Get status for a specific instance.
    pub fn getStatus(self: *Manager, component: []const u8, name: []const u8) ?InstanceStatus {
        const key_buf = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ component, name }) catch return null;
        defer self.allocator.free(key_buf);

        const inst = self.instances.get(key_buf) orelse return null;
        const now = std.time.milliTimestamp();
        const uptime: ?u64 = if (inst.started_at) |s| blk: {
            const diff = now - s;
            break :blk if (diff >= 0) @intCast(@divFloor(diff, 1000)) else null;
        } else null;

        return .{
            .component = inst.component,
            .name = inst.name,
            .status = inst.status,
            .pid = inst.pid,
            .port = inst.port,
            .uptime_seconds = uptime,
            .memory_rss_bytes = if (inst.pid) |pid| process.getMemoryRss(pid) else null,
            .restart_count = inst.restart_count,
            .last_health_ok = inst.last_health_ok,
            .health_consecutive_failures = inst.health_consecutive_failures,
        };
    }

    /// Get all instance statuses.
    pub fn getAllStatuses(self: *Manager, allocator: std.mem.Allocator) ![]InstanceStatus {
        var list = std.array_list.Managed(InstanceStatus).init(allocator);
        errdefer list.deinit();
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            const inst = entry.value_ptr.*;
            const now = std.time.milliTimestamp();
            const uptime: ?u64 = if (inst.started_at) |s| blk: {
                const diff = now - s;
                break :blk if (diff >= 0) @intCast(@divFloor(diff, 1000)) else null;
            } else null;
            try list.append(.{
                .component = inst.component,
                .name = inst.name,
                .status = inst.status,
                .pid = inst.pid,
                .port = inst.port,
                .uptime_seconds = uptime,
                .memory_rss_bytes = null,
                .restart_count = inst.restart_count,
                .last_health_ok = inst.last_health_ok,
                .health_consecutive_failures = inst.health_consecutive_failures,
            });
        }
        return list.toOwnedSlice();
    }

    /// Called periodically (every ~1 second) to manage instance lifecycle.
    /// Checks health, handles restarts, detects crashes.
    pub fn tick(self: *Manager) void {
        const now = std.time.milliTimestamp();
        var it = self.instances.iterator();
        while (it.next()) |entry| {
            const inst = entry.value_ptr;
            switch (inst.status) {
                .starting => self.tickStarting(inst, now),
                .running => self.tickRunning(inst, now),
                .restarting => self.tickRestarting(inst, now),
                .stopping, .stopped, .failed => {},
            }
        }
    }

    fn tickStarting(self: *Manager, inst: *ManagedInstance, now: i64) void {
        // Check if process is alive
        if (inst.pid) |pid| {
            if (!process.isAlive(pid)) {
                self.logSupervisor(inst.component, inst.name, "startup failed: pid={d} is not alive", .{pidToU64(pid)});
                if (inst.child) |*child| {
                    self.waitChildAndLog(inst, child, "startup: process exited before ready");
                    inst.child = null;
                }
                inst.pid = null;
                inst.status = .failed;
                return;
            }
        } else {
            self.logSupervisor(inst.component, inst.name, "startup failed: missing pid in starting state", .{});
            inst.status = .failed;
            return;
        }

        // No port means no health endpoint (e.g. agent mode) —
        // process being alive is sufficient to consider it running.
        if (inst.port == 0) {
            inst.status = .running;
            inst.last_health_ok = now;
            inst.last_health_check = now;
            inst.restart_count = 0;
            self.logSupervisor(inst.component, inst.name, "startup complete without health endpoint; status=running", .{});
            return;
        }

        // Check health endpoint
        const result = health.check(self.allocator, "127.0.0.1", inst.port, inst.health_endpoint);
        if (result.ok) {
            inst.status = .running;
            inst.last_health_ok = now;
            inst.last_health_check = now;
            inst.restart_count = 0;
            self.logSupervisor(inst.component, inst.name, "startup health check passed on port {d}{s}; status=running", .{ inst.port, inst.health_endpoint });
            return;
        }

        // Check timeout
        if (inst.starting_since) |since| {
            if (now - since > inst.start_timeout_ms) {
                self.logHealthFailure(inst, "startup health check did not pass", result, 1);
                self.logSupervisor(inst.component, inst.name, "startup timed out after {d} ms; marking failed", .{inst.start_timeout_ms});
                if (inst.pid) |pid| {
                    process.terminate(pid) catch |err| {
                        self.logSupervisor(inst.component, inst.name, "startup timeout: terminate failed for pid={d}: {s}", .{ pidToU64(pid), @errorName(err) });
                    };
                }
                if (inst.child) |*child| {
                    self.waitChildAndLog(inst, child, "startup timeout");
                    inst.child = null;
                }
                inst.pid = null;
                inst.status = .failed;
            }
        }
    }

    fn tickRunning(self: *Manager, inst: *ManagedInstance, now: i64) void {
        // Check if process is still alive
        if (inst.pid) |pid| {
            if (!process.isAlive(pid)) {
                self.logSupervisor(
                    inst.component,
                    inst.name,
                    "process pid={d} exited while running; scheduling restart attempt {d}/{d}",
                    .{ pidToU64(pid), inst.restart_count + 1, inst.max_restarts },
                );
                if (inst.child) |*child| {
                    self.waitChildAndLog(inst, child, "running: process exit detected");
                    inst.child = null;
                }
                inst.pid = null;
                inst.status = .restarting;
                inst.last_restart_attempt = now;
                return;
            }
        } else {
            self.logSupervisor(inst.component, inst.name, "running state has null pid; scheduling restart", .{});
            inst.status = .restarting;
            inst.last_restart_attempt = now;
            return;
        }

        // No port means no health endpoint — only process liveness matters.
        if (inst.port == 0) return;

        // Periodic health check
        if (inst.last_health_check) |last| {
            if (now - last < inst.health_interval_ms) return;
        }

        inst.last_health_check = now;
        const result = health.check(self.allocator, "127.0.0.1", inst.port, inst.health_endpoint);
        if (result.ok) {
            if (inst.health_consecutive_failures > 0) {
                self.logSupervisor(inst.component, inst.name, "health check recovered after {d} consecutive failures", .{inst.health_consecutive_failures});
            }
            inst.last_health_ok = now;
            inst.health_consecutive_failures = 0;
        } else {
            inst.health_consecutive_failures += 1;
            self.logHealthFailure(inst, "health check failed", result, inst.health_consecutive_failures);
            if (inst.health_consecutive_failures >= 3) {
                // Kill the unresponsive process and reap it to avoid zombies.
                if (inst.pid) |pid| {
                    self.logSupervisor(inst.component, inst.name, "health failure threshold reached; terminating pid={d}", .{pidToU64(pid)});
                    process.terminate(pid) catch |err| {
                        self.logSupervisor(inst.component, inst.name, "health failure: terminate failed for pid={d}: {s}", .{ pidToU64(pid), @errorName(err) });
                    };
                }
                if (inst.child) |*child| {
                    self.waitChildAndLog(inst, child, "health failure threshold");
                    inst.child = null;
                }
                inst.pid = null;
                inst.status = .failed;
                self.logSupervisor(inst.component, inst.name, "instance marked failed after {d} consecutive health failures", .{inst.health_consecutive_failures});
            }
        }
    }

    fn tickRestarting(self: *Manager, inst: *ManagedInstance, now: i64) void {
        if (inst.restart_count >= inst.max_restarts) {
            self.logSupervisor(inst.component, inst.name, "restart budget exhausted ({d}/{d}); marking failed", .{ inst.restart_count, inst.max_restarts });
            inst.status = .failed;
            return;
        }

        // Backoff: 0, 2s, 4s, 8s, 16s
        const delay_ms: i64 = if (inst.restart_count == 0)
            0
        else
            @as(i64, 1000) * (@as(i64, 1) << @intCast(@min(inst.restart_count, 4)));

        if (inst.last_restart_attempt) |last| {
            if (now - last < delay_ms) return; // still waiting
        }

        inst.restart_count += 1;
        inst.last_restart_attempt = now;
        self.logSupervisor(inst.component, inst.name, "restart attempt {d}/{d} after backoff {d} ms", .{ inst.restart_count, inst.max_restarts, delay_ms });

        // Reap the old child process before spawning a new one to avoid zombies
        if (inst.child) |*old_child| {
            self.waitChildAndLog(inst, old_child, "restart: previous child reap");
            inst.child = null;
        }

        if (inst.binary_path.len == 0) {
            self.logSupervisor(inst.component, inst.name, "restart failed: binary path is empty", .{});
            inst.status = .failed;
            return;
        }

        // Build argv from launch_args_str
        var argv_list = std.array_list.Managed([]const u8).init(self.allocator);
        defer argv_list.deinit();

        if (inst.launch_args_str.len > 0) {
            var it = std.mem.splitScalar(u8, inst.launch_args_str, ' ');
            while (it.next()) |arg| {
                if (arg.len > 0) {
                    argv_list.append(arg) catch |err| {
                        self.logSupervisor(inst.component, inst.name, "restart failed: argv allocation error: {s}", .{@errorName(err)});
                        inst.status = .failed;
                        return;
                    };
                }
            }
        }

        // Compute log file path for output redirect
        const logs_dir = self.p.instanceLogs(self.allocator, inst.component, inst.name) catch |err| {
            self.logSupervisor(inst.component, inst.name, "restart failed: cannot resolve logs dir: {s}", .{@errorName(err)});
            inst.status = .failed;
            return;
        };
        defer self.allocator.free(logs_dir);
        std.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => {
                self.logSupervisor(inst.component, inst.name, "restart failed: cannot create logs dir: {s}", .{@errorName(err)});
                inst.status = .failed;
                return;
            },
        };
        const stdout_log = std.fs.path.join(self.allocator, &.{ logs_dir, "stdout.log" }) catch |err| {
            self.logSupervisor(inst.component, inst.name, "restart failed: cannot build stdout.log path: {s}", .{@errorName(err)});
            inst.status = .failed;
            return;
        };
        defer self.allocator.free(stdout_log);

        const cwd: ?[]const u8 = if (inst.working_dir.len > 0) inst.working_dir else null;
        var home_env_buf: [1]process.EnvEntry = undefined;
        const extra_env: []const process.EnvEntry = if (inst.working_dir.len > 0)
            if (component_cli.homeEnvVarForComponent(inst.component)) |env_name| blk: {
                home_env_buf[0] = .{ env_name, inst.working_dir };
                break :blk home_env_buf[0..1];
            } else &.{}
        else
            &.{};
        const result = process.spawn(self.allocator, .{
            .binary = inst.binary_path,
            .argv = argv_list.items,
            .cwd = cwd,
            .stdout_path = stdout_log,
            .extra_env = extra_env,
        }) catch |err| {
            self.logSupervisor(inst.component, inst.name, "restart spawn failed: {s}", .{@errorName(err)});
            inst.status = .failed;
            return;
        };

        inst.pid = result.pid;
        inst.child = result.child;
        inst.status = .starting;
        inst.started_at = now;
        inst.starting_since = now;
        inst.health_consecutive_failures = 0;
        self.logSupervisor(inst.component, inst.name, "restart spawned pid={d}; status=starting", .{pidToU64(result.pid)});
    }
};

// ── Tests ───────────────────────────────────────────────────────────

test "Manager init and deinit (no leaks)" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();
}

test "Manager deinit terminates tracked child processes" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr-deinit-kill");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);

    const spawned = try process.spawn(allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"60"},
    });

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "inst" });
    try mgr.instances.put(key, .{
        .component = "comp",
        .name = "inst",
        .status = .running,
        .pid = spawned.pid,
        .child = spawned.child,
    });

    mgr.deinit();

    try std.testing.expect(!process.isAlive(spawned.pid));
}

test "getStatus returns null for unknown instance" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    try std.testing.expect(mgr.getStatus("foo", "bar") == null);
}

test "logSupervisor appends diagnostics to nullhub.log" {
    const allocator = std.testing.allocator;
    const tmp_root = "/tmp/test-nullhub-mgr-log-supervisor";
    std.fs.deleteTreeAbsolute(tmp_root) catch {};
    defer std.fs.deleteTreeAbsolute(tmp_root) catch {};

    var p = try paths_mod.Paths.init(allocator, tmp_root);
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    mgr.logSupervisor("nullclaw", "diag", "first diagnostic {d}", .{@as(u8, 1)});
    mgr.logSupervisor("nullclaw", "diag", "second diagnostic", .{});

    const logs_dir = try p.instanceLogs(allocator, "nullclaw", "diag");
    defer allocator.free(logs_dir);
    const log_path = try std.fs.path.join(allocator, &.{ logs_dir, "nullhub.log" });
    defer allocator.free(log_path);

    var file = try std.fs.openFileAbsolute(log_path, .{});
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 16 * 1024);
    defer allocator.free(contents);

    try std.testing.expect(std.mem.indexOf(u8, contents, "[nullhub/supervisor]") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "first diagnostic 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, contents, "second diagnostic") != null);
}

test "status reporting for manually-added instance" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "mycomp", "myinst" });
    try mgr.instances.put(key, .{
        .component = "mycomp",
        .name = "myinst",
        .status = .running,
        .pid = null,
        .port = 8080,
        .health_endpoint = "/health",
        .started_at = std.time.milliTimestamp() - 5000, // started 5s ago
        .restart_count = 2,
        .health_consecutive_failures = 1,
        .last_health_ok = std.time.milliTimestamp() - 1000,
    });

    const st = mgr.getStatus("mycomp", "myinst");
    try std.testing.expect(st != null);
    const s = st.?;
    try std.testing.expectEqualStrings("mycomp", s.component);
    try std.testing.expectEqualStrings("myinst", s.name);
    try std.testing.expectEqual(Status.running, s.status);
    try std.testing.expectEqual(@as(u16, 8080), s.port);
    try std.testing.expect(s.uptime_seconds != null);
    try std.testing.expect(s.uptime_seconds.? >= 4); // at least 4s
    try std.testing.expectEqual(@as(u32, 2), s.restart_count);
    try std.testing.expectEqual(@as(u32, 1), s.health_consecutive_failures);
}

test "getAllStatuses returns correct list" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    // Add two instances manually
    const key1 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp-a", "inst-1" });
    try mgr.instances.put(key1, .{
        .component = "comp-a",
        .name = "inst-1",
        .status = .running,
        .port = 3000,
    });
    const key2 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp-b", "inst-2" });
    try mgr.instances.put(key2, .{
        .component = "comp-b",
        .name = "inst-2",
        .status = .stopped,
        .port = 3001,
    });

    const statuses = try mgr.getAllStatuses(allocator);
    defer allocator.free(statuses);

    try std.testing.expectEqual(@as(usize, 2), statuses.len);

    // Both instances should be present (order is not guaranteed by HashMap)
    var found_a = false;
    var found_b = false;
    for (statuses) |s| {
        if (std.mem.eql(u8, s.component, "comp-a")) {
            found_a = true;
            try std.testing.expectEqual(Status.running, s.status);
            try std.testing.expectEqual(@as(u16, 3000), s.port);
        }
        if (std.mem.eql(u8, s.component, "comp-b")) {
            found_b = true;
            try std.testing.expectEqual(Status.stopped, s.status);
            try std.testing.expectEqual(@as(u16, 3001), s.port);
        }
    }
    try std.testing.expect(found_a);
    try std.testing.expect(found_b);
}

test "tick: restarting with max_restarts exceeded transitions to failed" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "inst" });
    try mgr.instances.put(key, .{
        .component = "comp",
        .name = "inst",
        .status = .restarting,
        .restart_count = 5, // already at max
        .max_restarts = 5,
        .last_restart_attempt = std.time.milliTimestamp(),
    });

    mgr.tick();

    const inst = mgr.instances.get("comp/inst").?;
    try std.testing.expectEqual(Status.failed, inst.status);
}

test "tick: restarting with restarts remaining transitions to failed (no binary)" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "inst" });
    try mgr.instances.put(key, .{
        .component = "comp",
        .name = "inst",
        .status = .restarting,
        .restart_count = 0,
        .max_restarts = 5,
        .last_restart_attempt = std.time.milliTimestamp() - 10_000, // well past any backoff
    });

    mgr.tick();

    // Without binary path stored, tickRestarting marks as failed
    const inst = mgr.instances.get("comp/inst").?;
    try std.testing.expectEqual(Status.failed, inst.status);
    try std.testing.expectEqual(@as(u32, 1), inst.restart_count);
}

test "tick: stopped and failed instances are not modified" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    const key1 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "stopped-inst" });
    try mgr.instances.put(key1, .{
        .component = "comp",
        .name = "stopped-inst",
        .status = .stopped,
    });

    const key2 = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "failed-inst" });
    try mgr.instances.put(key2, .{
        .component = "comp",
        .name = "failed-inst",
        .status = .failed,
        .restart_count = 3,
    });

    mgr.tick();

    const stopped = mgr.instances.get("comp/stopped-inst").?;
    try std.testing.expectEqual(Status.stopped, stopped.status);

    const failed = mgr.instances.get("comp/failed-inst").?;
    try std.testing.expectEqual(Status.failed, failed.status);
    try std.testing.expectEqual(@as(u32, 3), failed.restart_count);
}

test "tick: starting instance without pid transitions to failed" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    // An instance in .starting with a non-existent PID should go to .failed
    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "dead-start" });
    try mgr.instances.put(key, .{
        .component = "comp",
        .name = "dead-start",
        .status = .starting,
        .pid = 99999999, // non-existent
        .starting_since = std.time.milliTimestamp(),
    });

    mgr.tick();

    const inst = mgr.instances.get("comp/dead-start").?;
    try std.testing.expectEqual(Status.failed, inst.status);
}

test "tick: restarting with binary_path spawns new process" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "restartable" });
    try mgr.instances.put(key, .{
        .component = "comp",
        .name = "restartable",
        .status = .restarting,
        .restart_count = 0,
        .max_restarts = 5,
        .binary_path = "/bin/sleep",
        .launch_args_str = "60",
        .last_restart_attempt = std.time.milliTimestamp() - 10_000,
    });

    mgr.tick();

    const inst_ptr = mgr.instances.getPtr("comp/restartable").?;
    // Should have spawned a new process and moved to .starting
    try std.testing.expectEqual(Status.starting, inst_ptr.status);
    try std.testing.expect(inst_ptr.pid != null);
    try std.testing.expectEqual(@as(u32, 1), inst_ptr.restart_count);

    // Clean up the spawned process
    if (inst_ptr.child) |*child| {
        process.terminate(child.id) catch {};
        _ = child.wait() catch {};
        inst_ptr.child = null;
    }
}

test "tick: running instance with dead pid transitions to restarting" {
    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "crashed" });
    try mgr.instances.put(key, .{
        .component = "comp",
        .name = "crashed",
        .status = .running,
        .pid = 99999999, // non-existent
        .started_at = std.time.milliTimestamp() - 60_000,
        .last_health_check = std.time.milliTimestamp(),
    });

    mgr.tick();

    const inst = mgr.instances.get("comp/crashed").?;
    try std.testing.expectEqual(Status.restarting, inst.status);
}
