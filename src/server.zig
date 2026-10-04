const std = @import("std");
const std_compat = @import("compat");
const net_compat = @import("net_compat.zig");
const auth = @import("auth.zig");
const instances_api = @import("api/instances.zig");
const proxy_api = @import("api/proxy.zig");
const platform = @import("core/platform.zig");
const components_api = @import("api/components.zig");
const config_api = @import("api/config.zig");
const logs_api = @import("api/logs.zig");
const meta_api = @import("api/meta.zig");
const status_api = @import("api/status.zig");
const settings_api = @import("api/settings.zig");
const updates_api = @import("api/updates.zig");
const access = @import("access.zig");
const mdns_mod = @import("mdns.zig");
const state_mod = @import("core/state.zig");
const integration_mod = @import("core/integration.zig");
const paths_mod = @import("core/paths.zig");
const manager_mod = @import("supervisor/manager.zig");
const process_mod = @import("supervisor/process.zig");
const runtime_state_mod = @import("supervisor/runtime_state.zig");
const instance_runtime = @import("api/instance_runtime.zig");
const wizard_api = @import("api/wizard.zig");
const providers_api = @import("api/providers.zig");
const channels_api = @import("api/channels.zig");
const usage_api = @import("api/usage.zig");
const report_api = @import("api/report.zig");
const nullboiler_api = @import("api/nullboiler.zig");
const nulltickets_api = @import("api/nulltickets.zig");
const nullwatch_api = @import("api/nullwatch.zig");
const mission_control_api = @import("api/mission_control.zig");
const mission_core = @import("core/mission_control.zig");
const nullclaw_gateway_config = @import("core/nullclaw_gateway_config.zig");
const launch_args_mod = @import("core/launch_args.zig");
const ui_modules = @import("installer/ui_modules.zig");
const orchestrator = @import("installer/orchestrator.zig");
const registry = @import("installer/registry.zig");
const ui_assets = @import("ui_assets");
const version = @import("version.zig");
const test_helpers = @import("test_helpers.zig");

const default_max_request_size: usize = 64 * 1024;
const gateway_max_request_size: usize = @as(usize, @intCast(nullclaw_gateway_config.min_body_size));
const initial_request_buffer_size: usize = 64 * 1024;
const mission_workflow_evidence_ttl_ms: i64 = 5000;
const mission_workflow_scan_limit: usize = 50;
const mission_workflow_response_max_bytes: usize = 2 * 1024 * 1024;

const MissionWorkflowEvidenceCache = struct {
    mutex: std_compat.sync.Mutex = .{},
    arena: ?std.heap.ArenaAllocator = null,
    key: []const u8 = "",
    checked_at_ms: i64 = 0,
    evidence: mission_core.WorkflowEvidence = mission_core.workflowEvidenceUnavailable("not_checked"),

    fn deinit(self: *MissionWorkflowEvidenceCache) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.arena) |*arena| arena.deinit();
        self.arena = null;
        self.key = "";
        self.checked_at_ms = 0;
        self.evidence = mission_core.workflowEvidenceUnavailable("not_checked");
    }

    fn cloneFresh(self: *MissionWorkflowEvidenceCache, allocator: std.mem.Allocator, key: []const u8, now_ms: i64) ?mission_core.WorkflowEvidence {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.arena == null) return null;
        if (!std.mem.eql(u8, self.key, key)) return null;
        if (now_ms - self.checked_at_ms > mission_workflow_evidence_ttl_ms) return null;
        return mission_core.cloneWorkflowEvidence(allocator, self.evidence) catch
            mission_core.workflowEvidenceUnavailable("evidence_clone_failed");
    }

    fn replaceAndClone(
        self: *MissionWorkflowEvidenceCache,
        allocator: std.mem.Allocator,
        arena: std.heap.ArenaAllocator,
        key: []const u8,
        checked_at_ms: i64,
        evidence: mission_core.WorkflowEvidence,
    ) mission_core.WorkflowEvidence {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.arena) |*old| old.deinit();
        self.arena = arena;
        self.key = key;
        self.checked_at_ms = checked_at_ms;
        self.evidence = evidence;
        return mission_core.cloneWorkflowEvidence(allocator, self.evidence) catch
            mission_core.workflowEvidenceUnavailable("evidence_clone_failed");
    }
};

const MissionRunCandidate = struct {
    run: mission_core.WorkflowEvidenceRun,
    checkpoints: []const mission_core.WorkflowEvidenceCheckpoint,
};

