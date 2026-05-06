# Report Command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `nullhub report` CLI command + Web UI page + API endpoints for creating GitHub issues with auto-collected system data across 5 ecosystem repos.

**Architecture:** Core logic lives in `report.zig` (enums, system data collection, issue body formatting, submission fallback chain). CLI interactive flow in `report_cli.zig`. API handlers in `api/report.zig`. Svelte form page at `ui/src/routes/report/`. Wired into existing CLI parser, server router, sidebar nav, and API client.

**Tech Stack:** Zig 0.16.0, Svelte 5 + SvelteKit, GitHub API via `gh` CLI / curl fallback

**Spec:** `docs/superpowers/specs/2026-03-18-report-command-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `src/report.zig` | Enums (`ReportRepo`, `ReportType`), system info collection, markdown body generation, GitHub submission fallback chain |
| `src/report_cli.zig` | Interactive CLI prompts (stdin), preview display, `$EDITOR` integration, flag-driven non-interactive mode |
| `src/api/report.zig` | `POST /api/report/preview` and `POST /api/report` handlers, JSON request/response |
| `ui/src/routes/report/+page.svelte` | Three-step form: inputs → preview (editable textarea) → result |

**Modified files:**
- `src/cli.zig` — add `ReportRepo`, `ReportType`, `ReportOptions`, `report` variant to `Command`, `parseReport()`, update `printUsage()`
- `src/root.zig` — add `report`, `report_cli`, `report_api` imports + test refs
- `src/main.zig` — add `.report` case to command dispatch
- `src/server.zig` — add `POST /api/report` and `POST /api/report/preview` routes
- `ui/src/lib/api/client.ts` — add `reportPreview()` and `submitReport()` methods
- `ui/src/lib/components/Sidebar.svelte` — add Report link in `nav-bottom` section

---

## Task 1: CLI types and parser

**Files:**
- Modify: `src/cli.zig`

- [ ] **Step 1: Add ReportRepo enum after AddSourceOptions**

```zig
pub const ReportRepo = enum {
    nullhub,
    nullclaw,
    nullboiler,
    nulltickets,
    nullwatch,

    pub fn fromStr(s: []const u8) ?ReportRepo {
        const map = .{
            .{ "nullhub", ReportRepo.nullhub },
            .{ "nullclaw", ReportRepo.nullclaw },
            .{ "nullboiler", ReportRepo.nullboiler },
            .{ "nulltickets", ReportRepo.nulltickets },
            .{ "nullwatch", ReportRepo.nullwatch },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, s, pair[0])) return pair[1];
        }
        return null;
    }

    pub fn toGithubRepo(self: ReportRepo) []const u8 {
        return switch (self) {
            .nullhub => "nullclaw/nullhub",
            .nullclaw => "nullclaw/nullclaw",
            .nullboiler => "nullclaw/NullBoiler",
            .nulltickets => "nullclaw/nulltickets",
            .nullwatch => "nullclaw/nullwatch",
        };
    }

    pub fn displayName(self: ReportRepo) []const u8 {
        return switch (self) {
            .nullhub => "nullhub",
            .nullclaw => "nullclaw",
            .nullboiler => "nullboiler",
            .nulltickets => "nulltickets",
            .nullwatch => "nullwatch",
        };
    }
};
```

- [ ] **Step 2: Add ReportType enum**

```zig
pub const ReportType = enum {
    bug_crash,
    bug_behavior,
    regression,
    feature,

    pub fn fromStr(s: []const u8) ?ReportType {
        const map = .{
            .{ "bug:crash", ReportType.bug_crash },
            .{ "bug:behavior", ReportType.bug_behavior },
            .{ "regression", ReportType.regression },
            .{ "feature", ReportType.feature },
        };
        inline for (map) |pair| {
            if (std.mem.eql(u8, s, pair[0])) return pair[1];
        }
        return null;
    }

    pub fn toLabels(self: ReportType) []const []const u8 {
        return switch (self) {
            .bug_crash => &.{ "bug", "bug:crash" },
            .bug_behavior => &.{ "bug", "bug:behavior" },
            .regression => &.{ "bug", "regression" },
            .feature => &.{ "enhancement" },
        };
    }

    pub fn displayName(self: ReportType) []const u8 {
        return switch (self) {
            .bug_crash => "Crash (process exits or hangs)",
            .bug_behavior => "Behavior bug (incorrect output/state)",
            .regression => "Regression (worked before, now fails)",
            .feature => "Feature request",
        };
    }

    pub fn issuePrefix(self: ReportType) []const u8 {
        return switch (self) {
            .bug_crash, .bug_behavior, .regression => "[Bug]",
            .feature => "[Feature]",
        };
    }
};
```

- [ ] **Step 3: Add ReportOptions struct**

```zig
pub const ReportOptions = struct {
    repo: ?ReportRepo = null,
    report_type: ?ReportType = null,
    message: ?[]const u8 = null,
    yes: bool = false,
    dry_run: bool = false,
};
```

- [ ] **Step 4: Add `report` to Command union**

Add `report: ReportOptions,` after `add_source: AddSourceOptions,` in the `Command` union.

- [ ] **Step 5: Add parseReport function and wire into parse()**

Add to parse() before the help check:
```zig
if (std.mem.eql(u8, cmd, "report")) {
    return parseReport(args);
}
```

Add the sub-parser:
```zig
fn parseReport(args: *std.process.ArgIterator) Command {
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
```

- [ ] **Step 6: Update printUsage()**

Add this line in the Commands section (after the `uninstall` line):
```
\\  report                    Report a bug or feature request
```

- [ ] **Step 7: Add tests for new enums**

```zig
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
    try std.testing.expectEqualStrings("nullclaw/NullBoiler", ReportRepo.nullboiler.toGithubRepo());
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
    try std.testing.expectEqualStrings("[Feature]", ReportType.feature.issuePrefix());
}

