const std = @import("std");
const cli = @import("cli.zig");
const version = @import("version.zig");
const platform = @import("core/platform.zig");
const paths_mod = @import("core/paths.zig");
const state_mod = @import("core/state.zig");

// ─── System Info ────────────────────────────────────────────────────────────

pub const SystemInfo = struct {
    version: []const u8,
    platform_key: []const u8,
    os_version: []const u8,
    components: []const ComponentInfo,
    /// Whether os_version and components were heap-allocated and need freeing.
    owned: bool = false,

    pub fn deinit(self: *SystemInfo, allocator: std.mem.Allocator) void {
        if (!self.owned) return;
        for (self.components) |comp| {
            allocator.free(comp.name);
            allocator.free(comp.comp_version);
        }
        if (self.components.len > 0) allocator.free(self.components);
        // os_version is either "unknown" (static) or heap-allocated from uname
        if (!std.mem.eql(u8, self.os_version, "unknown")) {
            allocator.free(self.os_version);
        }
    }
};

pub const ComponentInfo = struct {
    name: []const u8,
    comp_version: []const u8,
};

pub fn collectSystemInfo(allocator: std.mem.Allocator) !SystemInfo {
    const os_version = getOsVersion(allocator) catch "unknown";
    const components = collectInstalledComponents(allocator) catch &.{};

    return .{
        .version = version.string,
        .platform_key = platform.detect().toString(),
        .os_version = os_version,
        .components = components,
        .owned = true,
    };
}

fn getOsVersion(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "uname", "-sr" },
    }) catch return error.CommandFailed;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return error.CommandFailed;
            }
        },
        else => {
            allocator.free(result.stdout);
            return error.CommandFailed;
        },
    }

    // Trim trailing newline and dupe so the free size matches the alloc size
    var out: []const u8 = result.stdout;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }
    const trimmed = try allocator.dupe(u8, out);
    allocator.free(result.stdout);
    return trimmed;
}

fn collectInstalledComponents(allocator: std.mem.Allocator) ![]const ComponentInfo {
    var paths = paths_mod.Paths.init(allocator, null) catch return &.{};
    defer paths.deinit(allocator);

    const state_path = paths.state(allocator) catch return &.{};
    defer allocator.free(state_path);

    var st = state_mod.State.load(allocator, state_path) catch return &.{};
    defer st.deinit();

    var list = std.array_list.Managed(ComponentInfo).init(allocator);

    // Iterate by component name (not instance name) — use the first
    // instance's version as representative for the component.
    var comp_it = st.instances.iterator();
    while (comp_it.next()) |comp_entry| {
        var inst_it = comp_entry.value_ptr.iterator();
        if (inst_it.next()) |inst_entry| {
            const entry = inst_entry.value_ptr.*;
            const name = allocator.dupe(u8, comp_entry.key_ptr.*) catch continue;
            const comp_ver = allocator.dupe(u8, entry.version) catch {
                allocator.free(name);
                continue;
            };
            list.append(.{ .name = name, .comp_version = comp_ver }) catch {
                allocator.free(name);
                allocator.free(comp_ver);
                continue;
            };
        }
    }

    return list.toOwnedSlice() catch &.{};
}

// ─── Markdown Generation ────────────────────────────────────────────────────

pub fn buildTitle(
    allocator: std.mem.Allocator,
    report_type: cli.ReportType,
    message: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}: {s}", .{ report_type.issuePrefix(), message });
}

pub fn buildBugBody(
    allocator: std.mem.Allocator,
    report_type: cli.ReportType,
    message: []const u8,
    info: SystemInfo,
) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();

    try w.print("### Bug type\n\n{s}\n\n", .{report_type.displayName()});
    try w.print("### Description\n\n{s}\n\n", .{message});
    try w.writeAll("### System information\n\n");
    try w.writeAll("| Field | Value |\n|---|---|\n");
    try w.print("| nullhub version | {s} |\n", .{info.version});
    try w.print("| Platform | {s} |\n", .{info.platform_key});
    try w.print("| OS version | {s} |\n", .{info.os_version});

    if (info.components.len > 0) {
        try w.writeAll("\n### Installed components\n\n");
        try w.writeAll("| Component | Version |\n|---|---|\n");
        for (info.components) |comp| {
            try w.print("| {s} | {s} |\n", .{ comp.name, comp.comp_version });
        }
    }

    return buf.toOwnedSlice();
}

