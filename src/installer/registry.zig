const std = @import("std");
const prereqs = @import("prereqs.zig");
const manifest = @import("../core/manifest.zig");

// ─── Known components ────────────────────────────────────────────────────────

pub const UiModuleRef = struct {
    name: []const u8,
    repo: []const u8,
};

pub const KnownComponent = struct {
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    repo: []const u8,
    is_alpha: bool = false,
    default_launch_command: []const u8 = "gateway",
    default_health_endpoint: []const u8 = "/health",
    default_port: u16 = 3000,
    min_version: []const u8 = "",
    ui_modules: []const UiModuleRef = &.{},
};

pub const known_components = [_]KnownComponent{
    .{
        .name = "nullclaw",
        .display_name = "NullClaw",
        .description = "Autonomous AI agent runtime. Connects to 30+ LLM providers, runs tools, manages memory, and exposes a gateway API. The core brain of the null stack.",
        .repo = "nullclaw/nullclaw",
        .min_version = "v2026.3.2",
        .ui_modules = &.{
            .{ .name = "nullclaw-chat-ui", .repo = "nullclaw/nullclaw-chat-ui" },
        },
    },
    .{
        .name = "nullboiler",
        .display_name = "NullBoiler",
        .description = "DAG-based workflow orchestrator. Chains agents into multi-step pipelines with branching, loops, and parallel execution. Turns NullClaw agents into teams.",
        .repo = "nullclaw/NullBoiler",
        .is_alpha = true,
    },
    .{
        .name = "nulltickets",
        .display_name = "NullTickets",
        .description = "Task and issue tracker for AI agents. Project management that agents can read, create, and update autonomously via API.",
        .repo = "nullclaw/nulltickets",
        .is_alpha = true,
    },
};

/// Look up a component by name in the known_components list.
pub fn findKnownComponent(name: []const u8) ?KnownComponent {
    for (&known_components) |*comp| {
        if (std.mem.eql(u8, comp.name, name)) {
            return comp.*;
        }
    }
    return null;
}

// ─── URL builders ────────────────────────────────────────────────────────────

/// Build the GitHub API URL for the latest release of a repository.
/// Caller owns the returned memory.
pub fn buildReleasesUrl(allocator: std.mem.Allocator, repo: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/latest", .{repo});
}

/// Build the GitHub API URL for a specific tagged release of a repository.
/// Caller owns the returned memory.
pub fn buildReleaseByTagUrl(allocator: std.mem.Allocator, repo: []const u8, tag: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "https://api.github.com/repos/{s}/releases/tags/{s}", .{ repo, tag });
}

// ─── Release types ───────────────────────────────────────────────────────────

pub const AssetInfo = struct {
    name: []const u8,
    browser_download_url: []const u8,
    size: u64 = 0,
};

pub const ReleaseInfo = struct {
    tag_name: []const u8,
    assets: []const AssetInfo,
};

// ─── JSON parsing ────────────────────────────────────────────────────────────