test "ReportOptions defaults" {
    const opts = ReportOptions{};
    try std.testing.expect(opts.repo == null);
    try std.testing.expect(opts.report_type == null);
    try std.testing.expect(opts.message == null);
    try std.testing.expect(!opts.yes);
    try std.testing.expect(!opts.dry_run);
}
```

- [ ] **Step 8: Run tests to verify**

Run: `zig build test --summary all 2>&1 | head -20`
Expected: all tests pass

- [ ] **Step 9: Commit**

```bash
git add src/cli.zig
git commit -m "Add report command CLI types and parser"
```

---

## Task 2: Core report module — system info and markdown generation

**Files:**
- Create: `src/report.zig`

- [ ] **Step 1: Create report.zig with system info collection**

```zig
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

    // Trim trailing newline
    var out = result.stdout;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }
    // Return stdout ownership to caller (trimmed via slice)
    return out;
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
            list.append(.{
                .name = allocator.dupe(u8, comp_entry.key_ptr.*) catch continue,
                .comp_version = allocator.dupe(u8, entry.version) catch continue,
            }) catch continue;
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
    if (getEnv("GITHUB_TOKEN")) |token| {
        if (tryCurlCreate(allocator, repo, report_type, title, body, token)) |url| {
            return .{ .success = url };
        }
    }

    // 4. Fallback
    return .no_auth;
}

fn getEnv(key: []const u8) ?[]const u8 {
    return std.process.getEnvVarOwned(std.heap.page_allocator, key) catch null;
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
    var label_str = std.ArrayList(u8).init(allocator);
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

    // Trim trailing newline from URL
    var out = result.stdout;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }
    return out;
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

    var out = result.stdout;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) {
        out = out[0 .. out.len - 1];
    }
    if (out.len == 0) {
        allocator.free(result.stdout);
        return null;
    }
    return out;
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
    var json_buf = std.ArrayList(u8).init(allocator);
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

    const issue_url = allocator.dupe(u8, parsed.value.html_url) catch return null;
    parsed.deinit();
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
    try writeJsonEscaped(buf.writer(), "hello \"world\"\nnewline");
    try std.testing.expectEqualStrings("hello \\\"world\\\"\\nnewline", buf.items);
}
```

- [ ] **Step 2: Run tests**

Run: `zig build test --summary all 2>&1 | head -20`
Expected: all tests pass

- [ ] **Step 3: Commit**

```bash
git add src/report.zig
git commit -m "Add core report module with system info and markdown generation"
```

---

## Task 3: Register report module in root.zig

**Files:**
- Modify: `src/root.zig`

- [ ] **Step 1: Add report to root.zig**

Add after `pub const registry = ...;`:
```zig
pub const report = @import("report.zig");
```

Add `_ = report;` in the test block after `_ = registry;`.

- [ ] **Step 2: Run build and tests**

Run: `zig build test --summary all 2>&1 | head -20`
Expected: all tests pass

- [ ] **Step 3: Commit**

```bash
git add src/root.zig
git commit -m "Register report module in root.zig"
```

---

## Task 4: CLI interactive flow + wire into main.zig

**Files:**
- Create: `src/report_cli.zig`
- Modify: `src/root.zig`
- Modify: `src/main.zig`

- [ ] **Step 1: Create report_cli.zig**

```zig
const std = @import("std");
const cli = @import("cli.zig");
const report = @import("report.zig");

// ─── Shared read buffer for stdin (avoids dangling stack pointers) ───────────

var line_buf: [1024]u8 = undefined;

