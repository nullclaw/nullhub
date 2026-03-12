const std = @import("std");
const builtin = @import("builtin");

pub const ServiceCommand = enum {
    install,
    uninstall,
    status,
};

pub const ServiceError = error{
    CommandFailed,
    NoHomeDir,
    UnsupportedPlatform,
    SystemctlUnavailable,
    SystemdUserUnavailable,
};

pub const ServiceStatus = struct {
    service_type: []const u8,
    registered: bool,
    running: bool,
    unit_path: []const u8,

    pub fn deinit(self: *ServiceStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.unit_path);
        self.* = undefined;
    }
};

const SERVICE_LABEL = "com.nullhub.server";
const SERVICE_NAME = "nullhub.service";

pub fn install(allocator: std.mem.Allocator) !void {
    switch (builtin.os.tag) {
        .macos => try installMacos(allocator),
        .linux => try installLinux(allocator),
        else => return error.UnsupportedPlatform,
    }
}

pub fn uninstall(allocator: std.mem.Allocator) !void {
    switch (builtin.os.tag) {
        .macos => try uninstallMacos(allocator),
        .linux => try uninstallLinux(allocator),
        else => return error.UnsupportedPlatform,
    }
}

pub fn queryStatus(allocator: std.mem.Allocator) !ServiceStatus {
    return switch (builtin.os.tag) {
        .macos => queryStatusMacos(allocator),
        .linux => queryStatusLinux(allocator),
        else => error.UnsupportedPlatform,
    };
}

pub fn plannedStatus(allocator: std.mem.Allocator) !ServiceStatus {
    const unit_path = switch (builtin.os.tag) {
        .macos => try macosServiceFile(allocator),
        .linux => try linuxServiceFile(allocator),
        else => return error.UnsupportedPlatform,
    };
    return .{
        .service_type = serviceType(),
        .registered = false,
        .running = false,
        .unit_path = unit_path,
    };
}

pub fn printStatus(allocator: std.mem.Allocator) !void {
    var status = try queryStatus(allocator);
    defer status.deinit(allocator);

    var stdout_buf: [1024]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &bw.interface;

    try w.print("Service type: {s}\n", .{status.service_type});
    try w.print("Registered: {s}\n", .{if (status.registered) "yes" else "no"});
    try w.print("Running: {s}\n", .{if (status.running) "yes" else "no"});
    try w.print("Unit: {s}\n", .{status.unit_path});
    try w.flush();
}

fn installMacos(allocator: std.mem.Allocator) !void {
    const plist = try macosServiceFile(allocator);
    defer allocator.free(plist);

    if (std.mem.lastIndexOfScalar(u8, plist, '/')) |idx| {
        try std.fs.cwd().makePath(plist[0..idx]);
    }

    const service_exe_path = try resolveServiceExecutablePath(allocator);
    defer allocator.free(service_exe_path);

    const home = try getHomeDir(allocator);
    defer allocator.free(home);

    const logs_dir = try std.fs.path.join(allocator, &.{ home, ".nullhub", "logs" });
    defer allocator.free(logs_dir);
    try std.fs.cwd().makePath(logs_dir);

    const stdout_log = try std.fs.path.join(allocator, &.{ logs_dir, "nullhub.stdout.log" });
    defer allocator.free(stdout_log);
    const stderr_log = try std.fs.path.join(allocator, &.{ logs_dir, "nullhub.stderr.log" });
    defer allocator.free(stderr_log);
    const escaped_exe = try xmlEscapeOwned(allocator, service_exe_path);
    defer allocator.free(escaped_exe);
    const escaped_stdout = try xmlEscapeOwned(allocator, stdout_log);
    defer allocator.free(escaped_stdout);
    const escaped_stderr = try xmlEscapeOwned(allocator, stderr_log);
    defer allocator.free(escaped_stderr);

    const content = try std.fmt.allocPrint(allocator,
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        \\<plist version="1.0">
        \\<dict>
        \\  <key>Label</key>
        \\  <string>{s}</string>
        \\  <key>ProgramArguments</key>
        \\  <array>
        \\    <string>{s}</string>
        \\    <string>serve</string>
        \\    <string>--no-open</string>
        \\  </array>
        \\  <key>RunAtLoad</key>
        \\  <true/>
        \\  <key>KeepAlive</key>
        \\  <true/>
        \\  <key>StandardOutPath</key>
        \\  <string>{s}</string>
        \\  <key>StandardErrorPath</key>
        \\  <string>{s}</string>
        \\</dict>
        \\</plist>
    , .{ SERVICE_LABEL, escaped_exe, escaped_stdout, escaped_stderr });
    defer allocator.free(content);

    const file = try std.fs.createFileAbsolute(plist, .{});
    defer file.close();
    try file.writeAll(content);

    runChecked(allocator, &.{ "launchctl", "unload", "-w", plist }) catch {};
    try runChecked(allocator, &.{ "launchctl", "load", "-w", plist });
}

