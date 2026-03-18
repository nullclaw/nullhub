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

fn appendSystemInfo(w: anytype, info: SystemInfo) !void {
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
    try w.print("### Summary\n\n{s}\n\n", .{message});
    try w.writeAll(
        \\### Steps to reproduce
        \\
        \\1. ...
        \\2. ...
        \\3. ...
        \\
        \\### Expected behavior
        \\
        \\...
        \\
        \\### Actual behavior
        \\
        \\...
        \\
        \\### Impact and severity
        \\
        \\Affected:
        \\Severity:
        \\Frequency:
        \\Consequence:
        \\
        \\
    );

    if (report_type == .regression) {
        try w.writeAll(
            \\### Regression details
            \\
            \\Last known good version:
            \\First known bad version:
            \\
        );
    }

    try w.writeAll(
        \\### Logs, screenshots, and evidence
        \\
        \\```text
        \\Paste redacted logs, screenshots, stack traces, or links here.
        \\```
        \\
        \\### Additional information
        \\
        \\Temporary workaround, config details, or anything else that helps triage.
        \\
        \\
    );
    try appendSystemInfo(w, info);

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
    try w.writeAll(
        \\### Problem to solve
        \\
        \\What pain or limitation are you trying to remove?
        \\
        \\### Proposed solution
        \\
        \\Describe the desired behavior, API, or UI in concrete terms.
        \\
        \\### Alternatives considered
        \\
        \\What other approaches did you consider, and why are they weaker?
        \\
        \\### Impact
        \\
        \\Affected:
        \\Severity:
        \\Frequency:
        \\Consequence:
        \\
        \\
        \\### Evidence and examples
        \\
        \\Prior art, screenshots, metrics, logs, or links that support this request.
        \\
        \\### Additional information
        \\
        \\Constraints, compatibility concerns, or rollout notes.
        \\
        \\
    );
    try appendSystemInfo(w, info);

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

pub const SubmitFailureKind = enum {
    no_auth,
    submit_failed,
};

pub const ManualSubmission = struct {
    kind: SubmitFailureKind,
    reason: []const u8,
    hint: []const u8,
    manual_url: []const u8,

    pub fn deinit(self: ManualSubmission, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
        allocator.free(self.hint);
        allocator.free(self.manual_url);
    }
};

pub const SubmitResult = union(enum) {
    success: []const u8, // issue URL
    manual: ManualSubmission,
};

const SubmissionAttempt = union(enum) {
    success: []const u8,
    skipped,
    failed: []const u8,
};

pub fn buildManualIssueUrl(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    title: []const u8,
    body: []const u8,
) ![]const u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();

    try w.print("https://github.com/{s}/issues/new?title=", .{repo.toGithubRepo()});
    try appendQueryValue(&buf, title);
    try w.writeAll("&labels=");
    try appendLabelsQueryValue(&buf, report_type.toLabels());
    try w.writeAll("&body=");
    try appendQueryValue(&buf, body);

    return buf.toOwnedSlice();
}

