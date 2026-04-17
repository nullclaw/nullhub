const std = @import("std");

pub const ResolvedLaunch = struct {
    allocator: std.mem.Allocator,
    raw_mode: []const u8,
    primary_command: []const u8,
    argv: []const []const u8,

    pub fn deinit(self: *ResolvedLaunch) void {
        freeOwnedArgv(self.allocator, self.argv);
        self.* = undefined;
    }

    pub fn usesHttpHealthChecks(self: ResolvedLaunch) bool {
        return usesHttpHealthChecksCommand(self.primary_command);
    }

    pub fn effectiveHealthPort(self: ResolvedLaunch, port: u16) u16 {
        return if (self.usesHttpHealthChecks()) port else 0;
    }
};

pub fn resolve(
    allocator: std.mem.Allocator,
    launch_mode: []const u8,
    verbose: bool,
) !ResolvedLaunch {
    var list = try parseLaunchMode(allocator, launch_mode);
    errdefer deinitOwnedArgList(allocator, &list);

    if (list.items.len == 0) return error.InvalidLaunchMode;

    // NullClaw convenience: bare `channel` isn't a runnable long-lived mode.
    // Expand it to `channel start` so Hub can actually supervise it.
    if (list.items.len == 1 and std.mem.eql(u8, list.items[0], "channel")) {
        try appendOwnedToken(allocator, &list, "start");
    }

    if (verbose) {
        try appendOwnedToken(allocator, &list, "--verbose");
    }

    return .{
        .allocator = allocator,
        .raw_mode = launch_mode,
        .primary_command = list.items[0],
        .argv = try list.toOwnedSlice(allocator),
    };
}

pub fn buildLaunchArgs(
    allocator: std.mem.Allocator,
    launch_mode: []const u8,
    verbose: bool,
) ![]const []const u8 {
    const resolved = try resolve(allocator, launch_mode, verbose);
    return resolved.argv;
}

pub fn freeOwnedArgv(allocator: std.mem.Allocator, argv: []const []const u8) void {
    if (argv.len == 0) return;
    for (argv) |arg| allocator.free(arg);
    allocator.free(argv);
}

fn parseLaunchMode(allocator: std.mem.Allocator, launch_mode: []const u8) !std.ArrayListUnmanaged([]const u8) {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer deinitOwnedArgList(allocator, &list);

    var token: std.ArrayListUnmanaged(u8) = .empty;
    defer token.deinit(allocator);

    var token_started = false;
    var quote: ?u8 = null;
    var escaped = false;

    for (launch_mode) |ch| {
        if (escaped) {
            try token.append(allocator, ch);
            token_started = true;
            escaped = false;
            continue;
        }

        if (quote) |active_quote| {
            if (ch == '\\') {
                escaped = true;
                token_started = true;
                continue;
            }
            if (ch == active_quote) {
                quote = null;
                token_started = true;
                continue;
            }
            try token.append(allocator, ch);
            token_started = true;
            continue;
        }

        switch (ch) {
            ' ', '\t', '\r', '\n' => {
                if (token_started) {
                    try appendOwnedToken(allocator, &list, token.items);
                    token.clearRetainingCapacity();
                    token_started = false;
                }
            },
            '\'', '"' => {
                quote = ch;
                token_started = true;
            },
            '\\' => {
                escaped = true;
                token_started = true;
            },
            else => {
                try token.append(allocator, ch);
                token_started = true;
            },
        }
    }

    if (quote != null or escaped) return error.InvalidLaunchMode;

    if (token_started) {
        try appendOwnedToken(allocator, &list, token.items);
    }

    return list;
}

fn appendOwnedToken(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged([]const u8),
    token: []const u8,
) !void {
    const owned = try allocator.dupe(u8, token);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn deinitOwnedArgList(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8)) void {
    for (list.items) |arg| allocator.free(arg);
    list.deinit(allocator);
}

fn usesHttpHealthChecksCommand(command: []const u8) bool {
    return std.mem.eql(u8, command, "serve") or std.mem.eql(u8, command, "gateway");
}