pub const Server = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    access_options: access.Options = .{},
    access_publisher: ?*const mdns_mod.Publisher = null,
    auth_token: ?[]const u8 = null,
    extra_allowed_origins: []const []const u8 = &.{},
    state: *state_mod.State,
    paths: paths_mod.Paths,
    manager: *manager_mod.Manager,
    mutex: *std_compat.sync.Mutex,
    mission_control: mission_control_api.RuntimeStore = .{},
    mission_workflow_evidence_cache: MissionWorkflowEvidenceCache = .{},
    start_time: i64,
    /// Background UI-module backfill started by `startUiModuleSync`.
    ui_sync_thread: ?std.Thread = null,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, manager: *manager_mod.Manager, mutex: *std_compat.sync.Mutex) !Server {
        var paths = try paths_mod.Paths.init(allocator, null);
        errdefer paths.deinit(allocator);

        const state_path = try paths.state(allocator);
        defer allocator.free(state_path);

        const state = try allocator.create(state_mod.State);
        state.* = state_mod.State.load(allocator, state_path) catch |err| blk: {
            std.log.err("state.json load failed ({s}): starting with empty state — YOUR DATA MAY BE AT RISK", .{@errorName(err)});
            break :blk state_mod.State.init(allocator, state_path);
        };

        // UI module sync is deliberately NOT done here: both passes can run
        // `npm` and unbounded network requests, and `init` runs before
        // `listener.listen()`. See startUiModuleSync().
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .access_options = .{},
            .state = state,
            .paths = paths,
            .manager = manager,
            .mutex = mutex,
            .start_time = std_compat.time.timestamp(),
        };
    }

    /// Initialize a server with an explicit state and paths (used by tests).
    fn initWithState(allocator: std.mem.Allocator, state: *state_mod.State, paths: paths_mod.Paths, manager: *manager_mod.Manager, mutex: *std_compat.sync.Mutex) Server {
        return .{
            .allocator = allocator,
            .host = "127.0.0.1",
            .port = access.default_port,
            .access_options = .{},
            .state = state,
            .paths = paths,
            .manager = manager,
            .mutex = mutex,
            .start_time = std_compat.time.timestamp(),
        };
    }

    pub fn deinit(self: *Server) void {
        // The sync worker borrows `state`/`paths`, so it must finish before
        // they are freed. Bounded by the curl --max-time ceiling.
        if (self.ui_sync_thread) |thread| {
            thread.join();
            self.ui_sync_thread = null;
        }
        self.mission_workflow_evidence_cache.deinit();
        self.state.deinit();
        self.allocator.destroy(self.state);
        self.paths.deinit(self.allocator);
    }

    /// Backfill declared UI modules on a background thread.
    ///
    /// This used to run inline in `init()`, before `listener.listen()`: a
    /// stalled registry fetch could delay or prevent the hub from becoming
    /// reachable at all. Called from `run()` once we are accepting connections,
    /// so the worst case is a late-arriving module rather than an unavailable
    /// hub. Joined in `deinit()`.
    pub fn startUiModuleSync(self: *Server) void {
        if (self.ui_sync_thread != null) return;
        self.ui_sync_thread = std.Thread.spawn(.{}, uiModuleSyncWorker, .{self}) catch |err| {
            std.log.warn("ui module sync not started: {s}", .{@errorName(err)});
            return;
        };
    }

    fn uiModuleSyncWorker(self: *Server) void {
        orchestrator.syncLocalUiModules(self.allocator, self.paths);
        orchestrator.syncMissingUiModules(self.allocator, self.paths, self.state);
    }

    pub fn setAccessOptions(self: *Server, options: access.Options) void {
        self.access_options = options;
    }

    pub fn setAccessPublisher(self: *Server, publisher: *const mdns_mod.Publisher) void {
        self.access_publisher = publisher;
    }

    /// Configure additional origins (e.g. a Tailscale domain) allowed to call
    /// the nullhub API in addition to the bind host and the built-in local
    /// aliases. Each origin must be a scheme+host(+port) string with no
    /// trailing slash, e.g. `https://hub.tailnet.ts.net`.
    pub fn setExtraAllowedOrigins(self: *Server, origins: []const []const u8) void {
        self.extra_allowed_origins = origins;
    }

    fn currentAccessOptions(self: *const Server) access.Options {
        if (self.access_publisher) |publisher| {
            return publisher.accessOptions();
        }
        return self.access_options;
    }

    /// Restore managed runtime state for surviving processes, then start any
    /// remaining instances that are marked auto_start.
    pub fn reconcileInstancesOnBoot(self: *Server) void {
        var comp_it = self.state.instances.iterator();
        while (comp_it.next()) |comp_entry| {
            var inst_it = comp_entry.value_ptr.iterator();
            while (inst_it.next()) |inst_entry| {
                const comp_name = comp_entry.key_ptr.*;
                const inst_name = inst_entry.key_ptr.*;
                if (self.tryRestoreManagedInstance(comp_name, inst_name, inst_entry.value_ptr.*)) continue;
                if (!inst_entry.value_ptr.auto_start) continue;
                _ = instances_api.handleStart(self.allocator, self.state, self.manager, self.paths, comp_name, inst_name, "");
            }
        }
    }

    fn tryRestoreManagedInstance(
        self: *Server,
        component: []const u8,
        name: []const u8,
        entry: state_mod.InstanceEntry,
    ) bool {
        var runtime = runtime_state_mod.load(self.allocator, self.paths, component, name) catch |err| {
            if (err == error.InvalidRuntimeState) {
                runtime_state_mod.delete(self.allocator, self.paths, component, name);
            }
            return false;
        } orelse return false;
        defer runtime.deinit(self.allocator);

        const desired_binary = self.paths.binary(self.allocator, component, entry.version) catch {
            self.terminatePersistedRuntime(&runtime, component, name);
            return false;
        };
        defer self.allocator.free(desired_binary);

        var desired_launch = launch_args_mod.resolve(self.allocator, entry.launch_mode, entry.verbose) catch {
            self.terminatePersistedRuntime(&runtime, component, name);
            return false;
        };
        defer desired_launch.deinit();

        if (!persistedMatchesDesired(runtime, desired_binary, desired_launch.primary_command, desired_launch.argv)) {
            self.terminatePersistedRuntime(&runtime, component, name);
            return false;
        }

        const restored = self.manager.adoptInstance(component, name, runtime) catch return false;
        if (!restored) runtime_state_mod.delete(self.allocator, self.paths, component, name);
        return restored;
    }

    fn terminatePersistedRuntime(
        self: *Server,
        runtime: *runtime_state_mod.PersistedRuntime,
        component: []const u8,
        name: []const u8,
    ) void {
        if (process_mod.reopenPersistedPid(runtime.pid)) |pid| {
            defer process_mod.releasePidHandle(pid);
            if (process_mod.isAlive(pid)) {
                process_mod.terminate(pid) catch {};
                var attempts: usize = 0;
                while (attempts < 5 and process_mod.isAlive(pid)) : (attempts += 1) {
                    std_compat.thread.sleep(50 * std.time.ns_per_ms);
                }
                if (process_mod.isAlive(pid)) {
                    process_mod.forceKill(pid) catch {};
                }
            }
        }
        runtime_state_mod.delete(self.allocator, self.paths, component, name);
    }

    fn persistedMatchesDesired(
        runtime: runtime_state_mod.PersistedRuntime,
        desired_binary: []const u8,
        desired_command: []const u8,
        desired_args: []const []const u8,
    ) bool {
        if (!std.mem.eql(u8, runtime.binary_path, desired_binary)) return false;
        if (!std.mem.eql(u8, runtime.launch_command, desired_command)) return false;
        if (runtime.launch_args.len != desired_args.len) return false;
        for (runtime.launch_args, desired_args) |lhs, rhs| {
            if (!std.mem.eql(u8, lhs, rhs)) return false;
        }
        return true;
    }

    fn handleUiModules(self: *Server, allocator: std.mem.Allocator) Response {
        const ui_path = std.fs.path.join(allocator, &.{ self.paths.root, "ui" }) catch {
            return jsonResponse("{\"modules\":{}}");
        };
        defer allocator.free(ui_path);

        var dir = std_compat.fs.openDirAbsolute(ui_path, .{ .iterate = true }) catch {
            return jsonResponse("{\"modules\":{}}");
        };
        defer dir.close();

        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        var modules: std.ArrayListUnmanaged(struct { name: []u8, version: []u8 }) = .empty;
        defer {
            for (modules.items) |entry| {
                allocator.free(entry.name);
                allocator.free(entry.version);
            }
            modules.deinit(allocator);
        }

        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const at_idx = std.mem.indexOfScalar(u8, entry.name, '@') orelse continue;
            const mod_name = entry.name[0..at_idx];
            const mod_version = entry.name[at_idx + 1 ..];
            if (mod_name.len == 0 or mod_version.len == 0) continue;

            const module_dir = std.fs.path.join(allocator, &.{ ui_path, entry.name }) catch continue;
            defer allocator.free(module_dir);
            if (!ui_modules.isModuleInstalled(module_dir)) continue;

            var existing_index: ?usize = null;
            for (modules.items, 0..) |existing, index| {
                if (std.mem.eql(u8, existing.name, mod_name)) {
                    existing_index = index;
                    break;
                }
            }

            if (existing_index) |index| {
                if (preferUiModuleVersion(modules.items[index].version, mod_version)) {
                    const new_version = allocator.dupe(u8, mod_version) catch continue;
                    allocator.free(modules.items[index].version);
                    modules.items[index].version = new_version;
                }
                continue;
            }

            const owned_name = allocator.dupe(u8, mod_name) catch continue;
            const owned_version = allocator.dupe(u8, mod_version) catch {
                allocator.free(owned_name);
                continue;
            };

            modules.append(allocator, .{
                .name = owned_name,
                .version = owned_version,
            }) catch {
                allocator.free(owned_name);
                allocator.free(owned_version);
                continue;
            };
        }

        writer.writeAll("{\"modules\":{") catch return jsonResponse("{\"modules\":{}}");
        var first = true;
        for (modules.items) |entry| {
            if (!first) writer.writeAll(",") catch {};
            first = false;
            writer.print("\"{s}\":\"{s}\"", .{ entry.name, entry.version }) catch {};
        }
        writer.writeAll("}}") catch {};

        const json = allocator.dupe(u8, writer.buffered()) catch return jsonResponse("{\"modules\":{}}");
        return jsonResponse(json);
    }

    fn preferUiModuleVersion(current: []const u8, candidate: []const u8) bool {
        if (std.mem.eql(u8, candidate, "dev-local")) return !std.mem.eql(u8, current, "dev-local");
        if (std.mem.eql(u8, current, "dev-local")) return false;
        return std.mem.order(u8, candidate, current) == .gt;
    }

    fn handleAvailableUiModules(self: *Server, allocator: std.mem.Allocator) Response {
        _ = self;
        var buf: [4096]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&buf);
        writer.writeAll("[") catch return jsonResponse("[]");
        var first = true;
        for (&registry.known_components) |comp| {
            for (comp.ui_modules) |ui_mod| {
                if (!first) writer.writeAll(",") catch {};
                first = false;
                writer.print("{{\"name\":\"{s}\",\"repo\":\"{s}\",\"component\":\"{s}\"}}", .{ ui_mod.name, ui_mod.repo, comp.name }) catch {};
            }
        }
        writer.writeAll("]") catch {};
        const json = allocator.dupe(u8, writer.buffered()) catch return jsonResponse("[]");
        return jsonResponse(json);
    }

    fn handleInstallUiModule(self: *Server, allocator: std.mem.Allocator, mod_name: []const u8) Response {
        // Find the module in the registry
        var ui_mod_ref: ?registry.UiModuleRef = null;
        for (&registry.known_components) |comp| {
            for (comp.ui_modules) |ui_mod| {
                if (std.mem.eql(u8, ui_mod.name, mod_name)) {
                    ui_mod_ref = ui_mod;
                    break;
                }
            }
        }
        const ui_mod = ui_mod_ref orelse return .{
            .status = "404 Not Found",
            .content_type = "application/json",
            .body = "{\"error\":\"unknown module\"}",
        };
        orchestrator.installUiModule(allocator, self.paths, ui_mod, "latest") catch {
            return .{
                .status = "500 Internal Server Error",
                .content_type = "application/json",
                .body = "{\"error\":\"module install failed\"}",
            };
        };
        return jsonResponse("{\"status\":\"ok\"}");
    }

    fn handleUninstallUiModule(self: *Server, allocator: std.mem.Allocator, mod_name: []const u8) Response {
        // Scan ui/ dir for any version of this module
        const ui_path = std.fs.path.join(allocator, &.{ self.paths.root, "ui" }) catch {
            return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
        };
        defer allocator.free(ui_path);

        var dir = std_compat.fs.openDirAbsolute(ui_path, .{ .iterate = true }) catch {
            return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"not found\"}" };
        };
        defer dir.close();

        var deleted = false;
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const at_idx = std.mem.indexOfScalar(u8, entry.name, '@') orelse continue;
            if (std.mem.eql(u8, entry.name[0..at_idx], mod_name)) {
                dir.deleteTree(entry.name) catch continue;
                deleted = true;
            }
        }

        if (!deleted) {
            return .{ .status = "404 Not Found", .content_type = "application/json", .body = "{\"error\":\"module not installed\"}" };
        }
        return jsonResponse("{\"status\":\"ok\"}");
    }

    fn serveUiModuleFile(self: *Server, allocator: std.mem.Allocator, target: []const u8) Response {
        if (std.mem.indexOf(u8, target, "..") != null) {
            return .{ .status = "400 Bad Request", .content_type = "text/plain", .body = "bad request" };
        }

        const rel = if (target.len > 1) target[1..] else return .{
            .status = "404 Not Found",
            .content_type = "text/plain",
            .body = "not found",
        };
        const full_path = std.fs.path.join(allocator, &.{ self.paths.root, rel }) catch {
            return .{ .status = "500 Internal Server Error", .content_type = "text/plain", .body = "internal server error" };
        };
        defer allocator.free(full_path);

        const file = std_compat.fs.openFileAbsolute(full_path, .{}) catch {
            return .{ .status = "404 Not Found", .content_type = "text/plain", .body = "not found" };
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            return .{ .status = "500 Internal Server Error", .content_type = "text/plain", .body = "internal server error" };
        };

        return .{ .status = "200 OK", .content_type = contentType(full_path), .body = content };
    }

    pub fn run(self: *Server) !void {
        const addr = try std_compat.net.Address.resolveIp(self.host, self.port);
        var listener = try addr.listen(.{ .reuse_address = true });
        defer listener.deinit();

        std.debug.print("listening on http://{s}:{d}\n", .{ self.host, self.port });
        // Only now that we accept connections: best-effort UI module backfill.
        self.startUiModuleSync();
        var urls = access.buildAccessUrlsWithOptions(self.allocator, self.host, self.port, self.currentAccessOptions()) catch null;
        defer if (urls) |*u| u.deinit(self.allocator);
        if (urls) |u| {
            if (u.local_alias_chain and u.public_alias_active) {
                std.debug.print("access chain: {s} -> {s} -> {s} (alias via {s})\n", .{ u.public_alias_url.?, u.canonical_url, u.fallback_url, u.public_alias_provider });
            } else if (u.local_alias_chain) {
                std.debug.print("access chain: {s} -> {s} -> {s}\n", .{ u.public_alias_url.?, u.canonical_url, u.fallback_url });
            } else {
                std.debug.print("access url: {s}\n", .{u.browser_open_url});
            }
        }

        while (true) {
            const conn = listener.accept() catch |err| {
                std.debug.print("accept error: {}\n", .{err});
                continue;
            };

            {
                defer conn.stream.close();

                var arena = std.heap.ArenaAllocator.init(self.allocator);
                defer arena.deinit();

                self.handleConnection(conn, arena.allocator()) catch |err| {
                    std.debug.print("request error: {}\n", .{err});
                };
            }
        }
    }

    fn handleConnection(self: *Server, conn: std_compat.net.Server.Connection, alloc: std.mem.Allocator) !void {
        var req_buf: [initial_request_buffer_size]u8 = undefined;
        const n = net_compat.streamRead(conn.stream, &req_buf) catch return;
        if (n == 0) return;
        const raw = req_buf[0..n];

        // Parse request line
        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;

        const extra_origins = self.extra_allowed_origins;

        if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) {
            if (try self.redirectLocationForAliasHost(alloc, raw, target)) |location| {
                defer alloc.free(location);
                try sendRedirect(conn.stream, location, raw, self.host, self.port, extra_origins);
                return;
            }
        }

        if (!requestOriginAllowed(raw, target, self.host, self.port, extra_origins)) {
            try sendResponse(conn.stream, .{
                .status = "403 Forbidden",
                .content_type = "application/json",
                .body = "{\"error\":\"forbidden origin\"}",
            }, raw, self.host, self.port, extra_origins);
            return;
        }

        // Handle OPTIONS preflight
        if (std.mem.eql(u8, method, "OPTIONS")) {
            try sendResponse(conn.stream, .{
                .status = "204 No Content",
                .content_type = "text/plain",
                .body = "",
            }, raw, self.host, self.port, extra_origins);
            return;
        }

        // Auth check for protected API paths
        if (self.auth_token != null and !auth.isPublicPath(target)) {
            if (!auth.checkAuth(raw, self.auth_token)) {
                try sendResponse(conn.stream, .{
                    .status = "401 Unauthorized",
                    .content_type = "application/json",
                    .body = "{\"error\":\"unauthorized\"}",
                }, raw, self.host, self.port, extra_origins);
                return;
            }
        }

        // Read remaining body only after origin and auth are accepted.
        const body = readBody(raw, n, conn.stream, alloc, maxRequestBodySize(target)) catch |err| {
            const response = switch (err) {
                error.RequestTooLarge => Response{
                    .status = "413 Request Entity Too Large",
                    .content_type = "application/json",
                    .body = "{\"error\":\"request body too large\"}",
                },
                error.IncompleteBody, error.InvalidContentLength => Response{
                    .status = "400 Bad Request",
                    .content_type = "application/json",
                    .body = "{\"error\":\"invalid request body\"}",
                },
                else => return err,
            };
            try sendResponse(conn.stream, response, raw, self.host, self.port, extra_origins);
            return;
        };

        if (instances_api.isGatewayProxyPath(target)) {
            const prepared = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk instances_api.prepareGatewayProxy(alloc, self.state, self.manager, self.paths, method, target, body);
            };
            switch (prepared) {
                .no_match => {},
                .response => |response| {
                    try sendResponse(conn.stream, .{ .status = response.status, .content_type = response.content_type, .body = response.body }, raw, self.host, self.port, extra_origins);
                    return;
                },
                .upstream => |upstream| {
                    defer upstream.deinit(alloc);
                    const cors_headers = try buildCorsHeaders(alloc, raw, self.host, self.port, extra_origins);
                    defer alloc.free(cors_headers);
                    const base_url = try std.fmt.allocPrint(alloc, "http://127.0.0.1:{d}", .{upstream.port});
                    defer alloc.free(base_url);
                    const proxy_options = proxy_api.ForwardOptions{
                        .method = method,
                        .base_url = base_url,
                        .path = upstream.upstream_path,
                        .body = upstream.body,
                        .bearer_token = upstream.token,
                        .accept = if (upstream.event_stream) "text/event-stream" else null,
                        .unreachable_body = "{\"error\":\"nullclaw gateway unreachable\"}",
                    };
                    if (upstream.event_stream) {
                        try proxy_api.forwardStream(alloc, proxy_options, conn.stream, cors_headers);
                    } else {
                        const proxied = proxy_api.forward(alloc, proxy_options);
                        try sendResponse(conn.stream, .{ .status = proxied.status, .content_type = proxied.content_type, .body = proxied.body }, raw, self.host, self.port, extra_origins);
                    }
                    return;
                },
            }
        }

        // Route dispatch (lock mutex so supervisor thread doesn't race)
        const response = if (routeWithoutServerMutex(target))
            self.route(alloc, method, target, body)
        else blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.route(alloc, method, target, body);
        };
        try sendResponse(conn.stream, response, raw, self.host, self.port, extra_origins);
    }

    fn redirectLocationForAliasHost(self: *const Server, allocator: std.mem.Allocator, raw: []const u8, target: []const u8) !?[]u8 {
        if (!access.isLocalBindHost(self.host)) return null;

        const host_header = extractHeader(raw, "Host") orelse return null;
        if (!hostMatchesAliasHost(host_header, access.public_alias_host)) return null;
        if (target.len == 0 or target[0] != '/') return null;

        return try std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{
            access.canonical_local_host,
            self.port,
            target,
        });
    }

    // std.posix.getenv is unavailable on Windows (WTF-16 encoding).
    // Orchestration proxy requires Unix — returns null on Windows.
    fn getEnv(name: []const u8) ?[]const u8 {
        const native = @import("builtin").os.tag;
        if (native == .windows) return null;
        const name_z: [*:0]const u8 = if (std.mem.eql(u8, name, "NULLBOILER_URL"))
            "NULLBOILER_URL"
        else if (std.mem.eql(u8, name, "NULLBOILER_TOKEN"))
            "NULLBOILER_TOKEN"
        else if (std.mem.eql(u8, name, "NULLTICKETS_URL"))
            "NULLTICKETS_URL"
        else if (std.mem.eql(u8, name, "NULLTICKETS_TOKEN"))
            "NULLTICKETS_TOKEN"
        else if (std.mem.eql(u8, name, "NULLWATCH_URL"))
            "NULLWATCH_URL"
        else if (std.mem.eql(u8, name, "NULLWATCH_TOKEN"))
            "NULLWATCH_TOKEN"
        else
            return null;
        return if (std.c.getenv(name_z)) |value| std.mem.span(value) else null;
    }

    fn getBoilerUrl(self: *Server) ?[]const u8 {
        _ = self;
        return getEnv("NULLBOILER_URL");
    }

    fn getBoilerToken(self: *Server) ?[]const u8 {
        _ = self;
        return getEnv("NULLBOILER_TOKEN");
    }

    fn getTicketsUrl(self: *Server) ?[]const u8 {
        _ = self;
        return getEnv("NULLTICKETS_URL");
    }

    fn getTicketsToken(self: *Server) ?[]const u8 {
        _ = self;
        return getEnv("NULLTICKETS_TOKEN");
    }

    const ManagedBackendConfig = struct {
        name: []u8,
        url: []u8,
        token: ?[]u8 = null,

        fn deinit(self: *ManagedBackendConfig, allocator: std.mem.Allocator) void {
            allocator.free(self.name);
            allocator.free(self.url);
            if (self.token) |token| allocator.free(token);
            self.* = undefined;
        }
    };

    fn resolveManagedBackend(self: *Server, allocator: std.mem.Allocator, component: []const u8, requested_name: ?[]const u8) ?ManagedBackendConfig {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (std.mem.eql(u8, component, "nullboiler")) {
            const configs = integration_mod.listNullBoilers(allocator, self.state, self.paths) catch return null;
            defer integration_mod.deinitNullBoilerConfigs(allocator, configs);
            return self.resolveManagedBackendFromConfigs(allocator, "nullboiler", requested_name, configs);
        }

        if (std.mem.eql(u8, component, "nulltickets")) {
            const configs = integration_mod.listNullTickets(allocator, self.state, self.paths) catch return null;
            defer integration_mod.deinitNullTicketsConfigs(allocator, configs);
            return self.resolveManagedBackendFromConfigs(allocator, "nulltickets", requested_name, configs);
        }

        return null;
    }

    fn resolveManagedBackendFromConfigs(self: *Server, allocator: std.mem.Allocator, component: []const u8, requested_name: ?[]const u8, configs: anytype) ?ManagedBackendConfig {
        if (configs.len == 0) return null;
        if (requested_name) |wanted| {
            for (configs) |cfg| {
                if (std.mem.eql(u8, cfg.name, wanted)) {
                    return managedBackendFromConfig(allocator, cfg.name, cfg.port, cfg.api_token);
                }
            }
            return null;
        }

        const selected = self.selectManagedBackendIndex(component, configs);
        return managedBackendFromConfig(allocator, configs[selected].name, configs[selected].port, configs[selected].api_token);
    }

    fn selectManagedBackendIndex(self: *Server, component: []const u8, configs: anytype) usize {
        var fallback: usize = 0;
        for (configs, 0..) |cfg, idx| {
            if (std.mem.eql(u8, cfg.name, "default")) fallback = idx;
            const status = self.manager.getStatus(component, cfg.name) orelse continue;
            if (status.status == .running) return idx;
        }
        return fallback;
    }

    fn managedBackendFromConfig(allocator: std.mem.Allocator, name: []const u8, port: u16, token: ?[]const u8) ?ManagedBackendConfig {
        const owned_name = allocator.dupe(u8, name) catch return null;
        const url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{port}) catch {
            allocator.free(owned_name);
            return null;
        };
        const owned_token = if (token) |value| allocator.dupe(u8, value) catch {
            allocator.free(owned_name);
            allocator.free(url);
            return null;
        } else null;
        return .{
            .name = owned_name,
            .url = url,
            .token = owned_token,
        };
    }

    fn ownedManagedBackend(allocator: std.mem.Allocator, name: []const u8, url: []const u8, token: ?[]const u8) !ManagedBackendConfig {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        const owned_url = try allocator.dupe(u8, url);
        errdefer allocator.free(owned_url);
        const owned_token = if (token) |value| try allocator.dupe(u8, value) else null;
        errdefer if (owned_token) |value| allocator.free(value);
        return .{
            .name = owned_name,
            .url = owned_url,
            .token = owned_token,
        };
    }

    fn deinitManagedBackendConfigs(allocator: std.mem.Allocator, configs: []ManagedBackendConfig) void {
        for (configs) |*cfg| cfg.deinit(allocator);
        allocator.free(configs);
    }

    fn appendUniqueManagedBackend(
        allocator: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(ManagedBackendConfig),
        backend: ManagedBackendConfig,
    ) !void {
        var owned = backend;
        errdefer owned.deinit(allocator);
        for (list.items) |item| {
            if (std.mem.eql(u8, item.url, owned.url)) {
                owned.deinit(allocator);
                return;
            }
        }
        try list.append(allocator, owned);
    }

    fn appendManagedNullBoilerBackends(self: *Server, allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(ManagedBackendConfig)) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const configs = try integration_mod.listNullBoilers(allocator, self.state, self.paths);
        defer integration_mod.deinitNullBoilerConfigs(allocator, configs);

        const before_running = list.items.len;
        try self.appendManagedBackendPass(allocator, list, "nullboiler", configs, true);
        if (list.items.len == before_running) {
            try self.appendManagedBackendPass(allocator, list, "nullboiler", configs, false);
        }
    }

    fn appendManagedBackendPass(
        self: *Server,
        allocator: std.mem.Allocator,
        list: *std.ArrayListUnmanaged(ManagedBackendConfig),
        component: []const u8,
        configs: anytype,
        running_pass: bool,
    ) !void {
        for (configs) |cfg| {
            const status = self.manager.getStatus(component, cfg.name);
            const running = if (status) |value| value.status == .running else false;
            if (running != running_pass) continue;
            const backend = managedBackendFromConfig(allocator, cfg.name, cfg.port, cfg.api_token) orelse return error.OutOfMemory;
            try appendUniqueManagedBackend(allocator, list, backend);
        }
    }

    fn missionWorkflowBackends(self: *Server, allocator: std.mem.Allocator) ![]ManagedBackendConfig {
        var list: std.ArrayListUnmanaged(ManagedBackendConfig) = .empty;
        errdefer {
            for (list.items) |*cfg| cfg.deinit(allocator);
            list.deinit(allocator);
        }
        defer list.deinit(allocator);

        if (self.getBoilerUrl()) |url| {
            const env_backend = try ownedManagedBackend(allocator, "env", url, self.getBoilerToken());
            try appendUniqueManagedBackend(allocator, &list, env_backend);
        }
        try self.appendManagedNullBoilerBackends(allocator, &list);
        return try list.toOwnedSlice(allocator);
    }

    fn shouldResolveManagedBackend(env_url: ?[]const u8, requested_name: ?[]const u8) bool {
        return requested_name != null or env_url == null;
    }

    fn selectBackendUrl(env_url: ?[]const u8, managed: ?ManagedBackendConfig, requested_name: ?[]const u8) ?[]const u8 {
        if (requested_name != null) return if (managed) |cfg| cfg.url else null;
        return env_url orelse if (managed) |cfg| cfg.url else null;
    }

    fn selectBackendToken(env_token: ?[]const u8, managed: ?ManagedBackendConfig, requested_name: ?[]const u8) ?[]const u8 {
        if (requested_name != null) return if (managed) |cfg| cfg.token else null;
        return env_token orelse if (managed) |cfg| cfg.token else null;
    }

    fn resolveMissionWorkflowEvidence(self: *Server, request_allocator: std.mem.Allocator, refs: mission_core.WorkflowEvidenceRefs) mission_core.WorkflowEvidence {
        const now_ms = std_compat.time.milliTimestamp();
        const backends = self.missionWorkflowBackends(request_allocator) catch
            return mission_core.workflowEvidenceUnavailable("nullboiler_backend_discovery_failed");
        defer deinitManagedBackendConfigs(request_allocator, backends);

        const cache_key = missionWorkflowEvidenceCacheKey(request_allocator, refs, backends) catch
            return mission_core.workflowEvidenceUnavailable("cache_key_allocation_failed");
        defer request_allocator.free(cache_key);

        if (self.mission_workflow_evidence_cache.cloneFresh(request_allocator, cache_key, now_ms)) |cached| return cached;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        const owned_key = allocator.dupe(u8, cache_key) catch
            return mission_core.workflowEvidenceUnavailable("cache_key_allocation_failed");
        const evidence = self.loadMissionWorkflowEvidence(allocator, refs, backends);
        return self.mission_workflow_evidence_cache.replaceAndClone(request_allocator, arena, owned_key, now_ms, evidence);
    }

    fn loadMissionWorkflowEvidence(
        self: *Server,
        allocator: std.mem.Allocator,
        refs: mission_core.WorkflowEvidenceRefs,
        backends: []const ManagedBackendConfig,
    ) mission_core.WorkflowEvidence {
        if (backends.len == 0) return missionWorkflowEvidenceStatus("not_configured", "nullboiler_not_configured", 0);

        var available: ?mission_core.WorkflowEvidence = null;
        var best_not_found: ?mission_core.WorkflowEvidence = null;
        var best_unavailable: ?mission_core.WorkflowEvidence = null;
        var scanned_run_count: usize = 0;

        for (backends) |backend| {
            const evidence = self.loadMissionWorkflowEvidenceFromBackend(allocator, refs, backend);
            scanned_run_count += evidence.scanned_run_count;
            if (std.mem.eql(u8, evidence.status, "available")) {
                if (available != null) {
                    return missionWorkflowEvidenceStatus("ambiguous", "workflow_evidence_matched_multiple_backends", scanned_run_count);
                }
                available = evidence;
                continue;
            }
            if (std.mem.eql(u8, evidence.status, "ambiguous")) return evidence;
            if (std.mem.eql(u8, evidence.status, "not_found")) {
                if (best_not_found == null or evidence.scanned_run_count > best_not_found.?.scanned_run_count) best_not_found = evidence;
                continue;
            }
            if (best_unavailable == null) best_unavailable = evidence;
        }

        if (available) |evidence| return evidence;
        if (best_not_found) |evidence| return evidence;
        if (best_unavailable) |evidence| return evidence;
        return missionWorkflowEvidenceStatus("not_configured", "nullboiler_not_configured", 0);
    }

    fn loadMissionWorkflowEvidenceFromBackend(
        self: *Server,
        allocator: std.mem.Allocator,
        refs: mission_core.WorkflowEvidenceRefs,
        backend: ManagedBackendConfig,
    ) mission_core.WorkflowEvidence {
        var scratch_arena = std.heap.ArenaAllocator.init(self.allocator);
        defer scratch_arena.deinit();
        const scratch_allocator = scratch_arena.allocator();

        const runs_resp = proxy_api.forward(scratch_allocator, .{
            .method = "GET",
            .base_url = backend.url,
            .path = "/runs?limit=50",
            .body = "",
            .bearer_token = backend.token,
            .unreachable_body = "{\"error\":\"NullBoiler unreachable\"}",
            .max_response_bytes = mission_workflow_response_max_bytes,
        });
        if (!isSuccessStatus(runs_resp.status)) {
            return missionWorkflowEvidenceWithBackendName(allocator, missionWorkflowEvidenceStatus("unavailable", "nullboiler_runs_unavailable", 0), backend.name);
        }

        const parsed_runs = std.json.parseFromSlice(std.json.Value, scratch_allocator, runs_resp.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return missionWorkflowEvidenceWithBackendName(allocator, missionWorkflowEvidenceStatus("schema_mismatch", "invalid_runs_payload", 0), backend.name);
        defer parsed_runs.deinit();

        const items = missionWorkflowRunItems(parsed_runs.value) orelse
            return missionWorkflowEvidenceWithBackendName(allocator, missionWorkflowEvidenceStatus("schema_mismatch", "missing_runs_items", 0), backend.name);

        var candidates: std.ArrayListUnmanaged(MissionRunCandidate) = .empty;
        for (items[0..@min(items.len, mission_workflow_scan_limit)]) |item| {
            const run_id = jsonStringField(item, "id");
            if (run_id.len == 0) continue;

            const loaded_checkpoints: ?[]const mission_core.WorkflowEvidenceCheckpoint =
                self.loadMissionRunCheckpoints(allocator, scratch_allocator, backend.url, backend.token, run_id) catch null;
            const checkpoints = loaded_checkpoints orelse &.{};
            const evidence_run = mission_core.WorkflowEvidenceRun{
                .run_id = allocator.dupe(u8, run_id) catch
                    return missionWorkflowEvidenceWithBackendName(allocator, missionWorkflowEvidenceStatus("unavailable", "run_id_allocation_failed", candidates.items.len), backend.name),
                .status = allocator.dupe(u8, jsonStringFieldOr(item, "status", "unknown")) catch
                    return missionWorkflowEvidenceWithBackendName(allocator, missionWorkflowEvidenceStatus("unavailable", "run_status_allocation_failed", candidates.items.len), backend.name),
                .created_at_ms = jsonIntField(item, "created_at_ms"),
                .updated_at_ms = jsonIntField(item, "updated_at_ms"),
                .checkpoint_count = if (loaded_checkpoints != null) checkpoints.len else null,
            };
            candidates.append(allocator, .{ .run = evidence_run, .checkpoints = checkpoints }) catch
                return missionWorkflowEvidenceWithBackendName(allocator, missionWorkflowEvidenceStatus("unavailable", "candidate_allocation_failed", candidates.items.len), backend.name);
        }

        return missionWorkflowEvidenceWithBackendName(allocator, selectMissionWorkflowEvidence(refs, candidates.items), backend.name);
    }

    fn loadMissionRunCheckpoints(
        self: *Server,
        allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        base_url: []const u8,
        token: ?[]const u8,
        run_id: []const u8,
    ) ![]const mission_core.WorkflowEvidenceCheckpoint {
        _ = self;
        const path = try missionRunCheckpointsPath(scratch_allocator, run_id);
        const resp = proxy_api.forward(scratch_allocator, .{
            .method = "GET",
            .base_url = base_url,
            .path = path,
            .body = "",
            .bearer_token = token,
            .unreachable_body = "{\"error\":\"NullBoiler unreachable\"}",
            .max_response_bytes = mission_workflow_response_max_bytes,
        });
        if (!isSuccessStatus(resp.status)) return error.CheckpointsUnavailable;

        const parsed = std.json.parseFromSlice(std.json.Value, scratch_allocator, resp.body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return error.InvalidCheckpointPayload;
        defer parsed.deinit();
        if (parsed.value != .array) return error.InvalidCheckpointPayload;

        var checkpoints: std.ArrayListUnmanaged(mission_core.WorkflowEvidenceCheckpoint) = .empty;
        for (parsed.value.array.items) |item| {
            if (try normalizeMissionCheckpoint(allocator, item, run_id)) |checkpoint| {
                try checkpoints.append(allocator, checkpoint);
            }
        }
        return try checkpoints.toOwnedSlice(allocator);
    }

    const WatchTarget = struct {
        url: ?[]const u8 = null,
        url_owned: bool = false,
        token: ?[]const u8 = null,
        token_owned: bool = false,

        fn deinit(self: WatchTarget, allocator: std.mem.Allocator) void {
            if (self.url_owned) if (self.url) |value| allocator.free(value);
            if (self.token_owned) if (self.token) |value| allocator.free(value);
        }
    };

    const WatchCandidate = struct {
        name: []const u8,
        port: u16,
    };

    const WatchCandidateSelection = struct {
        running: ?WatchCandidate = null,
        starting: ?WatchCandidate = null,
        selected: ?WatchCandidate = null,

        fn prefer(current: ?WatchCandidate, next: WatchCandidate) WatchCandidate {
            const existing = current orelse return next;
            return if (std.mem.order(u8, next.name, existing.name) == .lt) next else existing;
        }

        fn add(self: *@This(), selected_name: ?[]const u8, candidate: WatchCandidate, status: manager_mod.Status) void {
            if (candidate.port == 0) return;

            switch (status) {
                .running => {
                    if (selected_name) |name| {
                        if (std.mem.eql(u8, name, candidate.name)) self.selected = candidate;
                    }
                    self.running = prefer(self.running, candidate);
                },
                .starting, .restarting => {
                    if (selected_name) |name| {
                        if (std.mem.eql(u8, name, candidate.name)) self.selected = candidate;
                    }
                    self.starting = prefer(self.starting, candidate);
                },
                .stopped, .stopping, .failed => {},
            }
        }
    };

    fn getWatchTarget(self: *Server, allocator: std.mem.Allocator, selected_name: ?[]const u8) WatchTarget {
        const env_token = getEnv("NULLWATCH_TOKEN");
        if (selected_name == null) {
            if (getEnv("NULLWATCH_URL")) |url| return .{ .url = url, .token = env_token };
        }
        return self.getManagedWatchTarget(allocator, env_token, selected_name) catch .{ .token = env_token };
    }

    fn getManagedWatchTarget(self: *Server, allocator: std.mem.Allocator, token_override: ?[]const u8, selected_name: ?[]const u8) !WatchTarget {
        var candidates = WatchCandidateSelection{};

        if (self.state.instances.getPtr("nullwatch")) |watch_instances| {
            var state_it = watch_instances.iterator();
            while (state_it.next()) |entry| {
                const snapshot = instance_runtime.resolve(
                    allocator,
                    self.paths,
                    self.manager,
                    "nullwatch",
                    entry.key_ptr.*,
                    entry.value_ptr.*,
                );
                candidates.add(selected_name, .{ .name = entry.key_ptr.*, .port = snapshot.port }, snapshot.status);
            }
        }

        var manager_it = self.manager.instances.iterator();
        while (manager_it.next()) |entry| {
            const inst = entry.value_ptr.*;
            if (!std.mem.eql(u8, inst.component, "nullwatch")) continue;
            candidates.add(selected_name, .{ .name = inst.name, .port = inst.port }, inst.status);
        }

        if (selected_name != null) {
            if (candidates.selected) |candidate| {
                return try self.buildManagedWatchTarget(allocator, candidate.name, candidate.port, token_override);
            }
            return .{ .token = token_override };
        }
        if (candidates.running) |candidate| {
            return try self.buildManagedWatchTarget(allocator, candidate.name, candidate.port, token_override);
        }
        if (candidates.starting) |candidate| {
            return try self.buildManagedWatchTarget(allocator, candidate.name, candidate.port, token_override);
        }
        return .{ .token = token_override };
    }

    fn buildManagedWatchTarget(self: *Server, allocator: std.mem.Allocator, name: []const u8, port: u16, token_override: ?[]const u8) !WatchTarget {
        var cfg = (try integration_mod.loadNullWatchConfig(allocator, self.paths, name)) orelse blk: {
            const cfg_name = try allocator.dupe(u8, name);
            errdefer allocator.free(cfg_name);
            const cfg_host = try allocator.dupe(u8, "127.0.0.1");
            break :blk integration_mod.NullWatchConfig{
                .name = cfg_name,
                .host = cfg_host,
            };
        };
        defer integration_mod.deinitNullWatchConfig(allocator, &cfg);
        cfg.port = port;

        var target = WatchTarget{};
        errdefer target.deinit(allocator);
        target.url = try integration_mod.buildNullWatchEndpoint(allocator, cfg);
        target.url_owned = true;
        if (token_override) |token| {
            target.token = token;
        } else if (cfg.api_token) |token| {
            target.token = try allocator.dupe(u8, token);
            target.token_owned = true;
        }
        return target;
    }

    fn routeWithoutServerMutex(target: []const u8) bool {
        return instances_api.isIntegrationPath(target) or
            instances_api.isTicketsActionPath(target) or
            logs_api.isLogsPath(target) or
            nullboiler_api.isProxyPath(target) or
            nulltickets_api.isProxyPath(target) or
            nullwatch_api.isProxyPath(target) or
            mission_control_api.isPath(target);
    }

    fn route(self: *Server, allocator: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) Response {
        if (mission_control_api.isPath(target)) {
            const resp = mission_control_api.handleWithIntegrations(allocator, method, target, &self.mission_control, .{
                .paths = self.paths,
                .workflow_evidence_resolver = .{
                    .ptr = self,
                    .resolve = missionWorkflowEvidenceResolver,
                },
            });
            return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
        }

        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, target, "/health")) {
                return .{
                    .status = "200 OK",
                    .content_type = "application/json",
                    .body = "{\"status\":\"ok\"}",
                };
            }
            if (std.mem.eql(u8, target, "/api/status")) {
                const now = std_compat.time.timestamp();
                const uptime: u64 = @intCast(@max(0, now - self.start_time));
                const resp = status_api.handleStatus(allocator, self.state, self.manager, self.paths, uptime, self.host, self.port, self.currentAccessOptions());
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
            if (meta_api.isRoutesPath(target)) {
                const resp = meta_api.handleRoutes(allocator);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
            if (std.mem.eql(u8, target, "/api/components")) {
                if (components_api.handleList(allocator, self.state)) |json| {
                    return .{
                        .status = "200 OK",
                        .content_type = "application/json",
                        .body = json,
                    };
                } else |_| {
                    return .{
                        .status = "500 Internal Server Error",
                        .content_type = "application/json",
                        .body = "{\"error\":\"internal server error\"}",
                    };
                }
            }
            if (components_api.isManifestPath(target)) {
                if (components_api.extractComponentName(target)) |comp_name| {
                    if (components_api.handleManifest(allocator, comp_name)) |maybe_json| {
                        if (maybe_json) |json| {
                            return .{
                                .status = "200 OK",
                                .content_type = "application/json",
                                .body = json,
                            };
                        }
                    } else |_| {}
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"manifest not found\"}",
                };
            }
            if (std.mem.eql(u8, target, "/api/free-port")) {
                if (wizard_api.handleFreePort(allocator)) |json| {
                    return jsonResponse(json);
                } else |_| {
                    return jsonResponse("{\"port\":3000}");
                }
            }
            if (std.mem.eql(u8, target, "/api/updates")) {
                const ur = updates_api.handleCheckUpdates(allocator, self.state);
                return .{ .status = ur.status, .content_type = ur.content_type, .body = ur.body };
            }
            if (std.mem.eql(u8, target, "/api/ui-modules")) {
                return self.handleUiModules(allocator);
            }
            if (std.mem.eql(u8, target, "/api/ui-modules/available")) {
                return self.handleAvailableUiModules(allocator);
            }
            if (std.mem.eql(u8, target, "/api/report/meta")) {
                const resp = report_api.handleMeta(allocator);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
        }

        // UI module install/uninstall
        if (std.mem.startsWith(u8, target, "/api/ui-modules/") and !std.mem.eql(u8, target, "/api/ui-modules/available")) {
            const rest = target["/api/ui-modules/".len..];
            if (std.mem.eql(u8, method, "POST") and std.mem.endsWith(u8, rest, "/install")) {
                const mod_name = rest[0 .. rest.len - "/install".len];
                if (mod_name.len > 0) {
                    return self.handleInstallUiModule(allocator, mod_name);
                }
            }
            if (std.mem.eql(u8, method, "DELETE")) {
                if (rest.len > 0 and std.mem.indexOfScalar(u8, rest, '/') == null) {
                    return self.handleUninstallUiModule(allocator, rest);
                }
            }
        }

        if (std.mem.eql(u8, method, "POST")) {
            if (std.mem.eql(u8, target, "/api/components/refresh")) {
                if (components_api.handleRefresh(allocator)) |json| {
                    return .{
                        .status = "200 OK",
                        .content_type = "application/json",
                        .body = json,
                    };
                } else |_| {
                    return .{
                        .status = "500 Internal Server Error",
                        .content_type = "application/json",
                        .body = "{\"error\":\"internal server error\"}",
                    };
                }
            }
            if (std.mem.eql(u8, target, "/api/report")) {
                const resp = report_api.handleSubmit(allocator, body);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
            if (std.mem.eql(u8, target, "/api/report/preview")) {
                const resp = report_api.handlePreview(allocator, body);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
        }

        // Global Usage API
        if (std.mem.eql(u8, target, "/api/usage") or std.mem.startsWith(u8, target, "/api/usage?")) {
            if (std.mem.eql(u8, method, "GET")) {
                const resp = usage_api.handleGlobalUsage(allocator, self.state, self.paths, target);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }

        // Settings API
        if (std.mem.eql(u8, target, "/api/settings")) {
            if (std.mem.eql(u8, method, "GET")) {
                if (settings_api.handleGetSettings(allocator, self.host, self.port, self.currentAccessOptions())) |json| {
                    return jsonResponse(json);
                } else |_| {
                    return .{
                        .status = "500 Internal Server Error",
                        .content_type = "application/json",
                        .body = "{\"error\":\"internal server error\"}",
                    };
                }
            }
            if (std.mem.eql(u8, method, "PUT")) {
                if (settings_api.handlePutSettings(allocator, body)) |resp| {
                    return .{
                        .status = resp.status,
                        .content_type = resp.content_type,
                        .body = resp.body,
                    };
                } else |_| {
                    return .{
                        .status = "500 Internal Server Error",
                        .content_type = "application/json",
                        .body = "{\"error\":\"internal server error\"}",
                    };
                }
            }
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }

        // Service API
        if (std.mem.eql(u8, target, "/api/service/install")) {
            if (std.mem.eql(u8, method, "POST")) {
                if (settings_api.handleServiceInstall(allocator)) |json| {
                    return jsonResponse(json);
                } else |_| {
                    return .{
                        .status = "500 Internal Server Error",
                        .content_type = "application/json",
                        .body = "{\"error\":\"internal server error\"}",
                    };
                }
            }
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }
        if (std.mem.eql(u8, target, "/api/service/uninstall")) {
            if (std.mem.eql(u8, method, "POST")) {
                if (settings_api.handleServiceUninstall(allocator)) |json| {
                    return jsonResponse(json);
                } else |_| {
                    return .{
                        .status = "500 Internal Server Error",
                        .content_type = "application/json",
                        .body = "{\"error\":\"internal server error\"}",
                    };
                }
            }
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }
        if (std.mem.eql(u8, target, "/api/service/status")) {
            if (std.mem.eql(u8, method, "GET")) {
                if (settings_api.handleServiceStatus(allocator)) |json| {
                    return jsonResponse(json);
                } else |_| {
                    return .{
                        .status = "500 Internal Server Error",
                        .content_type = "application/json",
                        .body = "{\"error\":\"internal server error\"}",
                    };
                }
            }
            return .{
                .status = "405 Method Not Allowed",
                .content_type = "application/json",
                .body = "{\"error\":\"method not allowed\"}",
            };
        }

        // Validate Providers API — POST /api/wizard/{component}/validate-providers
        if (std.mem.eql(u8, method, "POST") and wizard_api.isValidateProvidersPath(target)) {
            if (wizard_api.extractComponentName(target)) |comp_name| {
                if (wizard_api.handleValidateProviders(allocator, comp_name, body, self.paths, self.state)) |json| {
                    const status = if (std.mem.indexOf(u8, json, "\"error\"") != null)
                        "400 Bad Request"
                    else
                        "200 OK";
                    return .{
                        .status = status,
                        .content_type = "application/json",
                        .body = json,
                    };
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"component not found\"}",
                };
            }
        }

        // Validate Channels API — POST /api/wizard/{component}/validate-channels
        if (std.mem.eql(u8, method, "POST") and wizard_api.isValidateChannelsPath(target)) {
            if (wizard_api.extractComponentName(target)) |comp_name| {
                if (wizard_api.handleValidateChannels(allocator, comp_name, body, self.paths, self.state)) |json| {
                    const status = if (std.mem.indexOf(u8, json, "\"error\"") != null)
                        "400 Bad Request"
                    else
                        "200 OK";
                    return .{
                        .status = status,
                        .content_type = "application/json",
                        .body = json,
                    };
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"component not found\"}",
                };
            }
        }

        // Versions API — GET /api/wizard/{component}/versions
        if (std.mem.eql(u8, method, "GET") and wizard_api.isVersionsPath(target)) {
            if (wizard_api.extractComponentName(target)) |comp_name| {
                if (wizard_api.handleGetVersions(allocator, comp_name)) |json| {
                    return .{
                        .status = "200 OK",
                        .content_type = "application/json",
                        .body = json,
                    };
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"component not found\"}",
                };
            }
        }

        // Models API — GET/POST /api/wizard/{component}/models
        if ((std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "POST")) and wizard_api.isModelsPath(target)) {
            if (wizard_api.extractComponentName(target)) |comp_name| {
                const json = if (std.mem.eql(u8, method, "POST"))
                    wizard_api.handlePostModels(allocator, comp_name, self.paths, body)
                else
                    wizard_api.handleGetModels(allocator, comp_name, self.paths, target);
                if (json) |payload| {
                    const status = if (std.mem.indexOf(u8, payload, "\"error\"") != null)
                        "400 Bad Request"
                    else
                        "200 OK";
                    return .{
                        .status = status,
                        .content_type = "application/json",
                        .body = payload,
                    };
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"component not found or models unavailable\"}",
                };
            }
        }

        // Wizard API
        if (wizard_api.isWizardPath(target)) {
            if (wizard_api.extractComponentName(target)) |comp_name| {
                if (std.mem.eql(u8, method, "GET")) {
                    if (wizard_api.handleGetWizard(allocator, comp_name, target, self.paths, self.state)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null)
                            "400 Bad Request"
                        else
                            "200 OK";
                        return .{
                            .status = status,
                            .content_type = "application/json",
                            .body = json,
                        };
                    }
                    return .{
                        .status = "404 Not Found",
                        .content_type = "application/json",
                        .body = "{\"error\":\"component not found\"}",
                    };
                }
                if (std.mem.eql(u8, method, "POST")) {
                    if (wizard_api.handlePostWizard(allocator, comp_name, body, self.paths, self.state, self.manager)) |json| {
                        // Check if the response is an error
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null)
                            "400 Bad Request"
                        else
                            "200 OK";
                        return .{
                            .status = status,
                            .content_type = "application/json",
                            .body = json,
                        };
                    }
                    return .{
                        .status = "404 Not Found",
                        .content_type = "application/json",
                        .body = "{\"error\":\"component not found\"}",
                    };
                }
                return .{
                    .status = "405 Method Not Allowed",
                    .content_type = "application/json",
                    .body = "{\"error\":\"method not allowed\"}",
                };
            }
        }

        // Providers API — /api/providers[/{id}[/validate]]
        if (providers_api.isProvidersPath(target)) {
            if (std.mem.eql(u8, target, "/api/providers") or std.mem.startsWith(u8, target, "/api/providers?")) {
                if (std.mem.eql(u8, method, "GET")) {
                    const reveal = providers_api.hasRevealParam(target);
                    if (providers_api.handleList(allocator, self.state, reveal)) |json| {
                        return jsonResponse(json);
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "POST")) {
                    if (providers_api.handleCreate(allocator, body, self.state, self.paths)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "422 Unprocessable Entity" else "201 Created";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
            }
            // /api/providers/probe-models — probe a custom endpoint before saving
            if (providers_api.isProbeModelsPath(target)) {
                if (std.mem.eql(u8, method, "GET")) {
                    if (providers_api.handleProbeModels(allocator, target)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "400 Bad Request" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "POST")) {
                    if (providers_api.handleProbeModelsBody(allocator, body)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "400 Bad Request" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
            }
            // Routes with ID: /api/providers/{id} and /api/providers/{id}/validate
            if (providers_api.extractProviderId(target)) |id| {
                if (providers_api.isValidatePath(target)) {
                    if (std.mem.eql(u8, method, "POST")) {
                        if (providers_api.handleValidate(allocator, id, self.state, self.paths)) |json| {
                            const status = if (std.mem.indexOf(u8, json, "\"error\"") != null or
                                std.mem.indexOf(u8, json, "\"live_ok\":false") != null)
                                "422 Unprocessable Entity"
                            else
                                "200 OK";
                            return .{ .status = status, .content_type = "application/json", .body = json };
                        } else |_| {
                            return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                        }
                    }
                    return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
                }
                if (std.mem.eql(u8, method, "PUT")) {
                    if (providers_api.handleUpdate(allocator, id, body, self.state, self.paths)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "422 Unprocessable Entity" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "DELETE")) {
                    if (providers_api.handleDelete(allocator, id, self.state)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "404 Not Found" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
            }
        }

        // Channels API — /api/channels[/{id}[/validate]]
        if (channels_api.isChannelsPath(target)) {
            if (std.mem.eql(u8, target, "/api/channels") or std.mem.startsWith(u8, target, "/api/channels?")) {
                if (std.mem.eql(u8, method, "GET")) {
                    const reveal = channels_api.hasRevealParam(target);
                    if (channels_api.handleList(allocator, self.state, reveal)) |json| {
                        return jsonResponse(json);
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "POST")) {
                    if (channels_api.handleCreate(allocator, body, self.state, self.paths)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "422 Unprocessable Entity" else "201 Created";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
            }
            if (channels_api.extractChannelId(target)) |id| {
                if (channels_api.isValidatePath(target)) {
                    if (std.mem.eql(u8, method, "POST")) {
                        if (channels_api.handleValidate(allocator, id, self.state, self.paths)) |json| {
                            const status = if (std.mem.indexOf(u8, json, "\"error\"") != null or
                                std.mem.indexOf(u8, json, "\"live_ok\":false") != null)
                                "422 Unprocessable Entity"
                            else
                                "200 OK";
                            return .{ .status = status, .content_type = "application/json", .body = json };
                        } else |_| {
                            return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                        }
                    }
                    return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
                }
                if (std.mem.eql(u8, method, "PUT")) {
                    if (channels_api.handleUpdate(allocator, id, body, self.state, self.paths)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "422 Unprocessable Entity" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "DELETE")) {
                    if (channels_api.handleDelete(allocator, id, self.state)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "404 Not Found" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
            }
        }

        // Config API — /api/instances/{c}/{n}/config
        if (config_api.isConfigPath(target)) {
            const parsed_owned = config_api.parseConfigPathAlloc(allocator, target) catch |err| switch (err) {
                error.InvalidPathSegment => return .{ .status = "400 Bad Request", .content_type = "application/json", .body = "{\"error\":\"invalid path segment\"}" },
                else => return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" },
            };
            if (parsed_owned) |parsed_storage| {
                defer parsed_storage.deinit(allocator);
                const parsed = parsed_storage.borrowed();
                if (std.mem.eql(u8, method, "GET")) {
                    const resp = config_api.handleGetManaged(allocator, self.state, self.paths, parsed.component, parsed.name, target);
                    return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
                }
                if (std.mem.eql(u8, method, "PUT")) {
                    const resp = config_api.handlePut(allocator, self.paths, parsed.component, parsed.name, body);
                    return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
                }
                if (std.mem.eql(u8, method, "PATCH")) {
                    const resp = config_api.handlePatch(allocator, self.paths, parsed.component, parsed.name, body);
                    return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
                }
                return .{
                    .status = "405 Method Not Allowed",
                    .content_type = "application/json",
                    .body = "{\"error\":\"method not allowed\"}",
                };
            }
        }

        // Logs API — /api/instances/{c}/{n}/logs and /api/instances/{c}/{n}/logs/stream
        if (logs_api.isLogsPath(target)) {
            const parsed_owned = logs_api.parseLogsPathAlloc(allocator, target) catch |err| switch (err) {
                error.InvalidPathSegment => return .{ .status = "400 Bad Request", .content_type = "application/json", .body = "{\"error\":\"invalid path segment\"}" },
                else => return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" },
            };
            if (parsed_owned) |parsed_storage| {
                defer parsed_storage.deinit(allocator);
                const parsed = parsed_storage.borrowed();
                if (std.mem.eql(u8, method, "DELETE")) {
                    const source = logs_api.parseSource(target);
                    const resp = logs_api.handleDelete(allocator, self.paths, parsed.component, parsed.name, source);
                    return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
                }
                if (!std.mem.eql(u8, method, "GET")) {
                    return .{
                        .status = "405 Method Not Allowed",
                        .content_type = "application/json",
                        .body = "{\"error\":\"method not allowed\"}",
                    };
                }
                if (parsed.is_stream) {
                    const max_lines = logs_api.parseLines(target);
                    const source = logs_api.parseSource(target);
                    const resp = logs_api.handleStream(allocator, self.paths, parsed.component, parsed.name, max_lines, source);
                    return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
                }
                const max_lines = logs_api.parseLines(target);
                const source = logs_api.parseSource(target);
                const resp = logs_api.handleGet(allocator, self.paths, parsed.component, parsed.name, max_lines, source);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
        }

        // Instances API — delegate to instances_api.dispatch and updates_api.
        if (std.mem.startsWith(u8, target, "/api/instances")) {
            // Updates API — POST /api/instances/{c}/{n}/update
            const update_owned = updates_api.parseUpdatePathAlloc(allocator, target) catch |err| switch (err) {
                error.InvalidPathSegment => return .{ .status = "400 Bad Request", .content_type = "application/json", .body = "{\"error\":\"invalid path segment\"}" },
                else => return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" },
            };
            if (update_owned) |update_storage| {
                defer update_storage.deinit(allocator);
                const up = update_storage.borrowed();
                if (std.mem.eql(u8, method, "POST")) {
                    const ur = updates_api.handleApplyUpdateRuntime(
                        allocator,
                        self.state,
                        self.manager,
                        self.paths,
                        up.component,
                        up.name,
                    );
                    return .{ .status = ur.status, .content_type = ur.content_type, .body = ur.body };
                }
                return .{
                    .status = "405 Method Not Allowed",
                    .content_type = "application/json",
                    .body = "{\"error\":\"method not allowed\"}",
                };
            }
            if (instances_api.dispatch(allocator, self.state, self.manager, self.mutex, self.paths, method, target, body)) |api_resp| {
                return .{ .status = api_resp.status, .content_type = api_resp.content_type, .body = api_resp.body };
            }
        }

        if (nullboiler_api.isProxyPath(target)) {
            const env_boiler_url = self.getBoilerUrl();
            const env_boiler_token = self.getBoilerToken();
            const requested_boiler = nullboiler_api.requestedBoilerInstance(allocator, target) catch null;
            defer if (requested_boiler) |value| allocator.free(value);

            var managed_boiler = if (shouldResolveManagedBackend(env_boiler_url, requested_boiler))
                self.resolveManagedBackend(allocator, "nullboiler", requested_boiler)
            else
                null;
            defer if (managed_boiler) |*cfg| cfg.deinit(allocator);

            const resp = nullboiler_api.handle(allocator, method, target, body, .{
                .boiler_url = selectBackendUrl(env_boiler_url, managed_boiler, requested_boiler),
                .boiler_token = selectBackendToken(env_boiler_token, managed_boiler, requested_boiler),
            });
            return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
        }

        if (nulltickets_api.isProxyPath(target)) {
            const env_tickets_url = self.getTicketsUrl();
            const env_tickets_token = self.getTicketsToken();
            const requested_tickets = nulltickets_api.requestedTicketsInstance(allocator, target) catch null;
            defer if (requested_tickets) |value| allocator.free(value);

            var managed_tickets = if (shouldResolveManagedBackend(env_tickets_url, requested_tickets))
                self.resolveManagedBackend(allocator, "nulltickets", requested_tickets)
            else
                null;
            defer if (managed_tickets) |*cfg| cfg.deinit(allocator);

            const resp = nulltickets_api.handle(allocator, method, target, body, .{
                .tickets_url = selectBackendUrl(env_tickets_url, managed_tickets, requested_tickets),
                .tickets_token = selectBackendToken(env_tickets_token, managed_tickets, requested_tickets),
            });
            return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
        }

        if (nullwatch_api.isProxyPath(target)) {
            const selected_watch = nullwatch_api.selectedWatchNameAlloc(allocator, target) catch
                return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
            defer if (selected_watch) |value| allocator.free(value);

            const watch_target = blk: {
                self.mutex.lock();
                defer self.mutex.unlock();
                break :blk self.getWatchTarget(allocator, selected_watch);
            };
            defer watch_target.deinit(allocator);

            const resp = nullwatch_api.handle(allocator, method, target, body, .{
                .watch_url = watch_target.url,
                .watch_token = watch_target.token,
            });
            return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
        }

        // Serve UI module files from data directory (~/.nullhub/ui/{name}@{version}/...)
        if (!auth.isApiPath(target) and std.mem.startsWith(u8, target, "/ui/")) {
            // Check if this looks like a module path: /ui/{name}@{version}/...
            if (target.len > 4) {
                const after_ui = target[4..]; // after "/ui/"
                if (std.mem.indexOfScalar(u8, after_ui, '@') != null) {
                    return self.serveUiModuleFile(allocator, target);
                }
            }
        }

        // For non-API paths, attempt to serve static files from the embedded UI bundle.
        if (!auth.isApiPath(target)) {
            return serveStaticFile(allocator, target);
        }

        return .{
            .status = "404 Not Found",
            .content_type = "application/json",
            .body = "{\"error\":\"not found\"}",
        };
    }
};

fn missionWorkflowEvidenceResolver(ptr: *anyopaque, allocator: std.mem.Allocator, refs: mission_core.WorkflowEvidenceRefs) mission_core.WorkflowEvidence {
    const server: *Server = @ptrCast(@alignCast(ptr));
    return server.resolveMissionWorkflowEvidence(allocator, refs);
}

fn missionWorkflowEvidenceCacheKey(
    allocator: std.mem.Allocator,
    refs: mission_core.WorkflowEvidenceRefs,
    backends: []const Server.ManagedBackendConfig,
) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice(refs.scenario_id);
    try buf.append('|');
    try buf.appendSlice(refs.mission_id);
    try buf.append('|');
    try buf.appendSlice(refs.failed_run_id);
    try buf.append('|');
    try buf.appendSlice(refs.recovered_run_id);
    try buf.append('|');
    try buf.appendSlice(refs.checkpoint_id);
    for (backends) |backend| {
        try buf.appendSlice("|backend=");
        try buf.appendSlice(backend.name);
        try buf.append('@');
        try buf.appendSlice(backend.url);
        try buf.append('#');
        try appendTokenFingerprint(&buf, backend.token);
    }
    return try buf.toOwnedSlice();
}

fn appendTokenFingerprint(buf: *std.array_list.Managed(u8), token: ?[]const u8) !void {
    const value = token orelse {
        try buf.append('-');
        return;
    };
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(value, &digest, .{});
    const hex = "0123456789abcdef";
    for (digest) |byte| {
        try buf.append(hex[byte >> 4]);
        try buf.append(hex[byte & 0x0f]);
    }
}

fn missionWorkflowEvidenceStatus(status: []const u8, reason: []const u8, scanned_run_count: usize) mission_core.WorkflowEvidence {
    return .{
        .status = status,
        .reason = reason,
        .scanned_run_count = scanned_run_count,
    };
}

fn missionWorkflowEvidenceWithBackendName(allocator: std.mem.Allocator, evidence: mission_core.WorkflowEvidence, backend_name: ?[]const u8) mission_core.WorkflowEvidence {
    var out = evidence;
    if (backend_name) |name| {
        out.boiler_instance = allocator.dupe(u8, name) catch null;
    }
    return out;
}

fn missionWorkflowRunItems(value: std.json.Value) ?[]std.json.Value {
    if (value == .array) return value.array.items;
    if (value != .object) return null;
    const items = value.object.get("items") orelse value.object.get("runs") orelse return null;
    if (items != .array) return null;
    return items.array.items;
}

fn missionRunCheckpointsPath(allocator: std.mem.Allocator, run_id: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("/runs/");
    try appendUrlPathSegment(&buf, run_id);
    try buf.appendSlice("/checkpoints");
    return try buf.toOwnedSlice();
}

fn appendUrlPathSegment(buf: *std.array_list.Managed(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~') {
            try buf.append(byte);
        } else {
            try buf.append('%');
            try buf.append(hex[byte >> 4]);
            try buf.append(hex[byte & 0x0f]);
        }
    }
}

fn isSuccessStatus(status: []const u8) bool {
    return status.len >= 1 and status[0] == '2';
}

fn normalizeMissionCheckpoint(allocator: std.mem.Allocator, item: std.json.Value, default_run_id: []const u8) !?mission_core.WorkflowEvidenceCheckpoint {
    const id = jsonStringField(item, "id");
    if (id.len == 0) return null;
    const run_id = jsonStringFieldOr(item, "run_id", default_run_id);
    return .{
        .id = try allocator.dupe(u8, id),
        .run_id = try allocator.dupe(u8, run_id),
        .step_id = try allocator.dupe(u8, firstJsonStringField(item, &.{ "step_id", "step_name", "after_step" })),
        .parent_id = try cloneOptionalWorkflowString(allocator, firstJsonOptionalStringField(item, &.{ "parent_id", "parent_checkpoint_id", "forked_from", "source_checkpoint_id" })),
        .version = jsonIntField(item, "version"),
        .created_at_ms = jsonIntField(item, "created_at_ms"),
        .completed_nodes = try jsonStringArrayFields(allocator, item, &.{ "completed_nodes", "completed_nodes_json" }),
        .metadata = try jsonCheckpointMetadata(allocator, item),
    };
}

fn cloneOptionalWorkflowString(allocator: std.mem.Allocator, value: ?[]const u8) !?[]const u8 {
    if (value) |text| return try allocator.dupe(u8, text);
    return null;
}

fn selectMissionWorkflowEvidence(refs: mission_core.WorkflowEvidenceRefs, candidates: []const MissionRunCandidate) mission_core.WorkflowEvidence {
    const checkpoint_match = findUniqueCheckpointById(candidates, refs.checkpoint_id) catch
        return missionWorkflowEvidenceStatus("ambiguous", "checkpoint_id_matched_multiple_runs", candidates.len);
    const failed_exact = findCandidateByRunId(candidates, refs.failed_run_id) catch
        return missionWorkflowEvidenceStatus("ambiguous", "failed_run_id_matched_multiple_runs", candidates.len);
    const recovered_exact = findCandidateByRunId(candidates, refs.recovered_run_id) catch
        return missionWorkflowEvidenceStatus("ambiguous", "recovered_run_id_matched_multiple_runs", candidates.len);
    const fork_match = if (checkpoint_match.checkpoint) |checkpoint|
        findUniqueForkCandidate(candidates, checkpoint.id) catch
            return missionWorkflowEvidenceStatus("ambiguous", "fork_parent_matched_multiple_runs", candidates.len)
    else
        MissionCandidateMatch{};

    var failed_run: ?mission_core.WorkflowEvidenceRun = null;
    if (failed_exact.candidate) |candidate| failed_run = candidate.run;
    if (checkpoint_match.candidate) |candidate| {
        if (failed_run) |run| {
            if (!std.mem.eql(u8, run.run_id, candidate.run.run_id)) {
                return missionWorkflowEvidenceStatus("ambiguous", "failed_run_checkpoint_owner_mismatch", candidates.len);
            }
        } else {
            failed_run = candidate.run;
        }
    }

    var recovered_run: ?mission_core.WorkflowEvidenceRun = null;
    if (recovered_exact.candidate) |candidate| recovered_run = candidate.run;
    if (fork_match.candidate) |candidate| {
        if (recovered_run) |run| {
            if (!std.mem.eql(u8, run.run_id, candidate.run.run_id)) {
                return missionWorkflowEvidenceStatus("ambiguous", "recovered_run_fork_owner_mismatch", candidates.len);
            }
        } else {
            recovered_run = candidate.run;
        }
    }

    if (failed_run == null and recovered_run == null and checkpoint_match.checkpoint == null) {
        return missionWorkflowEvidenceStatus("not_found", "no_matching_run_or_checkpoint", candidates.len);
    }

    return .{
        .status = "available",
        .failed_run = failed_run,
        .recovered_run = recovered_run,
        .checkpoint = checkpoint_match.checkpoint,
        .scanned_run_count = candidates.len,
    };
}

const MissionCandidateMatch = struct {
    candidate: ?MissionRunCandidate = null,
    checkpoint: ?mission_core.WorkflowEvidenceCheckpoint = null,
};

fn findCandidateByRunId(candidates: []const MissionRunCandidate, run_id: []const u8) !MissionCandidateMatch {
    if (run_id.len == 0) return .{};
    var match: ?MissionRunCandidate = null;
    for (candidates) |candidate| {
        if (!std.mem.eql(u8, candidate.run.run_id, run_id)) continue;
        if (match != null) return error.Ambiguous;
        match = candidate;
    }
    return .{ .candidate = match };
}

fn findUniqueCheckpointById(candidates: []const MissionRunCandidate, checkpoint_id: []const u8) !MissionCandidateMatch {
    if (checkpoint_id.len == 0) return .{};
    var found_candidate: ?MissionRunCandidate = null;
    var found_checkpoint: ?mission_core.WorkflowEvidenceCheckpoint = null;
    for (candidates) |candidate| {
        for (candidate.checkpoints) |checkpoint| {
            if (!std.mem.eql(u8, checkpoint.id, checkpoint_id)) continue;
            if (found_checkpoint != null) return error.Ambiguous;
            found_candidate = candidate;
            found_checkpoint = checkpoint;
        }
    }
    return .{ .candidate = found_candidate, .checkpoint = found_checkpoint };
}

fn findUniqueForkCandidate(candidates: []const MissionRunCandidate, checkpoint_id: []const u8) !MissionCandidateMatch {
    if (checkpoint_id.len == 0) return .{};
    var found: ?MissionRunCandidate = null;
    for (candidates) |candidate| {
        for (candidate.checkpoints) |checkpoint| {
            const parent_id = checkpoint.parent_id orelse continue;
            if (!std.mem.eql(u8, parent_id, checkpoint_id)) continue;
            if (found != null and !std.mem.eql(u8, found.?.run.run_id, candidate.run.run_id)) return error.Ambiguous;
            found = candidate;
        }
    }
    return .{ .candidate = found };
}

fn jsonStringField(value: std.json.Value, key: []const u8) []const u8 {
    if (value != .object) return "";
    return switch (value.object.get(key) orelse .null) {
        .string => |string| string,
        .number_string => |string| string,
        else => "",
    };
}

fn jsonStringFieldOr(value: std.json.Value, key: []const u8, default: []const u8) []const u8 {
    const string = jsonStringField(value, key);
    return if (string.len > 0) string else default;
}

fn firstJsonStringField(value: std.json.Value, keys: []const []const u8) []const u8 {
    for (keys) |key| {
        const string = jsonStringField(value, key);
        if (string.len > 0) return string;
    }
    return "";
}

fn firstJsonOptionalStringField(value: std.json.Value, keys: []const []const u8) ?[]const u8 {
    const string = firstJsonStringField(value, keys);
    return if (string.len > 0) string else null;
}

fn jsonOptionalValueField(value: std.json.Value, key: []const u8) ?std.json.Value {
    if (value != .object) return null;
    const field = value.object.get(key) orelse return null;
    if (field == .null) return null;
    return field;
}

fn jsonIntField(value: std.json.Value, key: []const u8) ?i64 {
    if (value != .object) return null;
    return switch (value.object.get(key) orelse .null) {
        .integer => |integer| integer,
        .number_string => |string| std.fmt.parseInt(i64, string, 10) catch null,
        .string => |string| std.fmt.parseInt(i64, string, 10) catch null,
        else => null,
    };
}

fn jsonStringArrayFields(allocator: std.mem.Allocator, value: std.json.Value, keys: []const []const u8) ![]const []const u8 {
    if (value != .object) return &.{};
    for (keys) |key| {
        if (value.object.get(key)) |field| {
            if (field == .null) continue;
            return try jsonStringArrayValue(allocator, field);
        }
    }
    return &.{};
}

fn jsonStringArrayValue(allocator: std.mem.Allocator, value: std.json.Value) anyerror![]const []const u8 {
    switch (value) {
        .array => |array| return try cloneJsonStringArray(allocator, array.items),
        .string => |string| return try jsonStringArrayFromEncodedValue(allocator, string),
        .number_string => |string| return try jsonStringArrayFromEncodedValue(allocator, string),
        else => return &.{},
    }
}

fn jsonStringArrayFromEncodedValue(allocator: std.mem.Allocator, text: []const u8) anyerror![]const []const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return &.{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return &.{},
    };
    defer parsed.deinit();
    return try jsonStringArrayValue(allocator, parsed.value);
}

fn cloneJsonStringArray(allocator: std.mem.Allocator, items: []const std.json.Value) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }
    for (items) |item| {
        if (item == .string) try list.append(allocator, try allocator.dupe(u8, item.string));
    }
    if (list.items.len == 0) {
        list.deinit(allocator);
        return &.{};
    }
    return try list.toOwnedSlice(allocator);
}

fn jsonCheckpointMetadata(allocator: std.mem.Allocator, value: std.json.Value) !?std.json.Value {
    if (jsonOptionalValueField(value, "metadata")) |metadata| {
        return try mission_core.cloneJsonValue(allocator, metadata);
    }
    const encoded = jsonOptionalValueField(value, "metadata_json") orelse return null;
    return try cloneJsonEncodedOrRawValue(allocator, encoded);
}

fn cloneJsonEncodedOrRawValue(allocator: std.mem.Allocator, value: std.json.Value) !?std.json.Value {
    return switch (value) {
        .string => |string| try parseJsonValueString(allocator, string),
        .number_string => |string| try parseJsonValueString(allocator, string),
        .null => null,
        else => try mission_core.cloneJsonValue(allocator, value),
    };
}

fn parseJsonValueString(allocator: std.mem.Allocator, text: []const u8) !?std.json.Value {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len == 0) return null;
    return std.json.parseFromSliceLeaky(std.json.Value, allocator, trimmed, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

test "normalizeMissionCheckpoint accepts encoded NullBoiler checkpoint fields" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const payload =
        \\{
        \\  "id": "cp-a",
        \\  "step_name": "code.build",
        \\  "parent_checkpoint_id": "cp-parent",
        \\  "completed_nodes_json": "[\"claim\",\"code\"]",
        \\  "metadata_json": "{\"source\":\"nullboiler\",\"attempt\":2}"
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{ .allocate = .alloc_always });
    const checkpoint = (try normalizeMissionCheckpoint(allocator, parsed.value, "run-a")).?;

    try std.testing.expectEqualStrings("cp-a", checkpoint.id);
    try std.testing.expectEqualStrings("run-a", checkpoint.run_id);
    try std.testing.expectEqualStrings("code.build", checkpoint.step_id);
    try std.testing.expectEqualStrings("cp-parent", checkpoint.parent_id.?);
    try std.testing.expectEqual(@as(usize, 2), checkpoint.completed_nodes.len);
    try std.testing.expectEqualStrings("claim", checkpoint.completed_nodes[0]);
    try std.testing.expectEqualStrings("code", checkpoint.completed_nodes[1]);
    try std.testing.expectEqualStrings("nullboiler", checkpoint.metadata.?.object.get("source").?.string);
}

const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

fn jsonResponse(body: []const u8) Response {
    return .{ .status = "200 OK", .content_type = "application/json", .body = body };
}

fn maxRequestBodySize(target: []const u8) usize {
    if (instances_api.isGatewayProxyPath(target)) return gateway_max_request_size;
    return default_max_request_size;
}

fn readBody(raw: []const u8, n: usize, stream: std_compat.net.Stream, alloc: std.mem.Allocator, max_body_size: usize) ![]const u8 {
    if (extractHeader(raw, "Content-Length")) |cl_str| {
        const content_length = std.fmt.parseInt(usize, cl_str, 10) catch return error.InvalidContentLength;
        if (content_length > max_body_size) return error.RequestTooLarge;
        if (content_length == 0) return "";

        const header_end_pos = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return error.IncompleteBody;
        const body_start = header_end_pos + 4;
        const body_received = n - body_start;
        if (body_received >= content_length) {
            return raw[body_start .. body_start + content_length];
        }
        // Need to read more data from the stream
        const total_size = body_start + content_length;
        const full_buf = try alloc.alloc(u8, total_size);
        @memcpy(full_buf[0..n], raw);
        var total_read = n;
        while (total_read < total_size) {
            const extra = try net_compat.streamRead(stream, full_buf[total_read..total_size]);
            if (extra == 0) return error.IncompleteBody;
            total_read += extra;
        }
        return full_buf[body_start..total_size];
    }
    return extractBody(raw);
}

fn sendResponse(stream: std_compat.net.Stream, response: Response, raw_request: []const u8, bind_host: []const u8, port: u16, extra_origins: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.print("HTTP/1.1 {s}\r\n", .{response.status});
    try writer.print("Content-Type: {s}\r\n", .{response.content_type});
    try writer.print("Content-Length: {d}\r\n", .{response.body.len});
    try appendCorsHeaders(&writer, raw_request, bind_host, port, extra_origins);
    try writer.writeAll("Connection: close\r\n\r\n");

    if (response.body.len <= buf.len - writer.buffered().len) {
        try writer.writeAll(response.body);
        try net_compat.streamWriteAll(stream, writer.buffered());
        return;
    }

    try net_compat.streamWriteAll(stream, writer.buffered());
    if (response.body.len > 0) {
        try net_compat.streamWriteAll(stream, response.body);
    }
}

fn sendRedirect(stream: std_compat.net.Stream, location: []const u8, raw_request: []const u8, bind_host: []const u8, port: u16, extra_origins: []const []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buf);

    try writer.writeAll("HTTP/1.1 308 Permanent Redirect\r\n");
    try writer.print("Location: {s}\r\n", .{location});
    try writer.writeAll("Content-Length: 0\r\n");
    try appendCorsHeaders(&writer, raw_request, bind_host, port, extra_origins);
    try writer.writeAll("Connection: close\r\n\r\n");

    try net_compat.streamWriteAll(stream, writer.buffered());
}

pub fn extractBody(raw: []const u8) []const u8 {
    if (std.mem.indexOf(u8, raw, "\r\n\r\n")) |pos| {
        const body_start = pos + 4;
        if (body_start < raw.len) {
            return raw[body_start..];
        }
    }
    return "";
}

pub fn extractHeader(raw: []const u8, name: []const u8) ?[]const u8 {
    const header_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    const headers = raw[0..header_end];
    var lines = std.mem.splitSequence(u8, headers, "\r\n");
    _ = lines.next(); // skip request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            const hdr_key = line[0..colon];
            if (std.ascii.eqlIgnoreCase(hdr_key, name)) {
                return std_compat.mem.trimLeft(u8, line[colon + 1 ..], " ");
            }
        }
    }
    return null;
}

fn requestOriginAllowed(raw_request: []const u8, target: []const u8, bind_host: []const u8, port: u16, extra_origins: []const []const u8) bool {
    if (!auth.isApiPath(target)) return true;
    const origin = extractHeader(raw_request, "Origin") orelse return true;
    return isAllowedCorsOrigin(origin, bind_host, port, extra_origins);
}

fn appendCorsHeaders(writer: anytype, raw_request: []const u8, bind_host: []const u8, port: u16, extra_origins: []const []const u8) !void {
    const origin = allowedCorsOrigin(raw_request, bind_host, port, extra_origins) orelse return;
    try writer.print("Access-Control-Allow-Origin: {s}\r\n", .{origin});
    try writer.writeAll("Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n");
    try writer.writeAll("Access-Control-Allow-Headers: Content-Type, Authorization\r\n");
    try writer.writeAll("Vary: Origin\r\n");
}

fn buildCorsHeaders(allocator: std.mem.Allocator, raw_request: []const u8, bind_host: []const u8, port: u16, extra_origins: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try appendCorsHeaders(&out.writer, raw_request, bind_host, port, extra_origins);
    return try out.toOwnedSlice();
}

fn allowedCorsOrigin(raw_request: []const u8, bind_host: []const u8, port: u16, extra_origins: []const []const u8) ?[]const u8 {
    const origin = extractHeader(raw_request, "Origin") orelse return null;
    if (!isAllowedCorsOrigin(origin, bind_host, port, extra_origins)) return null;
    return origin;
}

fn isAllowedCorsOrigin(origin: []const u8, bind_host: []const u8, port: u16, extra_origins: []const []const u8) bool {
    if (originMatchesHost(origin, bind_host, port)) return true;

    if (access.isLocalBindHost(bind_host)) {
        inline for (&[_][]const u8{
            "127.0.0.1",
            "localhost",
            "[::1]",
            access.canonical_local_host,
            access.public_alias_host,
        }) |host| {
            if (originMatchesHost(origin, host, port)) return true;
        }
    }

    for (extra_origins) |allowed| {
        if (allowed.len == 0) continue;
        if (std.ascii.eqlIgnoreCase(origin, allowed)) return true;
    }
    return false;
}

fn originMatchesHost(origin: []const u8, host: []const u8, port: u16) bool {
    var buf: [256]u8 = undefined;
    const expected = std.fmt.bufPrint(&buf, "http://{s}:{d}", .{ host, port }) catch return false;
    return std.ascii.eqlIgnoreCase(origin, expected);
}

fn hostMatchesAliasHost(host_header: []const u8, alias_host: []const u8) bool {
    const trimmed = std.mem.trim(u8, host_header, " \t");
    if (std.ascii.eqlIgnoreCase(trimmed, alias_host)) return true;
    if (trimmed.len <= alias_host.len) return false;
    return trimmed[alias_host.len] == ':' and std.ascii.eqlIgnoreCase(trimmed[0..alias_host.len], alias_host);
}

fn contentType(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "text/html";
    if (std.mem.endsWith(u8, path, ".js")) return "application/javascript";
    if (std.mem.endsWith(u8, path, ".css")) return "text/css";
    if (std.mem.endsWith(u8, path, ".json")) return "application/json";
    if (std.mem.endsWith(u8, path, ".svg")) return "image/svg+xml";
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".ico")) return "image/x-icon";
    return "application/octet-stream";
}

fn serveStaticFile(allocator: std.mem.Allocator, target: []const u8) Response {
    // Path traversal protection
    if (std.mem.indexOf(u8, target, "..") != null) {
        return .{ .status = "400 Bad Request", .content_type = "text/plain", .body = "bad request" };
    }

    // Determine the requested file inside the embedded UI bundle.
    const rel_path = if (std.mem.eql(u8, target, "/"))
        "index.html"
    else if (target.len > 1)
        target[1..] // strip leading '/'
    else
        "index.html";

    if (ui_assets.get(rel_path)) |asset| {
        const content = allocator.dupe(u8, asset.bytes) catch {
            return .{
                .status = "500 Internal Server Error",
                .content_type = "text/html",
                .body = "internal server error",
            };
        };
        return .{
            .status = "200 OK",
            .content_type = contentType(rel_path),
            .body = content,
        };
    }

    if (ui_assets.get("index.html")) |index_asset| {
        const index_content = allocator.dupe(u8, index_asset.bytes) catch {
            return .{
                .status = "500 Internal Server Error",
                .content_type = "text/html",
                .body = "internal server error",
            };
        };
        return .{
            .status = "200 OK",
            .content_type = "text/html",
            .body = index_content,
        };
    }

    return .{
        .status = "404 Not Found",
        .content_type = "text/html",
        .body = "not found",
    };
}

// --- Test helpers ---

const TestContext = struct {
    fixture: test_helpers.TempPaths,
    state: *state_mod.State,
    paths: paths_mod.Paths,
    manager: manager_mod.Manager,
    mutex: std_compat.sync.Mutex,
    server: Server,

    fn init(allocator: std.mem.Allocator) TestContext {
        const fixture = test_helpers.TempPaths.init(allocator) catch @panic("TempPaths.init failed");
        const state_path = fixture.paths.state(allocator) catch @panic("state path failed");
        defer allocator.free(state_path);
        const state = allocator.create(state_mod.State) catch @panic("OOM");
        state.* = state_mod.State.init(allocator, state_path);
        var ctx: TestContext = undefined;
        ctx.fixture = fixture;
        ctx.state = state;
        ctx.paths = fixture.paths;
        ctx.manager = manager_mod.Manager.init(allocator, fixture.paths);
        ctx.mutex = .{};
        ctx.server = Server.initWithState(allocator, state, fixture.paths, &ctx.manager, &ctx.mutex);
        return ctx;
    }

    fn deinit(self: *TestContext, allocator: std.mem.Allocator) void {
        self.server.mission_workflow_evidence_cache.deinit();
        self.manager.deinit();
        self.state.deinit();
        allocator.destroy(self.state);
        self.fixture.deinit();
    }

    fn route(self: *TestContext, allocator: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) Response {
        return self.server.route(allocator, method, target, body);
    }

    fn routeWithRequestArena(self: *TestContext, allocator: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) Response {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const resp = self.server.route(arena.allocator(), method, target, body);
        const owned_body = allocator.dupe(u8, resp.body) catch @panic("OOM");
        return .{ .status = resp.status, .content_type = resp.content_type, .body = owned_body };
    }
};

fn writeUiModuleEntrypoint(allocator: std.mem.Allocator, module_dir: []const u8) !void {
    const module_path = try std.fs.path.join(allocator, &.{ module_dir, "module.js" });
    defer allocator.free(module_path);

    var file = try std_compat.fs.createFileAbsolute(module_path, .{});
    defer file.close();
    try file.writeAll("export {};\n");
}

// --- Tests ---

test "route GET /health returns 200 OK" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/health", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
}

test "reconcileInstancesOnBoot adopts persisted managed instance without respawn" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);
    try ctx.paths.ensureDirs();

    const output_path = try ctx.fixture.path(allocator, "starts.log");
    defer allocator.free(output_path);

    const binary_path = try ctx.paths.binary(allocator, "nullclaw", "1.0.0");
    defer allocator.free(binary_path);
    {
        const script = try std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\nprintf 'started\\n' >> '{s}'\nsleep 60\n",
            .{output_path},
        );
        defer allocator.free(script);

        const file = try std_compat.fs.createFileAbsolute(binary_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(script);
        try file.chmod(0o755);
    }

    try ctx.state.addInstance("nullclaw", "demo", .{
        .version = "1.0.0",
        .auto_start = false,
        .launch_mode = "agent",
    });

    var launch = try launch_args_mod.resolve(allocator, "agent", false);
    defer launch.deinit();

    const spawned = try process_mod.spawn(allocator, .{
        .binary = binary_path,
        .argv = launch.argv,
    });

    try runtime_state_mod.write(allocator, ctx.paths, "nullclaw", "demo", .{
        .pid = process_mod.persistedPidValue(spawned.pid).?,
        .port = 0,
        .health_endpoint = "/health",
        .binary_path = binary_path,
        .launch_command = launch.primary_command,
        .launch_args = launch.argv,
        .started_at = std_compat.time.milliTimestamp(),
        .starting_since = std_compat.time.milliTimestamp(),
    });

    ctx.reconcileInstancesOnBoot();

    const status = ctx.manager.getStatus("nullclaw", "demo").?;
    try std.testing.expectEqual(manager_mod.Status.running, status.status);

    ctx.manager.stopInstance("nullclaw", "demo") catch {};
    _ = spawned.child.wait() catch {};

    const file = try std_compat.fs.openFileAbsolute(output_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("started\n", contents);
}