pub fn submitIssue(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    title: []const u8,
    body: []const u8,
) !SubmitResult {
    var failure_reason: ?[]const u8 = null;
    defer if (failure_reason) |msg| allocator.free(msg);

    switch (try tryGhCreate(allocator, repo, report_type, title, body)) {
        .success => |url| return .{ .success = url },
        .failed => |msg| replaceFailureReason(allocator, &failure_reason, msg),
        .skipped => {},
    }

    if (tryGhAuthToken(allocator)) |token| {
        defer allocator.free(token);
        switch (try tryCurlCreate(allocator, repo, report_type, title, body, token)) {
            .success => |url| return .{ .success = url },
            .failed => |msg| replaceFailureReason(allocator, &failure_reason, msg),
            .skipped => {},
        }
    }

    if (getEnv(allocator, "GITHUB_TOKEN")) |token| {
        defer allocator.free(token);
        switch (try tryCurlCreate(allocator, repo, report_type, title, body, token)) {
            .success => |url| return .{ .success = url },
            .failed => |msg| replaceFailureReason(allocator, &failure_reason, msg),
            .skipped => {},
        }
    }

    if (failure_reason) |msg| {
        const manual = try buildFailedManualSubmission(allocator, repo, report_type, title, body, msg);
        failure_reason = null;
        return .{ .manual = manual };
    }

    return .{ .manual = try buildNoAuthManualSubmission(allocator, repo, report_type, title, body) };
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
) !SubmissionAttempt {
    const auth_check = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "gh", "auth", "status" },
    }) catch return .skipped;
    defer allocator.free(auth_check.stdout);
    defer allocator.free(auth_check.stderr);

    switch (auth_check.term) {
        .Exited => |code| if (code != 0) return .skipped,
        else => return .skipped,
    }

    var label_str = std.array_list.Managed(u8).init(allocator);
    defer label_str.deinit();
    for (report_type.toLabels(), 0..) |label, i| {
        if (i > 0) try label_str.appendSlice(",");
        try label_str.appendSlice(label);
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
    }) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(allocator, "Failed to run `gh issue create`: {s}", .{@errorName(err)}) };
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                defer allocator.free(result.stdout);
                return .{ .failed = try buildProcessFailureMessage(
                    allocator,
                    "`gh issue create` failed",
                    code,
                    result.stdout,
                    result.stderr,
                ) };
            }
        },
        else => {
            defer allocator.free(result.stdout);
            return .{ .failed = try allocator.dupe(u8, "`gh issue create` terminated unexpectedly.") };
        },
    }

    var out: []const u8 = result.stdout;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }
    const trimmed = try allocator.dupe(u8, out);
    allocator.free(result.stdout);
    return .{ .success = trimmed };
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
) !SubmissionAttempt {
    const url = try std.fmt.allocPrint(
        allocator,
        "https://api.github.com/repos/{s}/issues",
        .{repo.toGithubRepo()},
    );
    defer allocator.free(url);

    const auth_header = try std.fmt.allocPrint(
        allocator,
        "Authorization: Bearer {s}",
        .{token},
    );
    defer allocator.free(auth_header);

    var json_buf = std.array_list.Managed(u8).init(allocator);
    defer json_buf.deinit();
    const jw = json_buf.writer();
    try jw.writeAll("{\"title\":\"");
    try writeJsonEscaped(jw, title);
    try jw.writeAll("\",\"body\":\"");
    try writeJsonEscaped(jw, body);
    try jw.writeAll("\",\"labels\":[");
    for (report_type.toLabels(), 0..) |label, i| {
        if (i > 0) try jw.writeAll(",");
        try jw.writeAll("\"");
        try jw.writeAll(label);
        try jw.writeAll("\"");
    }
    try jw.writeAll("]}");

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{
            "curl", "-sS",
            "-X",  "POST",
            "-H",  "Accept: application/vnd.github+json",
            "-H",  "Content-Type: application/json",
            "-H",  auth_header,
            "-d",  json_buf.items,
            url,
        },
    }) catch |err| {
        return .{ .failed = try std.fmt.allocPrint(allocator, "Failed to run GitHub API request: {s}", .{@errorName(err)}) };
    };
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) {
                defer allocator.free(result.stdout);
                return .{ .failed = try buildProcessFailureMessage(
                    allocator,
                    "GitHub API request failed",
                    code,
                    result.stdout,
                    result.stderr,
                ) };
            }
        },
        else => {
            defer allocator.free(result.stdout);
            return .{ .failed = try allocator.dupe(u8, "GitHub API request terminated unexpectedly.") };
        },
    }

    const parsed = std.json.parseFromSlice(
        struct {
            html_url: ?[]const u8 = null,
            message: ?[]const u8 = null,
        },
        allocator,
        result.stdout,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        defer allocator.free(result.stdout);
        return .{ .failed = try buildProcessFailureMessage(
            allocator,
            "GitHub API returned an unreadable response",
            0,
            result.stdout,
            result.stderr,
        ) };
    };
    defer allocator.free(result.stdout);
    defer parsed.deinit();

    if (parsed.value.html_url) |html_url| {
        return .{ .success = try allocator.dupe(u8, html_url) };
    }

    if (parsed.value.message) |message| {
        return .{ .failed = try std.fmt.allocPrint(allocator, "GitHub API error: {s}", .{message}) };
    }

    return .{ .failed = try allocator.dupe(u8, "GitHub API did not return an issue URL.") };
}

