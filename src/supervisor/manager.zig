const std = @import("std");
const std_compat = @import("compat");
const process = @import("process.zig");
const health = @import("health.zig");
const runtime_state = @import("runtime_state.zig");
const paths_mod = @import("../core/paths.zig");
const component_cli = @import("../core/component_cli.zig");
const test_helpers = @import("../test_helpers.zig");

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
    pid: ?std_compat.process.Child.Id = null,
    child: ?std_compat.process.Child = null,
    port: u16 = 0,
    health_endpoint: []const u8 = "/health",

    // Launch config (needed for restart)
    binary_path: []const u8 = "",
    working_dir: []const u8 = "",
    config_path: []const u8 = "",
    launch_command: []const u8 = "",
    launch_args: []const []const u8 = &.{},

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
    pid: ?std_compat.process.Child.Id,
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
        self.freeLaunchArgs(inst.launch_args);
        inst.owns_memory = false;
    }

    fn freeLaunchArgs(self: *Manager, args: []const []const u8) void {
        if (args.len == 0) return;
        for (args) |arg| self.allocator.free(arg);
        self.allocator.free(args);
    }

    const OwnedInstanceFields = struct {
        component: []const u8,
        name: []const u8,
        health_endpoint: []const u8,
        binary_path: []const u8,
        working_dir: []const u8,
        config_path: []const u8,
        launch_command: []const u8,
        launch_args: []const []const u8,

        fn deinit(self: *OwnedInstanceFields, allocator: std.mem.Allocator) void {
            allocator.free(self.component);
            allocator.free(self.name);
            allocator.free(self.health_endpoint);
            allocator.free(self.binary_path);
            if (self.working_dir.len > 0) allocator.free(self.working_dir);
            if (self.config_path.len > 0) allocator.free(self.config_path);
            if (self.launch_command.len > 0) allocator.free(self.launch_command);
            if (self.launch_args.len > 0) {
                for (self.launch_args) |arg| allocator.free(arg);
                allocator.free(self.launch_args);
            }
            self.* = undefined;
        }
    };

    fn ownInstanceFields(
        self: *Manager,
        component: []const u8,
        name: []const u8,
        health_endpoint: []const u8,
        binary_path: []const u8,
        working_dir: []const u8,
        config_path: []const u8,
        launch_command: []const u8,
        launch_args: []const []const u8,
    ) !OwnedInstanceFields {
        var owned = OwnedInstanceFields{
            .component = try self.allocator.dupe(u8, component),
            .name = "",
            .health_endpoint = "",
            .binary_path = "",
            .working_dir = "",
            .config_path = "",
            .launch_command = "",
            .launch_args = &.{},
        };
        errdefer owned.deinit(self.allocator);

        owned.name = try self.allocator.dupe(u8, name);
        owned.health_endpoint = try self.allocator.dupe(u8, health_endpoint);
        owned.binary_path = try self.allocator.dupe(u8, binary_path);
        owned.working_dir = if (working_dir.len > 0) try self.allocator.dupe(u8, working_dir) else "";
        owned.config_path = if (config_path.len > 0) try self.allocator.dupe(u8, config_path) else "";
        owned.launch_command = if (launch_command.len > 0) try self.allocator.dupe(u8, launch_command) else "";
        owned.launch_args = try self.cloneLaunchArgs(launch_args);
        return owned;
    }

    fn cloneLaunchArgs(self: *Manager, args: []const []const u8) ![]const []const u8 {
        if (args.len == 0) return &.{};

        const owned = try self.allocator.alloc([]const u8, args.len);
        errdefer self.allocator.free(owned);

        var cloned: usize = 0;
        errdefer {
            for (owned[0..cloned]) |arg| self.allocator.free(arg);
        }

        for (args, 0..) |arg, idx| {
            owned[idx] = try self.allocator.dupe(u8, arg);
            cloned += 1;
        }
        return owned;
    }

    fn clearRuntimeState(self: *Manager, component: []const u8, name: []const u8) void {
        runtime_state.delete(self.allocator, self.p, component, name);
    }

    fn clearPid(self: *Manager, inst: *ManagedInstance) void {
        if (inst.pid) |pid| {
            if (inst.child == null) process.releasePidHandle(pid);
            inst.pid = null;
        }
        self.clearRuntimeState(inst.component, inst.name);
    }

    fn persistRuntimeState(self: *Manager, inst: *const ManagedInstance) void {
        const pid = inst.pid orelse return;
        const persisted_pid = process.persistedPidValue(pid) orelse {
            self.logSupervisor(inst.component, inst.name, "failed to persist runtime state: unresolved pid", .{});
            return;
        };

        runtime_state.write(self.allocator, self.p, inst.component, inst.name, .{
            .pid = persisted_pid,
            .port = inst.port,
            .health_endpoint = inst.health_endpoint,
            .binary_path = inst.binary_path,
            .working_dir = inst.working_dir,
            .config_path = inst.config_path,
            .launch_command = inst.launch_command,
            .launch_args = inst.launch_args,
            .started_at = inst.started_at,
            .starting_since = inst.starting_since,
        }) catch |err| {
            self.logSupervisor(inst.component, inst.name, "failed to persist runtime state: {s}", .{@errorName(err)});
        };
    }

    fn pidToU64(pid: std_compat.process.Child.Id) u64 {
        return switch (@typeInfo(std_compat.process.Child.Id)) {
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
        std_compat.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return,
        };

        const nullhub_log = std.fs.path.join(self.allocator, &.{ logs_dir, "nullhub.log" }) catch return;
        defer self.allocator.free(nullhub_log);

        var file = std_compat.fs.createFileAbsolute(nullhub_log, .{ .truncate = false }) catch return;
        defer file.close();
        file.seekFromEnd(0) catch return;

        const msg = std.fmt.allocPrint(self.allocator, fmt, args) catch return;
        defer self.allocator.free(msg);

        const line = std.fmt.allocPrint(
            self.allocator,
            "[nullhub/supervisor][{d}] {s}\n",
            .{ std_compat.time.milliTimestamp(), msg },
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

    fn scheduleRestart(self: *Manager, inst: *ManagedInstance, now: i64, reason: []const u8) void {
        inst.status = .restarting;
        inst.last_restart_attempt = now;
        inst.health_consecutive_failures = 0;
        self.logSupervisor(inst.component, inst.name, "{s}; scheduling restart attempt {d}/{d}", .{
            reason,
            inst.restart_count + 1,
            inst.max_restarts,
        });
    }

    fn waitChildAndLog(
        self: *Manager,
        inst: *ManagedInstance,
        child: *std_compat.process.Child,
        context: []const u8,
    ) void {
        const term = child.wait() catch |err| {
            self.logSupervisor(inst.component, inst.name, "{s}: wait() failed: {s}", .{ context, @errorName(err) });
            return;
        };
        switch (term) {
            .exited => |code| self.logSupervisor(inst.component, inst.name, "{s}: exited with code {d}", .{ context, code }),
            .signal => |signal| self.logSupervisor(inst.component, inst.name, "{s}: terminated by signal {d}", .{ context, signal }),
            .stopped => |signal| self.logSupervisor(inst.component, inst.name, "{s}: stopped by signal {d}", .{ context, signal }),
            .unknown => |value| self.logSupervisor(inst.component, inst.name, "{s}: unknown termination value {d}", .{ context, value }),
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
        self.clearPid(inst);
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

        var owned = try self.ownInstanceFields(
            component,
            name,
            health_endpoint,
            binary_path,
            working_dir,
            config_path,
            launch_command,
            launch_args,
        );
        errdefer owned.deinit(self.allocator);

        // Ensure logs directory exists and compute log file path
        const logs_dir = try self.p.instanceLogs(self.allocator, component, name);
        defer self.allocator.free(logs_dir);
        std_compat.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
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
            self.clearPid(&old_value);
            self.freeInstanceOwned(&old_value);
            self.allocator.free(old_entry.key);
        }

        const now = std_compat.time.milliTimestamp();
        try self.instances.put(key, .{
            .component = owned.component,
            .name = owned.name,
            .owns_memory = true,
            .status = .starting,
            .pid = result.pid,
            .child = result.child,
            .port = port,
            .health_endpoint = owned.health_endpoint,
            .binary_path = owned.binary_path,
            .working_dir = owned.working_dir,
            .config_path = owned.config_path,
            .launch_command = owned.launch_command,
            .launch_args = owned.launch_args,
            .started_at = now,
            .starting_since = now,
        });
        const inst = self.instances.getPtr(key).?;
        self.persistRuntimeState(inst);
        self.logSupervisor(inst.component, inst.name, "spawned pid={d}; status=starting; port={d}", .{ pidToU64(result.pid), port });
    }

    pub fn adoptInstance(
        self: *Manager,
        component: []const u8,
        name: []const u8,
        runtime: runtime_state.PersistedRuntime,
    ) !bool {
        const pid = process.reopenPersistedPid(runtime.pid) orelse return false;
        errdefer process.releasePidHandle(pid);

        if (!process.isAlive(pid)) return false;

        const key = try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ component, name });
        errdefer self.allocator.free(key);

        var owned = try self.ownInstanceFields(
            component,
            name,
            runtime.health_endpoint,
            runtime.binary_path,
            runtime.working_dir,
            runtime.config_path,
            runtime.launch_command,
            runtime.launch_args,
        );
        errdefer owned.deinit(self.allocator);

        const now = std_compat.time.milliTimestamp();
        const probe = if (runtime.port > 0)
            health.check(self.allocator, "127.0.0.1", runtime.port, runtime.health_endpoint)
        else
            health.HealthCheckResult{ .ok = true };

        const status: Status = if (runtime.port == 0 or probe.ok) .running else .starting;
        const starting_since = if (status == .starting)
            runtime.starting_since orelse runtime.started_at orelse now
        else
            null;
        const last_health_ok = if (status == .running) now else null;
        const last_health_check = if (runtime.port > 0 and probe.ok) now else null;

        if (self.instances.fetchRemove(key)) |old_entry| {
            var old_value = old_entry.value;
            self.shutdownInstance(&old_value, "adopt replace");
            self.freeInstanceOwned(&old_value);
            self.allocator.free(old_entry.key);
        }

        try self.instances.put(key, .{
            .component = owned.component,
            .name = owned.name,
            .owns_memory = true,
            .status = status,
            .pid = pid,
            .child = null,
            .port = runtime.port,
            .health_endpoint = owned.health_endpoint,
            .binary_path = owned.binary_path,
            .working_dir = owned.working_dir,
            .config_path = owned.config_path,
            .launch_command = owned.launch_command,
            .launch_args = owned.launch_args,
            .started_at = runtime.started_at orelse now,
            .starting_since = starting_since,
            .last_health_ok = last_health_ok,
            .last_health_check = last_health_check,
        });

        const inst = self.instances.getPtr(key).?;
        self.persistRuntimeState(inst);
        self.logSupervisor(
            inst.component,
            inst.name,
            "adopted existing pid={d}; status={s}; port={d}",
            .{ pidToU64(pid), @tagName(status), runtime.port },
        );
        return true;
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
                self.clearRuntimeState(inst.component, inst.name);
                self.logSupervisor(inst.component, inst.name, "stop requested while pid is null; marking stopped", .{});
            }
        }
    }

    /// Get status for a specific instance.
    pub fn getStatus(self: *Manager, component: []const u8, name: []const u8) ?InstanceStatus {
        const key_buf = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ component, name }) catch return null;
        defer self.allocator.free(key_buf);

        const inst = self.instances.get(key_buf) orelse return null;
        const now = std_compat.time.milliTimestamp();
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
            const now = std_compat.time.milliTimestamp();
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
        const now = std_compat.time.milliTimestamp();
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
                self.clearPid(inst);
                self.scheduleRestart(inst, now, "startup failed before readiness");
                return;
            }
        } else {
            self.logSupervisor(inst.component, inst.name, "startup failed: missing pid in starting state", .{});
            self.scheduleRestart(inst, now, "startup state lost pid before readiness");
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
                self.clearPid(inst);
                self.scheduleRestart(inst, now, "startup timed out waiting for health");
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
                self.clearPid(inst);
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
                self.clearPid(inst);
                self.scheduleRestart(inst, now, "health failure threshold reached");
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

        // Compute log file path for output redirect
        const logs_dir = self.p.instanceLogs(self.allocator, inst.component, inst.name) catch |err| {
            self.logSupervisor(inst.component, inst.name, "restart failed: cannot resolve logs dir: {s}", .{@errorName(err)});
            inst.status = .failed;
            return;
        };
        defer self.allocator.free(logs_dir);
        std_compat.fs.makeDirAbsolute(logs_dir) catch |err| switch (err) {
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
            .argv = inst.launch_args,
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
        self.persistRuntimeState(inst);
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
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();

    var mgr = Manager.init(allocator, fixture.paths);
    defer mgr.deinit();

    mgr.logSupervisor("nullclaw", "diag", "first diagnostic {d}", .{@as(u8, 1)});
    mgr.logSupervisor("nullclaw", "diag", "second diagnostic", .{});

    const logs_dir = try fixture.paths.instanceLogs(allocator, "nullclaw", "diag");
    defer allocator.free(logs_dir);
    const log_path = try std.fs.path.join(allocator, &.{ logs_dir, "nullhub.log" });
    defer allocator.free(log_path);

    var file = try std_compat.fs.openFileAbsolute(log_path, .{});
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
        .started_at = std_compat.time.milliTimestamp() - 5000, // started 5s ago
        .restart_count = 2,
        .health_consecutive_failures = 1,
        .last_health_ok = std_compat.time.milliTimestamp() - 1000,
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

test "restart preserves launch args with spaces" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();

    const script_path = try fixture.path(allocator, "capture-arg.sh");
    defer allocator.free(script_path);
    const output_path = try fixture.path(allocator, "captured.txt");
    defer allocator.free(output_path);

    const script =
        \\printf '%s\n' "$1" >> "$2"
        \\sleep 1
        \\
    ;
    const script_file = try std_compat.fs.createFileAbsolute(script_path, .{ .truncate = true });
    defer script_file.close();
    try script_file.writeAll(script);

    var mgr = Manager.init(allocator, fixture.paths);
    defer mgr.deinit();

    const launch_args = [_][]const u8{ script_path, "hello world", output_path };
    try mgr.startInstance("nullclaw", "argv", "/bin/sh", &launch_args, 0, "/health", "", "", "gateway");

    std.time.sleep(100 * std.time.ns_per_ms);
    mgr.tick();

    std.time.sleep(1200 * std.time.ns_per_ms);
    mgr.tick();
    mgr.tick();

    var attempts: usize = 0;
    var found = false;
    while (attempts < 20 and !found) : (attempts += 1) {
        const file = std_compat.fs.openFileAbsolute(output_path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                std.time.sleep(50 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        defer file.close();

        const contents = try file.readToEndAlloc(allocator, 1024);
        defer allocator.free(contents);

        if (std.mem.eql(u8, contents, "hello world\nhello world\n")) {
            found = true;
            break;
        }

        std.time.sleep(50 * std.time.ns_per_ms);
    }

    try std.testing.expect(found);
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
        .last_restart_attempt = std_compat.time.milliTimestamp(),
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
        .last_restart_attempt = std_compat.time.milliTimestamp() - 10_000, // well past any backoff
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

test "tick: starting instance without pid transitions to restarting" {
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
        .starting_since = std_compat.time.milliTimestamp(),
    });

    mgr.tick();

    const inst = mgr.instances.get("comp/dead-start").?;
    try std.testing.expectEqual(Status.restarting, inst.status);
}

test "tick: startup timeout transitions to restarting" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr-start-timeout");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    const spawned = try process.spawn(allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"60"},
    });

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "slow-start" });
    try mgr.instances.put(key, .{
        .component = "comp",
        .name = "slow-start",
        .status = .starting,
        .pid = spawned.pid,
        .child = spawned.child,
        .port = 6553,
        .health_endpoint = "/health",
        .binary_path = "/bin/sleep",
        .launch_args = &.{"60"},
        .starting_since = std_compat.time.milliTimestamp() - 60_000,
        .start_timeout_ms = 100,
        .max_restarts = 5,
    });

    mgr.tick();

    const inst = mgr.instances.get("comp/slow-start").?;
    try std.testing.expectEqual(Status.restarting, inst.status);
    try std.testing.expectEqual(@as(?std_compat.process.Child.Id, null), inst.pid);
}

