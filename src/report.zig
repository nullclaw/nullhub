const std = @import("std");
const builtin = @import("builtin");
const cli = @import("cli.zig");
const report_schema = @import("report_schema.zig");
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

// ─── Template Loading ───────────────────────────────────────────────────────

const TemplateFieldKind = enum {
    markdown,
    textarea,
    input,
    dropdown,
    unsupported,

    fn fromString(raw: []const u8) TemplateFieldKind {
        if (std.mem.eql(u8, raw, "markdown")) return .markdown;
        if (std.mem.eql(u8, raw, "textarea")) return .textarea;
        if (std.mem.eql(u8, raw, "input")) return .input;
        if (std.mem.eql(u8, raw, "dropdown")) return .dropdown;
        return .unsupported;
    }
};

const TemplateField = struct {
    kind: TemplateFieldKind,
    id: []const u8 = "",
    label: []const u8 = "",
    description: []const u8 = "",
    placeholder: []const u8 = "",
    markdown_value: []const u8 = "",
    options: []const []const u8 = &.{},
};

const LoadedTemplate = struct {
    arena: std.heap.ArenaAllocator,
    fields: []const TemplateField = &.{},

    fn deinit(self: *LoadedTemplate) void {
        self.arena.deinit();
    }
};

const TemplateFieldBuilder = struct {
    allocator: std.mem.Allocator,
    kind: TemplateFieldKind = .unsupported,
    id: []const u8 = "",
    label: []const u8 = "",
    description: []const u8 = "",
    placeholder_inline: []const u8 = "",
    markdown_inline: []const u8 = "",
    placeholder_buf: std.array_list.Managed(u8),
    markdown_buf: std.array_list.Managed(u8),
    options: std.array_list.Managed([]const u8),

    fn init(allocator: std.mem.Allocator) TemplateFieldBuilder {
        return .{
            .allocator = allocator,
            .placeholder_buf = std.array_list.Managed(u8).init(allocator),
            .markdown_buf = std.array_list.Managed(u8).init(allocator),
            .options = std.array_list.Managed([]const u8).init(allocator),
        };
    }

    fn setId(self: *TemplateFieldBuilder, raw: []const u8) !void {
        self.id = try self.allocator.dupe(u8, raw);
    }

    fn setLabel(self: *TemplateFieldBuilder, raw: []const u8) !void {
        self.label = try self.allocator.dupe(u8, raw);
    }

    fn setDescription(self: *TemplateFieldBuilder, raw: []const u8) !void {
        self.description = try self.allocator.dupe(u8, raw);
    }

    fn setPlaceholderInline(self: *TemplateFieldBuilder, raw: []const u8) !void {
        self.placeholder_inline = try self.allocator.dupe(u8, raw);
    }

    fn setMarkdownInline(self: *TemplateFieldBuilder, raw: []const u8) !void {
        self.markdown_inline = try self.allocator.dupe(u8, raw);
    }

    fn appendPlaceholderLine(self: *TemplateFieldBuilder, raw: []const u8) !void {
        try self.placeholder_buf.appendSlice(raw);
        try self.placeholder_buf.append('\n');
    }

    fn appendMarkdownLine(self: *TemplateFieldBuilder, raw: []const u8) !void {
        try self.markdown_buf.appendSlice(raw);
        try self.markdown_buf.append('\n');
    }

    fn appendOption(self: *TemplateFieldBuilder, raw: []const u8) !void {
        try self.options.append(try self.allocator.dupe(u8, raw));
    }

    fn finish(self: *TemplateFieldBuilder) !TemplateField {
        return .{
            .kind = self.kind,
            .id = self.id,
            .label = self.label,
            .description = self.description,
            .placeholder = if (self.placeholder_buf.items.len > 0)
                try duplicateTrimmed(self.allocator, self.placeholder_buf.items)
            else
                self.placeholder_inline,
            .markdown_value = if (self.markdown_buf.items.len > 0)
                try duplicateTrimmed(self.allocator, self.markdown_buf.items)
            else
                self.markdown_inline,
            .options = try self.options.toOwnedSlice(),
        };
    }
};