/// Parse a GitHub Releases API JSON response into a ReleaseInfo.
/// Returns a Parsed wrapper so the caller can deinit the arena when done.
pub fn parseReleaseResponse(allocator: std.mem.Allocator, json_bytes: []const u8) !std.json.Parsed(ReleaseInfo) {
    return std.json.parseFromSlice(
        ReleaseInfo,
        allocator,
        json_bytes,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
}

// ─── Asset matching ──────────────────────────────────────────────────────────

/// Given a release and a manifest's platform mapping, find the asset that
/// matches the specified platform key.
///
/// Looks up the platform key in the manifest's platforms map to get the
/// expected asset name, then searches the release's assets for a match.
pub fn findAssetForPlatform(
    release: ReleaseInfo,
    platform_key: []const u8,
    m: manifest.Manifest,
) ?AssetInfo {
    const platform_entry = m.platforms.map.get(platform_key) orelse return null;
    for (release.assets) |asset| {
        if (std.mem.eql(u8, asset.name, platform_entry.asset)) {
            return asset;
        }
    }
    return null;
}

/// Find an asset by exact name in a release's asset list.
pub fn findAssetByName(release: ReleaseInfo, name: []const u8) ?AssetInfo {
    for (release.assets) |asset| {
        if (std.mem.eql(u8, asset.name, name)) {
            return asset;
        }
    }
    return null;
}

fn matchesAssetNameOrExt(asset_name: []const u8, base_name: []const u8) bool {
    if (std.mem.eql(u8, asset_name, base_name)) return true;
    if (asset_name.len == base_name.len + 4 and std.mem.startsWith(u8, asset_name, base_name)) {
        const ext = asset_name[base_name.len..];
        if (std.mem.eql(u8, ext, ".bin") or std.mem.eql(u8, ext, ".exe")) return true;
    }
    return false;
}

/// Find an asset for component+platform across known naming conventions:
/// - `{component}-{arch}-{os}` (platform key order)
/// - `{component}-{os}-{arch}` (release convention in nullclaw repos)
/// Optional `.bin` / `.exe` suffix is accepted.
pub fn findAssetForComponentPlatform(
    allocator: std.mem.Allocator,
    release: ReleaseInfo,
    component: []const u8,
    platform_key: []const u8,
) ?AssetInfo {
    const candidate_primary = std.fmt.allocPrint(allocator, "{s}-{s}", .{ component, platform_key }) catch return null;
    defer allocator.free(candidate_primary);
    for (release.assets) |asset| {
        if (matchesAssetNameOrExt(asset.name, candidate_primary)) return asset;
    }

    const dash = std.mem.indexOfScalar(u8, platform_key, '-') orelse return null;
    const arch = platform_key[0..dash];
    const os = platform_key[dash + 1 ..];
    const candidate_swapped = std.fmt.allocPrint(allocator, "{s}-{s}-{s}", .{ component, os, arch }) catch return null;
    defer allocator.free(candidate_swapped);
    for (release.assets) |asset| {
        if (matchesAssetNameOrExt(asset.name, candidate_swapped)) return asset;
    }

    return null;
}

// ─── HTTP fetch (via curl) ───────────────────────────────────────────────────

/// Fetch the latest release information for a GitHub repository.
///
/// Uses curl as a pragmatic approach for HTTPS requests. The caller owns
/// the returned Parsed wrapper and must call .deinit() when done.
pub fn fetchLatestRelease(allocator: std.mem.Allocator, repo: []const u8) !std.json.Parsed(ReleaseInfo) {
    prereqs.ensureTool(allocator, "curl") catch return error.FetchFailed;

    const url = try buildReleasesUrl(allocator, repo);
    defer allocator.free(url);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sfL", "-H", "Accept: application/vnd.github+json", url },
    }) catch return error.FetchFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.FetchFailed;
        },
        else => return error.FetchFailed,
    }

    return parseReleaseResponse(allocator, result.stdout);
}

/// Fetch release information for a specific tagged version.
///
/// Uses curl as a pragmatic approach for HTTPS requests. The caller owns
/// the returned Parsed wrapper and must call .deinit() when done.
pub fn fetchReleaseByTag(allocator: std.mem.Allocator, repo: []const u8, tag: []const u8) !std.json.Parsed(ReleaseInfo) {
    prereqs.ensureTool(allocator, "curl") catch return error.FetchFailed;

    const url = try buildReleaseByTagUrl(allocator, repo, tag);
    defer allocator.free(url);

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sfL", "-H", "Accept: application/vnd.github+json", url },
    }) catch return error.FetchFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| {
            if (code != 0) return error.FetchFailed;
        },
        else => return error.FetchFailed,
    }

    return parseReleaseResponse(allocator, result.stdout);
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "findKnownComponent returns nullclaw" {
    const comp = findKnownComponent("nullclaw");
    try std.testing.expect(comp != null);
    try std.testing.expectEqualStrings("nullclaw/nullclaw", comp.?.repo);
}

test "findKnownComponent returns nullboiler" {
    const comp = findKnownComponent("nullboiler");
    try std.testing.expect(comp != null);
    try std.testing.expectEqualStrings("nullclaw/NullBoiler", comp.?.repo);
}

test "findKnownComponent returns null for unknown" {
    try std.testing.expect(findKnownComponent("nonexistent") == null);
}

test "buildReleasesUrl" {
    const allocator = std.testing.allocator;
    const url = try buildReleasesUrl(allocator, "nullclaw/nullclaw");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/nullclaw/nullclaw/releases/latest", url);
}

test "buildReleaseByTagUrl" {
    const allocator = std.testing.allocator;
    const url = try buildReleaseByTagUrl(allocator, "nullclaw/nullclaw", "v2026.3.1");
    defer allocator.free(url);
    try std.testing.expectEqualStrings("https://api.github.com/repos/nullclaw/nullclaw/releases/tags/v2026.3.1", url);
}

