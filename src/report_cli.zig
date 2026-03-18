const std = @import("std");
const cli = @import("cli.zig");
const report = @import("report.zig");
const report_schema = @import("report_schema.zig");

// ─── Shared read buffer for stdin (avoids dangling stack pointers) ───────────

var line_buf: [1024]u8 = undefined;

pub fn run(allocator: std.mem.Allocator, opts: cli.ReportOptions) !void {
    var stdout_buf: [8192]u8 = undefined;
    var bw = std.fs.File.stdout().writer(&stdout_buf);
    const w = &bw.interface;

    // TTY detection: if stdin is not a TTY, require all flags
    const is_tty = std.fs.File.stdin().isTty();
    if (!is_tty) {
        if (opts.repo == null or opts.report_type == null or opts.message == null) {
            try w.writeAll("Error: --repo, --type, and --message are required in non-interactive mode.\n");
            try w.flush();
            return error.InvalidArguments;
        }
    }

    // Resolve options (interactive or from flags)
    const repo = opts.repo orelse try promptRepo(w) orelse return error.Cancelled;
    const report_type = opts.report_type orelse try promptType(w) orelse return error.Cancelled;
    var message_owned = false;
    const message = opts.message orelse blk: {
        const m = try promptMessage(allocator, w) orelse return error.Cancelled;
        message_owned = true;
        break :blk m;
    };
    defer if (message_owned) allocator.free(message);

    // Collect system info
    var info = report.collectSystemInfo(allocator) catch report.SystemInfo{
        .version = @import("version.zig").string,
        .platform_key = @import("core/platform.zig").detect().toString(),
        .os_version = "unknown",
        .components = &.{},
    };
    defer info.deinit(allocator);

    // Generate title and body
    const title = try report.buildTitle(allocator, report_type, message);
    defer allocator.free(title);

    var body_owned = false;
    var body = try report.buildBody(allocator, repo, report_type, message, info);

    defer {
        if (body_owned) allocator.free(body);
    }
    body_owned = true;

    // Preview
    try w.writeAll("\nPreview:\n");
    try w.writeAll("──────────────────────────\n");
    try w.print("Title: {s}\n\n", .{title});
    try w.writeAll(body);
    try w.writeAll("\n");
    try w.writeAll("──────────────────────────\n");
    try w.flush();

    if (opts.dry_run) {
        try w.writeAll("\n(dry run — not submitted)\n");
        try w.flush();
        return;
    }

    if (!opts.yes) {
        if (!is_tty) {
            try w.writeAll("Use --yes to confirm submission in non-interactive mode.\n");
            try w.flush();
            return error.InvalidArguments;
        }

        {
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
                } else {
                    try w.writeAll("Editor launch failed; keeping the current draft.\n");
                    try w.flush();
                }
            }
        }
    }

    // Submit
    try w.writeAll("\nCreating issue...\n");
    try w.flush();

    const result = report.submitIssue(allocator, repo, report_type, title, body) catch {
        try w.writeAll("Unexpected error while preparing the manual fallback.\n");
        try w.flush();
        return;
    };

    switch (result) {
        .success => |url| {
            defer allocator.free(url);
            try w.print("Created: {s}\n", .{url});
            try w.flush();
        },
        .manual => |manual| {
            defer manual.deinit(allocator);
            try printFallback(w, repo, title, body, report_type, manual);
            try w.flush();
        },
    }
}

fn printFallback(
    w: anytype,
    repo: cli.ReportRepo,
    title: []const u8,
    body: []const u8,
    report_type: cli.ReportType,
    manual: report.ManualSubmission,
) !void {
    try w.writeAll("\nCould not submit automatically. Copy the issue content below:\n\n");
    try w.print("Reason: {s}\n", .{manual.reason});
    try w.print("Hint: {s}\n", .{manual.hint});
    try w.print("Repository: {s}\n", .{repo.toGithubRepo()});
    try w.print("Open manually: {s}\n\n", .{manual.manual_url});
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

fn promptRepo(w: anytype) !?cli.ReportRepo {
    try w.writeAll("\nWhere is the problem?\n");
    const repos = report_schema.repos();
    for (repos, 0..) |repo_spec, i| {
        try w.print("  {d}. {s}\n", .{ i + 1, repo_spec.display_name });
    }
    try w.writeAll("> ");
    try w.flush();

    const line = readLine() orelse return null;
    const num = std.fmt.parseInt(usize, line, 10) catch return null;
    if (num < 1 or num > repos.len) return null;
    return repos[num - 1].id;
}

fn promptType(w: anytype) !?cli.ReportType {
    try w.writeAll("\nReport type?\n");
    const types = report_schema.types();
    for (types, 0..) |type_spec, i| {
        try w.print("  {d}. {s}\n", .{ i + 1, type_spec.display_name });
    }
    try w.writeAll("> ");
    try w.flush();

    const line = readLine() orelse return null;
    const num = std.fmt.parseInt(usize, line, 10) catch return null;
    if (num < 1 or num > types.len) return null;
    return types[num - 1].id;
}

fn promptMessage(allocator: std.mem.Allocator, w: anytype) !?[]const u8 {
    try w.writeAll("\nSummary: ");
    try w.flush();

    const line = readLine() orelse return null;
    if (line.len == 0) return null;
    // Dupe to heap since readLine returns a slice into a module-level buffer
    return try allocator.dupe(u8, line);
}

/// Read a line from stdin into the module-level line_buf.
/// Returns a slice into line_buf (valid until next readLine call).
fn readLine() ?[]const u8 {
    const stdin = std.fs.File.stdin();
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
        return openEditorWithCommand(allocator, "vi", content);
    };
    defer allocator.free(editor);
    const trimmed = std.mem.trim(u8, editor, " \r\n\t");
    if (trimmed.len == 0) return openEditorWithCommand(allocator, "vi", content);
    return openEditorWithCommand(allocator, trimmed, content);
}

fn openEditorWithCommand(allocator: std.mem.Allocator, editor: []const u8, content: []const u8) ?[]const u8 {
    // Write content to a temp file
    const tmp_path = "/tmp/nullhub-report.md";
    const file = std.fs.createFileAbsolute(tmp_path, .{}) catch return null;
    file.writeAll(content) catch {
        file.close();
        return null;
    };
    file.close();
    defer std.fs.deleteFileAbsolute(tmp_path) catch {};

    const shell = std.process.getEnvVarOwned(allocator, "SHELL") catch allocator.dupe(u8, "/bin/sh") catch return null;
    defer allocator.free(shell);

    const command = std.fmt.allocPrint(allocator, "{s} '{s}'", .{ editor, tmp_path }) catch return null;
    defer allocator.free(command);

    // Run editor through the user's shell so `$EDITOR` can include flags.
    var child = std.process.Child.init(&.{ shell, "-lc", command }, allocator);
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = child.spawnAndWait() catch return null;
    switch (term) {
        .Exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Read back
    const edited_file = std.fs.openFileAbsolute(tmp_path, .{}) catch return null;
    defer edited_file.close();
    return edited_file.readToEndAlloc(allocator, 64 * 1024) catch null;
}