fn replaceFailureReason(allocator: std.mem.Allocator, slot: *?[]const u8, message: []const u8) void {
    if (slot.*) |old| allocator.free(old);
    slot.* = message;
}

fn buildNoAuthManualSubmission(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    title: []const u8,
    body: []const u8,
) !ManualSubmission {
    return .{
        .kind = .no_auth,
        .reason = try allocator.dupe(u8, "Automatic submission requires GitHub authentication."),
        .hint = try allocator.dupe(u8, "Run `gh auth login` or set `GITHUB_TOKEN`, then retry. You can also open the prefilled GitHub URL below."),
        .manual_url = try buildManualIssueUrl(allocator, repo, report_type, title, body),
    };
}

fn buildFailedManualSubmission(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    title: []const u8,
    body: []const u8,
    reason: []const u8,
) !ManualSubmission {
    return .{
        .kind = .submit_failed,
        .reason = reason,
        .hint = try allocator.dupe(u8, "Automatic submission failed after reaching GitHub. Review the error below and use the prefilled GitHub URL or copied content to file the issue manually."),
        .manual_url = try buildManualIssueUrl(allocator, repo, report_type, title, body),
    };
}

fn buildProcessFailureMessage(
    allocator: std.mem.Allocator,
    prefix: []const u8,
    exit_code: u8,
    stdout: []const u8,
    stderr: []const u8,
) ![]const u8 {
    const detail = firstNonEmptyTrimmed(stderr, stdout) orelse "unknown error";
    if (exit_code == 0) {
        return std.fmt.allocPrint(allocator, "{s}: {s}", .{ prefix, detail });
    }
    return std.fmt.allocPrint(allocator, "{s} (exit {d}): {s}", .{ prefix, exit_code, detail });
}

fn firstNonEmptyTrimmed(a: []const u8, b: []const u8) ?[]const u8 {
    const first = std.mem.trim(u8, a, " \r\n\t");
    if (first.len > 0) return first;
    const second = std.mem.trim(u8, b, " \r\n\t");
    if (second.len > 0) return second;
    return null;
}

fn appendLabelsQueryValue(buf: *std.array_list.Managed(u8), labels: []const []const u8) !void {
    const w = buf.writer();
    for (labels, 0..) |label, i| {
        if (i > 0) try w.writeAll("%2C");
        try appendQueryValue(buf, label);
    }
}

fn appendQueryValue(buf: *std.array_list.Managed(u8), raw: []const u8) !void {
    const w = buf.writer();
    var start: usize = 0;
    for (raw, 0..) |c, i| {
        if (isQueryValueChar(c)) continue;
        try w.print("{s}%{X:0>2}", .{ raw[start..i], c });
        start = i + 1;
    }
    try w.writeAll(raw[start..]);
}

fn isQueryValueChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
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
    try std.testing.expect(std.mem.indexOf(u8, body, "### Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "App crashes") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Steps to reproduce") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Expected behavior") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Actual behavior") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Impact and severity") != null);
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

test "buildBugBody includes regression section" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{},
    };
    const body = try buildBugBody(allocator, .regression, "Update broke routing", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Regression details") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Last known good version") != null);
}

test "buildFeatureBody uses structured template" {
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
    try std.testing.expect(std.mem.indexOf(u8, body, "### Problem to solve") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Proposed solution") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Impact") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### System information") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Darwin 25.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "main") != null);
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

test "buildManualIssueUrl includes repo, labels, and encoded body" {
    const allocator = std.testing.allocator;
    const url = try buildManualIssueUrl(allocator, .nullhub, .bug_behavior, "[Bug]: Broken title", "Line 1\nLine 2");
    defer allocator.free(url);

    try std.testing.expect(std.mem.indexOf(u8, url, "https://github.com/nullclaw/nullhub/issues/new") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "labels=bug%2Cbug%3Abehavior") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "title=%5BBug%5D%3A%20Broken%20title") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "body=Line%201%0ALine%202") != null);
}

test "buildProcessFailureMessage prefers stderr" {
    const allocator = std.testing.allocator;
    const message = try buildProcessFailureMessage(allocator, "submit failed", 22, "{\"message\":\"ignored\"}", "validation failed\n");
    defer allocator.free(message);

    try std.testing.expectEqualStrings("submit failed (exit 22): validation failed", message);
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
