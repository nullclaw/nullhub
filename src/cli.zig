const std = @import("std");
const access = @import("access.zig");

// ─── Option Types ────────────────────────────────────────────────────────────

pub const ServeOptions = struct {
    port: u16 = access.default_port,
    host: []const u8 = access.default_bind_host,
    no_open: bool = false,
};

pub const InstanceRef = struct {
    component: []const u8,
    name: []const u8,
};

pub const StatusOptions = struct {
    instance: ?InstanceRef = null,
    host: []const u8 = access.default_bind_host,
    port: u16 = access.default_port,
};

pub const InstallOptions = struct {
    component: []const u8,
    name: ?[]const u8 = null,
    version: ?[]const u8 = null,
    build_from_source: bool = false,
};

pub const LogsOptions = struct {
    instance: InstanceRef,
    follow: bool = false,
    lines: u32 = 100,
};

pub const ConfigOptions = struct {
    instance: InstanceRef,
    edit: bool = false,
};

pub const WizardOptions = struct {
    component: []const u8,
};

pub const ApiOptions = struct {
    method: []const u8,
    target: []const u8,
    host: []const u8 = access.default_bind_host,
    port: u16 = access.default_port,
    body: ?[]const u8 = null,
    body_file: ?[]const u8 = null,
    token: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
    pretty: bool = false,
};

pub const ServiceCommand = enum {
    install,
    uninstall,
    status,

    pub fn fromStr(s: []const u8) ?ServiceCommand {
        if (std.mem.eql(u8, s, "install")) return .install;
        if (std.mem.eql(u8, s, "uninstall")) return .uninstall;
        if (std.mem.eql(u8, s, "status")) return .status;
        return null;
    }
};

pub const UninstallOptions = struct {
    instance: InstanceRef,
    remove_data: bool = false,
};

pub const AddSourceOptions = struct {
    repo: []const u8,
};

// ─── Command Union ───────────────────────────────────────────────────────────

pub const Command = union(enum) {
    serve: ServeOptions,
    version,
    status: StatusOptions,
    install: InstallOptions,
    start: InstanceRef,
    stop: InstanceRef,
    restart: InstanceRef,
    start_all,
    stop_all,
    logs: LogsOptions,
    check_updates,
    update: InstanceRef,
    update_all,
    config: ConfigOptions,
    wizard: WizardOptions,
    api: ApiOptions,
    service: ServiceCommand,
    uninstall: UninstallOptions,
    add_source: AddSourceOptions,
    help,
};

// ─── Parsing ─────────────────────────────────────────────────────────────────

pub fn parseInstanceRef(arg: []const u8) ?InstanceRef {
    const sep = std.mem.indexOfScalar(u8, arg, '/') orelse return null;
    if (sep == 0 or sep == arg.len - 1) return null;
    return .{
        .component = arg[0..sep],
        .name = arg[sep + 1 ..],
    };
}

/// Parse CLI arguments into a Command. Expects `args` to have already
/// consumed the program name (argv[0]).
pub fn parse(args: *std.process.ArgIterator) Command {
    const cmd = args.next() orelse return .{ .serve = .{} };

    if (std.mem.eql(u8, cmd, "serve")) {
        return parseServe(args);
    }
    if (std.mem.eql(u8, cmd, "version") or std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v")) {
        return .version;
    }
    if (std.mem.eql(u8, cmd, "status")) {
        return parseStatus(args);
    }
    if (std.mem.eql(u8, cmd, "install")) {
        return parseInstall(args);
    }
    if (std.mem.eql(u8, cmd, "start")) {
        return parseInstanceCommand(args, .start);
    }
    if (std.mem.eql(u8, cmd, "stop")) {
        return parseInstanceCommand(args, .stop);
    }
    if (std.mem.eql(u8, cmd, "restart")) {
        return parseInstanceCommand(args, .restart);
    }
    if (std.mem.eql(u8, cmd, "start-all")) {
        return .start_all;
    }
    if (std.mem.eql(u8, cmd, "stop-all")) {
        return .stop_all;
    }
    if (std.mem.eql(u8, cmd, "logs")) {
        return parseLogs(args);
    }
    if (std.mem.eql(u8, cmd, "check-updates")) {
        return .check_updates;
    }
    if (std.mem.eql(u8, cmd, "update")) {
        return parseInstanceCommand(args, .update);
    }
    if (std.mem.eql(u8, cmd, "update-all")) {
        return .update_all;
    }
    if (std.mem.eql(u8, cmd, "config")) {
        return parseConfig(args);
    }
    if (std.mem.eql(u8, cmd, "wizard")) {
        return parseWizard(args);
    }
    if (std.mem.eql(u8, cmd, "api")) {
        return parseApi(args);
    }
    if (std.mem.eql(u8, cmd, "service")) {
        return parseService(args);
    }
    if (std.mem.eql(u8, cmd, "uninstall")) {
        return parseUninstall(args);
    }
    if (std.mem.eql(u8, cmd, "add-source")) {
        return parseAddSource(args);
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return .help;
    }

    return .help;
}

// ─── Sub-parsers ─────────────────────────────────────────────────────────────

