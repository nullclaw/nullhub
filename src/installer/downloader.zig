const std = @import("std");
const std_compat = @import("compat");
const prereqs = @import("prereqs.zig");

// ─── Errors ──────────────────────────────────────────────────────────────────

pub const DownloadError = error{
    DownloadFailed,
    ChecksumMismatch,
};

// ─── SHA256 hashing ──────────────────────────────────────────────────────────

/// Compute the SHA256 hash of a file and return it as a 64-character hex string.
pub fn computeSha256(allocator: std.mem.Allocator, file_path: []const u8) ![64]u8 {
    _ = allocator;

    var file = try std_compat.fs.openFileAbsolute(file_path, .{});
    defer file.close();

    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [8192]u8 = undefined;

    while (true) {
        const n = try file.read(&buf);
        if (n == 0) break;
        hasher.update(buf[0..n]);
    }

    return std.fmt.bytesToHex(hasher.finalResult(), .lower);
}

// ─── Download ────────────────────────────────────────────────────────────────

pub fn fileExists(file_path: []const u8) bool {
    const file = std_compat.fs.openFileAbsolute(file_path, .{}) catch return false;
    file.close();
    return true;
}

/// Download a file from `url` to `dest_path` using curl.
///
/// Uses an atomic write pattern: downloads to `dest_path.tmp`, then renames
/// to `dest_path`. On POSIX systems, the resulting file is made executable.
pub fn download(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    prereqs.ensureTool(allocator, "curl") catch return error.DownloadFailed;

    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{dest_path});
    defer allocator.free(tmp_path);

    // Ensure parent directory exists.
    if (std.fs.path.dirnamePosix(dest_path)) |parent| {
        std_compat.fs.makeDirAbsolute(parent) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const result = std_compat.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "curl", "-sfL", "-o", tmp_path, url },
    }) catch return error.DownloadFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code != 0) return error.DownloadFailed;
        },
        else => return error.DownloadFailed,
    }

    // Atomic rename from .tmp to final destination.
    try std_compat.fs.renameAbsolute(tmp_path, dest_path);

    if (comptime std_compat.fs.has_executable_bit) {
        // Set executable permission (rwxr-xr-x) on platforms that support it.
        if (std_compat.fs.openFileAbsolute(dest_path, .{ .mode = .read_only })) |f| {
            defer f.close();
            f.chmod(0o755) catch {};
        } else |_| {}
    }
}

/// Download a file only when `dest_path` is not already present.
pub fn downloadIfMissing(allocator: std.mem.Allocator, url: []const u8, dest_path: []const u8) !void {
    if (fileExists(dest_path)) return;
    try download(allocator, url, dest_path);
}

/// Download a file and verify its SHA256 checksum.
///
/// If the checksum does not match `expected_sha256`, the downloaded file is
/// removed and `error.ChecksumMismatch` is returned.
pub fn downloadWithSha256(
    allocator: std.mem.Allocator,
    url: []const u8,
    dest_path: []const u8,
    expected_sha256: []const u8,
) !void {
    try download(allocator, url, dest_path);

    const actual_hex = try computeSha256(allocator, dest_path);
    if (!std.mem.eql(u8, &actual_hex, expected_sha256)) {
        // Clean up the mismatched file.
        std_compat.fs.deleteFileAbsolute(dest_path) catch {};
        return error.ChecksumMismatch;
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "computeSha256 returns correct hash for known content" {
    const allocator = std.testing.allocator;

    // Write a temp file with known content.
    const tmp_dir = "/tmp/test-nullhub-downloader-sha256";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const file_path_buf = try std.fmt.allocPrint(allocator, "{s}/testfile", .{tmp_dir});
    defer allocator.free(file_path_buf);

    {
        var file = try std_compat.fs.createFileAbsolute(file_path_buf, .{});
        defer file.close();
        try file.writeAll("hello world");
    }

    const hex = try computeSha256(allocator, file_path_buf);
    try std.testing.expectEqualStrings(
        "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9",
        &hex,
    );
}

test "download performs atomic rename and sets executable bit" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/test-nullhub-downloader-rename";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const src_path = try std.fmt.allocPrint(allocator, "{s}/source.txt", .{tmp_dir});
    defer allocator.free(src_path);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/binary", .{tmp_dir});
    defer allocator.free(dest_path);

    // Write a source file to serve via file:// URI.
    {
        var file = try std_compat.fs.createFileAbsolute(src_path, .{});
        defer file.close();
        try file.writeAll("binary content");
    }

    const file_url = try std.fmt.allocPrint(allocator, "file://{s}", .{src_path});
    defer allocator.free(file_url);

    try download(allocator, file_url, dest_path);

    // Verify the file exists at dest_path with correct content.
    {
        var file = try std_compat.fs.openFileAbsolute(dest_path, .{});
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = try file.readAll(&buf);
        try std.testing.expectEqualStrings("binary content", buf[0..n]);
    }

    // Verify the .tmp file is gone.
    {
        const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{dest_path});
        defer allocator.free(tmp_path);
        const result = std_compat.fs.openFileAbsolute(tmp_path, .{});
        try std.testing.expectError(error.FileNotFound, result);
    }

    // Verify executable permission is set.
    {
        const stat = try std_compat.fs.openFileAbsolute(dest_path, .{});
        defer stat.close();
        const md = try stat.metadata();
        const perms = md.permissions().inner;
        // Check owner execute bit.
        try std.testing.expect(perms.unixHas(.user, .execute));
    }
}

