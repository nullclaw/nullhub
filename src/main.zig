const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
pub const root = @import("root.zig");
const cli = root.cli;
const api_cli = root.api_cli;
const server = root.server;
const service = root.service;
const paths_mod = root.paths;
const manager_mod = root.manager;
const access = root.access;
const mdns_mod = root.mdns;
const routes_cli = @import("routes_cli.zig");
const status_cli = root.status_cli;
const report_cli = @import("report_cli.zig");
const version = root.version;

pub fn main(init: std.process.Init) !void {
    std_compat.initProcess(init);

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    const command = cli.parse(allocator, &args);

    switch (command) {
        .version => try printVersionLine(),
        .serve => |opts| {
            std.debug.print("nullhub v{s}\n", .{version.string});

            var paths = try paths_mod.Paths.init(allocator, null);
            defer paths.deinit(allocator);
            try paths.ensureDirs();

            var mgr = manager_mod.Manager.init(allocator, paths);
            defer mgr.deinit();
            var mutex: std_compat.sync.Mutex = .{};

            const allowed_origins = try resolveAllowedOrigins(allocator, opts.extra_allowed_origins);
            // `resolveAllowedOrigins` takes ownership of each item in
            // `opts.extra_allowed_origins`; only the outer slice remains.
            if (opts.extra_allowed_origins.len > 0) allocator.free(opts.extra_allowed_origins);
            defer freeResolvedOrigins(allocator, allowed_origins);

            var srv = try server.Server.init(allocator, opts.host, opts.port, &mgr, &mutex);
            defer srv.deinit();
            var mdns = try mdns_mod.Publisher.init(allocator, paths, opts.host, opts.port);
            defer mdns.deinit();
            mdns.start(opts.port);
            srv.setAccessOptions(mdns.accessOptions());
            srv.setAccessPublisher(&mdns);
            srv.setExtraAllowedOrigins(allowed_origins);

            const sup_thread = try std.Thread.spawn(.{}, supervisorLoop, .{ &mgr, &mutex });
            sup_thread.detach();

            srv.reconcileInstancesOnBoot();

            if (!opts.no_open) {
                const browser_thread = try std.Thread.spawn(.{}, delayedOpenBrowser, .{
                    allocator,
                    opts.host,
                    opts.port,
                    &mdns,
                });
                browser_thread.detach();
            }

            try srv.run();
        },
        .status => |opts| try status_cli.run(allocator, opts),
        .routes => |opts| try routes_cli.run(allocator, opts),
        .api => |opts| api_cli.run(allocator, opts) catch |err| {
            const any_err: anyerror = err;
            switch (any_err) {
                error.InvalidMethod => std.debug.print("Invalid HTTP method: {s}\n", .{opts.method}),
                error.InvalidTarget => std.debug.print("Invalid API target: {s}\n", .{opts.target}),
                error.FileNotFound => std.debug.print("Body file not found.\n", .{}),
                error.ConnectionRefused => std.debug.print("nullhub is not running on http://{s}:{d}\n", .{ opts.host, opts.port }),
                error.RequestFailed => {},
                else => std.debug.print("API request failed: {s}\n", .{@errorName(any_err)}),
            }
            std.process.exit(1);
        },
        .install => |opts| {
            std.debug.print("install {s}", .{opts.component});
            if (opts.name) |n| std.debug.print(" --name {s}", .{n});
            if (opts.version) |v| std.debug.print(" --version {s}", .{v});
            std.debug.print(" (not yet implemented)\n", .{});
        },
        .start => |ref| std.debug.print("start {s}/{s} (not yet implemented)\n", .{ ref.component, ref.name }),
        .stop => |ref| std.debug.print("stop {s}/{s} (not yet implemented)\n", .{ ref.component, ref.name }),
        .restart => |ref| std.debug.print("restart {s}/{s} (not yet implemented)\n", .{ ref.component, ref.name }),
        .start_all => std.debug.print("start-all (not yet implemented)\n", .{}),
        .stop_all => std.debug.print("stop-all (not yet implemented)\n", .{}),
        .logs => |opts| {
            std.debug.print("logs {s}/{s}", .{ opts.instance.component, opts.instance.name });
            if (opts.follow) std.debug.print(" -f", .{});
            std.debug.print(" --lines {d} (not yet implemented)\n", .{opts.lines});
        },
        .check_updates => std.debug.print("check-updates (not yet implemented)\n", .{}),
        .update => |ref| std.debug.print("update {s}/{s} (not yet implemented)\n", .{ ref.component, ref.name }),
        .update_all => std.debug.print("update-all (not yet implemented)\n", .{}),
        .config => |opts| {
            std.debug.print("config {s}/{s}", .{ opts.instance.component, opts.instance.name });
            if (opts.edit) std.debug.print(" --edit", .{});
            std.debug.print(" (not yet implemented)\n", .{});
        },
        .wizard => |opts| std.debug.print("wizard {s} (not yet implemented)\n", .{opts.component}),
        .service => |sc| handleServiceCommand(allocator, sc) catch |err| {
            const any_err: anyerror = err;
            switch (any_err) {
                error.UnsupportedPlatform => std.debug.print("Service management is not supported on this platform.\n", .{}),
                error.NoHomeDir => std.debug.print("Could not resolve home directory for service files.\n", .{}),
                error.SystemctlUnavailable => {
                    std.debug.print("`systemctl` is not available; Linux service commands require systemd user services.\n", .{});
                },
                error.SystemdUserUnavailable => {
                    std.debug.print("systemd user services are unavailable (`systemctl --user`).\n", .{});
                },
                error.CommandFailed => {
                    std.debug.print("Service command failed: {s}\n", .{@tagName(sc)});
                },
                else => return any_err,
            }
            std.process.exit(1);
        },
        .uninstall => |opts| {
            std.debug.print("uninstall {s}/{s}", .{ opts.instance.component, opts.instance.name });
            if (opts.remove_data) std.debug.print(" --remove-data", .{});
            std.debug.print(" (not yet implemented)\n", .{});
        },
        .add_source => |opts| std.debug.print("add-source {s} (not yet implemented)\n", .{opts.repo}),
        .report => |opts| report_cli.run(allocator, opts) catch |err| {
            const any_err: anyerror = err;
            switch (any_err) {
                error.Cancelled => {},
                error.InvalidArguments => std.process.exit(1),
                else => {
                    std.debug.print("Report failed: {s}\n", .{@errorName(any_err)});
                    std.process.exit(1);
                },
            }
        },
        .help => cli.printUsage(),
    }
}