test "reconcileInstancesOnBoot restarts auto-start instance when persisted pid is stale" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);
    try ctx.paths.ensureDirs();

    const output_path = try ctx.fixture.path(allocator, "starts.log");
    defer allocator.free(output_path);

    const binary_path = try ctx.paths.binary(allocator, "nullclaw", "1.0.0");
    defer allocator.free(binary_path);
    {
        const script = try std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\nprintf 'started\\n' >> '{s}'\nsleep 60\n",
            .{output_path},
        );
        defer allocator.free(script);

        const file = try std_compat.fs.createFileAbsolute(binary_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(script);
        try file.chmod(0o755);
    }

    try ctx.state.addInstance("nullclaw", "demo", .{
        .version = "1.0.0",
        .auto_start = true,
        .launch_mode = "agent",
    });

    var launch = try launch_args_mod.resolve(allocator, "agent", false);
    defer launch.deinit();

    try runtime_state_mod.write(allocator, ctx.paths, "nullclaw", "demo", .{
        .pid = 999_999_999,
        .port = 0,
        .health_endpoint = "/health",
        .binary_path = binary_path,
        .launch_command = launch.primary_command,
        .launch_args = launch.argv,
        .started_at = std_compat.time.milliTimestamp(),
        .starting_since = std_compat.time.milliTimestamp(),
    });

    ctx.reconcileInstancesOnBoot();
    ctx.manager.tick();

    const status = ctx.manager.getStatus("nullclaw", "demo").?;
    try std.testing.expectEqual(manager_mod.Status.running, status.status);

    const file = try std_compat.fs.openFileAbsolute(output_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("started\n", contents);
}

