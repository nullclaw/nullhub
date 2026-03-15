const std = @import("std");

pub const CatalogEntry = struct {
    name: []const u8,
    version: []const u8,
    description: []const u8,
    author: []const u8 = "",
    recommended: bool = false,
    install_kind: []const u8,
    source: ?[]const u8 = null,
    homepage_url: ?[]const u8 = null,
    clawhub_slug: ?[]const u8 = null,
    always: bool = false,
    required_allowed_commands: []const []const u8 = &.{},
};

pub const InstallDisposition = enum {
    installed,
    updated,
};

const BundledSkill = struct {
    entry: CatalogEntry,
    instructions: []const u8,
};

const clawhub_url = "https://clawhub.ai";

const bundled_skills = [_]BundledSkill{
    .{
        .entry = .{
            .name = "nullhub-admin",
            .version = "0.1.0",
            .description = "Teach managed nullclaw agents to discover NullHub routes first and then use nullhub api for instance, provider, component, and orchestration tasks.",
            .recommended = true,
            .install_kind = "bundled",
            .homepage_url = clawhub_url,
            .always = true,
            .required_allowed_commands = &.{"nullhub *"},
        },
        .instructions = @embedFile("bundled_skills/nullhub-admin/SKILL.md"),
    },
};

pub fn catalogForComponent(component: []const u8) []const BundledSkill {
    if (std.mem.eql(u8, component, "nullclaw")) return bundled_skills[0..];
    return &.{};
}

pub fn installBundledSkill(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    skill_name: []const u8,
) !InstallDisposition {
    const bundled = findBundledSkill(skill_name) orelse return error.SkillNotFound;

    const skills_dir = try std.fs.path.join(allocator, &.{ workspace_dir, "skills" });
    defer allocator.free(skills_dir);
    try ensurePathAbsolute(skills_dir);

    const skill_dir = try std.fs.path.join(allocator, &.{ skills_dir, bundled.entry.name });
    defer allocator.free(skill_dir);
    try ensurePathAbsolute(skill_dir);

    const skill_md_path = try std.fs.path.join(allocator, &.{ skill_dir, "SKILL.md" });
    defer allocator.free(skill_md_path);

    const existing = readOptionalFileAlloc(allocator, skill_md_path, bundled.instructions.len + 4096) catch null;
    defer if (existing) |bytes| allocator.free(bytes);

    const file = try std.fs.createFileAbsolute(skill_md_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bundled.instructions);

    if (existing) |bytes| {
        if (std.mem.eql(u8, bytes, bundled.instructions)) return .installed;
        return .updated;
    }
    return .installed;
}

pub fn installAlwaysBundledSkills(
    allocator: std.mem.Allocator,
    component: []const u8,
    workspace_dir: []const u8,
    config_path: []const u8,
) !bool {
    var config_changed = false;
    for (catalogForComponent(component)) |bundled| {
        if (!bundled.entry.always) continue;
        _ = try installBundledSkill(allocator, workspace_dir, bundled.entry.name);
        config_changed = (try syncBundledSkillRuntime(allocator, config_path, bundled.entry.name)) or config_changed;
    }
    return config_changed;
}

pub fn syncBundledSkillRuntime(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    skill_name: []const u8,
) !bool {
    const bundled = findBundledSkill(skill_name) orelse return error.SkillNotFound;
    return syncAllowedCommands(allocator, config_path, bundled.entry.required_allowed_commands);
}

fn ensurePathAbsolute(path: []const u8) !void {
    std.fs.cwd().makePath(path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
}

fn findBundledSkill(name: []const u8) ?BundledSkill {
    for (bundled_skills) |bundled| {
        if (std.mem.eql(u8, bundled.entry.name, name)) return bundled;
    }
    return null;
}

fn syncAllowedCommands(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    required_allowed_commands: []const []const u8,
) !bool {
    if (required_allowed_commands.len == 0) return false;

    const file = std.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidConfig;
    const root = &parsed.value.object;
    const autonomy = try ensureObjectField(allocator, root, "autonomy");

    if (autonomy.get("level")) |level_value| {
        if (level_value == .string and
            (std.mem.eql(u8, level_value.string, "full") or std.mem.eql(u8, level_value.string, "yolo")))
        {
            return false;
        }
    }

    if (autonomy.get("allowed_commands")) |existing_value| {
        if (existing_value == .array) {
            for (existing_value.array.items) |item| {
                if (item == .string and std.mem.eql(u8, item.string, "*")) return false;
            }
        }
    }

    const allowed_value = try ensureArrayField(allocator, autonomy, "allowed_commands");
    var changed = false;
    for (required_allowed_commands) |command| {
        if (arrayContainsString(allowed_value.*, command)) continue;
        try allowed_value.append(.{ .string = command });
        changed = true;
    }
    if (!changed) return false;

    const rendered = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(rendered);

    const out = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(rendered);
    try out.writeAll("\n");
    return true;
}

fn ensureObjectField(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.ObjectMap {
    const gop = try obj.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .object = std.json.ObjectMap.init(allocator) };
        return &gop.value_ptr.object;
    }
    if (gop.value_ptr.* != .object) {
        gop.value_ptr.* = .{ .object = std.json.ObjectMap.init(allocator) };
    }
    return &gop.value_ptr.object;
}

