const std = @import("std");
const helpers = @import("helpers.zig");
const cli = @import("../cli.zig");
const report = @import("../report.zig");
const report_schema = @import("../report_schema.zig");

pub fn handleMeta(allocator: std.mem.Allocator) helpers.ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();

    w.writeAll("{\"repos\":[") catch return helpers.serverError();
    for (report_schema.repos(), 0..) |repo_spec, i| {
        if (i > 0) w.writeAll(",") catch return helpers.serverError();
        w.writeAll("{\"value\":\"") catch return helpers.serverError();
        helpers.appendEscaped(&buf, repo_spec.value) catch return helpers.serverError();
        w.writeAll("\",\"label\":\"") catch return helpers.serverError();
        helpers.appendEscaped(&buf, repo_spec.display_name) catch return helpers.serverError();
        w.writeAll("\",\"repo\":\"") catch return helpers.serverError();
        helpers.appendEscaped(&buf, repo_spec.github_repo) catch return helpers.serverError();
        w.writeAll("\"}") catch return helpers.serverError();
    }
    w.writeAll("],\"types\":[") catch return helpers.serverError();
    for (report_schema.types(), 0..) |type_spec, i| {
        if (i > 0) w.writeAll(",") catch return helpers.serverError();
        w.writeAll("{\"value\":\"") catch return helpers.serverError();
        helpers.appendEscaped(&buf, type_spec.value) catch return helpers.serverError();
        w.writeAll("\",\"label\":\"") catch return helpers.serverError();
        helpers.appendEscaped(&buf, type_spec.display_name) catch return helpers.serverError();
        w.writeAll("\",\"labels\":[") catch return helpers.serverError();
        for (type_spec.labels, 0..) |label, j| {
            if (j > 0) w.writeAll(",") catch return helpers.serverError();
            w.writeAll("\"") catch return helpers.serverError();
            helpers.appendEscaped(&buf, label) catch return helpers.serverError();
            w.writeAll("\"") catch return helpers.serverError();
        }
        w.writeAll("]}") catch return helpers.serverError();
    }
    w.writeAll("]}") catch return helpers.serverError();

    return helpers.jsonOk(buf.toOwnedSlice() catch return helpers.serverError());
}

pub fn handlePreview(allocator: std.mem.Allocator, body: []const u8) helpers.ApiResponse {
    const parsed = parseRequest(allocator, body) orelse
        return helpers.badRequest("{\"status\":\"error\",\"error\":\"invalid request: repo, type, and message are required\"}");
    defer parsed.deinit(allocator);

    var info = report.collectSystemInfo(allocator) catch report.SystemInfo{
        .version = @import("../version.zig").string,
        .platform_key = @import("../core/platform.zig").detect().toString(),
        .os_version = "unknown",
        .components = &.{},
    };
    defer info.deinit(allocator);

    const title = report.buildTitle(allocator, parsed.report_type, parsed.message) catch
        return helpers.serverError();
    defer allocator.free(title);
    const markdown = report.buildBody(allocator, parsed.repo, parsed.report_type, parsed.message, info) catch
        return helpers.serverError();
    defer allocator.free(markdown);

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
        return helpers.badRequest("{\"status\":\"error\",\"error\":\"invalid request: repo, type, and message are required\"}");
    defer parsed.deinit(allocator);

    var info = report.collectSystemInfo(allocator) catch report.SystemInfo{
        .version = @import("../version.zig").string,
        .platform_key = @import("../core/platform.zig").detect().toString(),
        .os_version = "unknown",
        .components = &.{},
    };
    defer info.deinit(allocator);

    const title = report.buildTitle(allocator, parsed.report_type, parsed.message) catch
        return helpers.serverError();
    defer allocator.free(title);

    // Use provided markdown (edited by user) or generate
    const markdown = parsed.markdown orelse
        (report.buildBody(allocator, parsed.repo, parsed.report_type, parsed.message, info) catch
            return helpers.serverError());
    defer if (parsed.markdown == null) allocator.free(markdown);

    const result = report.submitIssue(allocator, parsed.repo, parsed.report_type, title, markdown) catch
        return helpers.serverError();

    switch (result) {
        .success => |url| {
            defer allocator.free(url);
            var buf = std.array_list.Managed(u8).init(allocator);
            const w = buf.writer();
            w.writeAll("{\"status\":\"created\",\"url\":\"") catch return helpers.serverError();
            helpers.appendEscaped(&buf, url) catch return helpers.serverError();
            w.writeAll("\"}") catch return helpers.serverError();
            return helpers.jsonOk(buf.toOwnedSlice() catch return helpers.serverError());
        },
        .manual => |manual| {
            defer manual.deinit(allocator);
            return buildManualResponse(allocator, title, markdown, parsed.report_type, parsed.repo, manual);
        },
    }
}

