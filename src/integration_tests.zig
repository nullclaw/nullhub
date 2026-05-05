const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const paths_mod = @import("core/paths.zig");
const state_mod = @import("core/state.zig");

const IntegrationServer = struct {
    allocator: std.mem.Allocator,
    tmp_dir: std.testing.TmpDir,
    temp_root: []const u8,
    home_dir: []const u8,
    port: u16,
    child: std_compat.process.Child,
    env_map: std_compat.process.EnvMap,

    fn start(allocator: std.mem.Allocator) !IntegrationServer {
        if (builtin.os.tag == .wasi) return error.SkipZigTest;

        return startWithSeed(allocator, struct {
            fn call(_: *IntegrationServer) !void {}
        }.call);
    }

    fn startWithEnv(
        allocator: std.mem.Allocator,
        extra_env: []const EnvEntry,
    ) !IntegrationServer {
        return startWithSeedAndEnv(allocator, struct {
            fn call(_: *IntegrationServer) !void {}
        }.call, extra_env);
    }

    fn startWithSeed(
        allocator: std.mem.Allocator,
        comptime seedFn: *const fn (*IntegrationServer) anyerror!void,
    ) !IntegrationServer {
        return startWithSeedAndEnv(allocator, seedFn, &.{});
    }

    fn startWithSeedAndEnv(
        allocator: std.mem.Allocator,
        comptime seedFn: *const fn (*IntegrationServer) anyerror!void,
        extra_env: []const EnvEntry,
    ) !IntegrationServer {
        if (builtin.os.tag == .wasi) return error.SkipZigTest;

        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        const temp_root = try std_compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
        errdefer allocator.free(temp_root);

        const home_dir = try std.fs.path.join(allocator, &.{ temp_root, "home" });
        errdefer allocator.free(home_dir);
        try std_compat.fs.makeDirAbsolute(home_dir);

        var server = IntegrationServer{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .temp_root = temp_root,
            .home_dir = home_dir,
            .port = undefined,
            .child = undefined,
            .env_map = undefined,
        };
        errdefer server.deinit();

        try seedFn(&server);

        const port = try reservePort();
        server.port = port;
        const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
        defer allocator.free(port_text);

        const exe_path = try std_compat.process.getEnvVarOwned(allocator, "NULLHUB_INTEGRATION_BIN");
        defer allocator.free(exe_path);

        server.env_map = try std_compat.process.getEnvMap(allocator);
        errdefer server.env_map.deinit();
        try server.env_map.put("HOME", home_dir);
        for (extra_env) |entry| try server.env_map.put(entry.key, entry.value);

        const argv = try allocator.dupe([]const u8, &.{ exe_path, "serve", "--port", port_text, "--no-open" });
        defer allocator.free(argv);

        server.child = std_compat.process.Child.init(argv, allocator);
        server.child.cwd = ".";
        server.child.env_map = &server.env_map;
        server.child.stdin_behavior = .Ignore;
        server.child.stdout_behavior = .Ignore;
        server.child.stderr_behavior = .Ignore;
        try server.child.spawn();

        try server.waitUntilReady();
        return server;
    }

    fn deinit(self: *IntegrationServer) void {
        if (@intFromPtr(self.child.argv.ptr) != 0) {
            _ = self.child.kill() catch {};
            _ = self.child.wait() catch {};
        }
        if (self.env_map.count() > 0) self.env_map.deinit();
        self.allocator.free(self.home_dir);
        self.allocator.free(self.temp_root);
        self.tmp_dir.cleanup();
        self.* = undefined;
    }

    fn waitUntilReady(self: *IntegrationServer) !void {
        var attempt: usize = 0;
        while (attempt < 40) : (attempt += 1) {
            const result = self.fetch(.{ .path = "/health" });
            if (result) |resp| {
                defer resp.deinit(self.allocator);
                if (resp.status == .ok) return;
            } else |_| {}

            std_compat.thread.sleep(250 * std.time.ns_per_ms);
        }

        return error.ServerNotReady;
    }

    fn fetch(self: *IntegrationServer, req: Request) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}{s}", .{ self.port, req.path });
        defer self.allocator.free(url);

        var client: std.http.Client = .{ .allocator = self.allocator, .io = std_compat.io() };
        defer client.deinit();

        var body: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body.deinit();

        var header_buf: [1]std.http.Header = undefined;
        const extra_headers: []const std.http.Header = if (req.body.len > 0) blk: {
            header_buf[0] = .{ .name = "Content-Type", .value = "application/json" };
            break :blk header_buf[0..1];
        } else &.{};

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = req.method,
            .payload = if (req.body.len > 0 or req.method.requestHasBody()) req.body else null,
            .response_writer = &body.writer,
            .extra_headers = extra_headers,
        });

        return .{
            .status = result.status,
            .body = try body.toOwnedSlice(),
        };
    }

    fn paths(self: *IntegrationServer) !paths_mod.Paths {
        const root = try std.fs.path.join(self.allocator, &.{ self.home_dir, ".nullhub" });
        defer self.allocator.free(root);
        return try paths_mod.Paths.init(self.allocator, root);
    }
};