fn ensureArrayField(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.Array {
    const gop = try obj.getOrPut(key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .array = std.json.Array.init(allocator) };
        return &gop.value_ptr.array;
    }
    if (gop.value_ptr.* != .array) {
        gop.value_ptr.* = .{ .array = std.json.Array.init(allocator) };
    }
    return &gop.value_ptr.array;
}

fn arrayContainsString(values: std.json.Array, expected: []const u8) bool {
    for (values.items) |value| {
        if (value == .string and std.mem.eql(u8, value.string, expected)) return true;
    }
    return false;
}

fn readOptionalFileAlloc(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: usize,
) !?[]u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();
    return try file.readToEndAlloc(allocator, max_bytes);
}

const ParsedAutonomyConfig = struct {
    autonomy: struct {
        level: ?[]const u8 = null,
        allowed_commands: ?[]const []const u8 = null,
    } = .{},
};

fn parseAutonomyConfig(allocator: std.mem.Allocator, config_path: []const u8) !std.json.Parsed(ParsedAutonomyConfig) {
    const bytes = try std.fs.readFileAbsolute(allocator, config_path, 64 * 1024);
    defer allocator.free(bytes);
    return try std.json.parseFromSlice(ParsedAutonomyConfig, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
}

test "catalogForComponent returns nullclaw recommendations" {
    const catalog = catalogForComponent("nullclaw");
    try std.testing.expect(catalog.len > 0);
    try std.testing.expectEqualStrings("nullhub-admin", catalog[0].entry.name);
    try std.testing.expect(catalog[0].entry.recommended);
}

test "installBundledSkill writes embedded skill to workspace" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const disposition = try installBundledSkill(allocator, cwd_path, "nullhub-admin");
    try std.testing.expectEqual(.installed, disposition);

    const skill_path = try std.fs.path.join(allocator, &.{ cwd_path, "skills", "nullhub-admin", "SKILL.md" });
    defer allocator.free(skill_path);

    const content = try std.fs.readFileAbsolute(allocator, skill_path, 64 * 1024);
    defer allocator.free(content);
    try std.testing.expect(std.mem.indexOf(u8, content, "nullhub routes --json") != null);
}

test "syncBundledSkillRuntime preserves supervised level and adds nullhub command" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const config_path = try std.fs.path.join(allocator, &.{ cwd_path, "config.json" });
    defer allocator.free(config_path);

    const file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"autonomy\":{\"level\":\"supervised\",\"allowed_commands\":[\"git\"]}}\n");

    try std.testing.expect(try syncBundledSkillRuntime(allocator, config_path, "nullhub-admin"));

    var parsed = try parseAutonomyConfig(allocator, config_path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("supervised", parsed.value.autonomy.level.?);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.autonomy.allowed_commands.?.len);
    try std.testing.expectEqualStrings("git", parsed.value.autonomy.allowed_commands.?[0]);
    try std.testing.expectEqualStrings("nullhub *", parsed.value.autonomy.allowed_commands.?[1]);
}

test "syncBundledSkillRuntime preserves full level without narrowing access" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const config_path = try std.fs.path.join(allocator, &.{ cwd_path, "config.json" });
    defer allocator.free(config_path);

    const file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"autonomy\":{\"level\":\"full\",\"allowed_commands\":[]}}\n");

    try std.testing.expect(!(try syncBundledSkillRuntime(allocator, config_path, "nullhub-admin")));

    var parsed = try parseAutonomyConfig(allocator, config_path);
    defer parsed.deinit();

    try std.testing.expectEqualStrings("full", parsed.value.autonomy.level.?);
    try std.testing.expectEqual(@as(usize, 0), parsed.value.autonomy.allowed_commands.?.len);
}

test "installAlwaysBundledSkills installs skill and syncs runtime access" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const cwd_path = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(cwd_path);

    const workspace_dir = try std.fs.path.join(allocator, &.{ cwd_path, "workspace" });
    defer allocator.free(workspace_dir);
    try ensurePathAbsolute(workspace_dir);

    const config_path = try std.fs.path.join(allocator, &.{ cwd_path, "config.json" });
    defer allocator.free(config_path);
    const file = try std.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\"autonomy\":{\"level\":\"supervised\"}}\n");

    try std.testing.expect(try installAlwaysBundledSkills(allocator, "nullclaw", workspace_dir, config_path));

    const skill_path = try std.fs.path.join(allocator, &.{ workspace_dir, "skills", "nullhub-admin", "SKILL.md" });
    defer allocator.free(skill_path);
    const skill_content = try std.fs.readFileAbsolute(allocator, skill_path, 64 * 1024);
    defer allocator.free(skill_content);
    try std.testing.expect(std.mem.indexOf(u8, skill_content, "nullhub api <METHOD> <PATH>") != null);

    const rendered = try std.fs.readFileAbsolute(allocator, config_path, 64 * 1024);
    defer allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"nullhub *\"") != null);
}