// ─── Internals ──────────────────────────────────────────────────────────────

const ParsedRequest = struct {
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    message: []const u8,
    markdown: ?[]const u8 = null,

    fn deinit(self: ParsedRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        if (self.markdown) |markdown| allocator.free(markdown);
    }
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
    defer parsed.deinit();

    const repo_str = parsed.value.repo orelse return null;
    const type_str = parsed.value.type orelse return null;
    const message_raw = parsed.value.message orelse return null;
    if (message_raw.len == 0) return null;

    const repo = cli.ReportRepo.fromStr(repo_str) orelse return null;
    const report_type = cli.ReportType.fromStr(type_str) orelse return null;

    const message = allocator.dupe(u8, message_raw) catch return null;
    errdefer allocator.free(message);

    const markdown = if (parsed.value.markdown) |value|
        allocator.dupe(u8, value) catch return null
    else
        null;
    errdefer if (markdown) |value| allocator.free(value);

    return .{
        .repo = repo,
        .report_type = report_type,
        .message = message,
        .markdown = markdown,
    };
}

fn buildManualResponse(
    allocator: std.mem.Allocator,
    title: []const u8,
    markdown: []const u8,
    report_type: cli.ReportType,
    repo: cli.ReportRepo,
    manual: report.ManualSubmission,
) helpers.ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();

    const status = switch (manual.kind) {
        .no_auth => "no_auth",
        .submit_failed => "failed",
    };

    w.writeAll("{\"status\":\"") catch return helpers.serverError();
    w.writeAll(status) catch return helpers.serverError();
    w.writeAll("\",\"title\":\"") catch return helpers.serverError();
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
    w.writeAll("\",\"manual_url\":\"") catch return helpers.serverError();
    helpers.appendEscaped(&buf, manual.manual_url) catch return helpers.serverError();
    w.writeAll("\",\"error\":\"") catch return helpers.serverError();
    helpers.appendEscaped(&buf, manual.reason) catch return helpers.serverError();
    w.writeAll("\",\"hint\":\"") catch return helpers.serverError();
    helpers.appendEscaped(&buf, manual.hint) catch return helpers.serverError();
    w.writeAll("\"}") catch return helpers.serverError();

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

test "handleMeta returns shared report options" {
    const allocator = std.testing.allocator;
    const resp = handleMeta(allocator);
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const parsed = try std.json.parseFromSlice(
        struct {
            repos: []const struct { value: []const u8, label: []const u8, repo: []const u8 },
            types: []const struct { value: []const u8, label: []const u8, labels: []const []const u8 },
        },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("nullhub", parsed.value.repos[0].value);
    try std.testing.expectEqualStrings("NullHub", parsed.value.repos[0].label);
    try std.testing.expectEqualStrings("nullwatch", parsed.value.repos[4].value);
    try std.testing.expectEqualStrings("bug:crash", parsed.value.types[0].value);
    try std.testing.expectEqualStrings("enhancement", parsed.value.types[3].labels[0]);
}

test "parseRequest invalid type returns null" {
    const allocator = std.testing.allocator;
    const json = "{\"repo\":\"nullhub\",\"type\":\"invalid\",\"message\":\"test\"}";
    try std.testing.expect(parseRequest(allocator, json) == null);
}

test "handleSubmit bad request" {
    const allocator = std.testing.allocator;
    const resp = handleSubmit(allocator, "{}");
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
}

test "handlePreview returns correct repo" {
    const allocator = std.testing.allocator;
    const json = "{\"repo\":\"nullboiler\",\"type\":\"feature\",\"message\":\"Add X\"}";
    const resp = handlePreview(allocator, json);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    // Verify it contains the correct GitHub repo (NullBoiler with capital letters)
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "nullclaw/NullBoiler") != null);
}
