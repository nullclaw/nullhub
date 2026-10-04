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
        .install => |opts| runInstallCommand(allocator, opts),
        .start => |ref| runInstanceAction(allocator, ref, "start"),
        .stop => |ref| runInstanceAction(allocator, ref, "stop"),
        .restart => |ref| runInstanceAction(allocator, ref, "restart"),
        .start_all => runBulkInstanceAction(allocator, "start"),
        .stop_all => runBulkInstanceAction(allocator, "stop"),
        .logs => |opts| runLogsCommand(allocator, opts),
        .check_updates => runApiChecked(allocator, .{ .method = "GET", .target = "/api/updates", .pretty = true }),
        .update => |ref| runInstanceAction(allocator, ref, "update"),
        .update_all => runBulkInstanceAction(allocator, "update"),
        .config => |opts| runConfigCommand(allocator, opts),
        .wizard => |opts| runWizardCommand(allocator, opts),
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
        .uninstall => |opts| runUninstallCommand(allocator, opts),
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

fn runApiChecked(allocator: std.mem.Allocator, opts: cli.ApiOptions) void {
    api_cli.run(allocator, opts) catch |err| {
        printApiError(opts, err);
        std.process.exit(1);
    };
}

fn printApiError(opts: cli.ApiOptions, err: anyerror) void {
    switch (err) {
        error.InvalidMethod => std.debug.print("Invalid HTTP method: {s}\n", .{opts.method}),
        error.InvalidTarget => std.debug.print("Invalid API target: {s}\n", .{opts.target}),
        error.FileNotFound => std.debug.print("Body file not found.\n", .{}),
        error.ConnectionRefused => std.debug.print("nullhub is not running on http://{s}:{d}\n", .{ opts.host, opts.port }),
        error.RequestFailed => {},
        else => std.debug.print("API request failed: {s}\n", .{@errorName(err)}),
    }
}

fn instanceActionTarget(allocator: std.mem.Allocator, ref: cli.InstanceRef, action: []const u8) ![]u8 {
    var suffix = std.array_list.Managed(u8).init(allocator);
    defer suffix.deinit();
    try suffix.append('/');
    try suffix.appendSlice(action);
    return instanceTarget(allocator, ref, suffix.items);
}

fn instanceTarget(allocator: std.mem.Allocator, ref: cli.InstanceRef, suffix: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("/api/instances/");
    try appendUrlPathSegment(&buf, ref.component);
    try buf.append('/');
    try appendUrlPathSegment(&buf, ref.name);
    try buf.appendSlice(suffix);
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

fn runInstanceAction(allocator: std.mem.Allocator, ref: cli.InstanceRef, action: []const u8) void {
    const target = instanceActionTarget(allocator, ref, action) catch {
        std.debug.print("failed to build API target\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(target);
    runApiChecked(allocator, .{ .method = "POST", .target = target, .pretty = true });
}

fn runInstallCommand(allocator: std.mem.Allocator, opts: cli.InstallOptions) void {
    const target = std.fmt.allocPrint(allocator, "/api/wizard/{s}", .{opts.component}) catch {
        std.debug.print("failed to build API target\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(target);

    const body = std.json.Stringify.valueAlloc(allocator, .{
        .instance_name = opts.name orelse "default",
        .version = opts.version orelse "latest",
    }, .{}) catch {
        std.debug.print("failed to build install request\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(body);

    runApiChecked(allocator, .{ .method = "POST", .target = target, .body = body, .pretty = true });
}

fn runWizardCommand(allocator: std.mem.Allocator, opts: cli.WizardOptions) void {
    const target = std.fmt.allocPrint(allocator, "/api/wizard/{s}", .{opts.component}) catch {
        std.debug.print("failed to build API target\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(target);
    runApiChecked(allocator, .{ .method = "GET", .target = target, .pretty = true });
}

fn runLogsCommand(allocator: std.mem.Allocator, opts: cli.LogsOptions) void {
    if (opts.follow) {
        std.debug.print("nullhub logs -f is not stream-backed yet; showing current logs.\n", .{});
    }
    const suffix = std.fmt.allocPrint(allocator, "/logs?lines={d}", .{opts.lines}) catch {
        std.debug.print("failed to build API target\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(suffix);
    const target = instanceTarget(allocator, opts.instance, suffix) catch {
        std.debug.print("failed to build API target\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(target);
    runApiChecked(allocator, .{ .method = "GET", .target = target });
}

fn runConfigCommand(allocator: std.mem.Allocator, opts: cli.ConfigOptions) void {
    if (opts.edit) {
        std.debug.print("nullhub config --edit is not stream-backed yet; showing current config.\n", .{});
    }
    const target = instanceTarget(allocator, opts.instance, "/config") catch {
        std.debug.print("failed to build API target\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(target);
    runApiChecked(allocator, .{ .method = "GET", .target = target, .pretty = true });
}

fn runUninstallCommand(allocator: std.mem.Allocator, opts: cli.UninstallOptions) void {
    _ = opts.remove_data;
    const target = instanceTarget(allocator, opts.instance, "") catch {
        std.debug.print("failed to build API target\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(target);
    runApiChecked(allocator, .{ .method = "DELETE", .target = target, .pretty = true });
}

fn runBulkInstanceAction(allocator: std.mem.Allocator, action: []const u8) void {
    var result = api_cli.execute(allocator, .{ .method = "GET", .target = "/api/instances" }) catch |err| {
        printApiError(.{ .method = "GET", .target = "/api/instances" }, err);
        std.process.exit(1);
    };
    defer result.deinit(allocator);

    const code = @intFromEnum(result.status);
    if (code < 200 or code >= 300) {
        if (result.body.len > 0) printStdout(result.body) catch {};
        std.debug.print("HTTP {d}\n", .{code});
        std.process.exit(1);
    }

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch {
        std.debug.print("Invalid /api/instances response.\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    const instances_value = if (parsed.value == .object) parsed.value.object.get("instances") else null;
    if (instances_value == null or instances_value.? != .object) {
        std.debug.print("Invalid /api/instances response.\n", .{});
        std.process.exit(1);
    }

    var count: usize = 0;
    var comp_it = instances_value.?.object.iterator();
    while (comp_it.next()) |comp_entry| {
        if (comp_entry.value_ptr.* != .object) continue;
        var inst_it = comp_entry.value_ptr.object.iterator();
        while (inst_it.next()) |inst_entry| {
            const ref = cli.InstanceRef{ .component = comp_entry.key_ptr.*, .name = inst_entry.key_ptr.* };
            runInstanceAction(allocator, ref, action);
            count += 1;
        }
    }

    if (count == 0) {
        printStdout("No instances.\n") catch {};
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
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
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

// TODO(#88): `build.zig` uses `src/main.zig` as the unit-test root, but this
// file had no test wiring at all — `zig build test` therefore executed **zero**
// tests while still reporting success. Wiring the full `root.zig` test block
// surfaces 15 pre-existing compile errors in unrelated modules (supervisor,
// discovery, downloader, managed_skills, compat/fs); those are tracked in #88.
//
// Until #88 lands, wire only the modules this change touches so its regression
// coverage actually runs rather than silently compiling to nothing.
test {
    _ = @import("installer/ui_modules.zig");
}