test "downloadIfMissing keeps an existing destination" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/test-nullhub-downloader-skip-existing";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const src_path = try std.fmt.allocPrint(allocator, "{s}/source.txt", .{tmp_dir});
    defer allocator.free(src_path);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/binary", .{tmp_dir});
    defer allocator.free(dest_path);

    {
        var file = try std_compat.fs.createFileAbsolute(src_path, .{});
        defer file.close();
        try file.writeAll("fresh content");
    }
    {
        var file = try std_compat.fs.createFileAbsolute(dest_path, .{});
        defer file.close();
        try file.writeAll("cached content");
    }

    const file_url = try std.fmt.allocPrint(allocator, "file://{s}", .{src_path});
    defer allocator.free(file_url);

    try downloadIfMissing(allocator, file_url, dest_path);

    var file = try std_compat.fs.openFileAbsolute(dest_path, .{});
    defer file.close();
    var buf: [256]u8 = undefined;
    const n = try file.readAll(&buf);
    try std.testing.expectEqualStrings("cached content", buf[0..n]);
}

test "downloadWithSha256 detects checksum mismatch" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/test-nullhub-downloader-mismatch";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const src_path = try std.fmt.allocPrint(allocator, "{s}/source.txt", .{tmp_dir});
    defer allocator.free(src_path);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/binary", .{tmp_dir});
    defer allocator.free(dest_path);

    {
        var file = try std_compat.fs.createFileAbsolute(src_path, .{});
        defer file.close();
        try file.writeAll("some content");
    }

    const file_url = try std.fmt.allocPrint(allocator, "file://{s}", .{src_path});
    defer allocator.free(file_url);

    // Use an obviously wrong hash.
    const wrong_hash = "0000000000000000000000000000000000000000000000000000000000000000";
    const result = downloadWithSha256(allocator, file_url, dest_path, wrong_hash);
    try std.testing.expectError(error.ChecksumMismatch, result);

    // Verify the file was cleaned up.
    const open_result = std_compat.fs.openFileAbsolute(dest_path, .{});
    try std.testing.expectError(error.FileNotFound, open_result);
}

test "downloadWithSha256 succeeds with correct hash" {
    const allocator = std.testing.allocator;

    const tmp_dir = "/tmp/test-nullhub-downloader-sha-ok";
    std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
    try std_compat.fs.makeDirAbsolute(tmp_dir);
    defer std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};

    const src_path = try std.fmt.allocPrint(allocator, "{s}/source.txt", .{tmp_dir});
    defer allocator.free(src_path);
    const dest_path = try std.fmt.allocPrint(allocator, "{s}/binary", .{tmp_dir});
    defer allocator.free(dest_path);

    {
        var file = try std_compat.fs.createFileAbsolute(src_path, .{});
        defer file.close();
        try file.writeAll("hello world");
    }

    const file_url = try std.fmt.allocPrint(allocator, "file://{s}", .{src_path});
    defer allocator.free(file_url);

    const correct_hash = "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9";
    try downloadWithSha256(allocator, file_url, dest_path, correct_hash);

    // Verify file exists with correct content.
    {
        var file = try std_compat.fs.openFileAbsolute(dest_path, .{});
        defer file.close();
        var buf: [256]u8 = undefined;
        const n = try file.readAll(&buf);
        try std.testing.expectEqualStrings("hello world", buf[0..n]);
    }
}
