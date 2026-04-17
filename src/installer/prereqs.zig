const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");

const log = std.log.scoped(.prereqs);

pub const EnsureError = error{
    ToolInstallFailed,
    UnsupportedPlatform,
};

const PackageManager = enum {
    apt,
    dnf,
    yum,
    pacman,
    zypper,
    apk,
    brew,
    winget,
    choco,
};

pub fn ensureTools(allocator: std.mem.Allocator, tools: []const []const u8) EnsureError!void {
    for (tools) |tool| try ensureTool(allocator, tool);
}

pub fn ensureTool(allocator: std.mem.Allocator, tool: []const u8) EnsureError!void {
    // Keep tests deterministic/offline.
    if (builtin.is_test) return;

    if (isCommandAvailable(allocator, tool)) return;
    log.warn("required tool '{s}' is missing, attempting auto-install", .{tool});

    const ok = installTool(allocator, tool) catch false;
    if (!ok or !isCommandAvailable(allocator, tool)) {
        log.err("failed to auto-install required tool '{s}'", .{tool});
        return error.ToolInstallFailed;
    }
}

fn installTool(allocator: std.mem.Allocator, tool: []const u8) !bool {
    return switch (builtin.os.tag) {
        .linux => installOnLinux(allocator, tool),
        .macos => installOnMacos(allocator, tool),
        .windows => installOnWindows(allocator, tool),
        else => error.UnsupportedPlatform,
    };
}

fn isElevated() bool {
    if (builtin.os.tag == .windows) return false;
    if (@hasDecl(std.posix, "geteuid")) return std.posix.geteuid() == 0;
    return false;
}

fn isCommandAvailable(allocator: std.mem.Allocator, command: []const u8) bool {
    return runCommand(allocator, &.{ command, "--version" }) or
        runCommand(allocator, &.{ command, "-V" }) or
        runCommand(allocator, &.{ command, "-v" });
}

fn runCommand(allocator: std.mem.Allocator, argv: []const []const u8) bool {
    const result = std_compat.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .max_output_bytes = 64 * 1024,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn detectLinuxManager(allocator: std.mem.Allocator) ?PackageManager {
    if (isCommandAvailable(allocator, "apt-get")) return .apt;
    if (isCommandAvailable(allocator, "dnf")) return .dnf;
    if (isCommandAvailable(allocator, "yum")) return .yum;
    if (isCommandAvailable(allocator, "pacman")) return .pacman;
    if (isCommandAvailable(allocator, "zypper")) return .zypper;
    if (isCommandAvailable(allocator, "apk")) return .apk;
    return null;
}

fn packageName(pm: PackageManager, tool: []const u8) []const u8 {
    return switch (pm) {
        .winget => if (std.mem.eql(u8, tool, "curl")) "cURL.cURL" else if (std.mem.eql(u8, tool, "tar")) "GnuWin32.Tar" else tool,
        .choco => if (std.mem.eql(u8, tool, "tar")) "gnuwin32-tar" else tool,
        else => tool,
    };
}

fn runWithOptionalSudo(allocator: std.mem.Allocator, direct: []const []const u8, with_sudo: []const []const u8) bool {
    if (isElevated()) return runCommand(allocator, direct);
    if (!isCommandAvailable(allocator, "sudo")) return false;
    return runCommand(allocator, with_sudo);
}

fn installViaManager(allocator: std.mem.Allocator, pm: PackageManager, tool: []const u8) bool {
    const pkg = packageName(pm, tool);
    return switch (pm) {
        .apt => runWithOptionalSudo(
            allocator,
            &.{ "apt-get", "install", "-y", pkg },
            &.{ "sudo", "-n", "apt-get", "install", "-y", pkg },
        ),
        .dnf => runWithOptionalSudo(
            allocator,
            &.{ "dnf", "install", "-y", pkg },
            &.{ "sudo", "-n", "dnf", "install", "-y", pkg },
        ),
        .yum => runWithOptionalSudo(
            allocator,
            &.{ "yum", "install", "-y", pkg },
            &.{ "sudo", "-n", "yum", "install", "-y", pkg },
        ),
        .pacman => runWithOptionalSudo(
            allocator,
            &.{ "pacman", "-S", "--noconfirm", pkg },
            &.{ "sudo", "-n", "pacman", "-S", "--noconfirm", pkg },
        ),
        .zypper => runWithOptionalSudo(
            allocator,
            &.{ "zypper", "--non-interactive", "install", pkg },
            &.{ "sudo", "-n", "zypper", "--non-interactive", "install", pkg },
        ),
        .apk => runWithOptionalSudo(
            allocator,
            &.{ "apk", "add", "--no-cache", pkg },
            &.{ "sudo", "-n", "apk", "add", "--no-cache", pkg },
        ),
        .brew => runCommand(allocator, &.{ "brew", "install", pkg }),
        .winget => runCommand(
            allocator,
            &.{ "winget", "install", "--id", pkg, "-e", "--accept-package-agreements", "--accept-source-agreements" },
        ),
        .choco => runCommand(allocator, &.{ "choco", "install", pkg, "-y" }),
    };
}

fn installOnLinux(allocator: std.mem.Allocator, tool: []const u8) bool {
    const pm = detectLinuxManager(allocator) orelse return false;
    return installViaManager(allocator, pm, tool);
}

fn installOnMacos(allocator: std.mem.Allocator, tool: []const u8) bool {
    if (!isCommandAvailable(allocator, "brew")) return false;
    return installViaManager(allocator, .brew, tool);
}

fn installOnWindows(allocator: std.mem.Allocator, tool: []const u8) bool {
    if (isCommandAvailable(allocator, "winget")) {
        if (installViaManager(allocator, .winget, tool)) return true;
    }
    if (isCommandAvailable(allocator, "choco")) {
        if (installViaManager(allocator, .choco, tool)) return true;
    }
    return false;
}

test "packageName maps windows package ids" {
    try std.testing.expectEqualStrings("cURL.cURL", packageName(.winget, "curl"));
    try std.testing.expectEqualStrings("GnuWin32.Tar", packageName(.winget, "tar"));
    try std.testing.expectEqualStrings("gnuwin32-tar", packageName(.choco, "tar"));
    try std.testing.expectEqualStrings("curl", packageName(.choco, "curl"));
}

test "ensureTool is no-op in tests" {
    try ensureTool(std.testing.allocator, "definitely-not-installed-tool");
}
