const std = @import("std");
const access = @import("access.zig");
const report_schema = @import("report_schema.zig");

const ArgIterator = std.process.Args.Iterator;

// ─── Option Types ────────────────────────────────────────────────────────────

pub const ServeOptions = struct {
    port: u16 = access.default_port,
    host: []const u8 = access.default_bind_host,
    no_open: bool = false,
    /// Additional origins accepted by the API CORS/origin guard, in addition
    /// to the bind host and built-in local aliases. Each entry is an origin
    /// of the form `scheme://host[:port]` with no trailing slash.
    extra_allowed_origins: []const []const u8 = &.{},
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

pub const RoutesOptions = struct {
    json: bool = false,
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

pub const ReportRepo = report_schema.ReportRepo;
pub const ReportType = report_schema.ReportType;

pub const ReportOptions = struct {
    repo: ?ReportRepo = null,
    report_type: ?ReportType = null,
    message: ?[]const u8 = null,
    yes: bool = false,
    dry_run: bool = false,
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
    routes: RoutesOptions,
    api: ApiOptions,
    service: ServiceCommand,
    uninstall: UninstallOptions,
    add_source: AddSourceOptions,
    report: ReportOptions,
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
/// consumed the program name (argv[0]). The allocator is used only for
/// subcommands that collect repeatable flags (e.g. `serve --allowed-origin`);
/// any allocations live for the remainder of the process.
pub fn parse(allocator: std.mem.Allocator, args: *ArgIterator) Command {
    const cmd = args.next() orelse return .{ .serve = .{} };

    if (std.mem.eql(u8, cmd, "serve")) {
        return parseServe(allocator, args);
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
    if (std.mem.eql(u8, cmd, "routes")) {
        return parseRoutes(args);
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
    if (std.mem.eql(u8, cmd, "report")) {
        return parseReport(args);
    }
    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h")) {
        return .help;
    }

    return .help;
}

// ─── Sub-parsers ─────────────────────────────────────────────────────────────

fn parseServe(allocator: std.mem.Allocator, args: *ArgIterator) Command {
    var opts = ServeOptions{};
    var origins: std.ArrayListUnmanaged([]const u8) = .empty;
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
        } else if (std.mem.eql(u8, arg, "--allowed-origin")) {
            if (args.next()) |val| {
                if (!appendOriginIfValid(allocator, &origins, val)) {
                    std.debug.print(
                        "nullhub: ignoring invalid --allowed-origin value: {s}\n",
                        .{val},
                    );
                }
            }
        }
    }
    if (origins.items.len > 0) {
        opts.extra_allowed_origins = origins.toOwnedSlice(allocator) catch blk: {
            for (origins.items) |origin| allocator.free(origin);
            origins.deinit(allocator);
            std.debug.print("nullhub: dropped --allowed-origin list (out of memory)\n", .{});
            break :blk &.{};
        };
    }
    return .{ .serve = opts };
}

/// Append a validated, allocator-owned copy of `raw` to `list`. Returns
/// `true` if the value was accepted, `false` if it was rejected (invalid
/// input or OOM). The caller is responsible for freeing each appended
/// string (callers that feed origin lists typically reuse a single
/// allocator and free the entire list at shutdown).
fn appendOriginIfValid(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
    raw: []const u8,
) bool {
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!isValidOrigin(trimmed)) return false;
    const owned = allocator.dupe(u8, trimmed) catch return false;
    list.append(allocator, owned) catch {
        allocator.free(owned);
        return false;
    };
    return true;
}

fn isValidOrigin(origin: []const u8) bool {
    const parsed = std.Uri.parse(origin) catch return false;
    if (!std.ascii.eqlIgnoreCase(parsed.scheme, "http") and !std.ascii.eqlIgnoreCase(parsed.scheme, "https")) {
        return false;
    }

    const host = parsed.host orelse return false;
    if (host.isEmpty()) return false;
    if (parsed.user != null or parsed.password != null) return false;
    if (!parsed.path.isEmpty()) return false;
    if (parsed.query != null or parsed.fragment != null) return false;

    return true;
}

/// Parse a comma-separated list of origins (e.g. from an environment
/// variable) and append any valid entries to `list`. Each accepted entry is
/// copied into `allocator` so the caller may free `csv` afterwards. Returns
/// the number of non-empty entries that were rejected as invalid so the
/// caller can surface a diagnostic.
pub fn appendOriginsFromCsv(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
    csv: []const u8,
) usize {
    var skipped: usize = 0;
    var it = std.mem.splitScalar(u8, csv, ',');
    while (it.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " \t\r\n");
        if (trimmed.len == 0) continue;
        if (!appendOriginIfValid(allocator, list, trimmed)) skipped += 1;
    }
    return skipped;
}