test "reconcileInstancesOnBoot terminates mismatched persisted runtime without respawn when auto_start is false" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);
    try ctx.paths.ensureDirs();

    const output_path = try ctx.fixture.path(allocator, "starts.log");
    defer allocator.free(output_path);

    const binary_path = try ctx.paths.binary(allocator, "nullclaw", "1.0.0");
    defer allocator.free(binary_path);
    {
        const script = try std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\nprintf 'started\\n' >> '{s}'\nsleep 60\n",
            .{output_path},
        );
        defer allocator.free(script);

        const file = try std_compat.fs.createFileAbsolute(binary_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(script);
        try file.chmod(0o755);
    }

    try ctx.state.addInstance("nullclaw", "demo", .{
        .version = "1.0.0",
        .auto_start = false,
        .launch_mode = "agent",
    });

    var launch = try launch_args_mod.resolve(allocator, "agent", false);
    defer launch.deinit();

    const spawned = try process_mod.spawn(allocator, .{
        .binary = binary_path,
        .argv = launch.argv,
    });
    defer {
        if (process_mod.isAlive(spawned.pid)) process_mod.forceKill(spawned.pid) catch {};
        _ = spawned.child.wait() catch {};
    }

    // Regression: if persisted runtime metadata no longer matches the desired
    // launch config, boot reconciliation must terminate the old process,
    // delete instance.json, and avoid an implicit respawn when auto_start=false.
    try runtime_state_mod.write(allocator, ctx.paths, "nullclaw", "demo", .{
        .pid = process_mod.persistedPidValue(spawned.pid).?,
        .port = 0,
        .health_endpoint = "/health",
        .binary_path = binary_path,
        .launch_command = "gateway",
        .launch_args = &.{"gateway"},
        .started_at = std_compat.time.milliTimestamp(),
        .starting_since = std_compat.time.milliTimestamp(),
    });

    ctx.reconcileInstancesOnBoot();

    var attempts: usize = 0;
    while (attempts < 20 and process_mod.isAlive(spawned.pid)) : (attempts += 1) {
        std_compat.thread.sleep(50 * std.time.ns_per_ms);
    }

    try std.testing.expect(!process_mod.isAlive(spawned.pid));
    try std.testing.expect(ctx.manager.getStatus("nullclaw", "demo") == null);
    try std.testing.expect((try runtime_state_mod.load(allocator, ctx.paths, "nullclaw", "demo")) == null);

    const file = try std_compat.fs.openFileAbsolute(output_path, .{});
    defer file.close();
    const contents = try file.readToEndAlloc(allocator, 1024);
    defer allocator.free(contents);
    try std.testing.expectEqualStrings("started\n", contents);
}

