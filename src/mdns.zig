const std = @import("std");
const builtin = @import("builtin");
const access = @import("access.zig");
const paths_mod = @import("core/paths.zig");
const process_mod = @import("supervisor/process.zig");

pub const Provider = enum {
    none,
    system,
    dns_sd,
    avahi,

    pub fn toString(self: Provider) []const u8 {
        return switch (self) {
            .none => "none",
            .system => "system",
            .dns_sd => "dns-sd",
            .avahi => "avahi",
        };
    }
};

pub const Publisher = struct {
    allocator: std.mem.Allocator,
    provider: Provider = .none,
    alias_active: bool = false,
    log_path: ?[]u8 = null,
    children: [2]?std.process.Child = .{ null, null },

    pub fn init(allocator: std.mem.Allocator, paths: paths_mod.Paths, host: []const u8, port: u16) !Publisher {
        var self = Publisher{ .allocator = allocator };
        if (!access.isLocalBindHost(host) or builtin.is_test) return self;

        self.log_path = try std.fs.path.join(allocator, &.{ paths.root, "cache", "mdns.log" });
        errdefer if (self.log_path) |path| allocator.free(path);

        self.activate(port);
        return self;
    }

    pub fn deinit(self: *Publisher) void {
        self.stopChildren();
        if (self.log_path) |path| self.allocator.free(path);
    }

    pub fn accessOptions(self: *const Publisher) access.Options {
        return .{
            .public_alias_active = self.alias_active,
            .public_alias_provider = self.provider.toString(),
        };
    }

    fn activate(self: *Publisher, port: u16) void {
        if (self.tryDnsSd(port)) return;
        if (self.tryAvahi(port)) return;
    }

    fn tryDnsSd(self: *Publisher, port: u16) bool {
        const binary = if (commandAvailable(self.allocator, "dns-sd", &.{"-h"}))
            "dns-sd"
        else if (commandAvailable(self.allocator, "dns-sd.exe", &.{"-h"}))
            "dns-sd.exe"
        else
            return false;

        const log_path = self.log_path orelse return false;
        var port_buf: [16]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return false;

        const result = process_mod.spawn(self.allocator, .{
            .binary = binary,
            .argv = &.{ "-P", "nullhub", "_http._tcp", "local", port_str, access.public_alias_host, access.fallback_local_host, "path=/" },
            .stdout_path = log_path,
            .stderr_path = log_path,
        }) catch return false;

        self.children[0] = result.child;
        self.alias_active = true;
        self.provider = .dns_sd;
        return true;
    }

    fn tryAvahi(self: *Publisher, port: u16) bool {
        if (!commandAvailable(self.allocator, "avahi-publish", &.{"--help"})) return false;

        const log_path = self.log_path orelse return false;
        var port_buf: [16]u8 = undefined;
        const port_str = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return false;

        const alias_child = process_mod.spawn(self.allocator, .{
            .binary = "avahi-publish",
            .argv = &.{ "-a", "-R", access.public_alias_host, access.fallback_local_host },
            .stdout_path = log_path,
            .stderr_path = log_path,
        }) catch return false;
        self.children[0] = alias_child.child;

        const service_child = process_mod.spawn(self.allocator, .{
            .binary = "avahi-publish",
            .argv = &.{ "-s", "nullhub", "_http._tcp", port_str, "path=/" },
            .stdout_path = log_path,
            .stderr_path = log_path,
        }) catch {
            self.stopChildren();
            return false;
        };
        self.children[1] = service_child.child;

        self.alias_active = true;
        self.provider = .avahi;
        return true;
    }

    fn stopChildren(self: *Publisher) void {
        for (&self.children) |*entry| {
            if (entry.*) |*child| {
                process_mod.terminate(child.id) catch {};
                process_mod.forceKill(child.id) catch {};
                _ = child.wait() catch {};
                entry.* = null;
            }
        }
    }
};

fn commandAvailable(allocator: std.mem.Allocator, binary: []const u8, args: []const []const u8) bool {
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    argv.append(binary) catch return false;
    for (args) |arg| argv.append(arg) catch return false;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 8 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return true;
}

test "provider toString is stable" {
    try std.testing.expectEqualStrings("dns-sd", Provider.dns_sd.toString());
    try std.testing.expectEqualStrings("avahi", Provider.avahi.toString());
    try std.testing.expectEqualStrings("system", Provider.system.toString());
    try std.testing.expectEqualStrings("none", Provider.none.toString());
}