fn loadIssueTemplate(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
) !LoadedTemplate {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    if (try loadTemplateFromLocal(a, repo, report_type)) |text| {
        if (parseIssueTemplateText(&arena, text)) |template| {
            return template;
        } else |_| {}
    }
    if (!builtin.is_test) {
        if (try loadTemplateFromRemote(a, repo, report_type)) |text| {
            if (parseIssueTemplateText(&arena, text)) |template| {
                return template;
            } else |_| {}
        }
    }

    return buildFallbackTemplate(&arena, report_type);
}

fn loadTemplateFromLocal(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
) !?[]const u8 {
    const local_path = report_schema.localTemplatePathAlloc(allocator, repo, report_type) catch return null;
    defer allocator.free(local_path);

    return std.fs.cwd().readFileAlloc(allocator, local_path, 256 * 1024) catch null;
}

fn loadTemplateFromRemote(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
) !?[]const u8 {
    const url = report_schema.remoteTemplateUrlAlloc(allocator, repo, report_type) catch return null;
    defer allocator.free(url);

    return fetchText(allocator, url) catch null;
}

fn fetchText(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body = std.Io.Writer.Allocating.init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
    });
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) {
        return error.BadHttpStatus;
    }

    return response_body.toOwnedSlice();
}

fn parseIssueTemplateText(arena: *std.heap.ArenaAllocator, text: []const u8) !LoadedTemplate {
    const a = arena.allocator();

    var fields = std.array_list.Managed(TemplateField).init(a);
    var current: ?TemplateFieldBuilder = null;
    var in_body = false;
    var in_attributes = false;
    var lines = std.array_list.Managed([]const u8).init(a);
    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line_raw| {
        try lines.append(std.mem.trimRight(u8, line_raw, "\r"));
    }

    const body_indent: usize = 2;
    const item_indent: usize = 4;
    const attr_indent: usize = 6;
    const block_indent: usize = 8;

    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        const indent = leadingSpaces(line);
        const content = line[@min(indent, line.len)..];

        if (indent == 0) {
            if (std.mem.eql(u8, content, "body:")) {
                in_body = true;
            }
            i += 1;
            continue;
        }

        if (!in_body) {
            i += 1;
            continue;
        }

        if (indent == body_indent and std.mem.startsWith(u8, content, "- type:")) {
            if (current) |*builder| {
                try fields.append(try builder.finish());
            }
            const raw_kind = stripQuotes(std.mem.trim(u8, content["- type:".len..], " "));
            current = TemplateFieldBuilder.init(a);
            current.?.kind = TemplateFieldKind.fromString(raw_kind);
            in_attributes = false;
            i += 1;
            continue;
        }

        if (current == null) {
            i += 1;
            continue;
        }

        if (indent == item_indent) {
            in_attributes = false;
            if (std.mem.startsWith(u8, content, "id:")) {
                const value = stripQuotes(std.mem.trim(u8, content["id:".len..], " "));
                if (value.len > 0) try current.?.setId(value);
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, content, "attributes:")) {
                in_attributes = true;
                i += 1;
                continue;
            }
            i += 1;
            continue;
        }

        if (!in_attributes or indent != attr_indent) {
            i += 1;
            continue;
        }

        if (std.mem.startsWith(u8, content, "label:")) {
            const value = stripQuotes(std.mem.trim(u8, content["label:".len..], " "));
            if (value.len > 0) try current.?.setLabel(value);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, content, "description:")) {
            const value = stripQuotes(std.mem.trim(u8, content["description:".len..], " "));
            if (value.len > 0) try current.?.setDescription(value);
            i += 1;
            continue;
        }
        if (std.mem.startsWith(u8, content, "placeholder:")) {
            const raw = std.mem.trim(u8, content["placeholder:".len..], " ");
            if (std.mem.eql(u8, raw, "|")) {
                i += 1;
                while (i < lines.items.len) : (i += 1) {
                    const block_line = lines.items[i];
                    const block_line_indent = leadingSpaces(block_line);
                    if (block_line_indent < block_indent) break;
                    const block_content = if (block_line.len >= block_indent) block_line[block_indent..] else "";
                    try current.?.appendPlaceholderLine(block_content);
                }
            } else {
                const value = stripQuotes(raw);
                if (value.len > 0) try current.?.setPlaceholderInline(value);
                i += 1;
            }
            continue;
        }
        if (std.mem.startsWith(u8, content, "value:")) {
            const raw = std.mem.trim(u8, content["value:".len..], " ");
            if (std.mem.eql(u8, raw, "|")) {
                i += 1;
                while (i < lines.items.len) : (i += 1) {
                    const block_line = lines.items[i];
                    const block_line_indent = leadingSpaces(block_line);
                    if (block_line_indent < block_indent) break;
                    const block_content = if (block_line.len >= block_indent) block_line[block_indent..] else "";
                    try current.?.appendMarkdownLine(block_content);
                }
            } else {
                const value = stripQuotes(raw);
                if (value.len > 0) try current.?.setMarkdownInline(value);
                i += 1;
            }
            continue;
        }
        if (std.mem.eql(u8, content, "options:")) {
            i += 1;
            while (i < lines.items.len) : (i += 1) {
                const option_line = lines.items[i];
                const option_indent = leadingSpaces(option_line);
                const option_content = option_line[@min(option_indent, option_line.len)..];
                if (option_indent < block_indent or !std.mem.startsWith(u8, option_content, "- ")) break;
                const value = stripQuotes(std.mem.trim(u8, option_content[2..], " "));
                if (value.len > 0) try current.?.appendOption(value);
            }
            continue;
        }

        i += 1;
    }

    if (current) |*builder| {
        try fields.append(try builder.finish());
    }

    const field_slice = try fields.toOwnedSlice();
    return .{
        .arena = arena.*,
        .fields = field_slice,
    };
}

