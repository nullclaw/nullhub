const std = @import("std");
pub const root = @import("root.zig");

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    var command: ?[]const u8 = null;
    var host: []const u8 = "127.0.0.1";
    var port: u16 = 9800;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--version")) {
            std.debug.print("nullhub v{s}\n", .{version});
            return;
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (args.next()) |val| {
                host = val;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |val| {
                port = std.fmt.parseInt(u16, val, 10) catch {
                    std.debug.print("invalid port: {s}\n", .{val});
                    return;
                };
            }
        } else if (command == null) {
            command = arg;
        }
    }

    const cmd = command orelse "serve";

    if (std.mem.eql(u8, cmd, "version")) {
        std.debug.print("nullhub v{s}\n", .{version});
        return;
    }

    if (std.mem.eql(u8, cmd, "serve")) {
        std.debug.print("nullhub v{s}\n", .{version});
        var server = root.server.Server.init(allocator, host, port);
        try server.run();
        return;
    }

    std.debug.print("nullhub v{s}\n", .{version});
    std.debug.print("usage: nullhub [serve|install|start|stop|status|version]\n", .{});
}