fn uninstallMacos(allocator: std.mem.Allocator) !void {
    const plist = try macosServiceFile(allocator);
    defer allocator.free(plist);

    runChecked(allocator, &.{ "launchctl", "unload", "-w", plist }) catch {};
    std.fs.deleteFileAbsolute(plist) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn queryStatusMacos(allocator: std.mem.Allocator) !ServiceStatus {
    const plist = try macosServiceFile(allocator);
    errdefer allocator.free(plist);

    const registered = fileExistsAbsolute(plist);
    const output = runCapture(allocator, &.{ "launchctl", "list" }) catch try allocator.dupe(u8, "");
    defer allocator.free(output);

    return .{
        .service_type = serviceType(),
        .registered = registered,
        .running = std.mem.indexOf(u8, output, SERVICE_LABEL) != null,
        .unit_path = plist,
    };
}

fn installLinux(allocator: std.mem.Allocator) !void {
    try assertLinuxSystemdUserAvailable(allocator);

    const unit = try linuxServiceFile(allocator);
    defer allocator.free(unit);

    if (std.mem.lastIndexOfScalar(u8, unit, '/')) |idx| {
        try std.fs.cwd().makePath(unit[0..idx]);
    }

    const service_exe_path = try resolveServiceExecutablePath(allocator);
    defer allocator.free(service_exe_path);

    const content = try std.fmt.allocPrint(allocator,
        \\[Unit]
        \\Description=nullhub management server
        \\After=network.target
        \\
        \\[Service]
        \\Type=simple
        \\ExecStart={s} serve --no-open
        \\Restart=always
        \\RestartSec=3
        \\
        \\[Install]
        \\WantedBy=default.target
    , .{service_exe_path});
    defer allocator.free(content);

    const file = try std.fs.createFileAbsolute(unit, .{});
    defer file.close();
    try file.writeAll(content);

    try runChecked(allocator, &.{ "systemctl", "--user", "daemon-reload" });
    try runChecked(allocator, &.{ "systemctl", "--user", "enable", "--now", SERVICE_NAME });
}

fn uninstallLinux(allocator: std.mem.Allocator) !void {
    const unit = try linuxServiceFile(allocator);
    defer allocator.free(unit);

    if (assertLinuxSystemdUserAvailable(allocator)) |_| {
        runChecked(allocator, &.{ "systemctl", "--user", "disable", "--now", SERVICE_NAME }) catch {};
        runChecked(allocator, &.{ "systemctl", "--user", "daemon-reload" }) catch {};
    } else |_| {}

    std.fs.deleteFileAbsolute(unit) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
}

fn queryStatusLinux(allocator: std.mem.Allocator) !ServiceStatus {
    const unit = try linuxServiceFile(allocator);
    errdefer allocator.free(unit);

    const registered = fileExistsAbsolute(unit);
    var running = false;

    if (registered) {
        if (assertLinuxSystemdUserAvailable(allocator)) |_| {
            const output = runCapture(allocator, &.{ "systemctl", "--user", "is-active", SERVICE_NAME }) catch try allocator.dupe(u8, "inactive");
            defer allocator.free(output);
            const trimmed = std.mem.trim(u8, output, " \t\r\n");
            running = std.mem.eql(u8, trimmed, "active");
        } else |_| {}
    }

    return .{
        .service_type = serviceType(),
        .registered = registered,
        .running = running,
        .unit_path = unit,
    };
}

fn serviceType() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "launchd",
        .linux => "systemd",
        else => "unsupported",
    };
}

fn resolveServiceExecutablePath(allocator: std.mem.Allocator) ![]u8 {
    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_path = try std.fs.selfExePath(&exe_buf);
    if (try preferredHomebrewShimPath(allocator, exe_path)) |candidate| {
        if (fileExistsAbsolute(candidate)) return candidate;
        allocator.free(candidate);
    }
    return allocator.dupe(u8, exe_path);
}

fn preferredHomebrewShimPath(allocator: std.mem.Allocator, exe_path: []const u8) !?[]u8 {
    if (!std.mem.endsWith(u8, exe_path, "/bin/nullhub")) return null;

    const cellar_marker = "/Cellar/nullhub/";
    const cellar_index = std.mem.indexOf(u8, exe_path, cellar_marker) orelse return null;
    if (cellar_index == 0) return null;

    const candidate = try std.fmt.allocPrint(allocator, "{s}/bin/nullhub", .{exe_path[0..cellar_index]});
    return candidate;
}