fn buildFallbackTemplate(arena: *std.heap.ArenaAllocator, report_type: cli.ReportType) !LoadedTemplate {
    const a = arena.allocator();
    const field_slice = switch (report_type) {
        .bug_crash, .bug_behavior => try a.dupe(TemplateField, &.{
            .{ .kind = .textarea, .id = "description", .label = "Summary", .placeholder = "What happened?" },
            .{ .kind = .textarea, .id = "reproduce", .label = "Steps to reproduce", .placeholder = "1. ...\n2. ...\n3. ..." },
            .{ .kind = .textarea, .id = "expected", .label = "Expected behavior", .placeholder = "What should happen?" },
            .{ .kind = .textarea, .id = "actual", .label = "Actual behavior", .placeholder = "What happened instead?" },
            .{ .kind = .textarea, .id = "impact", .label = "Impact and severity", .placeholder = "Affected:\nSeverity:\nFrequency:\nConsequence:" },
            .{ .kind = .input, .id = "version", .label = "Version" },
            .{ .kind = .input, .id = "os", .label = "OS" },
        }),
        .regression => try a.dupe(TemplateField, &.{
            .{ .kind = .textarea, .id = "description", .label = "Summary", .placeholder = "What regressed?" },
            .{ .kind = .textarea, .id = "reproduce", .label = "Steps to reproduce", .placeholder = "1. ...\n2. ...\n3. ..." },
            .{ .kind = .textarea, .id = "expected", .label = "Expected behavior", .placeholder = "What should happen?" },
            .{ .kind = .textarea, .id = "actual", .label = "Actual behavior", .placeholder = "What happened instead?" },
            .{ .kind = .textarea, .id = "impact", .label = "Impact and severity", .placeholder = "Affected:\nSeverity:\nFrequency:\nConsequence:" },
            .{ .kind = .textarea, .id = "regression", .label = "Regression details", .placeholder = "Last known good version:\nFirst known bad version:" },
            .{ .kind = .input, .id = "version", .label = "Version" },
            .{ .kind = .input, .id = "os", .label = "OS" },
        }),
        .feature => try a.dupe(TemplateField, &.{
            .{ .kind = .textarea, .id = "description", .label = "Summary", .placeholder = "What would you like to add?" },
            .{ .kind = .textarea, .id = "problem", .label = "Problem to solve", .placeholder = "What pain or limitation are you trying to remove?" },
            .{ .kind = .textarea, .id = "proposed_solution", .label = "Proposed solution", .placeholder = "Describe the desired behavior, API, or UI in concrete terms." },
            .{ .kind = .textarea, .id = "alternatives", .label = "Alternatives considered", .placeholder = "What other approaches did you consider, and why are they weaker?" },
            .{ .kind = .textarea, .id = "impact", .label = "Impact", .placeholder = "Affected:\nSeverity:\nFrequency:\nConsequence:" },
            .{ .kind = .input, .id = "version", .label = "Version" },
            .{ .kind = .input, .id = "os", .label = "OS" },
        }),
    };

    return .{
        .arena = arena.*,
        .fields = field_slice,
    };
}

