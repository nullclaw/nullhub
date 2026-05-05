const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");

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

        var tmp_dir = std.testing.tmpDir(.{});
        errdefer tmp_dir.cleanup();

        const temp_root = try std_compat.fs.Dir.wrap(tmp_dir.dir).realpathAlloc(allocator, ".");
        errdefer allocator.free(temp_root);

        const home_dir = try std.fs.path.join(allocator, &.{ temp_root, "home" });
        errdefer allocator.free(home_dir);
        try std_compat.fs.makeDirAbsolute(home_dir);

        const port = try reservePort();
        const port_text = try std.fmt.allocPrint(allocator, "{d}", .{port});
        defer allocator.free(port_text);

        const exe_path = try std_compat.process.getEnvVarOwned(allocator, "NULLHUB_INTEGRATION_BIN");
        defer allocator.free(exe_path);

        var env_map = try std_compat.process.getEnvMap(allocator);
        errdefer env_map.deinit();
        try env_map.put("HOME", home_dir);

        const argv = try allocator.dupe([]const u8, &.{ exe_path, "serve", "--port", port_text, "--no-open" });
        defer allocator.free(argv);

        var child = std_compat.process.Child.init(argv, allocator);
        child.cwd = ".";
        child.env_map = &env_map;
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Ignore;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        errdefer {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
        }

        var server = IntegrationServer{
            .allocator = allocator,
            .tmp_dir = tmp_dir,
            .temp_root = temp_root,
            .home_dir = home_dir,
            .port = port,
            .child = child,
            .env_map = env_map,
        };
        errdefer server.deinit();

        try server.waitUntilReady();
        return server;
    }

    fn deinit(self: *IntegrationServer) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        self.env_map.deinit();
        self.allocator.free(self.home_dir);
        self.allocator.free(self.temp_root);
        self.tmp_dir.cleanup();
        self.* = undefined;
    }

    fn waitUntilReady(self: *IntegrationServer) !void {
        var attempt: usize = 0;
        while (attempt < 40) : (attempt += 1) {
            const result = self.fetch("/health");
            if (result) |resp| {
                defer resp.deinit(self.allocator);
                if (resp.status == .ok) return;
            } else |_| {}

            std_compat.thread.sleep(250 * std.time.ns_per_ms);
        }

        return error.ServerNotReady;
    }

    fn fetch(self: *IntegrationServer, path: []const u8) !HttpResponse {
        const url = try std.fmt.allocPrint(self.allocator, "http://127.0.0.1:{d}{s}", .{ self.port, path });
        defer self.allocator.free(url);

        var client: std.http.Client = .{ .allocator = self.allocator, .io = std_compat.io() };
        defer client.deinit();

        var body: std.Io.Writer.Allocating = .init(self.allocator);
        errdefer body.deinit();

        const result = try client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .response_writer = &body.writer,
        });

        return .{
            .status = result.status,
            .body = try body.toOwnedSlice(),
        };
    }
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

test "integration harness serves health and core api routes" {
    var server = try IntegrationServer.start(std.testing.allocator);
    defer server.deinit();

    {
        const resp = try server.fetch("/health");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
    }

    {
        const resp = try server.fetch("/api/status");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.ok, resp.status);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"hub\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"version\"") != null);
    }

    {
        const resp = try server.fetch("/api/nonexistent");
        defer resp.deinit(std.testing.allocator);
        try std.testing.expectEqual(std.http.Status.not_found, resp.status);
    }
}
