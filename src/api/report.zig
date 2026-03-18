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