fn parseServe(args: *std.process.ArgIterator) Command {
    var opts = ServeOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |val| {
                opts.port = std.fmt.parseInt(u16, val, 10) catch access.default_port;
            }
        } else if (std.mem.eql(u8, arg, "--host")) {
            if (args.next()) |val| {
                opts.host = val;
            }
        } else if (std.mem.eql(u8, arg, "--no-open")) {
            opts.no_open = true;
        }
    }
    return .{ .serve = opts };
}

fn parseStatus(args: *std.process.ArgIterator) Command {
    var opts = StatusOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            if (args.next()) |val| opts.host = val;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |val| {
                opts.port = std.fmt.parseInt(u16, val, 10) catch access.default_port;
            }
        } else if (arg.len > 0 and arg[0] != '-') {
            opts.instance = parseInstanceRef(arg);
            break;
        }
    }
    return .{ .status = opts };
}

const InstanceTag = enum { start, stop, restart, update };

fn parseInstanceCommand(args: *std.process.ArgIterator, tag: InstanceTag) Command {
    const arg = args.next() orelse return .help;
    const ref = parseInstanceRef(arg) orelse return .help;
    return switch (tag) {
        .start => .{ .start = ref },
        .stop => .{ .stop = ref },
        .restart => .{ .restart = ref },
        .update => .{ .update = ref },
    };
}

fn parseInstall(args: *std.process.ArgIterator) Command {
    const component = args.next() orelse return .help;
    if (component.len == 0 or component[0] == '-') return .help;

    var opts = InstallOptions{ .component = component };
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name")) {
            if (args.next()) |val| {
                opts.name = val;
            }
        } else if (std.mem.eql(u8, arg, "--version")) {
            if (args.next()) |val| {
                opts.version = val;
            }
        } else if (std.mem.eql(u8, arg, "--build-from-source")) {
            opts.build_from_source = true;
        }
    }
    return .{ .install = opts };
}

fn parseLogs(args: *std.process.ArgIterator) Command {
    const arg = args.next() orelse return .help;
    const ref = parseInstanceRef(arg) orelse return .help;

    var opts = LogsOptions{ .instance = ref };
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "-f") or std.mem.eql(u8, a, "--follow")) {
            opts.follow = true;
        } else if (std.mem.eql(u8, a, "--lines")) {
            if (args.next()) |val| {
                opts.lines = std.fmt.parseInt(u32, val, 10) catch 100;
            }
        }
    }
    return .{ .logs = opts };
}

fn parseConfig(args: *std.process.ArgIterator) Command {
    const arg = args.next() orelse return .help;
    const ref = parseInstanceRef(arg) orelse return .help;

    var opts = ConfigOptions{ .instance = ref };
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--edit")) {
            opts.edit = true;
        }
    }
    return .{ .config = opts };
}

fn parseWizard(args: *std.process.ArgIterator) Command {
    const component = args.next() orelse return .help;
    if (component.len == 0 or component[0] == '-') return .help;
    return .{ .wizard = .{ .component = component } };
}

fn parseService(args: *std.process.ArgIterator) Command {
    const sub = args.next() orelse return .help;
    const sc = ServiceCommand.fromStr(sub) orelse return .help;
    return .{ .service = sc };
}

fn parseApi(args: *std.process.ArgIterator) Command {
    const method = args.next() orelse return .help;
    const target = args.next() orelse return .help;

    var opts = ApiOptions{
        .method = method,
        .target = target,
    };
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            if (args.next()) |val| opts.host = val;
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |val| {
                opts.port = std.fmt.parseInt(u16, val, 10) catch access.default_port;
            }
        } else if (std.mem.eql(u8, arg, "--body")) {
            if (args.next()) |val| opts.body = val;
        } else if (std.mem.eql(u8, arg, "--body-file")) {
            if (args.next()) |val| opts.body_file = val;
        } else if (std.mem.eql(u8, arg, "--token")) {
            if (args.next()) |val| opts.token = val;
        } else if (std.mem.eql(u8, arg, "--content-type")) {
            if (args.next()) |val| opts.content_type = val;
        } else if (std.mem.eql(u8, arg, "--pretty")) {
            opts.pretty = true;
        }
    }
    return .{ .api = opts };
}

fn parseUninstall(args: *std.process.ArgIterator) Command {
    const arg = args.next() orelse return .help;
    const ref = parseInstanceRef(arg) orelse return .help;

    var opts = UninstallOptions{ .instance = ref };
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--remove-data")) {
            opts.remove_data = true;
        }
    }
    return .{ .uninstall = opts };
}

fn parseAddSource(args: *std.process.ArgIterator) Command {
    const repo = args.next() orelse return .help;
    if (repo.len == 0 or repo[0] == '-') return .help;
    return .{ .add_source = .{ .repo = repo } };
}

// ─── Usage ───────────────────────────────────────────────────────────────────