test "tick: health failure threshold transitions to restarting" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var p = try paths_mod.Paths.init(allocator, "/tmp/test-nullhub-mgr-health-restart");
    defer p.deinit(allocator);

    var mgr = Manager.init(allocator, p);
    defer mgr.deinit();

    const spawned = try process.spawn(allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"60"},
    });

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "comp", "hung-http" });
    try mgr.instances.put(key, .{
        .component = "comp",
        .name = "hung-http",
        .status = .running,
        .pid = spawned.pid,
        .child = spawned.child,
        .port = 6554,
        .health_endpoint = "/health",
        .binary_path = "/bin/sleep",
        .launch_args = &.{"60"},
        .started_at = std_compat.time.milliTimestamp() - 60_000,
        .last_health_check = std_compat.time.milliTimestamp() - 60_000,
        .health_consecutive_failures = 2,
        .max_restarts = 5,
    });

    mgr.tick();

    const inst = mgr.instances.get("comp/hung-http").?;
    try std.testing.expectEqual(Status.restarting, inst.status);
    try std.testing.expectEqual(@as(?std_compat.process.Child.Id, null), inst.pid);
    try std.testing.expectEqual(@as(u32, 0), inst.health_consecutive_failures);
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
        .launch_args = &.{"60"},
        .last_restart_attempt = std_compat.time.milliTimestamp() - 10_000,
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
        .started_at = std_compat.time.milliTimestamp() - 60_000,
        .last_health_check = std_compat.time.milliTimestamp(),
    });

    mgr.tick();

    const inst = mgr.instances.get("comp/crashed").?;
    try std.testing.expectEqual(Status.restarting, inst.status);
}