fn macosServiceFile(allocator: std.mem.Allocator) ![]u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, "Library", "LaunchAgents", "com.nullhub.server.plist" });
}

fn linuxServiceFile(allocator: std.mem.Allocator) ![]u8 {
    const home = try getHomeDir(allocator);
    defer allocator.free(home);
    return std.fs.path.join(allocator, &.{ home, ".config", "systemd", "user", SERVICE_NAME });
}

fn getHomeDir(allocator: std.mem.Allocator) ![]u8 {
    return std.process.getEnvVarOwned(allocator, "HOME") catch error.NoHomeDir;
}

fn xmlEscapeOwned(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    for (input) |char| switch (char) {
        '&' => try buf.appendSlice("&amp;"),
        '<' => try buf.appendSlice("&lt;"),
        '>' => try buf.appendSlice("&gt;"),
        '"' => try buf.appendSlice("&quot;"),
        '\'' => try buf.appendSlice("&apos;"),
        else => try buf.append(char),
    };

    return try buf.toOwnedSlice();
}

fn fileExistsAbsolute(path: []const u8) bool {
    std.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn assertLinuxSystemdUserAvailable(allocator: std.mem.Allocator) !void {
    if (builtin.os.tag != .linux) return error.UnsupportedPlatform;

    const status = try runCaptureStatus(allocator, &.{ "systemctl", "--user", "is-active", SERVICE_NAME });
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);

    const detail = captureStatusDetail(&status);
    if (isSystemctlMissingDetail(detail)) return error.SystemctlUnavailable;
    if (isSystemdUnavailableDetail(detail)) return error.SystemdUserUnavailable;
}

const CaptureStatus = struct {
    success: bool,
    stdout: []u8,
    stderr: []u8,
};

fn runChecked(allocator: std.mem.Allocator, argv: []const []const u8) !void {
    const status = try runCaptureStatus(allocator, argv);
    defer allocator.free(status.stdout);
    defer allocator.free(status.stderr);
    if (status.success) return;
    return error.CommandFailed;
}

fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    const status = try runCaptureStatus(allocator, argv);
    defer allocator.free(status.stderr);
    if (!status.success) {
        allocator.free(status.stdout);
        return error.CommandFailed;
    }
    return status.stdout;
}

fn runCaptureStatus(allocator: std.mem.Allocator, argv: []const []const u8) !CaptureStatus {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch |err| switch (err) {
        error.FileNotFound => {
            return .{
                .success = false,
                .stdout = try allocator.dupe(u8, ""),
                .stderr = try allocator.dupe(u8, "command not found"),
            };
        },
        else => return err,
    };

    return .{
        .success = switch (result.term) {
            .Exited => |code| code == 0,
            else => false,
        },
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn captureStatusDetail(status: *const CaptureStatus) []const u8 {
    if (status.stderr.len > 0) return status.stderr;
    return status.stdout;
}

fn isSystemctlMissingDetail(detail: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(detail, "command not found") != null or
        std.ascii.indexOfIgnoreCase(detail, "not found") != null;
}

fn isSystemdUnavailableDetail(detail: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(detail, "Failed to connect to bus") != null or
        std.ascii.indexOfIgnoreCase(detail, "system has not been booted with systemd") != null or
        std.ascii.indexOfIgnoreCase(detail, "not been booted with systemd") != null;
}

test "preferredHomebrewShimPath resolves Apple Silicon Cellar install" {
    const shim = (try preferredHomebrewShimPath(std.testing.allocator, "/opt/homebrew/Cellar/nullhub/2026.3.7/bin/nullhub")).?;
    defer std.testing.allocator.free(shim);
    try std.testing.expectEqualStrings("/opt/homebrew/bin/nullhub", shim);
}

test "preferredHomebrewShimPath resolves Linux Homebrew Cellar install" {
    const shim = (try preferredHomebrewShimPath(std.testing.allocator, "/home/linuxbrew/.linuxbrew/Cellar/nullhub/2026.3.7/bin/nullhub")).?;
    defer std.testing.allocator.free(shim);
    try std.testing.expectEqualStrings("/home/linuxbrew/.linuxbrew/bin/nullhub", shim);
}

test "preferredHomebrewShimPath ignores non-Cellar paths" {
    try std.testing.expect((try preferredHomebrewShimPath(std.testing.allocator, "/usr/local/bin/nullhub")) == null);
}
