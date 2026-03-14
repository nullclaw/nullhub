const std = @import("std");
const cli = @import("cli.zig");

pub const ExecuteError = error{
    InvalidMethod,
    InvalidTarget,
};

pub const Result = struct {
    status: std.http.Status,
    body: []u8,

    pub fn deinit(self: *Result, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
        self.* = undefined;
    }
};

pub fn run(allocator: std.mem.Allocator, opts: cli.ApiOptions) !void {
    var result = try execute(allocator, opts);
    defer result.deinit(allocator);

    const formatted = if (opts.pretty)
        try prettyBody(allocator, result.body)
    else
        try allocator.dupe(u8, result.body);
    defer allocator.free(formatted);

    if (formatted.len > 0) {
        try writeAll(std.fs.File.stdout(), formatted);
        if (formatted[formatted.len - 1] != '\n') {
            try writeAll(std.fs.File.stdout(), "\n");
        }
    }

    const code = @intFromEnum(result.status);
    if (code < 200 or code >= 300) {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "HTTP {d}\n", .{code});
        try writeAll(std.fs.File.stderr(), line);
        return error.RequestFailed;
    }
}

pub fn execute(allocator: std.mem.Allocator, opts: cli.ApiOptions) !Result {
    const method = parseMethod(opts.method) orelse return ExecuteError.InvalidMethod;
    const target = try normalizeTargetAlloc(allocator, opts.target);
    defer allocator.free(target);

    const url = try std.fmt.allocPrint(allocator, "http://{s}:{d}{s}", .{ opts.host, opts.port, target });
    defer allocator.free(url);

    const request_body = try loadBodyAlloc(allocator, opts);
    defer if (request_body.owned) allocator.free(request_body.bytes);

    var auth_header: ?[]u8 = null;
    defer if (auth_header) |value| allocator.free(value);

    var header_storage: [2]std.http.Header = undefined;
    var header_count: usize = 0;
    if (request_body.bytes.len > 0) {
        header_storage[header_count] = .{ .name = "Content-Type", .value = opts.content_type };
        header_count += 1;
    }
    if (opts.token) |token| {
        auth_header = try std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
        header_storage[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var response_body: std.io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = url },
        .method = method,
        .payload = payloadForFetch(method, request_body.bytes),
        .response_writer = &response_body.writer,
        .extra_headers = header_storage[0..header_count],
    });

    return .{
        .status = result.status,
        .body = try response_body.toOwnedSlice(),
    };
}

fn writeAll(file: std.fs.File, bytes: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = file.writer(&buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

fn parseMethod(raw: []const u8) ?std.http.Method {
    if (std.ascii.eqlIgnoreCase(raw, "GET")) return .GET;
    if (std.ascii.eqlIgnoreCase(raw, "POST")) return .POST;
    if (std.ascii.eqlIgnoreCase(raw, "PUT")) return .PUT;
    if (std.ascii.eqlIgnoreCase(raw, "DELETE")) return .DELETE;
    if (std.ascii.eqlIgnoreCase(raw, "PATCH")) return .PATCH;
    if (std.ascii.eqlIgnoreCase(raw, "HEAD")) return .HEAD;
    if (std.ascii.eqlIgnoreCase(raw, "OPTIONS")) return .OPTIONS;
    return null;
}

fn normalizeTargetAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0) return ExecuteError.InvalidTarget;
    if (std.mem.startsWith(u8, raw, "http://") or std.mem.startsWith(u8, raw, "https://")) {
        return ExecuteError.InvalidTarget;
    }
    if (raw[0] == '/') return allocator.dupe(u8, raw);
    if (std.mem.startsWith(u8, raw, "api/")) return std.fmt.allocPrint(allocator, "/{s}", .{raw});
    if (std.mem.eql(u8, raw, "health")) return allocator.dupe(u8, "/health");
    return std.fmt.allocPrint(allocator, "/api/{s}", .{raw});
}

const LoadedBody = struct {
    bytes: []const u8,
    owned: bool = false,
};

fn loadBodyAlloc(allocator: std.mem.Allocator, opts: cli.ApiOptions) !LoadedBody {
    if (opts.body_file) |path| {
        if (std.mem.eql(u8, path, "-")) {
            const bytes = try std.fs.File.stdin().readToEndAlloc(allocator, 8 * 1024 * 1024);
            return .{ .bytes = bytes, .owned = true };
        }
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();
        const bytes = try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
        return .{ .bytes = bytes, .owned = true };
    }
    if (opts.body) |body| return .{ .bytes = body, .owned = false };
    return .{ .bytes = "", .owned = false };
}

fn payloadForFetch(method: std.http.Method, body: []const u8) ?[]const u8 {
    if (body.len > 0) return body;
    if (method.requestHasBody()) return body;
    return null;
}

fn prettyBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    if (body.len == 0) return allocator.dupe(u8, body);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return allocator.dupe(u8, body);
    defer parsed.deinit();

    return std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
    });
}

test "normalizeTargetAlloc keeps explicit API path" {
    const value = try normalizeTargetAlloc(std.testing.allocator, "/api/status");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("/api/status", value);
}

test "normalizeTargetAlloc prefixes api namespace" {
    const value = try normalizeTargetAlloc(std.testing.allocator, "instances/nullclaw/demo");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("/api/instances/nullclaw/demo", value);
}

test "normalizeTargetAlloc supports health shorthand" {
    const value = try normalizeTargetAlloc(std.testing.allocator, "health");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("/health", value);
}

test "parseMethod accepts common verbs case-insensitively" {
    try std.testing.expectEqual(std.http.Method.DELETE, parseMethod("delete").?);
    try std.testing.expectEqual(std.http.Method.PATCH, parseMethod("PATCH").?);
    try std.testing.expect(parseMethod("TRACE") == null);
}

test "prettyBody indents JSON output" {
    const value = try prettyBody(std.testing.allocator, "{\"ok\":true}");
    defer std.testing.allocator.free(value);
    try std.testing.expect(std.mem.indexOf(u8, value, "\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, value, "  \"ok\"") != null);
}

test "payloadForFetch keeps empty body for POST" {
    try std.testing.expect(payloadForFetch(.POST, "") != null);
    try std.testing.expect(payloadForFetch(.GET, "") == null);
}