test "reconcileInstancesOnBoot rejects mismatched nullwatch launch mode" {
    const builtin = @import("builtin");
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);
    try ctx.paths.ensureDirs();

    const binary_path = try ctx.paths.binary(allocator, "nullwatch", "1.0.0");
    defer allocator.free(binary_path);

    try ctx.state.addInstance("nullwatch", "watch", .{
        .version = "1.0.0",
        .auto_start = false,
        .launch_mode = "gateway",
    });

    var launch = try launch_args_mod.resolve(allocator, "serve", false);
    defer launch.deinit();

    const spawned = try process_mod.spawn(allocator, .{
        .binary = "/bin/sleep",
        .argv = &.{"60"},
    });

    try runtime_state_mod.write(allocator, ctx.paths, "nullwatch", "watch", .{
        .pid = process_mod.persistedPidValue(spawned.pid).?,
        .port = 0,
        .health_endpoint = "/health",
        .binary_path = binary_path,
        .launch_command = launch.primary_command,
        .launch_args = launch.argv,
        .started_at = std_compat.time.milliTimestamp(),
        .starting_since = std_compat.time.milliTimestamp(),
    });

    ctx.reconcileInstancesOnBoot();

    var attempts: usize = 0;
    while (attempts < 20 and process_mod.isAlive(spawned.pid)) : (attempts += 1) {
        std_compat.thread.sleep(50 * std.time.ns_per_ms);
    }

    try std.testing.expect(!process_mod.isAlive(spawned.pid));
    try std.testing.expect(ctx.manager.getStatus("nullwatch", "watch") == null);
    try std.testing.expectEqualStrings("gateway", ctx.state.getInstance("nullwatch", "watch").?.launch_mode);
    try std.testing.expect((try runtime_state_mod.load(allocator, ctx.paths, "nullwatch", "watch")) == null);
    _ = spawned.child.wait() catch {};
}