pub fn run(allocator: std.mem.Allocator, opts: cli.ReportOptions) !void {
    var stdout_buf: [8192]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &bw.interface;

    // TTY detection: if stdin is not a TTY, require all flags
    const is_tty = std.io.getStdIn().isTty();
    if (!is_tty) {
        if (opts.repo == null or opts.report_type == null or opts.message == null) {
            try w.writeAll("Error: --repo, --type, and --message are required in non-interactive mode.\n");
            try w.flush();
            return error.Cancelled;
        }
    }

    // Resolve options (interactive or from flags)
    const repo = opts.repo orelse try promptRepo(w) orelse return error.Cancelled;
    const report_type = opts.report_type orelse try promptType(w) orelse return error.Cancelled;
    const message = opts.message orelse blk: {
        const m = try promptMessage(allocator, w) orelse return error.Cancelled;
        break :blk m;
    };

    // Collect system info
    const info = report.collectSystemInfo(allocator) catch report.SystemInfo{
        .version = @import("version.zig").string,
        .platform_key = @import("core/platform.zig").detect().toString(),
        .os_version = "unknown",
        .components = &.{},
    };

    // Generate title and body
    const title = try report.buildTitle(allocator, report_type, message);
    defer allocator.free(title);

    var body_owned = false;
    var body = try report.buildBody(allocator, report_type, message, info);

    defer {
        if (body_owned) allocator.free(body);
    }
    body_owned = true;

    // Preview
    try w.writeAll("\nPreview:\n");
    try w.writeAll("──────────────────────────\n");
    try w.print("Title: {s}\n\n", .{title});
    try w.writeAll(body);
    try w.writeAll("──────────────────────────\n");
    try w.flush();

    if (opts.dry_run) {
        try w.writeAll("\n(dry run — not submitted)\n");
        try w.flush();
        return;
    }

    if (!opts.yes) {
        // In non-TTY mode with all flags, auto-confirm
        if (!is_tty) {
            // All flags provided, proceed without prompt
        } else {
            try w.writeAll("Submit? [Y/n/e] ");
            try w.flush();

            const answer = readLine() orelse return error.Cancelled;
            if (answer.len > 0 and (answer[0] == 'n' or answer[0] == 'N')) {
                try w.writeAll("Cancelled.\n");
                try w.flush();
                return error.Cancelled;
            }
            if (answer.len > 0 and (answer[0] == 'e' or answer[0] == 'E')) {
                if (openEditor(allocator, body)) |edited| {
                    allocator.free(body);
                    body = edited;
                    // body_owned remains true, defer will free the new body
                }
            }
        }
    }

    // Submit
    try w.writeAll("\nCreating issue...\n");
    try w.flush();

    const result = report.submitIssue(allocator, repo, report_type, title, body) catch {
        try printFallback(w, title, body, report_type);
        try w.flush();
        return;
    };

    switch (result) {
        .success => |url| {
            try w.print("Created: {s}\n", .{url});
            try w.flush();
        },
        .no_auth => {
            try printFallback(w, title, body, report_type);
            try w.flush();
        },
    }
}

fn printFallback(w: anytype, title: []const u8, body: []const u8, report_type: cli.ReportType) !void {
    try w.writeAll("\nCould not submit automatically. Copy the issue content below:\n\n");
    try w.writeAll("──────────────────────────\n");
    try w.print("Title: {s}\n", .{title});
    try w.print("Labels: ", .{});
    const labels = report_type.toLabels();
    for (labels, 0..) |label, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll(label);
    }
    try w.writeAll("\n\n");
    try w.writeAll(body);
    try w.writeAll("──────────────────────────\n\n");
    try w.writeAll("Tip: Install and authenticate the GitHub CLI to submit automatically:\n");
    try w.writeAll("  https://cli.github.com/\n");
}

// ─── Interactive Prompts ────────────────────────────────────────────────────

const repos = [_]cli.ReportRepo{ .nullhub, .nullclaw, .nullboiler, .nulltickets, .nullwatch };
const types = [_]cli.ReportType{ .bug_crash, .bug_behavior, .regression, .feature };

fn promptRepo(w: anytype) !?cli.ReportRepo {
    try w.writeAll("\nWhere is the problem?\n");
    for (repos, 0..) |r, i| {
        try w.print("  {d}. {s}\n", .{ i + 1, r.displayName() });
    }
    try w.writeAll("> ");
    try w.flush();

    const line = readLine() orelse return null;
    const num = std.fmt.parseInt(usize, line, 10) catch return null;
    if (num < 1 or num > repos.len) return null;
    return repos[num - 1];
}

fn promptType(w: anytype) !?cli.ReportType {
    try w.writeAll("\nReport type?\n");
    for (types, 0..) |t, i| {
        try w.print("  {d}. {s}\n", .{ i + 1, t.displayName() });
    }
    try w.writeAll("> ");
    try w.flush();

    const line = readLine() orelse return null;
    const num = std.fmt.parseInt(usize, line, 10) catch return null;
    if (num < 1 or num > types.len) return null;
    return types[num - 1];
}

fn promptMessage(allocator: std.mem.Allocator, w: anytype) !?[]const u8 {
    try w.writeAll("\nDescription: ");
    try w.flush();

    const line = readLine() orelse return null;
    if (line.len == 0) return null;
    // Dupe to heap since readLine returns a slice into a module-level buffer
    return try allocator.dupe(u8, line);
}

/// Read a line from stdin into the module-level line_buf.
/// Returns a slice into line_buf (valid until next readLine call).
fn readLine() ?[]const u8 {
    const stdin = std.io.getStdIn();
    const n = stdin.read(&line_buf) catch return null;
    if (n == 0) return null;
    var line: []const u8 = line_buf[0..n];
    // Trim trailing newline/carriage return
    while (line.len > 0 and (line[line.len - 1] == '\n' or line[line.len - 1] == '\r')) {
        line = line[0 .. line.len - 1];
    }
    return line;
}