fn duplicateTrimmed(allocator: std.mem.Allocator, raw: []const u8) ![]const u8 {
    return allocator.dupe(u8, std.mem.trimRight(u8, raw, "\r\n"));
}

fn leadingSpaces(line: []const u8) usize {
    var count: usize = 0;
    while (count < line.len and line[count] == ' ') : (count += 1) {}
    return count;
}

fn stripQuotes(raw: []const u8) []const u8 {
    if (raw.len >= 2 and ((raw[0] == '"' and raw[raw.len - 1] == '"') or (raw[0] == '\'' and raw[raw.len - 1] == '\''))) {
        return raw[1 .. raw.len - 1];
    }
    return raw;
}

fn componentVersionForRepo(info: SystemInfo, repo: cli.ReportRepo) ?[]const u8 {
    if (repo == .nullhub) return info.version;
    const target = repo.value();
    for (info.components) |component| {
        if (std.mem.eql(u8, component.name, target)) return component.comp_version;
    }
    return null;
}

fn reportVersionText(info: SystemInfo, repo: cli.ReportRepo) []const u8 {
    return componentVersionForRepo(info, repo) orelse "not installed locally";
}

fn templateFieldLabel(field: TemplateField) []const u8 {
    if (field.label.len > 0) return field.label;
    if (field.id.len > 0) return field.id;
    return "Details";
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn writeFieldValue(
    w: anytype,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    message: []const u8,
    info: SystemInfo,
    field: TemplateField,
) !void {
    const id = field.id;
    const label = templateFieldLabel(field);

    if (field.kind == .markdown) {
        if (field.markdown_value.len > 0) {
            try w.writeAll(field.markdown_value);
            try w.writeAll("\n\n");
        }
        return;
    }

    try w.print("### {s}\n\n", .{label});

    if ((std.mem.eql(u8, id, "summary") or std.mem.eql(u8, id, "description")) and message.len > 0) {
        try w.writeAll(message);
    } else if (std.mem.eql(u8, id, "bug_type") or containsIgnoreCase(label, "bug type")) {
        try w.writeAll(report_type.displayName());
    } else if (std.mem.eql(u8, id, "version") or containsIgnoreCase(label, "version")) {
        try w.writeAll(reportVersionText(info, repo));
    } else if (std.mem.eql(u8, id, "os") or containsIgnoreCase(label, "operating system") or std.ascii.eqlIgnoreCase(label, "OS")) {
        try w.print("{s} ({s})", .{ info.os_version, info.platform_key });
    } else if (std.mem.eql(u8, id, "install_method")) {
        try w.writeAll("Installed or managed via nullhub");
    } else if (field.placeholder.len > 0) {
        try w.writeAll(field.placeholder);
    } else if (field.description.len > 0) {
        try w.writeAll(field.description);
    } else if (field.kind == .dropdown and field.options.len > 0) {
        for (field.options, 0..) |option, i| {
            if (i > 0) try w.writeAll("\n");
            try w.print("- {s}", .{option});
        }
    } else {
        try w.writeAll("...");
    }

    try w.writeAll("\n\n");
}

fn templateHasField(
    fields: []const TemplateField,
    ids: []const []const u8,
    label_fragments: []const []const u8,
) bool {
    for (fields) |field| {
        for (ids) |id| {
            if (field.id.len > 0 and std.ascii.eqlIgnoreCase(field.id, id)) return true;
        }
        const label = templateFieldLabel(field);
        for (label_fragments) |fragment| {
            if (containsIgnoreCase(label, fragment)) return true;
        }
    }
    return false;
}

fn appendSection(w: anytype, label: []const u8, body: []const u8) !void {
    try w.print("### {s}\n\n{s}\n\n", .{ label, body });
}

fn appendBugPreamble(
    w: anytype,
    fields: []const TemplateField,
    report_type: cli.ReportType,
) !void {
    if (report_type == .feature) return;
    if (!templateHasField(fields, &.{"bug_type"}, &.{"bug type"})) {
        try appendSection(w, "Bug type", report_type.displayName());
    }
}

fn appendBugSupplementalSections(
    w: anytype,
    fields: []const TemplateField,
    report_type: cli.ReportType,
) !void {
    if (!templateHasField(fields, &.{"actual"}, &.{"actual behavior"})) {
        try appendSection(w, "Actual behavior", "What happened instead?");
    }
    if (!templateHasField(fields, &.{"impact"}, &.{"impact"})) {
        try appendSection(w, "Impact and severity", "Affected:\nSeverity:\nFrequency:\nConsequence:");
    }
    if (report_type == .regression and !templateHasField(fields, &.{"regression"}, &.{"regression"})) {
        try appendSection(w, "Regression details", "Last known good version:\nFirst known bad version:");
    }
    if (!templateHasField(fields, &.{ "logs", "evidence", "screenshots" }, &.{ "logs", "evidence", "screenshots" })) {
        try appendSection(w, "Logs, screenshots, and evidence", "```text\nPaste redacted logs, screenshots, stack traces, or links here.\n```");
    }
    if (!templateHasField(fields, &.{"additional"}, &.{"additional information"})) {
        try appendSection(w, "Additional information", "Temporary workaround, config details, or anything else that helps triage.");
    }
}

fn appendFeatureSupplementalSections(
    w: anytype,
    fields: []const TemplateField,
) !void {
    if (!templateHasField(fields, &.{ "problem", "motivation" }, &.{ "problem to solve", "motivation" })) {
        try appendSection(w, "Problem to solve", "What pain or limitation are you trying to remove?");
    }
    if (!templateHasField(fields, &.{"proposed_solution"}, &.{"proposed solution"})) {
        try appendSection(w, "Proposed solution", "Describe the desired behavior, API, or UI in concrete terms.");
    }
    if (!templateHasField(fields, &.{"alternatives"}, &.{"alternatives considered"})) {
        try appendSection(w, "Alternatives considered", "What other approaches did you consider, and why are they weaker?");
    }
    if (!templateHasField(fields, &.{"impact"}, &.{"impact"})) {
        try appendSection(w, "Impact", "Affected:\nSeverity:\nFrequency:\nConsequence:");
    }
    if (!templateHasField(fields, &.{ "evidence", "examples" }, &.{ "evidence", "examples" })) {
        try appendSection(w, "Evidence and examples", "Prior art, screenshots, metrics, logs, or links that support this request.");
    }
    if (!templateHasField(fields, &.{"additional"}, &.{"additional information"})) {
        try appendSection(w, "Additional information", "Constraints, compatibility concerns, or rollout notes.");
    }
}

fn buildBodyFromTemplate(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    message: []const u8,
    info: SystemInfo,
) ![]const u8 {
    var template = try loadIssueTemplate(allocator, repo, report_type);
    defer template.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    const w = buf.writer();

    var field_index: usize = 0;
    while (field_index < template.fields.len and template.fields[field_index].kind == .markdown) : (field_index += 1) {
        try writeFieldValue(w, repo, report_type, message, info, template.fields[field_index]);
    }

    try appendBugPreamble(w, template.fields, report_type);

    while (field_index < template.fields.len) : (field_index += 1) {
        try writeFieldValue(w, repo, report_type, message, info, template.fields[field_index]);
    }

    switch (report_type) {
        .bug_crash, .bug_behavior, .regression => try appendBugSupplementalSections(w, template.fields, report_type),
        .feature => try appendFeatureSupplementalSections(w, template.fields),
    }
    try appendSystemInfo(w, info);

    return buf.toOwnedSlice();
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

pub fn buildBody(
    allocator: std.mem.Allocator,
    repo: cli.ReportRepo,
    report_type: cli.ReportType,
    message: []const u8,
    info: SystemInfo,
) ![]const u8 {
    return buildBodyFromTemplate(allocator, repo, report_type, message, info);
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
            "gh",      "issue",             "create",
            "--repo",  repo.toGithubRepo(), "--title",
            title,     "--body",            body,
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
            "-X",   "POST",
            "-H",   "Accept: application/vnd.github+json",
            "-H",   "Content-Type: application/json",
            "-H",   auth_header,
            "-d",   json_buf.items,
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

test "buildBody uses local bug template when available" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{
            .{ .name = "nullclaw", .comp_version = "2026.3.14" },
        },
    };
    const body = try buildBody(allocator, .nullclaw, .bug_crash, "App crashes", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Bug type") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Bug: crash (process exits or hangs)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Description") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "App crashes") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Steps to reproduce") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Expected behavior") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Actual behavior") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Impact and severity") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Version") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2026.3.14") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### OS") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Logs, screenshots, and evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### System information") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "aarch64-macos") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Darwin 25.1.0") != null);
}