test "route GET /api/status returns version and platform" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/status", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    // Body should contain version
    try std.testing.expect(std.mem.indexOf(u8, resp.body, version.string) != null);
    // Body should contain platform key
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "platform") != null);
    // Body should contain uptime_seconds
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "uptime_seconds") != null);
}

test "route GET /api/meta/routes returns route catalog" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/meta/routes", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\": \"meta.routes.get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "/api/instances/{component}/{name}") != null);
}

test "route GET /api/spec returns route catalog alias" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/spec", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\": \"meta.spec.get\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"path_template\": \"/api/spec\"") != null);
}

test "route persists mission replay artifacts through server paths" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);

    ctx.server.mission_control.runtime = .{
        .launched = true,
        .started_at_ms = std_compat.time.milliTimestamp() - 20_000,
        .recovered = true,
        .recovery_started_at_ms = std_compat.time.milliTimestamp() - 12_000,
    };

    const save_resp = ctx.routeWithRequestArena(allocator, "POST", "/api/mission-control/replay/save", "");
    defer allocator.free(save_resp.body);
    try std.testing.expectEqualStrings("200 OK", save_resp.status);
    try std.testing.expectEqualStrings("application/json", save_resp.content_type);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, save_resp.body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const record = parsed.value.object.get("record").?.object;
    const id = record.get("id").?.string;

    const second_save_resp = ctx.routeWithRequestArena(allocator, "POST", "/api/mission-control/replay/save", "");
    defer allocator.free(second_save_resp.body);
    try std.testing.expectEqualStrings("200 OK", second_save_resp.status);

    const bounded_resp = ctx.routeWithRequestArena(allocator, "GET", "/api/mission-control/replays?limit=0", "");
    defer allocator.free(bounded_resp.body);
    try std.testing.expectEqualStrings("200 OK", bounded_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, bounded_resp.body, "\"count\": 1") != null);

    const list_resp = ctx.routeWithRequestArena(allocator, "GET", "/api/mission-control/replays?limit=100", "");
    defer allocator.free(list_resp.body);
    try std.testing.expectEqualStrings("200 OK", list_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, list_resp.body, id) != null);

    const read_path = try std.fmt.allocPrint(allocator, "/api/mission-control/replays/{s}", .{id});
    defer allocator.free(read_path);
    const read_resp = ctx.routeWithRequestArena(allocator, "GET", read_path, "");
    defer allocator.free(read_resp.body);
    try std.testing.expectEqualStrings("200 OK", read_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, read_resp.body, "\"artifact_kind\": \"nullhub.mission_control.replay\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, read_resp.body, "\"phase\": \"completed\"") != null);
}

