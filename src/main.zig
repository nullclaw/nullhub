const std = @import("std");
const builtin = @import("builtin");
pub const root = @import("root.zig");
const cli = root.cli;
const server = root.server;
const paths_mod = root.paths;
const manager_mod = root.manager;

const version = "2026.3.2";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    const command = cli.parse(&args);

    switch (command) {
        .version => std.debug.print("nullhub v{s}\n", .{version}),
        .serve => |opts| {
            std.debug.print("nullhub v{s}\n", .{version});

            var paths = try paths_mod.Paths.init(allocator, null);
            defer paths.deinit(allocator);
            try paths.ensureDirs();

            var mgr = manager_mod.Manager.init(allocator, paths);
            defer mgr.deinit();
            var mutex = std.Thread.Mutex{};

            var srv = try server.Server.init(allocator, opts.host, opts.port, &mgr, &mutex);
            defer srv.deinit();

            const sup_thread = try std.Thread.spawn(.{}, supervisorLoop, .{ &mgr, &mutex });
            sup_thread.detach();

            srv.autoStartAll();

            if (!opts.no_open) openBrowser(allocator, opts.host, opts.port);

            try srv.run();
        },
        .status => |opts| {
            if (opts.instance) |inst| {
                std.debug.print("status for {s}/{s} (not yet implemented)\n", .{ inst.component, inst.name });
            } else {
                std.debug.print("status: no instances (not yet implemented)\n", .{});
            }
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
        .service => |sc| std.debug.print("service {s} (not yet implemented)\n", .{@tagName(sc)}),
        .uninstall => |opts| {
            std.debug.print("uninstall {s}/{s}", .{ opts.instance.component, opts.instance.name });
            if (opts.remove_data) std.debug.print(" --remove-data", .{});
            std.debug.print(" (not yet implemented)\n", .{});
        },
        .add_source => |opts| std.debug.print("add-source {s} (not yet implemented)\n", .{opts.repo}),
        .help => cli.printUsage(),
    }
}

fn supervisorLoop(manager: *manager_mod.Manager, mutex: *std.Thread.Mutex) void {
    while (true) {
        {
            mutex.lock();
            defer mutex.unlock();
            manager.tick();
        }
        std.Thread.sleep(1_000_000_000); // 1 second
    }
}

fn openBrowser(allocator: std.mem.Allocator, host: []const u8, port: u16) void {
    const url = std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, port }) catch return;
    defer allocator.free(url);

    const open_cmd = comptime switch (builtin.os.tag) {
        .macos => "open",
        .windows => "start",
        else => "xdg-open",
    };

    var child = std.process.Child.init(&.{ open_cmd, url }, allocator);
    _ = child.spawnAndWait() catch return;
}