fn openEditor(allocator: std.mem.Allocator, content: []const u8) ?[]const u8 {
    const editor = std.process.getEnvVarOwned(allocator, "EDITOR") catch {
        // Fallback to vi
        return openEditorWith(allocator, "vi", content);
    };
    defer allocator.free(editor);
    return openEditorWith(allocator, editor, content);
}

fn openEditorWith(allocator: std.mem.Allocator, editor: []const u8, content: []const u8) ?[]const u8 {
    // Write content to a temp file
    const tmp_path = "/tmp/nullhub-report.md";
    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch return null;
    file.writeAll(content) catch {
        file.close();
        return null;
    };
    file.close();
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    // Run editor
    var child = std.process.Child.init(&.{ editor, tmp_path }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    _ = child.spawnAndWait() catch return null;

    // Read back
    const edited_file = std.fs.openFileAbsolute(tmp_path, .{}) catch return null;
    defer edited_file.close();
    return edited_file.readToEndAlloc(allocator, 64 * 1024) catch null;
}
```

- [ ] **Step 2: Add report_cli to root.zig and wire main.zig**

In `src/root.zig`, add after `pub const report = ...;`:
```zig
pub const report_cli = @import("report_cli.zig");
```

Add `_ = report_cli;` in the test block.

In `src/main.zig`, add the import at the top alongside other imports:
```zig
const report_cli = @import("report_cli.zig");
```

Add before `.help =>` in the switch:
```zig
.report => |opts| report_cli.run(allocator, opts) catch |err| {
    const any_err: anyerror = err;
    switch (any_err) {
        error.Cancelled => {},
        else => std.debug.print("Report failed: {s}\n", .{@errorName(any_err)}),
    }
},
```

- [ ] **Step 3: Run build and tests**

Run: `zig build test --summary all 2>&1 | head -20`
Expected: builds and tests pass

- [ ] **Step 4: Commit**

```bash
git add src/report_cli.zig src/root.zig src/main.zig
git commit -m "Add interactive CLI flow for report command and wire into main"
```

---

## Task 5: API endpoint

**Files:**
- Create: `src/api/report.zig`
- Modify: `src/server.zig`
- Modify: `src/root.zig`

- [ ] **Step 1: Create src/api/report.zig**

```zig
const std = @import("std");
const helpers = @import("helpers.zig");
const cli = @import("../cli.zig");
const report = @import("../report.zig");

pub fn handlePreview(allocator: std.mem.Allocator, body: []const u8) helpers.ApiResponse {
    const parsed = parseRequest(allocator, body) orelse
        return helpers.badRequest("{\"error\":\"invalid request: repo, type, and message are required\"}");

    const info = report.collectSystemInfo(allocator) catch report.SystemInfo{
        .version = @import("../version.zig").string,
        .platform_key = @import("../core/platform.zig").detect().toString(),
        .os_version = "unknown",
        .components = &.{},
    };

    const title = report.buildTitle(allocator, parsed.report_type, parsed.message) catch
        return helpers.serverError();
    const markdown = report.buildBody(allocator, parsed.report_type, parsed.message, info) catch
        return helpers.serverError();

    // Build JSON response
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();

    w.writeAll("{\"title\":\"") catch return helpers.serverError();
    helpers.appendEscaped(&buf, title) catch return helpers.serverError();
    w.writeAll("\",\"markdown\":\"") catch return helpers.serverError();
    helpers.appendEscaped(&buf, markdown) catch return helpers.serverError();
    w.writeAll("\",\"labels\":[") catch return helpers.serverError();
    const labels = parsed.report_type.toLabels();
    for (labels, 0..) |label, i| {
        if (i > 0) w.writeAll(",") catch return helpers.serverError();
        w.writeAll("\"") catch return helpers.serverError();
        w.writeAll(label) catch return helpers.serverError();
        w.writeAll("\"") catch return helpers.serverError();
    }
    w.writeAll("],\"repo\":\"") catch return helpers.serverError();
    w.writeAll(parsed.repo.toGithubRepo()) catch return helpers.serverError();
    w.writeAll("\"}") catch return helpers.serverError();

    return helpers.jsonOk(buf.toOwnedSlice() catch return helpers.serverError());
}

pub fn handleSubmit(allocator: std.mem.Allocator, body: []const u8) helpers.ApiResponse {
    const parsed = parseRequest(allocator, body) orelse
        return helpers.badRequest("{\"error\":\"invalid request: repo, type, and message are required\"}");

    const info = report.collectSystemInfo(allocator) catch report.SystemInfo{
        .version = @import("../version.zig").string,
        .platform_key = @import("../core/platform.zig").detect().toString(),
        .os_version = "unknown",
        .components = &.{},
    };

    const title = report.buildTitle(allocator, parsed.report_type, parsed.message) catch
        return helpers.serverError();

    // Use provided markdown (edited by user) or generate
    const markdown = parsed.markdown orelse
        (report.buildBody(allocator, parsed.report_type, parsed.message, info) catch
        return helpers.serverError());

    const result = report.submitIssue(allocator, parsed.repo, parsed.report_type, title, markdown) catch
        return buildNoAuthResponse(allocator, title, markdown, parsed.report_type, parsed.repo);

    switch (result) {
        .success => |url| {
            var buf = std.array_list.Managed(u8).init(allocator);
            const w = buf.writer();
            w.writeAll("{\"status\":\"created\",\"url\":\"") catch return helpers.serverError();
            helpers.appendEscaped(&buf, url) catch return helpers.serverError();
            w.writeAll("\"}") catch return helpers.serverError();
            return helpers.jsonOk(buf.toOwnedSlice() catch return helpers.serverError());
        },
        .no_auth => return buildNoAuthResponse(allocator, title, markdown, parsed.report_type, parsed.repo),
    }
}

// ─── Internals ──────────────────────────────────────────────────────────────

const ParsedRequest = struct {
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    message: []const u8,
    markdown: ?[]const u8 = null,
};

fn parseRequest(allocator: std.mem.Allocator, body: []const u8) ?ParsedRequest {
    const parsed = std.json.parseFromSlice(
        struct {
            repo: ?[]const u8 = null,
            type: ?[]const u8 = null,
            message: ?[]const u8 = null,
            markdown: ?[]const u8 = null,
        },
        allocator,
        body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return null;
    // Don't deinit — we'll borrow the strings

    const repo_str = parsed.value.repo orelse return null;
    const type_str = parsed.value.type orelse return null;
    const message = parsed.value.message orelse return null;
    if (message.len == 0) return null;

    const repo = cli.ReportRepo.fromStr(repo_str) orelse return null;
    const report_type = cli.ReportType.fromStr(type_str) orelse return null;

    return .{
        .repo = repo,
        .report_type = report_type,
        .message = message,
        .markdown = parsed.value.markdown,
    };
}

fn buildNoAuthResponse(
    allocator: std.mem.Allocator,
    title: []const u8,
    markdown: []const u8,
    report_type: cli.ReportType,
    repo: cli.ReportRepo,
) helpers.ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();

    w.writeAll("{\"status\":\"no_auth\",\"title\":\"") catch return helpers.serverError();
    helpers.appendEscaped(&buf, title) catch return helpers.serverError();
    w.writeAll("\",\"markdown\":\"") catch return helpers.serverError();
    helpers.appendEscaped(&buf, markdown) catch return helpers.serverError();
    w.writeAll("\",\"labels\":[") catch return helpers.serverError();
    const labels = report_type.toLabels();
    for (labels, 0..) |label, i| {
        if (i > 0) w.writeAll(",") catch return helpers.serverError();
        w.writeAll("\"") catch return helpers.serverError();
        w.writeAll(label) catch return helpers.serverError();
        w.writeAll("\"") catch return helpers.serverError();
    }
    w.writeAll("],\"repo\":\"") catch return helpers.serverError();
    w.writeAll(repo.toGithubRepo()) catch return helpers.serverError();
    w.writeAll("\",\"hint\":\"Install and authenticate gh CLI to submit automatically: https://cli.github.com/\"}") catch return helpers.serverError();

    return helpers.jsonOk(buf.toOwnedSlice() catch return helpers.serverError());
}

// ─── Tests ──────────────────────────────────────────────────────────────────

test "parseRequest valid" {
    const allocator = std.testing.allocator;
    const json = "{\"repo\":\"nullhub\",\"type\":\"bug:crash\",\"message\":\"App crashes\"}";
    const result = parseRequest(allocator, json);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.repo == .nullhub);
    try std.testing.expect(result.?.report_type == .bug_crash);
    try std.testing.expectEqualStrings("App crashes", result.?.message);
    try std.testing.expect(result.?.markdown == null);
}