test "route unknown non-API path attempts static file serving" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/nonexistent", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("text/html", resp.content_type);
}

test "route POST to GET-only route falls through to static serving" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "POST", "/health", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
}

test "route unknown API path returns JSON 404" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/nonexistent", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", resp.body);
}

test "route bare API root returns JSON 404 instead of static fallback" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", resp.body);
}

test "route bare API root with query returns JSON 404 instead of static fallback" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api?format=json", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", resp.body);
}

test "route GET /api/components returns component list" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/components", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"components\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"nullclaw\"") != null);
}

test "route GET /api/components/{name}/manifest returns 404 for uncached" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/components/nullclaw/manifest", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"manifest not found\"}", resp.body);
}

test "route POST /api/components/refresh returns 200" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "POST", "/api/components/refresh", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"component_count\":4") != null);
}

test "extractHeader finds Content-Length" {
    const raw = "GET / HTTP/1.1\r\nContent-Length: 42\r\nHost: localhost\r\n\r\nbody";
    const val = extractHeader(raw, "Content-Length");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("42", val.?);
}

test "extractHeader returns null for missing header" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expect(extractHeader(raw, "Content-Length") == null);
}

test "extractHeader is case-insensitive" {
    const raw = "GET / HTTP/1.1\r\ncontent-length: 10\r\n\r\n";
    const val = extractHeader(raw, "Content-Length");
    try std.testing.expect(val != null);
    try std.testing.expectEqualStrings("10", val.?);
}

test "hostMatchesAliasHost matches bare host and host with port" {
    try std.testing.expect(hostMatchesAliasHost("nullhub.local", "nullhub.local"));
    try std.testing.expect(hostMatchesAliasHost("nullhub.local:19800", "nullhub.local"));
    try std.testing.expect(!hostMatchesAliasHost("nullhub.localhost:19800", "nullhub.local"));
}

test "isAllowedCorsOrigin allows local aliases for loopback binds" {
    try std.testing.expect(isAllowedCorsOrigin("http://127.0.0.1:19800", "127.0.0.1", 19800, &.{}));
    try std.testing.expect(isAllowedCorsOrigin("http://nullhub.localhost:19800", "127.0.0.1", 19800, &.{}));
    try std.testing.expect(isAllowedCorsOrigin("http://nullhub.local:19800", "127.0.0.1", 19800, &.{}));
}

test "isAllowedCorsOrigin rejects foreign or mismatched origins" {
    try std.testing.expect(!isAllowedCorsOrigin("http://evil.example:19800", "127.0.0.1", 19800, &.{}));
    try std.testing.expect(!isAllowedCorsOrigin("http://127.0.0.1:19801", "127.0.0.1", 19800, &.{}));
}

test "isAllowedCorsOrigin admits configured extra origins for any bind" {
    const extras = &[_][]const u8{
        "https://hub.tailnet.ts.net",
        "http://100.64.0.5:19800",
    };
    try std.testing.expect(isAllowedCorsOrigin("https://hub.tailnet.ts.net", "127.0.0.1", 19800, extras));
    try std.testing.expect(isAllowedCorsOrigin("HTTPS://HUB.TAILNET.TS.NET", "127.0.0.1", 19800, extras));
    try std.testing.expect(isAllowedCorsOrigin("http://100.64.0.5:19800", "192.168.1.50", 22000, extras));
    try std.testing.expect(!isAllowedCorsOrigin("http://evil.example", "192.168.1.50", 22000, extras));
}

test "isAllowedCorsOrigin ignores empty extra entries" {
    const extras = &[_][]const u8{ "", "https://hub.tailnet.ts.net" };
    try std.testing.expect(!isAllowedCorsOrigin("", "127.0.0.1", 19800, extras));
    try std.testing.expect(isAllowedCorsOrigin("https://hub.tailnet.ts.net", "127.0.0.1", 19800, extras));
}

test "isAllowedCorsOrigin allows extras alongside local aliases when bound to 0.0.0.0" {
    // Binding to 0.0.0.0 is treated as a local bind (see access.isLocalBindHost),
    // so local aliases are still accepted — matching how buildAccessUrls
    // advertises the service locally — and extras layer on top for
    // external hostnames (Tailscale, custom DNS, etc.).
    const extras = &[_][]const u8{"https://hub.tailnet.ts.net"};
    try std.testing.expect(isAllowedCorsOrigin("http://127.0.0.1:19800", "0.0.0.0", 19800, extras));
    try std.testing.expect(isAllowedCorsOrigin("https://hub.tailnet.ts.net", "0.0.0.0", 19800, extras));
    try std.testing.expect(!isAllowedCorsOrigin("http://evil.example:19800", "0.0.0.0", 19800, extras));
}

test "requestOriginAllowed rejects foreign API origins" {
    const evil_raw =
        "GET /api/status HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:19800\r\n" ++
        "Origin: http://evil.example:19800\r\n\r\n";
    try std.testing.expect(!requestOriginAllowed(evil_raw, "/api/status", "127.0.0.1", 19800, &.{}));

    const local_raw =
        "GET /api/status HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:19800\r\n" ++
        "Origin: http://nullhub.localhost:19800\r\n\r\n";
    try std.testing.expect(requestOriginAllowed(local_raw, "/api/status", "127.0.0.1", 19800, &.{}));
}

test "requestOriginAllowed treats bare API root with query as API" {
    const evil_raw =
        "GET /api?format=json HTTP/1.1\r\n" ++
        "Host: 127.0.0.1:19800\r\n" ++
        "Origin: http://evil.example:19800\r\n\r\n";
    try std.testing.expect(!requestOriginAllowed(evil_raw, "/api?format=json", "127.0.0.1", 19800, &.{}));
}

test "requestOriginAllowed honors configured extra origins" {
    const extras = &[_][]const u8{"https://hub.tailnet.ts.net"};
    const tailscale_raw =
        "GET /api/status HTTP/1.1\r\n" ++
        "Host: hub.tailnet.ts.net\r\n" ++
        "Origin: https://hub.tailnet.ts.net\r\n\r\n";
    try std.testing.expect(requestOriginAllowed(tailscale_raw, "/api/status", "127.0.0.1", 19800, extras));

    const foreign_raw =
        "GET /api/status HTTP/1.1\r\n" ++
        "Host: hub.tailnet.ts.net\r\n" ++
        "Origin: https://evil.example\r\n\r\n";
    try std.testing.expect(!requestOriginAllowed(foreign_raw, "/api/status", "127.0.0.1", 19800, extras));
}