pub fn buildFeatureBody(
    allocator: std.mem.Allocator,
    message: []const u8,
    info: SystemInfo,
) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();

    try w.print("### Summary\n\n{s}\n\n", .{message});
    try w.writeAll("### System information\n\n");
    try w.writeAll("| Field | Value |\n|---|---|\n");
    try w.print("| nullhub version | {s} |\n", .{info.version});
    try w.print("| Platform | {s} |\n", .{info.platform_key});

    return buf.toOwnedSlice();
}

pub fn buildBody(
    allocator: std.mem.Allocator,
    report_type: cli.ReportType,
    message: []const u8,
    info: SystemInfo,
) ![]const u8 {
    return switch (report_type) {
        .bug_crash, .bug_behavior, .regression => buildBugBody(allocator, report_type, message, info),
        .feature => buildFeatureBody(allocator, message, info),
    };
}

// ─── Submission ─────────────────────────────────────────────────────────────

pub const SubmitResult = union(enum) {
    success: []const u8, // issue URL
    no_auth: void,
};

pub fn submitIssue(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    title: []const u8,
    body: []const u8,
) !SubmitResult {
    // 1. Try `gh issue create`
    if (tryGhCreate(allocator, repo, report_type, title, body)) |url| {
        return .{ .success = url };
    }

    // 2. Try curl with `gh auth token`
    if (tryGhAuthToken(allocator)) |token| {
        defer allocator.free(token);
        if (tryCurlCreate(allocator, repo, report_type, title, body, token)) |url| {
            return .{ .success = url };
        }
    }

    // 3. Try $GITHUB_TOKEN
    if (getEnv(allocator, "GITHUB_TOKEN")) |token| {
        defer allocator.free(token);
        if (tryCurlCreate(allocator, repo, report_type, title, body, token)) |url| {
            return .{ .success = url };
        }
    }

    // 4. Fallback
    return .no_auth;
}

fn getEnv(allocator: std.mem.Allocator, key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(allocator, key) catch null;
}

fn tryGhCreate(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    title: []const u8,
    body: []const u8,
) ?[]const u8 {
    // Check gh auth status first
    const auth_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "gh", "auth", "status" },
    }) catch return null;
    defer allocator.free(auth_check.stdout);
    defer allocator.free(auth_check.stderr);

    switch (auth_check.term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Build label args
    const labels = report_type.toLabels();
    var label_str = std.array_list.Managed(u8).init(allocator);
    defer label_str.deinit();
    for (labels, 0..) |label, i| {
        if (i > 0) label_str.appendSlice(",") catch return null;
        label_str.appendSlice(label) catch return null;
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "gh", "issue", "create",
            "--repo",  repo.toGithubRepo(),
            "--title", title,
            "--body",  body,
            "--label", label_str.items,
        },
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    // Trim trailing newline from URL and dupe so free size matches alloc size
    var out: []const u8 = result.stdout;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }
    const trimmed = allocator.dupe(u8, out) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return trimmed;
}

fn tryGhAuthToken(allocator: std.mem.Allocator) ?[]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "gh", "auth", "token" },
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    var out: []const u8 = result.stdout;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }
    if (out.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    const trimmed = allocator.dupe(u8, out) catch {
        allocator.free(result.stdout);
        return null;
    };
    allocator.free(result.stdout);
    return trimmed;
}