pub fn primaryLaunchCommand(launch_mode: []const u8) []const u8 {
    var i: usize = 0;
    while (i < launch_mode.len and std.ascii.isWhitespace(launch_mode[i])) : (i += 1) {}
    const start = i;
    while (i < launch_mode.len and !std.ascii.isWhitespace(launch_mode[i])) : (i += 1) {}
    return launch_mode[start..i];
}

pub fn usesHttpHealthChecks(launch_mode: []const u8) bool {
    return usesHttpHealthChecksCommand(primaryLaunchCommand(launch_mode));
}

pub fn effectiveHealthPort(launch_mode: []const u8, port: u16) u16 {
    return if (usesHttpHealthChecks(launch_mode)) port else 0;
}

test "buildLaunchArgs appends verbose flag when enabled" {
    const allocator = std.testing.allocator;
    var resolved = try resolve(allocator, "gateway", true);
    defer resolved.deinit();
    const args = resolved.argv;

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("gateway", args[0]);
    try std.testing.expectEqualStrings("--verbose", args[1]);
}

test "buildLaunchArgs preserves tokenized launch mode when verbose disabled" {
    const allocator = std.testing.allocator;
    var resolved = try resolve(allocator, "agent --foo bar", false);
    defer resolved.deinit();
    const args = resolved.argv;

    try std.testing.expectEqual(@as(usize, 3), args.len);
    try std.testing.expectEqualStrings("agent", args[0]);
    try std.testing.expectEqualStrings("--foo", args[1]);
    try std.testing.expectEqualStrings("bar", args[2]);
}

test "resolve preserves quoted arguments with spaces" {
    const allocator = std.testing.allocator;
    var resolved = try resolve(allocator, "agent --prompt \"hello world\" 'two words'", false);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 4), resolved.argv.len);
    try std.testing.expectEqualStrings("agent", resolved.argv[0]);
    try std.testing.expectEqualStrings("--prompt", resolved.argv[1]);
    try std.testing.expectEqualStrings("hello world", resolved.argv[2]);
    try std.testing.expectEqualStrings("two words", resolved.argv[3]);
}

test "resolve preserves escaped spaces outside quotes" {
    const allocator = std.testing.allocator;
    var resolved = try resolve(allocator, "agent --path /tmp/my\\ file", false);
    defer resolved.deinit();

    try std.testing.expectEqual(@as(usize, 3), resolved.argv.len);
    try std.testing.expectEqualStrings("/tmp/my file", resolved.argv[2]);
}

test "buildLaunchArgs expands bare channel to channel start" {
    const allocator = std.testing.allocator;
    var resolved = try resolve(allocator, "channel", false);
    defer resolved.deinit();
    const args = resolved.argv;

    try std.testing.expectEqual(@as(usize, 2), args.len);
    try std.testing.expectEqualStrings("channel", args[0]);
    try std.testing.expectEqualStrings("start", args[1]);
}

test "resolve rejects empty launch mode" {
    try std.testing.expectError(error.InvalidLaunchMode, resolve(std.testing.allocator, "   \t", false));
}

test "resolve rejects unterminated quoted launch mode" {
    try std.testing.expectError(error.InvalidLaunchMode, resolve(std.testing.allocator, "agent \"unterminated", false));
}

test "effectiveHealthPort keeps HTTP health checks for serve mode" {
    try std.testing.expectEqual(@as(u16, 8080), effectiveHealthPort("serve", 8080));
    try std.testing.expectEqual(@as(u16, 8080), effectiveHealthPort("serve --host 0.0.0.0", 8080));
}

test "effectiveHealthPort keeps HTTP health checks for gateway mode" {
    try std.testing.expectEqual(@as(u16, 8080), effectiveHealthPort("gateway", 8080));
    try std.testing.expectEqual(@as(u16, 8080), effectiveHealthPort("gateway --host 0.0.0.0", 8080));
}

test "effectiveHealthPort disables HTTP health checks for non-server modes" {
    try std.testing.expectEqual(@as(u16, 0), effectiveHealthPort("agent", 8080));
    try std.testing.expectEqual(@as(u16, 0), effectiveHealthPort("channel", 8080));
    try std.testing.expectEqual(@as(u16, 0), effectiveHealthPort("channel start", 8080));
}