test "parseReleaseResponse" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tag_name":"v2026.3.1","assets":[{"name":"nullclaw-linux-x86_64","browser_download_url":"https://example.com/dl","size":700000}]}
    ;
    var parsed = try parseReleaseResponse(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("v2026.3.1", parsed.value.tag_name);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.assets.len);
    try std.testing.expectEqualStrings("nullclaw-linux-x86_64", parsed.value.assets[0].name);
    try std.testing.expectEqualStrings("https://example.com/dl", parsed.value.assets[0].browser_download_url);
    try std.testing.expectEqual(@as(u64, 700000), parsed.value.assets[0].size);
}

test "parseReleaseResponse with multiple assets" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tag_name":"v1.0.0","assets":[
        \\  {"name":"app-linux-x86_64","browser_download_url":"https://example.com/linux","size":500000},
        \\  {"name":"app-macos-aarch64","browser_download_url":"https://example.com/macos","size":600000}
        \\]}
    ;
    var parsed = try parseReleaseResponse(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("v1.0.0", parsed.value.tag_name);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.assets.len);
    try std.testing.expectEqualStrings("app-linux-x86_64", parsed.value.assets[0].name);
    try std.testing.expectEqualStrings("app-macos-aarch64", parsed.value.assets[1].name);
}

test "parseReleaseResponse ignores unknown fields" {
    const allocator = std.testing.allocator;
    const json =
        \\{"tag_name":"v1.0.0","id":12345,"draft":false,"prerelease":false,"assets":[{"name":"a","browser_download_url":"https://x.com/a","size":1,"id":99,"content_type":"application/octet-stream"}]}
    ;
    var parsed = try parseReleaseResponse(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("v1.0.0", parsed.value.tag_name);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.assets.len);
}

test "findAssetForPlatform matches correct asset" {
    const allocator = std.testing.allocator;

    // Parse a minimal manifest with platform mappings
    const manifest_json =
        \\{
        \\  "schema_version": 1,
        \\  "name": "nullclaw",
        \\  "display_name": "NullClaw",
        \\  "description": "AI agent",
        \\  "icon": "agent",
        \\  "repo": "nullclaw/nullclaw",
        \\  "platforms": {
        \\    "aarch64-macos": { "asset": "nullclaw-macos-aarch64", "binary": "nullclaw" },
        \\    "x86_64-linux": { "asset": "nullclaw-linux-x86_64", "binary": "nullclaw" }
        \\  },
        \\  "config": { "path": "config.json" },
        \\  "launch": { "command": "gateway" },
        \\  "health": { "endpoint": "/health", "port_from_config": "gateway.port" },
        \\  "ports": [],
        \\  "wizard": { "steps": [] },
        \\  "ui_modules": [],
        \\  "depends_on": [],
        \\  "connects_to": []
        \\}
    ;
    const parsed_manifest = try manifest.parseManifest(allocator, manifest_json);
    defer parsed_manifest.deinit();

    const release = ReleaseInfo{
        .tag_name = "v2026.3.1",
        .assets = &.{
            .{ .name = "nullclaw-linux-x86_64", .browser_download_url = "https://example.com/linux", .size = 700000 },
            .{ .name = "nullclaw-macos-aarch64", .browser_download_url = "https://example.com/macos", .size = 800000 },
        },
    };

    // Match x86_64-linux platform
    const linux_asset = findAssetForPlatform(release, "x86_64-linux", parsed_manifest.value);
    try std.testing.expect(linux_asset != null);
    try std.testing.expectEqualStrings("nullclaw-linux-x86_64", linux_asset.?.name);
    try std.testing.expectEqualStrings("https://example.com/linux", linux_asset.?.browser_download_url);
    try std.testing.expectEqual(@as(u64, 700000), linux_asset.?.size);

    // Match aarch64-macos platform
    const macos_asset = findAssetForPlatform(release, "aarch64-macos", parsed_manifest.value);
    try std.testing.expect(macos_asset != null);
    try std.testing.expectEqualStrings("nullclaw-macos-aarch64", macos_asset.?.name);

    // No match for unknown platform
    const unknown_asset = findAssetForPlatform(release, "riscv64-linux", parsed_manifest.value);
    try std.testing.expect(unknown_asset == null);
}

test "findAssetForComponentPlatform matches swapped platform order" {
    const allocator = std.testing.allocator;
    const release = ReleaseInfo{
        .tag_name = "v1.0.0",
        .assets = &.{
            .{ .name = "nullclaw-macos-aarch64.bin", .browser_download_url = "https://example.com/macos", .size = 1 },
        },
    };

    const asset = findAssetForComponentPlatform(allocator, release, "nullclaw", "aarch64-macos");
    try std.testing.expect(asset != null);
    try std.testing.expectEqualStrings("nullclaw-macos-aarch64.bin", asset.?.name);
}