const EnvEntry = struct {
    key: []const u8,
    value: []const u8,
};

const Request = struct {
    path: []const u8,
    method: std.http.Method = .GET,
    body: []const u8 = "",
};

const HttpResponse = struct {
    status: std.http.Status,
    body: []u8,

    fn deinit(self: HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

fn reservePort() !u16 {
    const addr = try std_compat.net.Address.resolveIp("127.0.0.1", 0);
    var listener = try addr.listen(.{});
    defer listener.deinit();
    return listener.listen_address.in.getPort();
}

fn seedManagedInstance(server: *IntegrationServer, component: []const u8, name: []const u8) !void {
    var paths = try server.paths();
    defer paths.deinit(server.allocator);
    try paths.ensureDirs();

    const state_path = try paths.state(server.allocator);
    defer server.allocator.free(state_path);
    var state = state_mod.State.init(server.allocator, state_path);
    defer state.deinit();

    try state.addInstance(component, name, .{
        .version = "1.0.0",
        .auto_start = false,
        .launch_mode = "gateway",
        .verbose = false,
    });
    try state.save();
}

test "integration harness serves health and core api routes" {
    var server = try IntegrationServer.start(std.testing.allocator);
    defer server.deinit();

    {
        const resp = try server.fetch(.{ .path = "/health" });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
    }

    {
        const resp = try server.fetch(.{ .path = "/api/status" });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"hub\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"version\"") != null);
    }

    {
        const resp = try server.fetch(.{ .path = "/api/nonexistent" });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.not_found, resp.status);
    }
}

test "integration harness covers settings and config round-trips" {
    var server = try IntegrationServer.startWithSeed(std.testing.allocator, struct {
        fn call(srv: *IntegrationServer) !void {
            try seedManagedInstance(srv, "nullboiler", "demo");
        }
    }.call);
    defer server.deinit();

    {
        const resp = try server.fetch(.{ .path = "/api/settings" });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"port\":") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"access\"") != null);
    }

    {
        const resp = try server.fetch(.{
            .path = "/api/settings",
            .method = .PUT,
            .body = "{\"port\":19901}",
        });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"port\":19901") != null);
    }

    {
        const resp = try server.fetch(.{ .path = "/api/instances" });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"nullboiler\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"demo\"") != null);
    }

    {
        const resp = try server.fetch(.{
            .path = "/api/instances/nullboiler/demo/config",
            .method = .PUT,
            .body = "{\"gateway\":{\"port\":43123},\"provider\":\"openrouter\"}",
        });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"saved\"") != null);
    }

    {
        const resp = try server.fetch(.{ .path = "/api/instances/nullboiler/demo/config" });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"gateway\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "43123") != null);
    }

    {
        const resp = try server.fetch(.{ .path = "/api/instances/nullboiler/demo/config?path=gateway.port" });
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"path\":\"gateway.port\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"value\":43123") != null);
    }
}

test "integration harness covers orchestration proxy not configured" {
    var server = try IntegrationServer.start(std.testing.allocator);
    defer server.deinit();

    const resp = try server.fetch(.{ .path = "/api/orchestration/runs" });
    defer resp.deinit(std.testing.allocator);
    try std.testing.expectEqual(std.http.Status.service_unavailable, resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "NullBoiler not configured") != null);
}