fn tryCurlCreate(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    title: []const u8,
    body: []const u8,
    token: []const u8,
) ?[]const u8 {
    const url = std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/issues",
        .{repo.toGithubRepo()},
    ) catch return null;
    defer allocator.free(url);

    const auth_header = std.fmt.allocPrint(
        allocator,
        "Authorization: Bearer {s}",
        .{token},
    ) catch return null;
    defer allocator.free(auth_header);

    // Build JSON body
    var json_buf = std.array_list.Managed(u8).init(allocator);
    defer json_buf.deinit();
    const jw = json_buf.writer();
    jw.writeAll("{\"title\":\"") catch return null;
    writeJsonEscaped(jw, title) catch return null;
    jw.writeAll("\",\"body\":\"") catch return null;
    writeJsonEscaped(jw, body) catch return null;
    jw.writeAll("\",\"labels\":[") catch return null;
    const labels = report_type.toLabels();
    for (labels, 0..) |label, i| {
        if (i > 0) jw.writeAll(",") catch return null;
        jw.writeAll("\"") catch return null;
        jw.writeAll(label) catch return null;
        jw.writeAll("\"") catch return null;
    }
    jw.writeAll("]}") catch return null;

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl", "-sf",
            "-X",  "POST",
            "-H",  "Accept: application/vnd.github+json",
            "-H",  auth_header,
            "-d",  json_buf.items,
            url,
        },
    }) catch return null;
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                allocator.free(result.stdout);
                return null;
            }
        },
        else => {
            allocator.free(result.stdout);
            return null;
        },
    }

    // Parse response to extract html_url
    const parsed = std.json.parseFromSlice(
        struct { html_url: []const u8 },
        allocator,
        result.stdout,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        allocator.free(result.stdout);
        return null;
    };
    defer allocator.free(result.stdout);
    defer parsed.deinit();

    const issue_url = allocator.dupe(u8, parsed.value.html_url) catch return null;
    return issue_url;
}

fn writeJsonEscaped(writer: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0x00...0x08, 0x0B, 0x0C, 0x0E...0x1F => {
                try writer.print("\\u{x:0>4}", .{c});
            },
            else => try writer.writeByte(c),
        }
    }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "buildTitle bug" {
    const allocator = std.testing.allocator;
    const title = try buildTitle(allocator, .bug_crash, "App crashes on start");
    defer allocator.free(title);
    try std.testing.expectEqualStrings("[Bug]: App crashes on start", title);
}

test "buildTitle feature" {
    const allocator = std.testing.allocator;
    const title = try buildTitle(allocator, .feature, "Add dark mode");
    defer allocator.free(title);
    try std.testing.expectEqualStrings("[Feature]: Add dark mode", title);
}

test "buildBugBody contains required sections" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{},
    };
    const body = try buildBugBody(allocator, .bug_crash, "App crashes", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Bug type") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Crash (process exits or hangs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Description") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "App crashes") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### System information") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2026.3.13") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "aarch64-macos") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Darwin 25.1.0") != null);
}

test "buildBugBody includes components" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{
            .{ .name = "main", .comp_version = "2026.3.14" },
        },
    };
    const body = try buildBugBody(allocator, .bug_behavior, "Wrong output", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Installed components") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "main") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2026.3.14") != null);
}

test "buildFeatureBody is lightweight" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{
            .{ .name = "main", .comp_version = "2026.3.14" },
        },
    };
    const body = try buildFeatureBody(allocator, "Add feature X", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Add feature X") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2026.3.13") != null);
    // Feature body should NOT include components or OS version
    try std.testing.expect(std.mem.indexOf(u8, body, "### Installed components") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Darwin") == null);
}

test "buildBody dispatches correctly" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "1.0.0",
        .platform_key = "x86_64-linux",
        .os_version = "Linux 6.1",
        .components = &.{},
    };

    const bug_body = try buildBody(allocator, .regression, "Broke after update", info);
    defer allocator.free(bug_body);
    try std.testing.expect(std.mem.indexOf(u8, bug_body, "### Bug type") != null);

    const feat_body = try buildBody(allocator, .feature, "Want X", info);
    defer allocator.free(feat_body);
    try std.testing.expect(std.mem.indexOf(u8, feat_body, "### Summary") != null);
}

test "writeJsonEscaped" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try writeJsonEscaped(buf.writer(), "hello \"world\"\nnewline\\back\r\ttab");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnewline\\\\back\\r\\ttab", buf.items);
}

test "writeJsonEscaped control characters" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try writeJsonEscaped(buf.writer(), &.{ 0x00, 0x0B, 0x1F });
    try std.testing.expectEqualStrings("\\u0000\\u000b\\u001f", buf.items);
}