pub fn printUsage() void {
    std.debug.print(
        \\nullhub — management hub for the nullclaw ecosystem
        \\
        \\Usage: nullhub [command]
        \\
        \\Commands:
        \\  serve                     Start web UI server (default)
        \\  install <component>       Install a component
        \\  start <component/name>    Start an instance
        \\  stop <component/name>     Stop an instance
        \\  restart <component/name>  Restart an instance
        \\  start-all                 Start all auto-start instances
        \\  stop-all                  Stop all instances
        \\  status [component/name]   Show hub or instance status
        \\  logs <component/name>     View instance logs
        \\  config <component/name>   View/edit instance config
        \\  wizard <component>        Run setup wizard
        \\  check-updates             Check for updates
        \\  update <component/name>   Update an instance
        \\  update-all                Update all instances
        \\  api <METHOD> <PATH>       Call any local nullhub HTTP API route
        \\  uninstall <component/name> Remove an instance
        \\  service <install|uninstall|status>  Manage OS service
        \\  add-source <repo-url>     Add custom component source
        \\  version, -v, --version    Show version
        \\
        \\API examples:
        \\  nullhub api GET /api/instances
        \\  nullhub api DELETE /api/instances/nullclaw/demo
        \\  nullhub api POST providers/2/validate
        \\  nullhub api PATCH instances/nullclaw/demo --body '{{"auto_start":true}}'
        \\
    , .{});
}

// ─── Tests ───────────────────────────────────────────────────────────────────

// We cannot directly construct a std.process.ArgIterator from a string slice,
// so we test the helper functions directly and test `parse` via the binary.

test "parseInstanceRef: valid component/name" {
    const ref = parseInstanceRef("nullclaw/my-agent");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("nullclaw", ref.?.component);
    try std.testing.expectEqualStrings("my-agent", ref.?.name);
}

test "parseInstanceRef: no slash returns null" {
    try std.testing.expect(parseInstanceRef("nullclaw") == null);
}

test "parseInstanceRef: leading slash returns null" {
    try std.testing.expect(parseInstanceRef("/name") == null);
}

test "parseInstanceRef: trailing slash returns null" {
    try std.testing.expect(parseInstanceRef("comp/") == null);
}

test "parseInstanceRef: multiple slashes parses first segment" {
    const ref = parseInstanceRef("a/b/c");
    try std.testing.expect(ref != null);
    try std.testing.expectEqualStrings("a", ref.?.component);
    try std.testing.expectEqualStrings("b/c", ref.?.name);
}

test "parseInstanceRef: empty string returns null" {
    try std.testing.expect(parseInstanceRef("") == null);
}

test "ServiceCommand.fromStr valid" {
    try std.testing.expect(ServiceCommand.fromStr("install") == .install);
    try std.testing.expect(ServiceCommand.fromStr("uninstall") == .uninstall);
    try std.testing.expect(ServiceCommand.fromStr("status") == .status);
}

test "ServiceCommand.fromStr invalid returns null" {
    try std.testing.expect(ServiceCommand.fromStr("restart") == null);
    try std.testing.expect(ServiceCommand.fromStr("") == null);
}

test "ServeOptions defaults" {
    const opts = ServeOptions{};
    try std.testing.expectEqual(access.default_port, opts.port);
    try std.testing.expectEqualStrings(access.default_bind_host, opts.host);
    try std.testing.expect(!opts.no_open);
}

test "InstallOptions defaults" {
    const opts = InstallOptions{ .component = "nullclaw" };
    try std.testing.expectEqualStrings("nullclaw", opts.component);
    try std.testing.expect(opts.name == null);
    try std.testing.expect(opts.version == null);
    try std.testing.expect(!opts.build_from_source);
}

test "LogsOptions defaults" {
    const ref = InstanceRef{ .component = "nullclaw", .name = "agent" };
    const opts = LogsOptions{ .instance = ref };
    try std.testing.expect(!opts.follow);
    try std.testing.expectEqual(@as(u32, 100), opts.lines);
}

test "StatusOptions defaults" {
    const opts = StatusOptions{};
    try std.testing.expect(opts.instance == null);
    try std.testing.expectEqualStrings(access.default_bind_host, opts.host);
    try std.testing.expectEqual(access.default_port, opts.port);
}

test "ConfigOptions defaults" {
    const ref = InstanceRef{ .component = "comp", .name = "inst" };
    const opts = ConfigOptions{ .instance = ref };
    try std.testing.expect(!opts.edit);
}

test "UninstallOptions defaults" {
    const ref = InstanceRef{ .component = "comp", .name = "inst" };
    const opts = UninstallOptions{ .instance = ref };
    try std.testing.expect(!opts.remove_data);
}

test "ApiOptions defaults" {
    const opts = ApiOptions{
        .method = "GET",
        .target = "/api/status",
    };
    try std.testing.expectEqualStrings("GET", opts.method);
    try std.testing.expectEqualStrings("/api/status", opts.target);
    try std.testing.expectEqualStrings(access.default_bind_host, opts.host);
    try std.testing.expectEqual(access.default_port, opts.port);
    try std.testing.expect(opts.body == null);
    try std.testing.expect(opts.body_file == null);
    try std.testing.expect(opts.token == null);
    try std.testing.expectEqualStrings("application/json", opts.content_type);
    try std.testing.expect(!opts.pretty);
}