test "parseRequest with markdown" {
    const allocator = std.testing.allocator;
    const json = "{\"repo\":\"nullclaw\",\"type\":\"feature\",\"message\":\"Want X\",\"markdown\":\"custom body\"}";
    const result = parseRequest(allocator, json);
    try std.testing.expect(result != null);
    try std.testing.expect(result.?.markdown != null);
    try std.testing.expectEqualStrings("custom body", result.?.markdown.?);
}

test "parseRequest missing fields returns null" {
    const allocator = std.testing.allocator;
    try std.testing.expect(parseRequest(allocator, "{\"repo\":\"nullhub\"}") == null);
    try std.testing.expect(parseRequest(allocator, "{\"repo\":\"nullhub\",\"type\":\"bug:crash\"}") == null);
    try std.testing.expect(parseRequest(allocator, "{}") == null);
    try std.testing.expect(parseRequest(allocator, "invalid json") == null);
}

test "parseRequest invalid repo returns null" {
    const allocator = std.testing.allocator;
    const json = "{\"repo\":\"invalid\",\"type\":\"bug:crash\",\"message\":\"test\"}";
    try std.testing.expect(parseRequest(allocator, json) == null);
}

test "parseRequest empty message returns null" {
    const allocator = std.testing.allocator;
    const json = "{\"repo\":\"nullhub\",\"type\":\"bug:crash\",\"message\":\"\"}";
    try std.testing.expect(parseRequest(allocator, json) == null);
}