fn parseStatus(args: *ArgIterator) Command {
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

fn parseInstanceCommand(args: *ArgIterator, tag: InstanceTag) Command {
    const arg = args.next() orelse return .help;
    const ref = parseInstanceRef(arg) orelse return .help;
    return switch (tag) {
        .start => .{ .start = ref },
        .stop => .{ .stop = ref },
        .restart => .{ .restart = ref },
        .update => .{ .update = ref },
    };
}

fn parseInstall(args: *ArgIterator) Command {
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

fn parseLogs(args: *ArgIterator) Command {
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

fn parseConfig(args: *ArgIterator) Command {
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

fn parseWizard(args: *ArgIterator) Command {
    const component = args.next() orelse return .help;
    if (component.len == 0 or component[0] == '-') return .help;
    return .{ .wizard = .{ .component = component } };
}

fn parseService(args: *ArgIterator) Command {
    const sub = args.next() orelse return .help;
    const sc = ServiceCommand.fromStr(sub) orelse return .help;
    return .{ .service = sc };
}

fn parseRoutes(args: *ArgIterator) Command {
    var opts = RoutesOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            opts.json = true;
        } else {
            return .help;
        }
    }
    return .{ .routes = opts };
}

fn parseApi(args: *ArgIterator) Command {
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

fn parseUninstall(args: *ArgIterator) Command {
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

fn parseAddSource(args: *ArgIterator) Command {
    const repo = args.next() orelse return .help;
    if (repo.len == 0 or repo[0] == '-') return .help;
    return .{ .add_source = .{ .repo = repo } };
}

fn parseReport(args: *ArgIterator) Command {
    var opts = ReportOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--repo")) {
            if (args.next()) |val| {
                opts.repo = ReportRepo.fromStr(val);
            }
        } else if (std.mem.eql(u8, arg, "--type")) {
            if (args.next()) |val| {
                opts.report_type = ReportType.fromStr(val);
            }
        } else if (std.mem.eql(u8, arg, "--message")) {
            if (args.next()) |val| {
                opts.message = val;
            }
        } else if (std.mem.eql(u8, arg, "--yes")) {
            opts.yes = true;
        } else if (std.mem.eql(u8, arg, "--dry-run")) {
            opts.dry_run = true;
        }
    }
    return .{ .report = opts };
}

// ─── Usage ───────────────────────────────────────────────────────────────────

pub fn printUsage() void {
    std.debug.print(
        \\nullhub — management hub for the nullclaw ecosystem
        \\
        \\Usage: nullhub [command]
        \\
        \\Commands:
        \\  serve [--host H] [--port N] [--no-open]
        \\        [--allowed-origin ORIGIN ...]
        \\                            Start web UI server (default). Repeat
        \\                            --allowed-origin to authorize extra
        \\                            origins (e.g. a Tailscale domain) to
        \\                            call the API. Origins may also come
        \\                            from NULLHUB_ALLOWED_ORIGINS as a
        \\                            comma-separated list.
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
        \\  routes [--json]           List known nullhub API routes
        \\  check-updates             Check for updates
        \\  update <component/name>   Update an instance
        \\  update-all                Update all instances
        \\  api <METHOD> <PATH>       Call any local nullhub HTTP API route
        \\  uninstall <component/name> Remove an instance
        \\  service <install|uninstall|status>  Manage OS service
        \\  add-source <repo-url>     Add custom component source
        \\  report                    Report a bug or feature request
        \\  version, -v, --version    Show version
        \\
        \\API examples:
        \\  nullhub routes --json
        \\  nullhub api GET /api/instances
        \\  nullhub api GET /api/meta/routes --pretty
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
    try std.testing.expectEqual(@as(usize, 0), opts.extra_allowed_origins.len);
}

test "isValidOrigin accepts scheme+host, rejects malformed" {
    try std.testing.expect(isValidOrigin("http://nullhub.local:19800"));
    try std.testing.expect(isValidOrigin("https://hub.tailnet.ts.net"));
    try std.testing.expect(isValidOrigin("http://[::1]:19800"));
    try std.testing.expect(!isValidOrigin(""));
    try std.testing.expect(!isValidOrigin("hub.tailnet.ts.net"));
    try std.testing.expect(!isValidOrigin("ftp://example.com"));
    try std.testing.expect(!isValidOrigin("https://"));
    try std.testing.expect(!isValidOrigin("https://hub.example/"));
    try std.testing.expect(!isValidOrigin("https://hub.example/path"));
    try std.testing.expect(!isValidOrigin("https://hub.example?x=1"));
    try std.testing.expect(!isValidOrigin("https://user@hub.example"));
}

test "appendOriginsFromCsv skips blanks and invalid entries" {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (list.items) |item| std.testing.allocator.free(item);
        list.deinit(std.testing.allocator);
    }
    const skipped = appendOriginsFromCsv(
        std.testing.allocator,
        &list,
        "https://hub.tailnet.ts.net, ,not-a-url,http://10.0.0.1:19800",
    );
    try std.testing.expectEqual(@as(usize, 1), skipped);
    try std.testing.expectEqual(@as(usize, 2), list.items.len);
    try std.testing.expectEqualStrings("https://hub.tailnet.ts.net", list.items[0]);
    try std.testing.expectEqualStrings("http://10.0.0.1:19800", list.items[1]);
}

test "appendOriginsFromCsv copies entries so the source can be freed" {
    const csv = try std.testing.allocator.dupe(u8, "https://hub.tailnet.ts.net");
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (list.items) |item| std.testing.allocator.free(item);
        list.deinit(std.testing.allocator);
    }
    _ = appendOriginsFromCsv(std.testing.allocator, &list, csv);
    std.testing.allocator.free(csv);
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqualStrings("https://hub.tailnet.ts.net", list.items[0]);
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

test "ReportRepo.fromStr valid" {
    try std.testing.expect(ReportRepo.fromStr("nullhub") == .nullhub);
    try std.testing.expect(ReportRepo.fromStr("nullclaw") == .nullclaw);
    try std.testing.expect(ReportRepo.fromStr("nullboiler") == .nullboiler);
    try std.testing.expect(ReportRepo.fromStr("nulltickets") == .nulltickets);
    try std.testing.expect(ReportRepo.fromStr("nullwatch") == .nullwatch);
}

test "ReportRepo.fromStr invalid returns null" {
    try std.testing.expect(ReportRepo.fromStr("unknown") == null);
    try std.testing.expect(ReportRepo.fromStr("") == null);
}

test "ReportRepo.toGithubRepo" {
    try std.testing.expectEqualStrings("nullclaw/nullhub", ReportRepo.nullhub.toGithubRepo());
    try std.testing.expectEqualStrings("nullclaw/nullclaw", ReportRepo.nullclaw.toGithubRepo());
    try std.testing.expectEqualStrings("nullclaw/NullBoiler", ReportRepo.nullboiler.toGithubRepo());
    try std.testing.expectEqualStrings("nullclaw/nulltickets", ReportRepo.nulltickets.toGithubRepo());
    try std.testing.expectEqualStrings("nullclaw/nullwatch", ReportRepo.nullwatch.toGithubRepo());
}

test "ReportRepo.displayName all variants" {
    try std.testing.expectEqualStrings("NullHub", ReportRepo.nullhub.displayName());
    try std.testing.expectEqualStrings("NullClaw", ReportRepo.nullclaw.displayName());
    try std.testing.expectEqualStrings("NullBoiler", ReportRepo.nullboiler.displayName());
    try std.testing.expectEqualStrings("NullTickets", ReportRepo.nulltickets.displayName());
    try std.testing.expectEqualStrings("NullWatch", ReportRepo.nullwatch.displayName());
}

test "ReportType.fromStr valid" {
    try std.testing.expect(ReportType.fromStr("bug:crash") == .bug_crash);
    try std.testing.expect(ReportType.fromStr("bug:behavior") == .bug_behavior);
    try std.testing.expect(ReportType.fromStr("regression") == .regression);
    try std.testing.expect(ReportType.fromStr("feature") == .feature);
}

test "ReportType.fromStr invalid returns null" {
    try std.testing.expect(ReportType.fromStr("unknown") == null);
    try std.testing.expect(ReportType.fromStr("") == null);
}

test "ReportType.toLabels" {
    const crash_labels = ReportType.bug_crash.toLabels();
    try std.testing.expectEqual(@as(usize, 2), crash_labels.len);
    try std.testing.expectEqualStrings("bug", crash_labels[0]);
    try std.testing.expectEqualStrings("bug:crash", crash_labels[1]);

    const feature_labels = ReportType.feature.toLabels();
    try std.testing.expectEqual(@as(usize, 1), feature_labels.len);
    try std.testing.expectEqualStrings("enhancement", feature_labels[0]);
}

test "ReportType.issuePrefix" {
    try std.testing.expectEqualStrings("[Bug]", ReportType.bug_crash.issuePrefix());
    try std.testing.expectEqualStrings("[Bug]", ReportType.bug_behavior.issuePrefix());
    try std.testing.expectEqualStrings("[Bug]", ReportType.regression.issuePrefix());
    try std.testing.expectEqualStrings("[Feature]", ReportType.feature.issuePrefix());
}

test "ReportType.displayName all variants" {
    try std.testing.expectEqualStrings("Bug: crash (process exits or hangs)", ReportType.bug_crash.displayName());
    try std.testing.expectEqualStrings("Bug: behavior (incorrect output/state)", ReportType.bug_behavior.displayName());
    try std.testing.expectEqualStrings("Bug: regression (worked before, now fails)", ReportType.regression.displayName());
    try std.testing.expectEqualStrings("Feature request", ReportType.feature.displayName());
}

test "ReportOptions defaults" {
    const opts = ReportOptions{};
    try std.testing.expect(opts.repo == null);
    try std.testing.expect(opts.report_type == null);
    try std.testing.expect(opts.message == null);
    try std.testing.expect(!opts.yes);
    try std.testing.expect(!opts.dry_run);
}