test "routeWithoutServerMutex keeps product proxy requests off global lock" {
    try std.testing.expect(Server.routeWithoutServerMutex("/api/nullboiler"));
    try std.testing.expect(Server.routeWithoutServerMutex("/api/nullboiler/runs"));
    try std.testing.expect(Server.routeWithoutServerMutex("/api/nulltickets/store/search"));
    try std.testing.expect(Server.routeWithoutServerMutex("/api/nullwatch/v1/runs"));
    try std.testing.expect(!Server.routeWithoutServerMutex("/api/nulltickets/tasks"));
    try std.testing.expect(Server.routeWithoutServerMutex("/api/mission-control/state"));
    try std.testing.expect(Server.routeWithoutServerMutex("/api/instances/nullclaw/demo/logs"));
    try std.testing.expect(Server.routeWithoutServerMutex("/api/instances/nulltickets/tracker-a/tickets"));
    try std.testing.expect(!Server.routeWithoutServerMutex("/api/components"));
}

test "explicit managed product backend selection overrides env fallback" {
    const allocator = std.testing.allocator;
    var managed = Server.ManagedBackendConfig{
        .name = try allocator.dupe(u8, "worker-a"),
        .url = try allocator.dupe(u8, "http://127.0.0.1:8081"),
        .token = try allocator.dupe(u8, "managed-token"),
    };
    defer managed.deinit(allocator);

    try std.testing.expect(Server.shouldResolveManagedBackend("http://env.example", "worker-a"));
    try std.testing.expectEqualStrings(
        "http://127.0.0.1:8081",
        Server.selectBackendUrl("http://env.example", managed, "worker-a").?,
    );
    try std.testing.expectEqualStrings(
        "managed-token",
        Server.selectBackendToken("env-token", managed, "worker-a").?,
    );
    try std.testing.expectEqualStrings(
        "http://env.example",
        Server.selectBackendUrl("http://env.example", managed, null).?,
    );
    try std.testing.expectEqualStrings(
        "env-token",
        Server.selectBackendToken("env-token", managed, null).?,
    );
    const evidence = missionWorkflowEvidenceWithBackendName(
        allocator,
        missionWorkflowEvidenceStatus("available", "ok", 1),
        managed.name,
    );
    defer allocator.free(evidence.boiler_instance.?);
    try std.testing.expectEqualStrings("worker-a", evidence.boiler_instance.?);
}

test "managed NullWatch target is discovered from supervisor state" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "nullwatch", "watch" });
    try ctx.manager.instances.put(key, .{
        .component = "nullwatch",
        .name = "watch",
        .status = .running,
        .port = 7710,
    });

    const target = try ctx.server.getManagedWatchTarget(allocator, null, null);
    defer target.deinit(allocator);
    try std.testing.expect(target.url != null);
    try std.testing.expectEqualStrings("http://127.0.0.1:7710", target.url.?);
    try std.testing.expect(target.token == null);
}

test "managed NullWatch target prefers first running instance by name" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);

    const key_z = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "nullwatch", "zulu" });
    try ctx.manager.instances.put(key_z, .{
        .component = "nullwatch",
        .name = "zulu",
        .status = .running,
        .port = 7712,
    });
    const key_a = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "nullwatch", "alpha" });
    try ctx.manager.instances.put(key_a, .{
        .component = "nullwatch",
        .name = "alpha",
        .status = .running,
        .port = 7711,
    });

    const target = try ctx.server.getManagedWatchTarget(allocator, null, null);
    defer target.deinit(allocator);
    try std.testing.expectEqualStrings("http://127.0.0.1:7711", target.url.?);
}

test "managed NullWatch target can select a specific running instance" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);

    const key_alpha = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "nullwatch", "alpha" });
    try ctx.manager.instances.put(key_alpha, .{
        .component = "nullwatch",
        .name = "alpha",
        .status = .running,
        .port = 7711,
    });
    const key_zulu = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "nullwatch", "zulu" });
    try ctx.manager.instances.put(key_zulu, .{
        .component = "nullwatch",
        .name = "zulu",
        .status = .running,
        .port = 7712,
    });

    const target = try ctx.server.getManagedWatchTarget(allocator, null, "zulu");
    defer target.deinit(allocator);
    try std.testing.expectEqualStrings("http://127.0.0.1:7712", target.url.?);
}

test "managed NullWatch target reads host and token from config" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);
    try ctx.paths.ensureDirs();

    const inst_dir = try ctx.paths.instanceDir(allocator, "nullwatch", "watch");
    defer allocator.free(inst_dir);
    try std_compat.fs.makeDirAbsolute(inst_dir);

    const config_path = try ctx.paths.instanceConfig(allocator, "nullwatch", "watch");
    defer allocator.free(config_path);
    var file = try std_compat.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"host\":\"0.0.0.0\",\"api_token\":\"managed-secret\"}");

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "nullwatch", "watch" });
    try ctx.manager.instances.put(key, .{
        .component = "nullwatch",
        .name = "watch",
        .status = .running,
        .port = 7710,
    });

    const target = try ctx.server.getManagedWatchTarget(allocator, null, null);
    defer target.deinit(allocator);
    try std.testing.expectEqualStrings("http://127.0.0.1:7710", target.url.?);
    try std.testing.expectEqualStrings("managed-secret", target.token.?);
}

test "managed NullWatch target brackets IPv6 host and lets env token override config" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);
    try ctx.paths.ensureDirs();

    const inst_dir = try ctx.paths.instanceDir(allocator, "nullwatch", "watch");
    defer allocator.free(inst_dir);
    try std_compat.fs.makeDirAbsolute(inst_dir);

    const config_path = try ctx.paths.instanceConfig(allocator, "nullwatch", "watch");
    defer allocator.free(config_path);
    var file = try std_compat.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"host\":\"::1\",\"api_token\":\"managed-secret\"}");

    const key = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ "nullwatch", "watch" });
    try ctx.manager.instances.put(key, .{
        .component = "nullwatch",
        .name = "watch",
        .status = .running,
        .port = 7710,
    });

    const target = try ctx.server.getManagedWatchTarget(allocator, "env-secret", null);
    defer target.deinit(allocator);
    try std.testing.expectEqualStrings("http://[::1]:7710", target.url.?);
    try std.testing.expectEqualStrings("env-secret", target.token.?);
}

test "extractBody returns body after headers" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\nhello world";
    try std.testing.expectEqualStrings("hello world", extractBody(raw));
}

test "extractBody returns empty for no body" {
    const raw = "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n";
    try std.testing.expectEqualStrings("", extractBody(raw));
}

test "route GET /api/instances returns empty instances" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/instances", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"instances\":{}}", resp.body);
}

test "route GET /api/ui-modules prefers dev-local and deduplicates module versions" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    std_compat.fs.deleteTreeAbsolute(ctx.paths.root) catch {};
    try ctx.paths.ensureDirs();

    const release_dir = try ctx.paths.uiModule(std.testing.allocator, "nullclaw-chat-ui", "v2026.3.1");
    defer std.testing.allocator.free(release_dir);
    try std_compat.fs.makeDirAbsolute(release_dir);
    try writeUiModuleEntrypoint(std.testing.allocator, release_dir);

    const dev_local_dir = try ctx.paths.uiModule(std.testing.allocator, "nullclaw-chat-ui", "dev-local");
    defer std.testing.allocator.free(dev_local_dir);
    try std_compat.fs.makeDirAbsolute(dev_local_dir);
    try writeUiModuleEntrypoint(std.testing.allocator, dev_local_dir);

    const other_release_dir = try ctx.paths.uiModule(std.testing.allocator, "other-ui", "v1.0.0");
    defer std.testing.allocator.free(other_release_dir);
    try std_compat.fs.makeDirAbsolute(other_release_dir);
    try writeUiModuleEntrypoint(std.testing.allocator, other_release_dir);

    const broken_release_dir = try ctx.paths.uiModule(std.testing.allocator, "broken-ui", "v1.0.0");
    defer std.testing.allocator.free(broken_release_dir);
    try std_compat.fs.makeDirAbsolute(broken_release_dir);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/ui-modules", "");
    defer std.testing.allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"nullclaw-chat-ui\":\"dev-local\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"nullclaw-chat-ui\":\"v2026.3.1\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"other-ui\":\"v1.0.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"broken-ui\"") == null);
}

test "route POST /api/instances/{component}/{name}/start returns 500 without binary" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    try ctx.state.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    const resp = ctx.route(std.testing.allocator, "POST", "/api/instances/nullclaw/my-agent/start", "");
    // Binary doesn't exist in test env, so startInstance fails => 500
    try std.testing.expectEqualStrings("500 Internal Server Error", resp.status);
}

test "route POST /api/instances/{component}/{name}/stop returns 200" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    try ctx.state.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    const resp = ctx.route(std.testing.allocator, "POST", "/api/instances/nullclaw/my-agent/stop", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"stopped\"}", resp.body);
}

test "route POST /api/instances/{component}/{name}/restart returns 500 without binary" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    try ctx.state.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    const resp = ctx.route(std.testing.allocator, "POST", "/api/instances/nullclaw/my-agent/restart", "");
    // Binary doesn't exist in test env, so startInstance fails => 500
    try std.testing.expectEqualStrings("500 Internal Server Error", resp.status);
}

test "route DELETE /api/instances/{component}/{name} returns 200" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    try ctx.state.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    const resp = ctx.route(std.testing.allocator, "DELETE", "/api/instances/nullclaw/my-agent", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"deleted\"}", resp.body);
}

test "route PATCH /api/instances/{component}/{name} returns 200" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    try ctx.state.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .auto_start = false });
    const resp = ctx.route(std.testing.allocator, "PATCH", "/api/instances/nullclaw/my-agent", "{\"auto_start\":true}");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"updated\"}", resp.body);
}

test "route GET /api/instances with wrong method returns 405" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "POST", "/api/instances", "");
    try std.testing.expectEqualStrings("405 Method Not Allowed", resp.status);
}

test "route GET /api/settings returns defaults" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/settings", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"port\":19800") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"host\":\"127.0.0.1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"browser_open_url\":\"http://nullhub.localhost:19800\"") != null);
}

test "route PUT /api/settings returns ok" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "PUT", "/api/settings", "{\"port\":19801}");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
}

test "route PUT /api/settings rejects invalid JSON" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "PUT", "/api/settings", "not json");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"invalid JSON body\"") != null);
}

test "route POST /api/service/install returns platform info" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "POST", "/api/service/install", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
}

test "route POST /api/service/uninstall returns ok" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "POST", "/api/service/uninstall", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
}

test "route GET /api/service/status returns status" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/service/status", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"registered\":false") != null);
}

test "route GET /api/updates returns empty updates" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/api/updates", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"updates\":[]}", resp.body);
}

test "route POST /api/instances/{c}/{n}/update returns 404 for empty state" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "POST", "/api/instances/nullclaw/my-agent/update", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "route GET config supports percent-encoded instance names" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);
    try ctx.paths.ensureDirs();

    const inst_dir = try ctx.paths.instanceDir(allocator, "nullclaw", "Opencode Go");
    defer allocator.free(inst_dir);
    try std_compat.fs.makeDirAbsolute(inst_dir);

    const config_path = try ctx.paths.instanceConfig(allocator, "nullclaw", "Opencode Go");
    defer allocator.free(config_path);
    var file = try std_compat.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"gateway\":{\"port\":3000}}");

    const resp = ctx.route(allocator, "GET", "/api/instances/nullclaw/Opencode%20Go/config", "");
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "3000") != null);
}

test "route GET config rejects decoded traversal instance names" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);

    const resp = ctx.route(allocator, "GET", "/api/instances/nullclaw/%2E%2E/config", "");
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"invalid path segment\"}", resp.body);
}

test "route GET logs supports percent-encoded instance names" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);
    try ctx.paths.ensureDirs();

    const logs_dir = try ctx.paths.instanceLogs(allocator, "nullclaw", "Opencode Go");
    defer allocator.free(logs_dir);
    try std_compat.fs.makeDirAbsolute(logs_dir);

    const log_path = try std.fs.path.join(allocator, &.{ logs_dir, "stdout.log" });
    defer allocator.free(log_path);
    var file = try std_compat.fs.createFileAbsolute(log_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("hello\n");

    const resp = ctx.route(allocator, "GET", "/api/instances/nullclaw/Opencode%20Go/logs", "");
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "hello") != null);
}

test "route POST update supports percent-encoded instance names" {
    const allocator = std.testing.allocator;
    var ctx = TestContext.init(allocator);
    defer ctx.deinit(allocator);

    try ctx.state.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.0" });

    const resp = ctx.route(allocator, "POST", "/api/instances/nullclaw/Opencode%20Go/update", "");
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Opencode Go") != null);
}

test "Server init sets fields" {
    const paths = try paths_mod.Paths.init(std.testing.allocator, null);
    var mgr = manager_mod.Manager.init(std.testing.allocator, paths);
    defer mgr.deinit();
    var mutex: std_compat.sync.Mutex = .{};
    var s = try Server.init(std.testing.allocator, "127.0.0.1", access.default_port, &mgr, &mutex);
    defer s.deinit();
    try std.testing.expectEqualStrings("127.0.0.1", s.host);
    try std.testing.expectEqual(access.default_port, s.port);
    try std.testing.expect(s.start_time > 0);
}

test "contentType returns correct MIME type for .html" {
    try std.testing.expectEqualStrings("text/html", contentType("index.html"));
}

test "initial request buffer stays small while media body limit remains high" {
    try std.testing.expect(initial_request_buffer_size <= 128 * 1024);
    try std.testing.expect(default_max_request_size <= 128 * 1024);
    try std.testing.expect(gateway_max_request_size >= 64 * 1024 * 1024);
    try std.testing.expectEqual(@as(usize, @intCast(nullclaw_gateway_config.min_body_size)), gateway_max_request_size);
    try std.testing.expectEqual(default_max_request_size, maxRequestBodySize("/api/status"));
    try std.testing.expectEqual(gateway_max_request_size, maxRequestBodySize("/api/instances/nullclaw/demo/a2a"));
    try std.testing.expectEqual(gateway_max_request_size, maxRequestBodySize("/api/instances/nullclaw/Opencode%20Go/a2a"));
    try std.testing.expectEqual(default_max_request_size, maxRequestBodySize("/api/instances/nullclaw/name%2Fwith%2Fslash/a2a"));
}

test "contentType returns correct MIME type for .js" {
    try std.testing.expectEqualStrings("application/javascript", contentType("app.js"));
}

test "contentType returns correct MIME type for .css" {
    try std.testing.expectEqualStrings("text/css", contentType("style.css"));
}

test "contentType returns correct MIME type for .json" {
    try std.testing.expectEqualStrings("application/json", contentType("data.json"));
}

test "contentType returns correct MIME type for .svg" {
    try std.testing.expectEqualStrings("image/svg+xml", contentType("icon.svg"));
}

test "contentType returns correct MIME type for .png" {
    try std.testing.expectEqualStrings("image/png", contentType("logo.png"));
}

test "contentType returns correct MIME type for .ico" {
    try std.testing.expectEqualStrings("image/x-icon", contentType("favicon.ico"));
}

test "contentType returns octet-stream for unknown extension" {
    try std.testing.expectEqualStrings("application/octet-stream", contentType("file.xyz"));
}

test "serveStaticFile serves embedded index fallback" {
    const resp = serveStaticFile(std.testing.allocator, "/nonexistent.html");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("text/html", resp.content_type);
}

test "serveStaticFile rejects path traversal" {
    const resp = serveStaticFile(std.testing.allocator, "/../etc/passwd");
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expectEqualStrings("bad request", resp.body);
}

test "route GET / attempts static file serving" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/", "");
    defer std.testing.allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("text/html", resp.content_type);
}