fn handleServiceCommand(allocator: std.mem.Allocator, command: cli.ServiceCommand) !void {
    switch (command) {
        .install => {
            try service.install(allocator);
            try printStdout("Service installed and started.\n");
        },
        .uninstall => {
            try service.uninstall(allocator);
            try printStdout("Service uninstalled.\n");
        },
        .status => try service.printStatus(allocator),
    }
}

fn printVersionLine() !void {
    var line_buf: [128]u8 = undefined;
    const line = try std.fmt.bufPrint(&line_buf, "nullhub v{s}\n", .{version.string});
    try printStdout(line);
}

fn printStdout(text: []const u8) !void {
    var stdout_buf: [1024]u8 = undefined;
    var bw = std_compat.fs.File.stdout().writer(&stdout_buf);
    const w = &bw.interface;
    try w.writeAll(text);
    try w.flush();
}

const allowed_origins_env_var = "NULLHUB_ALLOWED_ORIGINS";

/// Combine CLI-provided `--allowed-origin` entries with any origins supplied
/// via the `NULLHUB_ALLOWED_ORIGINS` environment variable. `from_cli`
/// entries are already allocator-owned and ownership transfers into the
/// returned slice; entries parsed from the env var are copied in. The
/// caller must release the result with `freeResolvedOrigins`.
fn resolveAllowedOrigins(
    allocator: std.mem.Allocator,
    from_cli: []const []const u8,
) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (list.items) |item| allocator.free(item);
        list.deinit(allocator);
    }

    for (from_cli) |origin| try list.append(allocator, origin);

    if (std_compat.process.getEnvVarOwned(allocator, allowed_origins_env_var)) |csv| {
        defer allocator.free(csv);
        const skipped = cli.appendOriginsFromCsv(allocator, &list, csv);
        if (skipped > 0) {
            std.debug.print(
                "nullhub: {d} invalid entr{s} in {s} ignored\n",
                .{ skipped, if (skipped == 1) "y" else "ies", allowed_origins_env_var },
            );
        }
    } else |err| switch (err) {
        error.EnvironmentVariableNotFound => {},
        else => return err,
    }

    return list.toOwnedSlice(allocator);
}

fn freeResolvedOrigins(allocator: std.mem.Allocator, origins: []const []const u8) void {
    for (origins) |origin| allocator.free(origin);
    allocator.free(origins);
}

fn supervisorLoop(manager: *manager_mod.Manager, mutex: *std_compat.sync.Mutex) void {
    while (true) {
        {
            mutex.lock();
            defer mutex.unlock();
            manager.tick();
        }
        std_compat.thread.sleep(1_000_000_000); // 1 second
    }
}

fn openBrowser(allocator: std.mem.Allocator, host: []const u8, port: u16, access_options: access.Options) void {
    var urls = access.buildAccessUrlsWithOptions(allocator, host, port, access_options) catch return;
    defer urls.deinit(allocator);

    var child = switch (builtin.os.tag) {
        .macos => std_compat.process.Child.init(&.{ "open", urls.browser_open_url }, allocator),
        .windows => std_compat.process.Child.init(&.{ "cmd", "/c", "start", "", urls.browser_open_url }, allocator),
        else => std_compat.process.Child.init(&.{ "xdg-open", urls.browser_open_url }, allocator),
    };
    _ = child.spawnAndWait() catch return;
}

fn delayedOpenBrowser(
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    publisher: *const mdns_mod.Publisher,
) void {
    std_compat.thread.sleep(750 * std.time.ns_per_ms);
    openBrowser(allocator, host, port, publisher.accessOptions());
}