test "buildBody includes installed components table" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{
            .{ .name = "nullclaw", .comp_version = "2026.3.14" },
            .{ .name = "main", .comp_version = "2026.3.14" },
        },
    };
    const body = try buildBody(allocator, .nullclaw, .bug_behavior, "Wrong output", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Installed components") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "main") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "2026.3.14") != null);
}

test "buildBody supplements regression sections when template is generic" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{
            .{ .name = "nullclaw", .comp_version = "2026.3.14" },
        },
    };
    const body = try buildBody(allocator, .nullclaw, .regression, "Update broke routing", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Bug type") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Bug: regression (worked before, now fails)") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Regression details") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Last known good version") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Actual behavior") != null);
}

test "buildBody falls back when repo template is unavailable" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{},
    };
    const body = try buildBody(allocator, .nullhub, .regression, "Update broke routing", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Update broke routing") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Regression details") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Last known good version") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### System information") != null);
}

test "buildBody uses local feature template when available" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{
            .{ .name = "nullboiler", .comp_version = "0.1.0" },
        },
    };
    const body = try buildBody(allocator, .nullboiler, .feature, "Add feature X", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Description") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Add feature X") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Motivation") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Why is this feature useful?") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Proposed solution") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Alternatives considered") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### Impact") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "### System information") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "0.1.0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "Darwin 25.1.0") != null);
}

test "buildBody marks missing component version explicitly" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "2026.3.13",
        .platform_key = "aarch64-macos",
        .os_version = "Darwin 25.1.0",
        .components = &.{
            .{ .name = "nullclaw", .comp_version = "2026.3.14" },
        },
    };
    const body = try buildBody(allocator, .nullwatch, .feature, "Add feature X", info);
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "### Version") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "not installed locally") != null);
}

test "buildBody dispatches correctly" {
    const allocator = std.testing.allocator;
    const info = SystemInfo{
        .version = "1.0.0",
        .platform_key = "x86_64-linux",
        .os_version = "Linux 6.1",
        .components = &.{},
    };

    const bug_body = try buildBody(allocator, .nullhub, .regression, "Broke after update", info);
    defer allocator.free(bug_body);
    try std.testing.expect(std.mem.indexOf(u8, bug_body, "### Bug type") != null);
    try std.testing.expect(std.mem.indexOf(u8, bug_body, "### Regression details") != null);

    const feat_body = try buildBody(allocator, .nullboiler, .feature, "Want X", info);
    defer allocator.free(feat_body);
    try std.testing.expect(std.mem.indexOf(u8, feat_body, "### Proposed solution") != null);
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