test "handlePreview returns valid JSON" {
    const allocator = std.testing.allocator;
    const json = "{\"repo\":\"nullhub\",\"type\":\"bug:behavior\",\"message\":\"Broken UI\"}";
    const resp = handlePreview(allocator, json);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(resp.body.len > 0);
    // Verify it's valid JSON by parsing
    const parsed = try std.json.parseFromSlice(
        struct { title: []const u8, repo: []const u8 },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expect(std.mem.indexOf(u8, parsed.value.title, "[Bug]") != null);
    try std.testing.expectEqualStrings("nullclaw/nullhub", parsed.value.repo);
}

test "handlePreview bad request" {
    const allocator = std.testing.allocator;
    const resp = handlePreview(allocator, "{}");
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
}
```

- [ ] **Step 2: Add routes to server.zig**

Find the POST section in `route()` (around line 536, after the `if (std.mem.eql(u8, method, "POST"))` block that handles `/api/components/refresh`). Add inside the POST check block, before the closing brace:

```zig
if (std.mem.eql(u8, target, "/api/report")) {
    const resp = report_api.handleSubmit(allocator, body);
    return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
}
if (std.mem.eql(u8, target, "/api/report/preview")) {
    const resp = report_api.handlePreview(allocator, body);
    return .{ .status = resp.status, .content_type = resp.content_type, .body = resp.body };
}
```

Add the import at the top of server.zig alongside other api imports:
```zig
const report_api = @import("api/report.zig");
```

- [ ] **Step 3: Add report_api to root.zig**

Add: `pub const report_api = @import("api/report.zig");`
Add `_ = report_api;` in test block.

- [ ] **Step 4: Run build and tests**

Run: `zig build test --summary all 2>&1 | head -20`
Expected: all tests pass

- [ ] **Step 5: Commit**

```bash
git add src/api/report.zig src/server.zig src/root.zig
git commit -m "Add report API endpoints for preview and submit"
```

---

## Task 6: Web UI — report page

**Files:**
- Create: `ui/src/routes/report/+page.svelte`
- Modify: `ui/src/lib/api/client.ts`
- Modify: `ui/src/lib/components/Sidebar.svelte`

- [ ] **Step 1: Add API methods to client.ts**

Add before the `...createOrchestrationApi(request, withQuery)` line:

```typescript
  reportPreview: (data: { repo: string; type: string; message: string }) =>
    request<{ title: string; markdown: string; labels: string[]; repo: string }>('/report/preview', {
      method: 'POST',
      body: JSON.stringify(data),
    }),

  submitReport: (data: { repo: string; type: string; message: string; markdown?: string }) =>
    request<{ status: string; url?: string; title?: string; markdown?: string; labels?: string[]; repo?: string; hint?: string }>('/report', {
      method: 'POST',
      body: JSON.stringify(data),
    }),
```

- [ ] **Step 2: Add Report link to Sidebar.svelte**

In the `nav-bottom` div, add a Report link before the Settings link:

```svelte
  <div class="nav-bottom">
    <a href="/report" class:active={currentPath === "/report"}>Report Issue</a>
    <a href="/settings" class:active={currentPath === "/settings"}>Settings</a>
  </div>
```

- [ ] **Step 3: Create report page**

Create `ui/src/routes/report/+page.svelte`:

```svelte
<script lang="ts">
  import { api } from "$lib/api/client";

  type Step = "form" | "preview" | "result";

  const REPOS = [
    { value: "nullhub", label: "NullHub" },
    { value: "nullclaw", label: "NullClaw" },
    { value: "nullboiler", label: "NullBoiler" },
    { value: "nulltickets", label: "NullTickets" },
    { value: "nullwatch", label: "NullWatch" },
  ];

  const TYPES = [
    { value: "bug:crash", label: "Bug: crash (process exits or hangs)" },
    { value: "bug:behavior", label: "Bug: behavior (incorrect output/state)" },
    { value: "regression", label: "Bug: regression (worked before, now fails)" },
    { value: "feature", label: "Feature request" },
  ];

  let step = $state<Step>("form");
  let repo = $state("nullhub");
  let type = $state("bug:crash");
  let message = $state("");
  let loading = $state(false);
  let error = $state("");

  // Preview state
  let previewTitle = $state("");
  let previewMarkdown = $state("");
  let previewLabels = $state<string[]>([]);
  let previewRepo = $state("");

  // Result state
  let resultUrl = $state("");
  let resultHint = $state("");
  let resultMarkdown = $state("");
  let copied = $state(false);

  async function goToPreview() {
    if (!message.trim()) {
      error = "Description is required";
      return;
    }
    loading = true;
    error = "";
    try {
      const res = await api.reportPreview({ repo, type, message: message.trim() });
      previewTitle = res.title;
      previewMarkdown = res.markdown;
      previewLabels = res.labels;
      previewRepo = res.repo;
      step = "preview";
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  async function submit() {
    loading = true;
    error = "";
    try {
      const res = await api.submitReport({
        repo,
        type,
        message: message.trim(),
        markdown: previewMarkdown,
      });
      if (res.status === "created" && res.url) {
        resultUrl = res.url;
        resultHint = "";
        resultMarkdown = "";
      } else {
        resultUrl = "";
        resultHint = res.hint || "";
        resultMarkdown = previewMarkdown;
      }
      step = "result";
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  function reset() {
    step = "form";
    message = "";
    error = "";
    resultUrl = "";
    resultHint = "";
    resultMarkdown = "";
    copied = false;
  }

  async function copyMarkdown() {
    try {
      await navigator.clipboard.writeText(resultMarkdown);
      copied = true;
      setTimeout(() => (copied = false), 2000);
    } catch {
      // Fallback: select text
    }
  }
</script>

<div class="report-page">
  <h1>Report Issue</h1>

  {#if step === "form"}
    <div class="form-section">
      <div class="field">
        <label for="report-repo">Repository</label>
        <select id="report-repo" bind:value={repo}>
          {#each REPOS as r}
            <option value={r.value}>{r.label}</option>
          {/each}
        </select>
      </div>

      <div class="field">
        <label for="report-type">Report Type</label>
        <select id="report-type" bind:value={type}>
          {#each TYPES as t}
            <option value={t.value}>{t.label}</option>
          {/each}
        </select>
      </div>

      <div class="field">
        <label for="report-message">Description</label>
        <input
          id="report-message"
          type="text"
          bind:value={message}
          placeholder="Describe the issue or feature..."
          onkeydown={(e) => e.key === "Enter" && goToPreview()}
        />
      </div>

      {#if error}
        <div class="message message-error">{error}</div>
      {/if}

      <div class="actions">
        <button class="primary-btn" onclick={goToPreview} disabled={loading}>
          {loading ? "Loading..." : "Next"}
        </button>
      </div>
    </div>

  {:else if step === "preview"}
    <div class="preview-section">
      <div class="preview-header">
        <span class="preview-label">Title</span>
        <code>{previewTitle}</code>
      </div>
      <div class="preview-header">
        <span class="preview-label">Labels</span>
        <span class="label-list">
          {#each previewLabels as label}
            <span class="label-pill">{label}</span>
          {/each}
        </span>
      </div>
      <div class="preview-header">
        <span class="preview-label">Repository</span>
        <code>{previewRepo}</code>
      </div>

      <div class="field">
        <label for="report-preview">Issue Body</label>
        <textarea id="report-preview" bind:value={previewMarkdown} rows="16"></textarea>
      </div>

      {#if error}
        <div class="message message-error">{error}</div>
      {/if}

      <div class="actions actions-split">
        <button class="btn" onclick={() => (step = "form")}>Back</button>
        <button class="primary-btn" onclick={submit} disabled={loading}>
          {loading ? "Submitting..." : "Submit"}
        </button>
      </div>
    </div>

  {:else if step === "result"}
    <div class="result-section">
      {#if resultUrl}
        <div class="message message-success">
          Issue created successfully!
        </div>
        <div class="result-link">
          <a href={resultUrl} target="_blank" rel="noopener noreferrer">{resultUrl}</a>
        </div>
      {:else}
        <div class="message message-error">
          Could not submit automatically.
        </div>
        {#if resultHint}
          <p class="hint">{resultHint}</p>
        {/if}
        <div class="fallback-block">
          <div class="fallback-header">
            <span>Copy this content and create the issue manually:</span>
            <button class="btn copy-btn" onclick={copyMarkdown}>
              {copied ? "Copied!" : "Copy"}
            </button>
          </div>
          <pre>{resultMarkdown}</pre>
        </div>
      {/if}

      <div class="actions">
        <button class="btn" onclick={reset}>New Report</button>
      </div>
    </div>
  {/if}
</div>

<style>
  .report-page {
    max-width: 700px;
    margin: 0 auto;
    padding: 2rem;
  }

  h1 {
    font-size: 1.75rem;
    font-weight: 700;
    margin-bottom: 2rem;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }

  .field {
    margin-bottom: 1.25rem;
  }

  .field label {
    display: block;
    font-size: 0.8125rem;
    font-weight: 700;
    color: var(--fg-dim);
    margin-bottom: 0.5rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .field input[type="text"],
  .field select,
  .field textarea {
    width: 100%;
    padding: 0.625rem 0.875rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
  }

  .field input:focus,
  .field select:focus,
  .field textarea:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .field input::placeholder {
    color: color-mix(in srgb, var(--fg-dim) 50%, transparent);
  }

  .field textarea {
    resize: vertical;
    min-height: 200px;
    line-height: 1.5;
  }

  .field select {
    cursor: pointer;
  }

  .preview-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 0.75rem;
  }

  .preview-label {
    font-size: 0.75rem;
    font-weight: 700;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    min-width: 6rem;
  }

  .preview-header code {
    font-family: var(--font-mono);
    font-size: 0.875rem;
    color: var(--fg);
  }

  .label-list {
    display: flex;
    gap: 0.5rem;
  }

  .label-pill {
    padding: 0.125rem 0.5rem;
    border: 1px solid var(--accent-dim);
    border-radius: var(--radius-sm);
    font-size: 0.75rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 0.5px;
  }

  .actions {
    padding-top: 1rem;
    display: flex;
    justify-content: flex-end;
  }

  .actions-split {
    justify-content: space-between;
  }

  .primary-btn {
    padding: 0.75rem 2rem;
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 2px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
    box-shadow: inset 0 0 10px color-mix(in srgb, var(--accent) 30%, transparent);
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    box-shadow: 0 0 15px var(--border-glow), inset 0 0 15px color-mix(in srgb, var(--accent) 40%, transparent);
    text-shadow: 0 0 10px var(--accent);
  }

  .primary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn {
    padding: 0.5rem 1.25rem;
    background: var(--bg-surface);
    color: var(--fg-dim);
    border: 1px solid color-mix(in srgb, var(--border) 80%, transparent);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }

  .btn:hover {
    background: var(--bg-hover);
    color: var(--fg);
    border-color: var(--accent-dim);
  }

  .message {
    padding: 0.875rem 1.25rem;
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: bold;
    margin-bottom: 1rem;
  }

  .message-success {
    background: color-mix(in srgb, var(--success) 10%, transparent);
    border: 1px solid var(--success);
    color: var(--success);
    box-shadow: 0 0 10px color-mix(in srgb, var(--success) 30%, transparent);
  }

  .message-error {
    background: color-mix(in srgb, var(--error) 10%, transparent);
    border: 1px solid var(--error);
    color: var(--error);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error) 30%, transparent);
  }

  .result-link {
    margin-bottom: 1.5rem;
  }

  .result-link a {
    color: var(--accent);
    font-family: var(--font-mono);
    font-size: 0.875rem;
    word-break: break-all;
  }

  .hint {
    font-size: 0.8125rem;
    color: var(--fg-dim);
    margin-bottom: 1rem;
    font-family: var(--font-mono);
  }

  .fallback-block {
    border: 1px solid var(--border);
    border-radius: 2px;
    margin-bottom: 1.5rem;
    overflow: hidden;
  }

  .fallback-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.75rem 1rem;
    background: var(--bg-surface);
    border-bottom: 1px solid var(--border);
    font-size: 0.8125rem;
    color: var(--fg-dim);
  }

  .copy-btn {
    padding: 0.25rem 0.75rem;
    font-size: 0.75rem;
    margin-top: 0;
  }

  .fallback-block pre {
    padding: 1rem;
    margin: 0;
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--fg);
    white-space: pre-wrap;
    word-break: break-word;
    line-height: 1.5;
    max-height: 400px;
    overflow-y: auto;
  }
</style>
```

- [ ] **Step 4: Commit**

```bash
git add ui/src/routes/report/+page.svelte ui/src/lib/api/client.ts ui/src/lib/components/Sidebar.svelte
git commit -m "Add report page to Web UI with preview and submit flow"
```

---

## Task 7: Create GitHub labels in all repos

- [ ] **Step 1: Run label creation commands**

```bash
for repo in nullclaw/nullhub nullclaw/nullclaw nullclaw/NullBoiler nullclaw/nulltickets nullclaw/nullwatch; do
  gh label create "regression" --description "Behavior that previously worked and now fails" --color "D93F0B" -R "$repo" 2>/dev/null || true
  gh label create "bug:behavior" --description "Incorrect behavior without a crash" --color "D73A4A" -R "$repo" 2>/dev/null || true
  gh label create "bug:crash" --description "Process/app exits unexpectedly or hangs" --color "B60205" -R "$repo" 2>/dev/null || true
done
```

- [ ] **Step 2: Verify labels exist**

```bash
gh label list -R nullclaw/nullhub | grep -E "regression|bug:behavior|bug:crash"
```

Expected: 3 labels shown

---

## Task 8: Build verification and final test

- [ ] **Step 1: Run full test suite**

Run: `zig build test --summary all 2>&1`
Expected: all tests pass

- [ ] **Step 2: Build the binary**

Run: `zig build 2>&1`
Expected: clean build

- [ ] **Step 3: Verify CLI help shows report**

Run: `./zig-out/bin/nullhub help 2>&1 | grep report`
Expected: shows `report` in help text

- [ ] **Step 4: Verify CLI report --dry-run works**

Run: `./zig-out/bin/nullhub report --repo nullhub --type bug:behavior --message "Test report" --dry-run 2>&1`
Expected: shows preview with system info and "(dry run — not submitted)"

- [ ] **Step 5: Final commit if any fixups needed**

```bash
git add -A
git commit -m "Fix any build/test issues from integration"
```
