const std = @import("std");
const builtin = @import("builtin");
const GeneratedUiAssetsPath = ".generated_ui_assets.zig";

const EmptyUiAssetsSource =
    \\const std = @import("std");
    \\
    \\pub const Asset = struct {
    \\    path: []const u8,
    \\    bytes: []const u8,
    \\};
    \\
    \\pub const assets = [_]Asset{};
    \\
    \\pub fn get(path: []const u8) ?Asset {
    \\    _ = path;
    \\    return null;
    \\}
    \\
    \\pub fn hasAssets() bool {
    \\    return false;
    \\}
;

const UiFile = struct {
    fs_path: []const u8,
    web_path: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const app_version = b.option([]const u8, "version", "Version string embedded in the binary") orelse "dev";
    const embed_ui = b.option(bool, "embed-ui", "Embed the Svelte UI into the binary") orelse true;
    const build_ui = b.option(bool, "build-ui", "Build the UI before embedding it") orelse embed_ui;

    if (embed_ui) {
        if (build_ui) ensureUiBuildReady(b);
        ensureUiBuildExists();
    }

    var build_options = b.addOptions();
    build_options.addOption([]const u8, "version", app_version);
    const build_options_module = build_options.createModule();
    const ui_assets_module = createUiAssetsModule(b, embed_ui);

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_module.addImport("build_options", build_options_module);
    exe_module.addImport("ui_assets", ui_assets_module);

    const exe = b.addExecutable(.{
        .name = "nullhub",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run nullhub");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addImport("build_options", build_options_module);
    test_module.addImport("ui_assets", ui_assets_module);

    const exe_unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn createUiAssetsModule(b: *std.Build, embed_ui: bool) *std.Build.Module {
    const source = if (embed_ui)
        generateUiAssetsSource(b.allocator) catch |err| std.debug.panic("failed to generate embedded UI assets: {s}", .{@errorName(err)})
    else
        b.allocator.dupe(u8, EmptyUiAssetsSource) catch @panic("OOM");

    writeGeneratedUiAssetsSource(source) catch |err| std.debug.panic("failed to write generated UI assets module: {s}", .{@errorName(err)});
    return b.createModule(.{ .root_source_file = b.path(GeneratedUiAssetsPath) });
}

fn ensureUiBuildReady(b: *std.Build) void {
    if (!pathExists("ui/node_modules")) {
        runCommandOrPanic(b.allocator, &.{ npmCommand(), "--prefix", "ui", "ci", "--no-audit", "--no-fund" });
    }
    runCommandOrPanic(b.allocator, &.{ npmCommand(), "--prefix", "ui", "run", "build" });
}

fn ensureUiBuildExists() void {
    if (!pathExists("ui/build")) {
        std.debug.panic("embedded UI assets are missing; run `npm --prefix ui run build` or build with -Dbuild-ui=true", .{});
    }
}

fn runCommandOrPanic(allocator: std.mem.Allocator, argv: []const []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
    }) catch |err| std.debug.panic("failed to run {s}: {s}", .{ argv[0], @errorName(err) });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code == 0) return;
            if (result.stdout.len > 0) std.debug.print("{s}", .{result.stdout});
            if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
            std.debug.panic("command failed with exit code {d}: {s}", .{ code, argv[0] });
        },
        else => std.debug.panic("command did not exit cleanly: {s}", .{argv[0]}),
    }
}

fn npmCommand() []const u8 {
    return if (builtin.os.tag == .windows) "npm.cmd" else "npm";
}

fn pathExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn generateUiAssetsSource(allocator: std.mem.Allocator) ![]u8 {
    var dir = try std.fs.cwd().openDir("ui/build", .{ .iterate = true });
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    var files: std.ArrayListUnmanaged(UiFile) = .empty;
    defer {
        for (files.items) |file| {
            allocator.free(file.fs_path);
            allocator.free(file.web_path);
        }
        files.deinit(allocator);
    }

    while (try walker.next()) |entry| {
        if (entry.kind != .file) continue;

        const fs_path = try allocator.dupe(u8, entry.path);
        errdefer allocator.free(fs_path);
        const web_path = try normalizeWebPath(allocator, entry.path);
        errdefer allocator.free(web_path);
        try files.append(allocator, .{
            .fs_path = fs_path,
            .web_path = web_path,
        });
    }

    std.mem.sort(UiFile, files.items, {}, struct {
        fn lessThan(_: void, lhs: UiFile, rhs: UiFile) bool {
            return std.mem.lessThan(u8, lhs.web_path, rhs.web_path);
        }
    }.lessThan);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice(
        \\const std = @import("std");
        \\
        \\pub const Asset = struct {
        \\    path: []const u8,
        \\    bytes: []const u8,
        \\};
        \\
        \\pub const assets = [_]Asset{
        \\
    );

    for (files.items) |file| {
        try buf.appendSlice("    .{ .path = ");
        try appendZigStringLiteral(&buf, file.web_path);
        try buf.appendSlice(", .bytes = @embedFile(");
        const embed_path = try std.fmt.allocPrint(allocator, "ui/build/{s}", .{file.fs_path});
        defer allocator.free(embed_path);
        try appendZigStringLiteral(&buf, embed_path);
        try buf.appendSlice(") },\n");
    }

    try buf.appendSlice(
        \\};
        \\
        \\pub fn get(path: []const u8) ?Asset {
        \\    inline for (assets) |asset| {
        \\        if (std.mem.eql(u8, path, asset.path)) return asset;
        \\    }
        \\    return null;
        \\}
        \\
        \\pub fn hasAssets() bool {
        \\    return assets.len > 0;
        \\}
        \\
    );

    return buf.toOwnedSlice();
}

fn writeGeneratedUiAssetsSource(source: []const u8) !void {
    const file = try std.fs.cwd().createFile(GeneratedUiAssetsPath, .{ .truncate = true });
    defer file.close();
    try file.writeAll(source);
}

fn normalizeWebPath(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const duped = try allocator.dupe(u8, input);
    for (duped) |*char| {
        if (char.* == '\\') char.* = '/';
    }
    return duped;
}

fn appendZigStringLiteral(buf: *std.array_list.Managed(u8), value: []const u8) !void {
    try buf.append('"');
    for (value) |char| switch (char) {
        '\\' => try buf.appendSlice("\\\\"),
        '"' => try buf.appendSlice("\\\""),
        '\n' => try buf.appendSlice("\\n"),
        '\r' => try buf.appendSlice("\\r"),
        '\t' => try buf.appendSlice("\\t"),
        else => try buf.append(char),
    };
    try buf.append('"');
}
