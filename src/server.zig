const std = @import("std");
const auth = @import("auth.zig");
const instances_api = @import("api/instances.zig");
const platform = @import("core/platform.zig");
const components_api = @import("api/components.zig");
const config_api = @import("api/config.zig");
const logs_api = @import("api/logs.zig");
const status_api = @import("api/status.zig");
const settings_api = @import("api/settings.zig");
const updates_api = @import("api/updates.zig");
const access = @import("access.zig");
const mdns_mod = @import("mdns.zig");
const state_mod = @import("core/state.zig");
const paths_mod = @import("core/paths.zig");
const manager_mod = @import("supervisor/manager.zig");
const wizard_api = @import("api/wizard.zig");
const providers_api = @import("api/providers.zig");
const channels_api = @import("api/channels.zig");
const usage_api = @import("api/usage.zig");
const ui_modules = @import("installer/ui_modules.zig");
const orchestrator = @import("installer/orchestrator.zig");
const registry = @import("installer/registry.zig");
const ui_assets = @import("ui_assets");
const version = @import("version.zig");

const max_request_size: usize = 65_536;

pub const Server = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    access_options: access.Options = .{},
    access_publisher: ?*const mdns_mod.Publisher = null,
    auth_token: ?[]const u8 = null,
    state: *state_mod.State,
    paths: paths_mod.Paths,
    manager: *manager_mod.Manager,
    mutex: *std.Thread.Mutex,
    start_time: i64,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16, manager: *manager_mod.Manager, mutex: *std.Thread.Mutex) !Server {
        var paths = try paths_mod.Paths.init(allocator, null);
        errdefer paths.deinit(allocator);

        const state_path = try paths.state(allocator);
        defer allocator.free(state_path);

        const state = try allocator.create(state_mod.State);
        state.* = state_mod.State.load(allocator, state_path) catch state_mod.State.init(allocator, state_path);

        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .access_options = .{},
            .state = state,
            .paths = paths,
            .manager = manager,
            .mutex = mutex,
            .start_time = std.time.timestamp(),
        };
    }

    /// Initialize a server with an explicit state and paths (used by tests).
    fn initWithState(allocator: std.mem.Allocator, state: *state_mod.State, paths: paths_mod.Paths, manager: *manager_mod.Manager, mutex: *std.Thread.Mutex) Server {
        return .{
            .allocator = allocator,
            .host = "127.0.0.1",
            .port = access.default_port,
            .access_options = .{},
            .state = state,
            .paths = paths,
            .manager = manager,
            .mutex = mutex,
            .start_time = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Server) void {
        self.state.deinit();
        self.allocator.destroy(self.state);
        self.paths.deinit(self.allocator);
    }

    pub fn setAccessOptions(self: *Server, options: access.Options) void {
        self.access_options = options;
    }

    pub fn setAccessPublisher(self: *Server, publisher: *const mdns_mod.Publisher) void {
        self.access_publisher = publisher;
    }

    fn currentAccessOptions(self: *const Server) access.Options {
        if (self.access_publisher) |publisher| {
            return publisher.accessOptions();
        }
        return self.access_options;
    }

    /// Start all instances that have auto_start enabled.
    pub fn autoStartAll(self: *Server) void {
        var comp_it = self.state.instances.iterator();
        while (comp_it.next()) |comp_entry| {
            var inst_it = comp_entry.value_ptr.iterator();
            while (inst_it.next()) |inst_entry| {
                if (inst_entry.value_ptr.auto_start) {
                    const comp_name = comp_entry.key_ptr.*;
                    const inst_name = inst_entry.key_ptr.*;
                    _ = instances_api.handleStart(self.allocator, self.state, self.manager, self.paths, comp_name, inst_name, "");
                }
            }
        }
    }

    fn handleUiModules(self: *Server, allocator: std.mem.Allocator) Response {
        const ui_path = std.fs.path.join(allocator, &.{ self.paths.root, "ui" }) catch {
            return jsonResponse("{\"modules\":{}}");
        };
        defer allocator.free(ui_path);

        var dir = std.fs.openDirAbsolute(ui_path, .{ .iterate = true }) catch {
            return jsonResponse("{\"modules\":{}}");
        };
        defer dir.close();

        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        writer.writeAll("{\"modules\":{") catch return jsonResponse("{\"modules\":{}}");

        var first = true;
        var it = dir.iterate();
        while (it.next() catch null) |entry| {
            if (entry.kind != .directory) continue;
            const at_idx = std.mem.indexOfScalar(u8, entry.name, '@') orelse continue;
            const mod_name = entry.name[0..at_idx];
            const mod_version = entry.name[at_idx + 1 ..];
            if (mod_name.len == 0 or mod_version.len == 0) continue;

            if (!first) writer.writeAll(",") catch {};
            first = false;
            writer.print("\"{s}\":\"{s}\"", .{ mod_name, mod_version }) catch {};
        }

        writer.writeAll("}}") catch {};

        const json = allocator.dupe(u8, stream.getWritten()) catch return jsonResponse("{\"modules\":{}}");
        return jsonResponse(json);
    }

    fn handleAvailableUiModules(self: *Server, allocator: std.mem.Allocator) Response {
        _ = self;
        var buf: [4096]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();
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
        const json = allocator.dupe(u8, stream.getWritten()) catch return jsonResponse("[]");
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

        var dir = std.fs.openDirAbsolute(ui_path, .{ .iterate = true }) catch {
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

        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            return .{ .status = "404 Not Found", .content_type = "text/plain", .body = "not found" };
        };
        defer file.close();

        const content = file.readToEndAlloc(allocator, 10 * 1024 * 1024) catch {
            return .{ .status = "500 Internal Server Error", .content_type = "text/plain", .body = "internal server error" };
        };

        return .{ .status = "200 OK", .content_type = contentType(full_path), .body = content };
    }

    pub fn run(self: *Server) !void {
        const addr = try std.net.Address.resolveIp(self.host, self.port);
        var listener = try addr.listen(.{ .reuse_address = true });
        defer listener.deinit();

        std.debug.print("listening on http://{s}:{d}\n", .{ self.host, self.port });
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
            defer conn.stream.close();

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            self.handleConnection(conn, arena.allocator()) catch |err| {
                std.debug.print("request error: {}\n", .{err});
            };
        }
    }

    fn handleConnection(self: *Server, conn: std.net.Server.Connection, alloc: std.mem.Allocator) !void {
        var req_buf: [max_request_size]u8 = undefined;
        const n = conn.stream.read(&req_buf) catch return;
        if (n == 0) return;
        const raw = req_buf[0..n];

        // Parse request line
        const first_line_end = std.mem.indexOf(u8, raw, "\r\n") orelse return;
        const first_line = raw[0..first_line_end];
        var parts = std.mem.splitScalar(u8, first_line, ' ');
        const method = parts.next() orelse return;
        const target = parts.next() orelse return;

        if (std.mem.eql(u8, method, "GET") or std.mem.eql(u8, method, "HEAD")) {
            if (try self.redirectLocationForAliasHost(alloc, raw, target)) |location| {
                defer alloc.free(location);
                try sendRedirect(conn.stream, location);
                return;
            }
        }

        // Read remaining body if Content-Length indicates more data
        const body = readBody(raw, n, conn.stream, alloc) catch return;

        // Handle OPTIONS preflight
        if (std.mem.eql(u8, method, "OPTIONS")) {
            try sendResponse(conn.stream, .{
                .status = "204 No Content",
                .content_type = "text/plain",
                .body = "",
            });
            return;
        }

        // Auth check for protected API paths
        if (self.auth_token != null and !auth.isPublicPath(target)) {
            if (!auth.checkAuth(raw, self.auth_token)) {
                try sendResponse(conn.stream, .{
                    .status = "401 Unauthorized",
                    .content_type = "application/json",
                    .body = "{\"error\":\"unauthorized\"}",
                });
                return;
            }
        }

        // Route dispatch (lock mutex so supervisor thread doesn't race)
        const response = if (instances_api.isIntegrationPath(target))
            self.route(alloc, method, target, body)
        else blk: {
            self.mutex.lock();
            defer self.mutex.unlock();
            break :blk self.route(alloc, method, target, body);
        };
        try sendResponse(conn.stream, response);
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

    fn route(self: *Server, allocator: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) Response {
        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, target, "/health")) {
                return .{
                    .status = "200 OK",
                    .content_type = "application/json",
                    .body = "{\"status\":\"ok\"}",
                };
            }
            if (std.mem.eql(u8, target, "/api/status")) {
                const now = std.time.timestamp();
                const uptime: u64 = @intCast(@max(0, now - self.start_time));
                const resp = status_api.handleStatus(allocator, self.state, self.manager, uptime, self.host, self.port, self.currentAccessOptions());
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
                if (settings_api.handlePutSettings(allocator, body)) |json| {
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

        // Models API — GET /api/wizard/{component}/models?provider=X&api_key=Y
        if (std.mem.eql(u8, method, "GET") and wizard_api.isModelsPath(target)) {
            if (wizard_api.extractComponentName(target)) |comp_name| {
                if (wizard_api.handleGetModels(allocator, comp_name, self.paths, target)) |json| {
                    return .{
                        .status = "200 OK",
                        .content_type = "application/json",
                        .body = json,
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
                    if (wizard_api.handleGetWizard(allocator, comp_name, self.paths, self.state)) |json| {
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
            if (config_api.parseConfigPath(target)) |parsed| {
                if (std.mem.eql(u8, method, "GET")) {
                    const resp = config_api.handleGet(allocator, self.paths, parsed.component, parsed.name);
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
            if (logs_api.parseLogsPath(target)) |parsed| {
                if (std.mem.eql(u8, method, "DELETE")) {
                    const resp = logs_api.handleDelete(allocator, self.paths, parsed.component, parsed.name);
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
                    const resp = logs_api.handleStream(allocator, self.paths, parsed.component, parsed.name, max_lines);
                    return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
                }
                const max_lines = logs_api.parseLines(target);
                const resp = logs_api.handleGet(allocator, self.paths, parsed.component, parsed.name, max_lines);
                return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
            }
        }

        // Instances API — delegate to instances_api.dispatch and updates_api.
        if (std.mem.startsWith(u8, target, "/api/instances")) {
            // Updates API — POST /api/instances/{c}/{n}/update
            if (updates_api.parseUpdatePath(target)) |up| {
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

        // Serve UI module files from data directory (~/.nullhub/ui/{name}@{version}/...)
        if (!std.mem.startsWith(u8, target, "/api/") and std.mem.startsWith(u8, target, "/ui/")) {
            // Check if this looks like a module path: /ui/{name}@{version}/...
            if (target.len > 4) {
                const after_ui = target[4..]; // after "/ui/"
                if (std.mem.indexOfScalar(u8, after_ui, '@') != null) {
                    return self.serveUiModuleFile(allocator, target);
                }
            }
        }

        // For non-API paths, attempt to serve static files from the embedded UI bundle.
        if (!std.mem.startsWith(u8, target, "/api/")) {
            return serveStaticFile(allocator, target);
        }

        return .{
            .status = "404 Not Found",
            .content_type = "application/json",
            .body = "{\"error\":\"not found\"}",
        };
    }
};

const Response = struct {
    status: []const u8,
    content_type: []const u8,
    body: []const u8,
};

fn jsonResponse(body: []const u8) Response {
    return .{ .status = "200 OK", .content_type = "application/json", .body = body };
}

fn readBody(raw: []const u8, n: usize, stream: std.net.Stream, alloc: std.mem.Allocator) ![]const u8 {
    if (extractHeader(raw, "Content-Length")) |cl_str| {
        const content_length = std.fmt.parseInt(usize, cl_str, 10) catch 0;
        if (content_length > 0) {
            const header_end_pos = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse return "";
            const body_start = header_end_pos + 4;
            const body_received = n - body_start;
            if (body_received >= content_length) {
                return raw[body_start .. body_start + content_length];
            }
            // Need to read more data from the stream
            const total_size = body_start + content_length;
            if (total_size > max_request_size) return error.RequestTooLarge;
            const full_buf = try alloc.alloc(u8, total_size);
            @memcpy(full_buf[0..n], raw);
            var total_read = n;
            while (total_read < total_size) {
                const extra = stream.read(full_buf[total_read..total_size]) catch break;
                if (extra == 0) break;
                total_read += extra;
            }
            return full_buf[body_start..total_read];
        }
    }
    return extractBody(raw);
}

fn sendResponse(stream: std.net.Stream, response: Response) !void {
    var buf: [4096]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 {s}\r\n" ++
            "Content-Type: {s}\r\n" ++
            "Content-Length: {d}\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
            "Connection: close\r\n\r\n",
        .{ response.status, response.content_type, response.body.len },
    );
    _ = try stream.write(header);
    if (response.body.len > 0) {
        _ = try stream.write(response.body);
    }
}

fn sendRedirect(stream: std.net.Stream, location: []const u8) !void {
    var buf: [4096]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &buf,
        "HTTP/1.1 308 Permanent Redirect\r\n" ++
            "Location: {s}\r\n" ++
            "Content-Length: 0\r\n" ++
            "Access-Control-Allow-Origin: *\r\n" ++
            "Access-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, OPTIONS\r\n" ++
            "Access-Control-Allow-Headers: Content-Type, Authorization\r\n" ++
            "Connection: close\r\n\r\n",
        .{location},
    );
    _ = try stream.write(header);
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
                return std.mem.trimLeft(u8, line[colon + 1 ..], " ");
            }
        }
    }
    return null;
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
    state: *state_mod.State,
    paths: paths_mod.Paths,
    manager: manager_mod.Manager,
    mutex: std.Thread.Mutex,
    server: Server,

    fn init(allocator: std.mem.Allocator) TestContext {
        const state = allocator.create(state_mod.State) catch @panic("OOM");
        state.* = state_mod.State.init(allocator, "/tmp/nullhub-test-server-state.json");
        const paths = paths_mod.Paths.init(allocator, "/tmp/nullhub-test-server") catch @panic("Paths.init failed");
        var ctx: TestContext = undefined;
        ctx.state = state;
        ctx.paths = paths;
        ctx.manager = manager_mod.Manager.init(allocator, paths);
        ctx.mutex = .{};
        ctx.server = Server.initWithState(allocator, state, paths, &ctx.manager, &ctx.mutex);
        return ctx;
    }

    fn deinit(self: *TestContext, allocator: std.mem.Allocator) void {
        self.manager.deinit();
        self.state.deinit();
        allocator.destroy(self.state);
        self.paths.deinit(allocator);
    }

    fn route(self: *TestContext, allocator: std.mem.Allocator, method: []const u8, target: []const u8, body: []const u8) Response {
        return self.server.route(allocator, method, target, body);
    }
};

// --- Tests ---

test "route GET /health returns 200 OK" {
    var ctx = TestContext.init(std.testing.allocator);
    defer ctx.deinit(std.testing.allocator);

    const resp = ctx.route(std.testing.allocator, "GET", "/health", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
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
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", resp.body);
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

test "Server init sets fields" {
    const paths = try paths_mod.Paths.init(std.testing.allocator, null);
    var mgr = manager_mod.Manager.init(std.testing.allocator, paths);
    defer mgr.deinit();
    var mutex = std.Thread.Mutex{};
    var s = try Server.init(std.testing.allocator, "127.0.0.1", access.default_port, &mgr, &mutex);
    defer s.deinit();
    try std.testing.expectEqualStrings("127.0.0.1", s.host);
    try std.testing.expectEqual(access.default_port, s.port);
    try std.testing.expect(s.start_time > 0);
}

test "contentType returns correct MIME type for .html" {
    try std.testing.expectEqualStrings("text/html", contentType("index.html"));
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
