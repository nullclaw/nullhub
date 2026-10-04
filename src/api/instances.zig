const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const state_mod = @import("../core/state.zig");
const manager_mod = @import("../supervisor/manager.zig");
const paths_mod = @import("../core/paths.zig");
const registry = @import("../installer/registry.zig");
const orchestrator = @import("../installer/orchestrator.zig");
const downloader = @import("../installer/downloader.zig");
const platform = @import("../core/platform.zig");
const helpers = @import("helpers.zig");
const local_binary = @import("../core/local_binary.zig");
const component_cli = @import("../core/component_cli.zig");
const integration_mod = @import("../core/integration.zig");
const launch_args_mod = @import("../core/launch_args.zig");
const managed_skills = @import("../managed_skills.zig");
const manifest_mod = @import("../core/manifest.zig");
const managed_cli = @import("managed_cli.zig");
const nullclaw_web_channel = @import("../core/nullclaw_web_channel.zig");
const nullclaw_gateway_config = @import("../core/nullclaw_gateway_config.zig");
const query_api = @import("query.zig");
const test_helpers = @import("../test_helpers.zig");
const instance_runtime = @import("instance_runtime.zig");

const ApiResponse = helpers.ApiResponse;
const appendEscaped = helpers.appendEscaped;
const jsonOk = helpers.jsonOk;
const notFound = helpers.notFound;
const badRequest = helpers.badRequest;
const methodNotAllowed = helpers.methodNotAllowed;
const imported_standalone_storage_mode = "imported-standalone";

// ─── Helpers ─────────────────────────────────────────────────────────────────

fn defaultLaunchModeForComponent(component: []const u8) []const u8 {
    if (registry.findKnownComponent(component)) |known| return known.default_launch_command;
    return "gateway";
}

const StartBinary = struct {
    path: []const u8,
    version: []const u8,
    version_owned: bool = false,

    fn deinit(self: StartBinary, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.version_owned) allocator.free(self.version);
    }
};

fn persistStartVersion(
    s: *state_mod.State,
    component: []const u8,
    name: []const u8,
    entry: state_mod.InstanceEntry,
    version: []const u8,
) !void {
    const updated = try s.updateInstance(component, name, .{
        .version = version,
        .auto_start = entry.auto_start,
        .launch_mode = entry.launch_mode,
        .verbose = entry.verbose,
        .storage_mode = entry.storage_mode,
        .source_path = entry.source_path,
    });
    if (!updated) return error.StateError;
    s.save() catch return error.StateError;
}

fn resolveStandaloneStartBinary(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    entry: state_mod.InstanceEntry,
) !StartBinary {
    if (local_binary.stageDevLocal(allocator, paths, component)) |dest_bin| {
        persistStartVersion(s, component, name, entry, local_binary.dev_local_version) catch |err| {
            allocator.free(dest_bin);
            return err;
        };
        return .{ .path = dest_bin, .version = local_binary.dev_local_version };
    }

    const known = registry.findKnownComponent(component) orelse return error.NoPlatformAsset;
    var release = registry.fetchLatestRelease(allocator, known.repo) catch return error.FetchFailed;
    defer release.deinit();

    const platform_key = comptime platform.detect().toString();
    const asset = registry.findAssetForComponentPlatform(allocator, release.value, component, platform_key) orelse return error.NoPlatformAsset;

    const version = try allocator.dupe(u8, release.value.tag_name);
    errdefer allocator.free(version);
    const bin_path = try paths.binary(allocator, component, version);
    errdefer allocator.free(bin_path);

    downloader.downloadIfMissing(allocator, asset.browser_download_url, bin_path) catch return error.DownloadFailed;
    persistStartVersion(s, component, name, entry, version) catch |err| return err;

    return .{ .path = bin_path, .version = version, .version_owned = true };
}

fn resolveStartBinary(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    entry: state_mod.InstanceEntry,
) !StartBinary {
    if (std.mem.eql(u8, entry.version, "standalone")) {
        return resolveStandaloneStartBinary(allocator, s, paths, component, name, entry);
    }

    local_binary.refreshStagedDevLocal(allocator, paths, component, entry.version);
    return .{
        .path = try paths.binary(allocator, component, entry.version),
        .version = entry.version,
    };
}

fn startBinaryError(err: anyerror) ApiResponse {
    return switch (err) {
        error.FetchFailed => .{
            .status = "502 Bad Gateway",
            .content_type = "application/json",
            .body = "{\"error\":\"failed to fetch latest release\"}",
        },
        error.NoPlatformAsset => .{
            .status = "502 Bad Gateway",
            .content_type = "application/json",
            .body = "{\"error\":\"no platform asset for latest version\"}",
        },
        error.DownloadFailed => .{
            .status = "502 Bad Gateway",
            .content_type = "application/json",
            .body = "{\"error\":\"failed to download latest binary\"}",
        },
        else => helpers.serverError(),
    };
}

fn isExternalStandaloneRunning(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    manager: *manager_mod.Manager,
    component: []const u8,
    name: []const u8,
    entry: state_mod.InstanceEntry,
) bool {
    if (manager.getStatus(component, name) != null) return false;
    const snapshot = instance_runtime.resolve(allocator, paths, manager, component, name, entry);
    return snapshot.status == .running;
}

fn externalStandaloneConflict() ApiResponse {
    return .{
        .status = "409 Conflict",
        .content_type = "application/json",
        .body = "{\"error\":\"instance is running outside nullhub supervision\"}",
    };
}

const FetchedJsonValue = struct {
    bytes: []u8,
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *FetchedJsonValue, allocator: std.mem.Allocator) void {
        self.parsed.deinit();
        allocator.free(self.bytes);
    }
};

fn fetchJsonValue(allocator: std.mem.Allocator, url: []const u8, bearer_token: ?[]const u8) ?FetchedJsonValue {
    var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var header_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (bearer_token) |token| blk: {
        auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch return null;
        header_buf[0] = .{ .name = "Authorization", .value = auth_header.? };
        break :blk header_buf[0..1];
    } else &.{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
    }) catch return null;
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) return null;

    const bytes = response_body.toOwnedSlice() catch return null;
    errdefer allocator.free(bytes);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    return .{
        .bytes = bytes,
        .parsed = parsed,
    };
}

fn buildInstanceUrl(allocator: std.mem.Allocator, port: u16, path: []const u8) ?[]const u8 {
    return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}{s}", .{ port, path }) catch null;
}

const NullTicketsActionRequest = struct {
    method: ?[]const u8 = null,
    path: []const u8,
    payload: ?std.json.Value = null,
    bearer_token: ?[]const u8 = null,
};

fn parseNullTicketsActionMethod(method: []const u8) ?std.http.Method {
    if (std.mem.eql(u8, method, "GET")) return .GET;
    if (std.mem.eql(u8, method, "POST")) return .POST;
    if (std.mem.eql(u8, method, "DELETE")) return .DELETE;
    return null;
}

fn actionStatus(code: u10) []const u8 {
    return switch (code) {
        200 => "200 OK",
        201 => "201 Created",
        204 => "204 No Content",
        400 => "400 Bad Request",
        401 => "401 Unauthorized",
        403 => "403 Forbidden",
        404 => "404 Not Found",
        405 => "405 Method Not Allowed",
        409 => "409 Conflict",
        410 => "410 Gone",
        422 => "422 Unprocessable Entity",
        500 => "500 Internal Server Error",
        502 => "502 Bad Gateway",
        503 => "503 Service Unavailable",
        else => if (code >= 200 and code < 300) "200 OK" else if (code >= 400 and code < 500) "400 Bad Request" else "500 Internal Server Error",
    };
}

fn hasUnsafeActionPathByte(path: []const u8) bool {
    for (path) |ch| {
        if (ch <= 0x20 or ch == 0x7f) return true;
    }
    return false;
}

fn hasSinglePathTail(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const tail = path[prefix.len..];
    return tail.len > 0 and std.mem.indexOfScalar(u8, tail, '/') == null;
}

fn isTaskSubpath(path: []const u8, suffix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/tasks/")) return false;
    if (!std.mem.endsWith(u8, path, suffix)) return false;
    const tail = path["/tasks/".len .. path.len - suffix.len];
    return tail.len > 0 and std.mem.indexOfScalar(u8, tail, '/') == null;
}

fn isTaskAssignmentTarget(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/tasks/")) return false;
    const tail = path["/tasks/".len..];
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return false;
    const task_id = tail[0..slash];
    const rest = tail[slash + 1 ..];
    if (task_id.len == 0) return false;
    if (!std.mem.startsWith(u8, rest, "assignments/")) return false;
    const agent_id = rest["assignments/".len..];
    return agent_id.len > 0 and std.mem.indexOfScalar(u8, agent_id, '/') == null;
}

fn isRunSubpath(path: []const u8, suffix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/runs/")) return false;
    if (!std.mem.endsWith(u8, path, suffix)) return false;
    const tail = path["/runs/".len .. path.len - suffix.len];
    return tail.len > 0 and std.mem.indexOfScalar(u8, tail, '/') == null;
}

fn isLeaseHeartbeatTarget(path: []const u8) bool {
    if (!std.mem.startsWith(u8, path, "/leases/")) return false;
    if (!std.mem.endsWith(u8, path, "/heartbeat")) return false;
    const lease_id = path["/leases/".len .. path.len - "/heartbeat".len];
    return lease_id.len > 0 and std.mem.indexOfScalar(u8, lease_id, '/') == null;
}

const NullTicketsActionAuthMode = enum {
    instance_token,
    lease_token,
};

fn classifyNullTicketsAction(method: std.http.Method, path: []const u8) ?NullTicketsActionAuthMode {
    if (path.len == 0 or path.len > 2048) return null;
    if (path[0] != '/') return null;
    if (std.mem.startsWith(u8, path, "//")) return null;
    if (std.mem.indexOfScalar(u8, path, '#') != null) return null;
    if (hasUnsafeActionPathByte(path)) return null;

    const clean = stripQuery(path);
    return switch (method) {
        .GET => if (std.mem.eql(u8, clean, "/pipelines") or
            hasSinglePathTail(clean, "/pipelines/") or
            std.mem.eql(u8, clean, "/tasks") or
            hasSinglePathTail(clean, "/tasks/") or
            isTaskSubpath(clean, "/run-state") or
            isTaskSubpath(clean, "/dependencies") or
            isTaskSubpath(clean, "/assignments") or
            isRunSubpath(clean, "/events") or
            std.mem.eql(u8, clean, "/artifacts") or
            std.mem.eql(u8, clean, "/ops/queue")) .instance_token else null,
        .POST => blk: {
            if (path.len != clean.len) break :blk null;
            if (isLeaseHeartbeatTarget(clean) or
                isRunSubpath(clean, "/events") or
                isRunSubpath(clean, "/transition") or
                isRunSubpath(clean, "/fail"))
            {
                break :blk .lease_token;
            }
            if (std.mem.eql(u8, clean, "/pipelines") or
                std.mem.eql(u8, clean, "/tasks") or
                std.mem.eql(u8, clean, "/tasks/bulk") or
                isTaskSubpath(clean, "/dependencies") or
                isTaskSubpath(clean, "/assignments") or
                std.mem.eql(u8, clean, "/leases/claim") or
                std.mem.eql(u8, clean, "/artifacts"))
            {
                break :blk .instance_token;
            }
            break :blk null;
        },
        .DELETE => if (path.len == clean.len and isTaskAssignmentTarget(clean)) .instance_token else null,
        else => null,
    };
}

fn isAllowedNullTicketsAction(method: std.http.Method, path: []const u8) bool {
    return classifyNullTicketsAction(method, path) != null;
}

fn nullTicketsForwardedToken(
    auth_mode: NullTicketsActionAuthMode,
    instance_token: ?[]const u8,
    request_bearer_token: ?[]const u8,
) ?[]const u8 {
    return switch (auth_mode) {
        .instance_token => instance_token,
        .lease_token => blk: {
            const token = request_bearer_token orelse break :blk null;
            break :blk if (token.len > 0) token else null;
        },
    };
}

fn handleNullTicketsAction(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    mutex: *std_compat.sync.Mutex,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    body: []const u8,
) ApiResponse {
    if (!std.mem.eql(u8, component, "nulltickets")) {
        return badRequest("{\"error\":\"tickets actions are only supported for nulltickets\"}");
    }

    var parsed = std.json.parseFromSlice(NullTicketsActionRequest, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const method_name = parsed.value.method orelse "GET";
    const http_method = parseNullTicketsActionMethod(method_name) orelse
        return methodNotAllowed();
    const auth_mode = classifyNullTicketsAction(http_method, parsed.value.path) orelse {
        return badRequest("{\"error\":\"unsupported nulltickets action\"}");
    };

    var tickets_cfg = blk: {
        mutex.lock();
        defer mutex.unlock();
        _ = s.getInstance(component, name) orelse return notFound();
        const runtime = manager.getStatus("nulltickets", name) orelse
            return conflict("{\"error\":\"nulltickets instance is not running\"}");
        if (runtime.status != .running) {
            return conflict("{\"error\":\"nulltickets instance is not running\"}");
        }
        break :blk integration_mod.loadNullTicketsConfig(allocator, paths, name) catch null orelse return notFound();
    };
    defer integration_mod.deinitNullTicketsConfig(allocator, &tickets_cfg);

    var payload_json: ?[]u8 = null;
    defer if (payload_json) |value| allocator.free(value);
    if (parsed.value.payload) |payload| {
        payload_json = std.json.Stringify.valueAlloc(allocator, payload, .{
            .emit_null_optional_fields = false,
        }) catch return helpers.serverError();
    }

    const url = buildInstanceUrl(allocator, tickets_cfg.port, parsed.value.path) orelse return helpers.serverError();
    defer allocator.free(url);

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var header_buf: [2]std.http.Header = undefined;
    var header_count: usize = 0;
    const forwarded_token = nullTicketsForwardedToken(auth_mode, tickets_cfg.api_token, parsed.value.bearer_token);
    if (forwarded_token) |token| {
        auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch return helpers.serverError();
        header_buf[header_count] = .{ .name = "Authorization", .value = auth_header.? };
        header_count += 1;
    }
    if (payload_json != null) {
        header_buf[header_count] = .{ .name = "Content-Type", .value = "application/json" };
        header_count += 1;
    }

    var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = http_method,
        .payload = if (payload_json) |value| value else null,
        .response_writer = &response_body.writer,
        .extra_headers = header_buf[0..header_count],
    }) catch {
        return .{
            .status = "502 Bad Gateway",
            .content_type = "application/json",
            .body = "{\"error\":\"NullTickets unreachable\"}",
        };
    };

    const response_bytes = response_body.toOwnedSlice() catch return helpers.serverError();
    const status_code: u10 = @intFromEnum(result.status);
    return .{
        .status = actionStatus(status_code),
        .content_type = "application/json",
        .body = response_bytes,
    };
}

fn getStatusLocked(
    mutex: *std_compat.sync.Mutex,
    manager: *manager_mod.Manager,
    component: []const u8,
    name: []const u8,
) ?manager_mod.InstanceStatus {
    mutex.lock();
    defer mutex.unlock();
    return manager.getStatus(component, name);
}

const NullclawOnboardingStatus = struct {
    supported: bool = false,
    pending: bool = false,
    completed: bool = false,
    bootstrap_exists: bool = false,
    bootstrap_seeded_at: ?[]u8 = null,
    onboarding_completed_at: ?[]u8 = null,

    fn deinit(self: *NullclawOnboardingStatus, allocator: std.mem.Allocator) void {
        if (self.bootstrap_seeded_at) |value| allocator.free(value);
        if (self.onboarding_completed_at) |value| allocator.free(value);
        self.* = .{};
    }
};

fn fileExistsAbsolute(path: []const u8) bool {
    std_compat.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn nullclawWorkspaceStatePath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ workspace_dir, ".nullclaw", "workspace-state.json" });
}

fn readNullclawOnboardingStatus(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) !NullclawOnboardingStatus {
    var status = NullclawOnboardingStatus{};
    errdefer status.deinit(allocator);

    if (!std.mem.eql(u8, component, "nullclaw")) return status;
    status.supported = true;

    const inst_dir = try paths.instanceDir(allocator, component, name);
    defer allocator.free(inst_dir);
    const workspace_dir = try std.fs.path.join(allocator, &.{ inst_dir, "workspace" });
    defer allocator.free(workspace_dir);

    const bootstrap_path = try std.fs.path.join(allocator, &.{ workspace_dir, "BOOTSTRAP.md" });
    defer allocator.free(bootstrap_path);
    status.bootstrap_exists = fileExistsAbsolute(bootstrap_path);

    const state_path = try nullclawWorkspaceStatePath(allocator, workspace_dir);
    defer allocator.free(state_path);

    const state_file = std_compat.fs.openFileAbsolute(state_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
    if (state_file) |file| {
        defer file.close();
        const raw = file.readToEndAlloc(allocator, 64 * 1024) catch null;
        if (raw) |state_raw| {
            defer allocator.free(state_raw);
            const parsed = std.json.parseFromSlice(struct {
                bootstrap_seeded_at: ?[]const u8 = null,
                bootstrapSeededAt: ?[]const u8 = null,
                onboarding_completed_at: ?[]const u8 = null,
                onboardingCompletedAt: ?[]const u8 = null,
            }, allocator, state_raw, .{
                .allocate = .alloc_if_needed,
                .ignore_unknown_fields = true,
            }) catch null;
            if (parsed) |state_parsed| {
                defer state_parsed.deinit();
                if (state_parsed.value.bootstrap_seeded_at orelse state_parsed.value.bootstrapSeededAt) |seeded| {
                    status.bootstrap_seeded_at = try allocator.dupe(u8, seeded);
                }
                if (state_parsed.value.onboarding_completed_at orelse state_parsed.value.onboardingCompletedAt) |completed| {
                    status.onboarding_completed_at = try allocator.dupe(u8, completed);
                }
            }
        }
    }

    status.completed = status.onboarding_completed_at != null and !status.bootstrap_exists;
    status.pending = !status.completed and (status.bootstrap_exists or status.bootstrap_seeded_at != null);
    return status;
}

fn listNullTicketsLocked(
    allocator: std.mem.Allocator,
    mutex: *std_compat.sync.Mutex,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]integration_mod.NullTicketsConfig {
    mutex.lock();
    defer mutex.unlock();
    return integration_mod.listNullTickets(allocator, state, paths);
}

fn listNullBoilersLocked(
    allocator: std.mem.Allocator,
    mutex: *std_compat.sync.Mutex,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]integration_mod.NullBoilerConfig {
    mutex.lock();
    defer mutex.unlock();
    return integration_mod.listNullBoilers(allocator, state, paths);
}

fn listNullWatchLocked(
    allocator: std.mem.Allocator,
    mutex: *std_compat.sync.Mutex,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]integration_mod.NullWatchConfig {
    mutex.lock();
    defer mutex.unlock();
    return integration_mod.listNullWatch(allocator, state, paths);
}

const PipelineSummary = struct {
    id: []const u8,
    name: []const u8,
    roles: []const []const u8,
    triggers: []const []const u8,
};

const TrackerIntegrationOption = struct {
    name: []const u8,
    port: u16,
    running: bool,
    pipelines: []const PipelineSummary = &.{},
};

const WatchIntegrationOption = struct {
    name: []const u8,
    host: []const u8,
    port: u16,
    running: bool,
};

const ClawIntegrationOption = struct {
    name: []const u8,
    running: bool,
    linked: bool,
};

fn fetchPipelineSummaries(allocator: std.mem.Allocator, url: []const u8, bearer_token: ?[]const u8) ?[]PipelineSummary {
    var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var auth_header: ?[]const u8 = null;
    defer if (auth_header) |value| allocator.free(value);
    var header_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (bearer_token) |token| blk: {
        auth_header = std.fmt.allocPrint(allocator, "Bearer {s}", .{token}) catch return null;
        header_buf[0] = .{ .name = "Authorization", .value = auth_header.? };
        break :blk header_buf[0..1];
    } else &.{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
    }) catch return null;
    if (@intFromEnum(result.status) < 200 or @intFromEnum(result.status) >= 300) return null;

    const bytes = response_body.written();
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();
    const pipeline_items = pipelineItemsFromValue(parsed.value) orelse return null;

    var list: std.ArrayListUnmanaged(PipelineSummary) = .empty;
    var summaries_owned = false;
    defer {
        if (!summaries_owned) {
            for (list.items) |summary| deinitPipelineSummary(allocator, summary);
        }
    }
    defer list.deinit(allocator);

    for (pipeline_items) |item| {
        const summary = parsePipelineSummary(allocator, item) catch continue;
        list.append(allocator, summary) catch {
            deinitPipelineSummary(allocator, summary);
            return null;
        };
    }

    const summaries = list.toOwnedSlice(allocator) catch return null;
    summaries_owned = true;
    return summaries;
}

fn pipelineItemsFromValue(value: std.json.Value) ?[]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        .object => |object| blk: {
            if (object.get("pipelines")) |pipelines| {
                if (pipelines == .array) break :blk pipelines.array.items;
            }
            if (object.get("items")) |items| {
                if (items == .array) break :blk items.array.items;
            }
            break :blk null;
        },
        else => null,
    };
}

fn parsePipelineSummary(allocator: std.mem.Allocator, value: std.json.Value) !PipelineSummary {
    if (value != .object) return error.InvalidPipelineSummary;
    const obj = value.object;
    var parsed_definition: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_definition) |*parsed| parsed.deinit();
    const definition = try pipelineDefinitionValue(
        allocator,
        obj.get("definition") orelse obj.get("definition_json") orelse return error.InvalidPipelineSummary,
        &parsed_definition,
    );

    const id = try allocator.dupe(u8, jsonStringOrEmpty(obj, "id"));
    errdefer allocator.free(id);
    const name = try allocator.dupe(u8, jsonStringOrEmpty(obj, "name"));
    errdefer allocator.free(name);
    const roles = try collectPipelineRoles(allocator, definition);
    errdefer freeStringList(allocator, roles);
    const triggers = try collectPipelineTriggers(allocator, definition);

    return .{ .id = id, .name = name, .roles = roles, .triggers = triggers };
}

fn pipelineDefinitionValue(
    allocator: std.mem.Allocator,
    value: std.json.Value,
    parsed_out: *?std.json.Parsed(std.json.Value),
) !std.json.Value {
    return switch (value) {
        .object => value,
        .string => |raw| blk: {
            parsed_out.* = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            });
            const parsed = &parsed_out.*.?;
            if (parsed.value != .object) return error.InvalidPipelineSummary;
            break :blk parsed.value;
        },
        else => error.InvalidPipelineSummary,
    };
}

fn collectPipelineRoles(allocator: std.mem.Allocator, definition: std.json.Value) ![]const []const u8 {
    if (definition != .object) return allocator.alloc([]const u8, 0);
    const states_val = definition.object.get("states") orelse return allocator.alloc([]const u8, 0);
    if (states_val != .object) return allocator.alloc([]const u8, 0);

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer for (list.items) |role| allocator.free(role);
    defer list.deinit(allocator);

    var it = states_val.object.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.* != .object) continue;
        const role = jsonString(entry.value_ptr.*.object, "agent_role") orelse continue;
        try appendUniqueString(allocator, &list, role);
    }

    return list.toOwnedSlice(allocator);
}

fn collectPipelineTriggers(allocator: std.mem.Allocator, definition: std.json.Value) ![]const []const u8 {
    if (definition != .object) return allocator.alloc([]const u8, 0);
    const transitions_val = definition.object.get("transitions") orelse return allocator.alloc([]const u8, 0);
    if (transitions_val != .array) return allocator.alloc([]const u8, 0);

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer for (list.items) |trigger| allocator.free(trigger);
    defer list.deinit(allocator);

    for (transitions_val.array.items) |transition| {
        if (transition != .object) continue;
        const trigger = jsonString(transition.object, "trigger") orelse continue;
        try appendUniqueString(allocator, &list, trigger);
    }

    return list.toOwnedSlice(allocator);
}

fn appendUniqueString(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged([]const u8), value: []const u8) !void {
    for (list.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try list.append(allocator, owned);
}

fn freeStringList(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    allocator.free(@constCast(values));
}

fn deinitPipelineSummary(allocator: std.mem.Allocator, summary: PipelineSummary) void {
    allocator.free(summary.id);
    allocator.free(summary.name);
    freeStringList(allocator, summary.roles);
    freeStringList(allocator, summary.triggers);
}

fn deinitPipelineSummaries(allocator: std.mem.Allocator, summaries: []const PipelineSummary) void {
    for (summaries) |summary| deinitPipelineSummary(allocator, summary);
    allocator.free(@constCast(summaries));
}

fn jsonString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

fn jsonStringOrEmpty(obj: std.json.ObjectMap, key: []const u8) []const u8 {
    return jsonString(obj, key) orelse "";
}

fn pipelineContainsString(values: []const []const u8, candidate: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, candidate)) return true;
    }
    return false;
}

fn ensurePath(path: []const u8) !void {
    try std_compat.fs.cwd().makePath(path);
}

fn writeJsonConfigValue(allocator: std.mem.Allocator, config_path: []const u8, value: std.json.Value) !void {
    const rendered = try std.json.Stringify.valueAlloc(allocator, value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(rendered);

    const out = try std_compat.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(rendered);
    try out.writeAll("\n");
}

pub const GatewayProxyUpstream = struct {
    port: u16,
    token: []u8,
    upstream_path: []const u8,
    body: []const u8,
    body_owned: bool = false,
    event_stream: bool,

    pub fn deinit(self: GatewayProxyUpstream, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        if (self.body_owned) allocator.free(self.body);
    }
};

pub const GatewayProxyPrepareResult = union(enum) {
    no_match,
    response: ApiResponse,
    upstream: GatewayProxyUpstream,
};

fn resolveGatewayPort(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    manager: *manager_mod.Manager,
    component: []const u8,
    name: []const u8,
    entry: state_mod.InstanceEntry,
) ?u16 {
    const snapshot = instance_runtime.resolve(allocator, paths, manager, component, name, entry);
    if (snapshot.port != 0) return snapshot.port;
    return instance_runtime.readPortFromConfig(allocator, paths, component, name, "gateway.port");
}

fn gatewayNotReady() ApiResponse {
    return .{
        .status = "503 Service Unavailable",
        .content_type = "application/json",
        .body = "{\"error\":\"nullclaw gateway is not running\"}",
    };
}

fn gatewayNotPrepared() ApiResponse {
    return .{
        .status = "409 Conflict",
        .content_type = "application/json",
        .body = "{\"error\":\"nullclaw gateway pairing is not configured\"}",
    };
}

const GatewayProxyRoute = struct {
    upstream_path: []const u8,
    event_stream: bool,
    body_mode: enum { raw, agent_stream_a2a },
};

fn gatewayProxyRouteForAction(action: []const u8) ?GatewayProxyRoute {
    if (std.mem.eql(u8, action, "agent-stream")) return .{ .upstream_path = "/a2a", .event_stream = true, .body_mode = .agent_stream_a2a };
    if (std.mem.eql(u8, action, "a2a")) return .{ .upstream_path = "/a2a", .event_stream = false, .body_mode = .raw };
    if (std.mem.eql(u8, action, "a2a-stream")) return .{ .upstream_path = "/a2a", .event_stream = true, .body_mode = .raw };
    if (std.mem.eql(u8, action, "transcribe")) return .{ .upstream_path = "/media/transcribe", .event_stream = false, .body_mode = .raw };
    return null;
}

fn buildAgentStreamA2aBody(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(struct {
        message: ?[]const u8 = null,
        session_key: ?[]const u8 = null,
        context_id: ?[]const u8 = null,
        request_id: ?[]const u8 = null,
        message_id: ?[]const u8 = null,
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();

    const message = parsed.value.message orelse return error.MissingMessage;
    if (message.len == 0) return error.MissingMessage;

    const now = std_compat.time.milliTimestamp();
    const request_id = parsed.value.request_id orelse "";
    const message_id = parsed.value.message_id orelse "";
    const context_id = parsed.value.context_id orelse (parsed.value.session_key orelse "");

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"jsonrpc\":\"2.0\",\"id\":\"");
    if (request_id.len > 0) {
        try appendEscaped(&buf, request_id);
    } else {
        const generated = try std.fmt.allocPrint(allocator, "nullhub-agent-stream-{d}", .{now});
        defer allocator.free(generated);
        try buf.appendSlice(generated);
    }
    try buf.appendSlice("\",\"method\":\"message/stream\",\"params\":{\"message\":{\"kind\":\"message\",\"role\":\"user\",\"messageId\":\"");
    if (message_id.len > 0) {
        try appendEscaped(&buf, message_id);
    } else {
        const generated = try std.fmt.allocPrint(allocator, "msg-nullhub-{d}", .{now});
        defer allocator.free(generated);
        try buf.appendSlice(generated);
    }
    try buf.appendSlice("\"");
    if (context_id.len > 0) {
        try buf.appendSlice(",\"contextId\":\"");
        try appendEscaped(&buf, context_id);
        try buf.appendSlice("\"");
    }
    try buf.appendSlice(",\"parts\":[{\"kind\":\"text\",\"text\":\"");
    try appendEscaped(&buf, message);
    try buf.appendSlice("\"}]},\"configuration\":{\"acceptedOutputModes\":[\"text/plain\"]}}}");

    return try buf.toOwnedSlice();
}

pub fn isGatewayProxyPath(target: []const u8) bool {
    const parsed = parsePath(target) orelse return false;
    if (!parsedPathSegmentsAreSafe(parsed)) return false;
    const action = parsed.action orelse return false;
    return gatewayProxyRouteForAction(action) != null;
}

pub fn prepareGatewayProxy(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    paths: paths_mod.Paths,
    method: []const u8,
    target: []const u8,
    body: []const u8,
) GatewayProxyPrepareResult {
    const parsed_owned = parsePathAlloc(allocator, target) catch |err| switch (err) {
        error.InvalidPathSegment => return .{ .response = badRequest("{\"error\":\"invalid path segment\"}") },
        else => return .{ .response = helpers.serverError() },
    };
    const parsed_storage = parsed_owned orelse return .no_match;
    defer parsed_storage.deinit(allocator);
    const parsed = parsed_storage.borrowed();
    const action = parsed.action orelse return .no_match;
    const route = gatewayProxyRouteForAction(action) orelse return .no_match;
    if (!std.mem.eql(u8, method, "POST")) return .{ .response = methodNotAllowed() };
    if (!std.mem.eql(u8, parsed.component, "nullclaw")) {
        return .{ .response = badRequest("{\"error\":\"gateway proxy routes are only supported for nullclaw instances\"}") };
    }

    const proxy_body = switch (route.body_mode) {
        .raw => body,
        .agent_stream_a2a => buildAgentStreamA2aBody(allocator, body) catch |err| switch (err) {
            error.InvalidJson => return .{ .response = badRequest("{\"error\":\"invalid JSON body\"}") },
            error.MissingMessage => return .{ .response = badRequest("{\"error\":\"message is required\"}") },
            else => return .{ .response = helpers.serverError() },
        },
    };
    const proxy_body_owned = route.body_mode == .agent_stream_a2a;
    var proxy_body_transferred = false;
    defer if (proxy_body_owned and !proxy_body_transferred) allocator.free(proxy_body);

    const entry = s.getInstance(parsed.component, parsed.name) orelse return .{ .response = notFound() };
    var access = nullclaw_gateway_config.loadAccess(allocator, paths, parsed.component, parsed.name) catch |err| switch (err) {
        error.UnsupportedComponent => return .{ .response = badRequest("{\"error\":\"unsupported component\"}") },
        error.FileNotFound,
        error.GatewayConfigMissing,
        error.GatewayTokenMissing,
        error.GatewayPairingMissing,
        => return .{ .response = gatewayNotPrepared() },
        else => return .{ .response = helpers.serverError() },
    };
    errdefer access.deinit(allocator);

    const snapshot = instance_runtime.resolve(allocator, paths, manager, parsed.component, parsed.name, entry);
    if (snapshot.status != .running) {
        access.deinit(allocator);
        return .{ .response = gatewayNotReady() };
    }

    const port = resolveGatewayPort(allocator, paths, manager, parsed.component, parsed.name, entry) orelse {
        access.deinit(allocator);
        return .{ .response = .{ .status = "503 Service Unavailable", .content_type = "application/json", .body = "{\"error\":\"gateway port unavailable\"}" } };
    };

    const token = access.token orelse {
        access.deinit(allocator);
        return .{ .response = gatewayNotPrepared() };
    };
    access.token = null;
    proxy_body_transferred = true;
    return .{ .upstream = .{
        .port = port,
        .token = token,
        .upstream_path = route.upstream_path,
        .body = proxy_body,
        .body_owned = proxy_body_owned,
        .event_stream = route.event_stream,
    } };
}

const ProviderHealthConfig = struct {
    agents: ?struct {
        defaults: ?struct {
            model: ?struct {
                primary: ?[]const u8 = null,
            } = null,
        } = null,
    } = null,
    models: ?struct {
        providers: ?std.json.ArrayHashMap(struct {
            api_key: ?[]const u8 = null,
            base_url: ?[]const u8 = null,
            api_url: ?[]const u8 = null,
        }) = null,
    } = null,
};

const ProviderProbeResult = struct {
    live_ok: bool,
    status_code: ?u16 = null,
    reason: []const u8,
};

fn parseAnyHttpStatusCode(s: []const u8) ?u16 {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (!std.ascii.isDigit(s[i])) continue;
        var j = i;
        while (j < s.len and std.ascii.isDigit(s[j])) : (j += 1) {}
        if (j - i == 3) {
            const code = std.fmt.parseInt(u16, s[i..j], 10) catch continue;
            if (code >= 100 and code <= 599) return code;
        }
        i = j;
    }
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn isLocalEndpoint(url: []const u8) bool {
    return std.mem.startsWith(u8, url, "http://localhost") or
        std.mem.startsWith(u8, url, "https://localhost") or
        std.mem.startsWith(u8, url, "http://127.") or
        std.mem.startsWith(u8, url, "https://127.") or
        std.mem.startsWith(u8, url, "http://0.0.0.0") or
        std.mem.startsWith(u8, url, "https://0.0.0.0") or
        std.mem.startsWith(u8, url, "http://[::1]") or
        std.mem.startsWith(u8, url, "https://[::1]");
}

fn knownCompatibleProviderUrl(provider_name: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, provider_name, "lmstudio") or std.mem.eql(u8, provider_name, "lm-studio")) {
        return "http://localhost:1234/v1";
    }
    if (std.mem.eql(u8, provider_name, "vllm")) return "http://localhost:8000/v1";
    if (std.mem.eql(u8, provider_name, "llamacpp") or std.mem.eql(u8, provider_name, "llama.cpp")) {
        return "http://localhost:8080/v1";
    }
    if (std.mem.eql(u8, provider_name, "sglang")) return "http://localhost:30000/v1";
    if (std.mem.eql(u8, provider_name, "osaurus")) return "http://localhost:1337/v1";
    if (std.mem.eql(u8, provider_name, "litellm")) return "http://localhost:4000";
    return null;
}

fn providerRequiresApiKey(provider_name: []const u8, base_url: ?[]const u8) bool {
    if (std.mem.eql(u8, provider_name, "ollama") or
        std.mem.eql(u8, provider_name, "claude-cli") or
        std.mem.eql(u8, provider_name, "codex-cli") or
        std.mem.eql(u8, provider_name, "openai-codex"))
    {
        return false;
    }

    if (base_url) |configured| return !isLocalEndpoint(configured);

    if (std.mem.startsWith(u8, provider_name, "custom:")) {
        return !isLocalEndpoint(provider_name["custom:".len..]);
    }

    if (knownCompatibleProviderUrl(provider_name)) |known_url| {
        return !isLocalEndpoint(known_url);
    }

    return true;
}

fn classifyProbeFailure(status_code: ?u16, stdout: []const u8, stderr: []const u8) ProviderProbeResult {
    if (status_code) |code| {
        return switch (code) {
            401 => .{ .live_ok = false, .status_code = code, .reason = "invalid_api_key" },
            403 => .{ .live_ok = false, .status_code = code, .reason = "forbidden" },
            429 => .{ .live_ok = false, .status_code = code, .reason = "rate_limited" },
            else => if (code >= 500 and code <= 599)
                .{ .live_ok = false, .status_code = code, .reason = "provider_unavailable" }
            else
                .{ .live_ok = false, .status_code = code, .reason = "auth_check_failed" },
        };
    }

    if (containsIgnoreCase(stderr, "unauthorized") or containsIgnoreCase(stdout, "unauthorized")) {
        return .{ .live_ok = false, .reason = "invalid_api_key" };
    }
    if (containsIgnoreCase(stderr, "forbidden") or containsIgnoreCase(stdout, "forbidden")) {
        return .{ .live_ok = false, .reason = "forbidden" };
    }
    if (containsIgnoreCase(stderr, "rate limit") or containsIgnoreCase(stdout, "rate limit") or
        containsIgnoreCase(stderr, "too many requests") or containsIgnoreCase(stdout, "too many requests"))
    {
        return .{ .live_ok = false, .reason = "rate_limited" };
    }
    if (containsIgnoreCase(stderr, "timeout") or containsIgnoreCase(stdout, "timeout") or
        containsIgnoreCase(stderr, "network") or containsIgnoreCase(stdout, "network") or
        containsIgnoreCase(stderr, "connection") or containsIgnoreCase(stdout, "connection"))
    {
        return .{ .live_ok = false, .reason = "network_error" };
    }
    return .{ .live_ok = false, .reason = "auth_check_failed" };
}

fn canonicalProbeReason(raw: ?[]const u8, live_ok: bool) []const u8 {
    const reason = raw orelse (if (live_ok) "ok" else "auth_check_failed");

    if (std.mem.eql(u8, reason, "ok")) return "ok";
    if (std.mem.eql(u8, reason, "invalid_api_key")) return "invalid_api_key";
    if (std.mem.eql(u8, reason, "missing_api_key")) return "missing_api_key";
    if (std.mem.eql(u8, reason, "provider_not_detected")) return "provider_not_detected";
    if (std.mem.eql(u8, reason, "instance_not_running")) return "instance_not_running";
    if (std.mem.eql(u8, reason, "rate_limited")) return "rate_limited";
    if (std.mem.eql(u8, reason, "forbidden")) return "forbidden";
    if (std.mem.eql(u8, reason, "provider_unavailable")) return "provider_unavailable";
    if (std.mem.eql(u8, reason, "network_error")) return "network_error";
    if (std.mem.eql(u8, reason, "provider_rejected")) return "provider_rejected";
    if (std.mem.eql(u8, reason, "probe_exec_failed")) return "probe_exec_failed";
    if (std.mem.eql(u8, reason, "probe_request_failed")) return "probe_request_failed";
    if (std.mem.eql(u8, reason, "config_load_failed")) return "config_load_failed";
    if (std.mem.eql(u8, reason, "component_binary_missing")) return "component_binary_missing";
    if (std.mem.eql(u8, reason, "component_probe_failed")) return "component_probe_failed";
    if (std.mem.eql(u8, reason, "probe_timeout")) return "probe_timeout";
    if (std.mem.eql(u8, reason, "probe_home_path_failed")) return "probe_home_path_failed";
    if (std.mem.eql(u8, reason, "invalid_probe_response")) return "invalid_probe_response";
    if (std.mem.eql(u8, reason, "auth_check_failed")) return "auth_check_failed";

    return if (live_ok) "ok" else "auth_check_failed";
}

const ComponentHealthProbePayload = struct {
    live_ok: bool = false,
    reason: ?[]const u8 = null,
    status_code: ?u16 = null,
};

fn probeProviderViaComponentHealth(
    allocator: std.mem.Allocator,
    component: []const u8,
    binary_path: []const u8,
    instance_home: []const u8,
    provider: []const u8,
    model: []const u8,
) ProviderProbeResult {
    const args: []const []const u8 = if (model.len > 0)
        &.{ "--probe-provider-health", "--provider", provider, "--model", model, "--timeout-secs", "30" }
    else
        &.{ "--probe-provider-health", "--provider", provider, "--timeout-secs", "30" };
    const result = component_cli.runWithComponentHome(
        allocator,
        component,
        binary_path,
        args,
        null,
        instance_home,
    ) catch return .{ .live_ok = false, .reason = "probe_exec_failed" };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed = std.json.parseFromSlice(ComponentHealthProbePayload, allocator, result.stdout, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch {
        const status_code = parseAnyHttpStatusCode(result.stderr) orelse parseAnyHttpStatusCode(result.stdout);
        return if (result.success)
            .{ .live_ok = false, .reason = "invalid_probe_response", .status_code = status_code }
        else
            classifyProbeFailure(status_code, result.stdout, result.stderr);
    };
    defer parsed.deinit();

    const payload = parsed.value;
    const reason = canonicalProbeReason(payload.reason, payload.live_ok);
    if (!result.success and payload.reason == null and !payload.live_ok) {
        const status_code = payload.status_code orelse parseAnyHttpStatusCode(result.stderr) orelse parseAnyHttpStatusCode(result.stdout);
        return classifyProbeFailure(status_code, result.stdout, result.stderr);
    }
    return .{
        .live_ok = payload.live_ok,
        .status_code = payload.status_code,
        .reason = reason,
    };
}

fn probeComponentProvider(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    entry: state_mod.InstanceEntry,
    component: []const u8,
    name: []const u8,
    provider: []const u8,
    model: []const u8,
) ProviderProbeResult {
    const bin_path = paths.binary(allocator, component, entry.version) catch {
        return .{ .live_ok = false, .reason = "probe_binary_path_failed" };
    };
    defer allocator.free(bin_path);

    std_compat.fs.accessAbsolute(bin_path, .{}) catch return .{ .live_ok = false, .reason = "component_binary_missing" };
    const inst_dir = paths.instanceDir(allocator, component, name) catch return .{ .live_ok = false, .reason = "probe_home_path_failed" };
    defer allocator.free(inst_dir);
    return probeProviderViaComponentHealth(allocator, component, bin_path, inst_dir, provider, model);
}

// ─── Path Parsing ────────────────────────────────────────────────────────────

pub const ParsedPath = struct {
    component: []const u8,
    name: []const u8,
    action: ?[]const u8,
};

const ParsedPathOwned = struct {
    component: []u8,
    name: []u8,
    action: ?[]u8,

    fn deinit(self: ParsedPathOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.component);
        allocator.free(self.name);
        if (self.action) |action| allocator.free(action);
    }

    fn borrowed(self: ParsedPathOwned) ParsedPath {
        return .{
            .component = self.component,
            .name = self.name,
            .action = self.action,
        };
    }
};

const ParsedChannelsPath = struct {
    component: []const u8,
    name: []const u8,
    channel_type: ?[]const u8,
};

const ParsedChannelsPathOwned = struct {
    component: []u8,
    name: []u8,
    channel_type: ?[]u8,

    fn deinit(self: ParsedChannelsPathOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.component);
        allocator.free(self.name);
        if (self.channel_type) |channel_type| allocator.free(channel_type);
    }

    fn borrowed(self: ParsedChannelsPathOwned) ParsedChannelsPath {
        return .{
            .component = self.component,
            .name = self.name,
            .channel_type = self.channel_type,
        };
    }
};

fn stripQuery(target: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, target, '?')) |qmark| {
        return target[0..qmark];
    }
    return target;
}

/// Parse `/api/instances/{component}/{name}` or
/// `/api/instances/{component}/{name}/{action}` from a request target.
/// Returns `null` if the path does not match the expected prefix or has
/// too few / too many segments.
pub fn parsePath(target: []const u8) ?ParsedPath {
    const clean = stripQuery(target);
    const prefix = "/api/instances/";
    if (!std.mem.startsWith(u8, clean, prefix)) return null;

    const rest = clean[prefix.len..];
    if (rest.len == 0) return null;

    var it = std.mem.splitScalar(u8, rest, '/');
    const component = it.next() orelse return null;
    if (component.len == 0) return null;

    const name = it.next() orelse return null;
    if (name.len == 0) return null;

    const action_raw = it.next();
    // If there is a fourth segment the path is invalid.
    if (it.next() != null) return null;

    const action: ?[]const u8 = if (action_raw) |a| (if (a.len == 0) null else a) else null;

    return .{ .component = component, .name = name, .action = action };
}

fn parsePathAlloc(allocator: std.mem.Allocator, target: []const u8) !?ParsedPathOwned {
    const parsed = parsePath(target) orelse return null;
    if (!parsedPathSegmentsAreSafe(parsed)) return error.InvalidPathSegment;

    const component = try query_api.decodePathSegmentAlloc(allocator, parsed.component);
    errdefer allocator.free(component);
    const name = try query_api.decodePathSegmentAlloc(allocator, parsed.name);
    errdefer allocator.free(name);
    const action = if (parsed.action) |value|
        try query_api.decodePathSegmentAlloc(allocator, value)
    else
        null;
    errdefer if (action) |owned| allocator.free(owned);

    return .{
        .component = component,
        .name = name,
        .action = action,
    };
}

fn parsedPathSegmentsAreSafe(parsed: ParsedPath) bool {
    if (!query_api.isSafeEncodedPathSegment(parsed.component)) return false;
    if (!query_api.isSafeEncodedPathSegment(parsed.name)) return false;
    if (parsed.action) |action| {
        if (!query_api.isSafeEncodedPathSegment(action)) return false;
    }
    return true;
}

fn parseChannelsPath(target: []const u8) ?ParsedChannelsPath {
    const clean = stripQuery(target);
    const prefix = "/api/instances/";
    if (!std.mem.startsWith(u8, clean, prefix)) return null;

    const rest = clean[prefix.len..];
    if (rest.len == 0) return null;

    var it = std.mem.splitScalar(u8, rest, '/');
    const component = it.next() orelse return null;
    if (component.len == 0) return null;

    const name = it.next() orelse return null;
    if (name.len == 0) return null;

    const action = it.next() orelse return null;
    if (!std.mem.eql(u8, action, "channels")) return null;

    const channel_type_raw = it.next();
    if (it.next() != null) return null;

    return .{
        .component = component,
        .name = name,
        .channel_type = if (channel_type_raw) |value| if (value.len > 0) value else null else null,
    };
}

fn parseChannelsPathAlloc(allocator: std.mem.Allocator, target: []const u8) !?ParsedChannelsPathOwned {
    const parsed = parseChannelsPath(target) orelse return null;

    const component = try query_api.decodePathSegmentAlloc(allocator, parsed.component);
    errdefer allocator.free(component);
    const name = try query_api.decodePathSegmentAlloc(allocator, parsed.name);
    errdefer allocator.free(name);
    const channel_type = if (parsed.channel_type) |value|
        try query_api.decodePathSegmentAlloc(allocator, value)
    else
        null;
    errdefer if (channel_type) |owned| allocator.free(owned);

    return .{
        .component = component,
        .name = name,
        .channel_type = channel_type,
    };
}

pub const UsageLedgerLine = struct {
    ts: i64 = 0,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    success: bool = true,
};

pub const UsageAggregate = struct {
    provider: []const u8,
    model: []const u8,
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    requests: u64 = 0,
    last_used: i64 = 0,
};

pub const TOKEN_USAGE_LEDGER_FILENAME = "llm_token_usage.jsonl";
pub const USAGE_CACHE_VERSION: u32 = 1;
pub const USAGE_CACHE_MAX_LEDGER_BYTES: usize = 128 * 1024 * 1024;
pub const USAGE_HOURLY_RETENTION_SECS: i64 = 14 * 24 * 60 * 60;
pub const USAGE_DAILY_RETENTION_SECS: i64 = 730 * 24 * 60 * 60;
pub const HOUR_SECS: i64 = 60 * 60;
pub const DAY_SECS: i64 = 24 * 60 * 60;

pub const UsageCacheBucket = struct {
    bucket_start: i64 = 0,
    provider: []const u8 = "",
    model: []const u8 = "",
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    total_tokens: u64 = 0,
    requests: u64 = 0,
    last_used: i64 = 0,
};

pub const UsageCacheSnapshot = struct {
    version: u32 = USAGE_CACHE_VERSION,
    generated_at: i64 = 0,
    ledger_size: u64 = 0,
    ledger_mtime_ns: i64 = 0,
    hourly: []UsageCacheBucket = &.{},
    daily: []UsageCacheBucket = &.{},

    pub fn deinit(self: *UsageCacheSnapshot, allocator: std.mem.Allocator) void {
        for (self.hourly) |row| {
            allocator.free(row.provider);
            allocator.free(row.model);
        }
        if (self.hourly.len > 0) allocator.free(self.hourly);
        for (self.daily) |row| {
            allocator.free(row.provider);
            allocator.free(row.model);
        }
        if (self.daily.len > 0) allocator.free(self.daily);
        self.* = .{};
    }
};

pub fn emptyUsageCache(now_ts: i64) UsageCacheSnapshot {
    return .{ .generated_at = now_ts };
}

fn bucketFloor(ts: i64, bucket_secs: i64) i64 {
    return @divFloor(ts, bucket_secs) * bucket_secs;
}

pub fn isShortUsageWindow(window: []const u8) bool {
    return std.mem.eql(u8, window, "24h") or std.mem.eql(u8, window, "7d");
}

pub fn resolveUsageLedgerPath(allocator: std.mem.Allocator, inst_dir: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ inst_dir, TOKEN_USAGE_LEDGER_FILENAME });
}

pub fn usageCachePath(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8, name: []const u8) ![]u8 {
    const filename = try std.fmt.allocPrint(allocator, "{s}.json", .{name});
    defer allocator.free(filename);
    return std.fs.path.join(allocator, &.{ paths.root, "cache", "usage", component, filename });
}

fn parseI64(v: std.json.Value) ?i64 {
    return switch (v) {
        .integer => @intCast(v.integer),
        else => null,
    };
}

fn parseU64(v: std.json.Value) ?u64 {
    return switch (v) {
        .integer => if (v.integer >= 0) @intCast(v.integer) else null,
        else => null,
    };
}

fn parseU32(v: std.json.Value) ?u32 {
    return switch (v) {
        .integer => if (v.integer >= 0 and v.integer <= std.math.maxInt(u32)) @intCast(v.integer) else null,
        else => null,
    };
}

fn parseUsageCacheBuckets(allocator: std.mem.Allocator, value: std.json.Value) ![]UsageCacheBucket {
    if (value != .array) return allocator.alloc(UsageCacheBucket, 0);

    var list: std.ArrayListUnmanaged(UsageCacheBucket) = .empty;
    errdefer {
        for (list.items) |row| {
            allocator.free(row.provider);
            allocator.free(row.model);
        }
        list.deinit(allocator);
    }

    for (value.array.items) |item| {
        if (item != .object) continue;
        const provider_v = item.object.get("provider") orelse continue;
        const model_v = item.object.get("model") orelse continue;
        if (provider_v != .string or model_v != .string) continue;

        const provider_copy = try allocator.dupe(u8, provider_v.string);
        errdefer allocator.free(provider_copy);
        const model_copy = try allocator.dupe(u8, model_v.string);
        errdefer allocator.free(model_copy);

        try list.append(allocator, .{
            .bucket_start = if (item.object.get("bucket_start")) |v| parseI64(v) orelse 0 else 0,
            .provider = provider_copy,
            .model = model_copy,
            .prompt_tokens = if (item.object.get("prompt_tokens")) |v| parseU64(v) orelse 0 else 0,
            .completion_tokens = if (item.object.get("completion_tokens")) |v| parseU64(v) orelse 0 else 0,
            .total_tokens = if (item.object.get("total_tokens")) |v| parseU64(v) orelse 0 else 0,
            .requests = if (item.object.get("requests")) |v| parseU64(v) orelse 0 else 0,
            .last_used = if (item.object.get("last_used")) |v| parseI64(v) orelse 0 else 0,
        });
    }

    return list.toOwnedSlice(allocator);
}

pub fn loadUsageCacheSnapshot(allocator: std.mem.Allocator, cache_path: []const u8, now_ts: i64) !?UsageCacheSnapshot {
    const file = std_compat.fs.openFileAbsolute(cache_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer file.close();

    const content = try file.readToEndAlloc(allocator, 16 * 1024 * 1024);
    defer allocator.free(content);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{
        .allocate = .alloc_if_needed,
    }) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;

    var snapshot = emptyUsageCache(now_ts);
    errdefer snapshot.deinit(allocator);

    const root = parsed.value.object;
    if (root.get("version")) |v| snapshot.version = parseU32(v) orelse USAGE_CACHE_VERSION;
    if (root.get("generated_at")) |v| snapshot.generated_at = parseI64(v) orelse now_ts;
    if (root.get("ledger_size")) |v| snapshot.ledger_size = parseU64(v) orelse 0;
    if (root.get("ledger_mtime_ns")) |v| snapshot.ledger_mtime_ns = parseI64(v) orelse 0;
    if (root.get("hourly")) |v| snapshot.hourly = try parseUsageCacheBuckets(allocator, v);
    if (root.get("daily")) |v| snapshot.daily = try parseUsageCacheBuckets(allocator, v);

    return snapshot;
}

fn writeUsageCacheBuckets(
    allocator: std.mem.Allocator,
    w: *std.Io.Writer,
    buckets: []const UsageCacheBucket,
) !void {
    _ = allocator;
    try w.writeByte('[');
    for (buckets, 0..) |row, idx| {
        if (idx > 0) try w.writeByte(',');
        try w.writeAll("{\"bucket_start\":");
        try w.print("{d}", .{row.bucket_start});
        try w.writeAll(",\"provider\":");
        try w.print("{f}", .{std.json.fmt(row.provider, .{})});
        try w.writeAll(",\"model\":");
        try w.print("{f}", .{std.json.fmt(row.model, .{})});
        try w.writeAll(",\"prompt_tokens\":");
        try w.print("{d}", .{row.prompt_tokens});
        try w.writeAll(",\"completion_tokens\":");
        try w.print("{d}", .{row.completion_tokens});
        try w.writeAll(",\"total_tokens\":");
        try w.print("{d}", .{row.total_tokens});
        try w.writeAll(",\"requests\":");
        try w.print("{d}", .{row.requests});
        try w.writeAll(",\"last_used\":");
        try w.print("{d}", .{row.last_used});
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

pub fn writeUsageCacheSnapshot(allocator: std.mem.Allocator, cache_path: []const u8, snapshot: *const UsageCacheSnapshot) !void {
    const cache_dir = std.fs.path.dirname(cache_path) orelse return error.InvalidPath;
    std_compat.fs.makeDirAbsolute(cache_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    var file = try std_compat.fs.createFileAbsolute(cache_path, .{ .truncate = true });
    defer file.close();

    var writer_buf: [8192]u8 = undefined;
    var file_writer = file.writer(&writer_buf);
    const w = &file_writer.interface;

    try w.writeAll("{\"version\":");
    try w.print("{d}", .{snapshot.version});
    try w.writeAll(",\"generated_at\":");
    try w.print("{d}", .{snapshot.generated_at});
    try w.writeAll(",\"ledger_size\":");
    try w.print("{d}", .{snapshot.ledger_size});
    try w.writeAll(",\"ledger_mtime_ns\":");
    try w.print("{d}", .{snapshot.ledger_mtime_ns});
    try w.writeAll(",\"hourly\":");
    try writeUsageCacheBuckets(allocator, w, snapshot.hourly);
    try w.writeAll(",\"daily\":");
    try writeUsageCacheBuckets(allocator, w, snapshot.daily);
    try w.writeAll("}\n");
    try w.flush();
}

fn upsertUsageBucket(
    allocator: std.mem.Allocator,
    list: *std.ArrayListUnmanaged(UsageCacheBucket),
    bucket_start: i64,
    provider: []const u8,
    model: []const u8,
    prompt_tokens: u64,
    completion_tokens: u64,
    total_tokens: u64,
    ts: i64,
) !void {
    for (list.items) |*row| {
        if (row.bucket_start == bucket_start and std.mem.eql(u8, row.provider, provider) and std.mem.eql(u8, row.model, model)) {
            row.prompt_tokens += prompt_tokens;
            row.completion_tokens += completion_tokens;
            row.total_tokens += total_tokens;
            row.requests += 1;
            if (ts > row.last_used) row.last_used = ts;
            return;
        }
    }

    try list.append(allocator, .{
        .bucket_start = bucket_start,
        .provider = try allocator.dupe(u8, provider),
        .model = try allocator.dupe(u8, model),
        .prompt_tokens = prompt_tokens,
        .completion_tokens = completion_tokens,
        .total_tokens = total_tokens,
        .requests = 1,
        .last_used = ts,
    });
}

fn pruneUsageBuckets(allocator: std.mem.Allocator, list: *std.ArrayListUnmanaged(UsageCacheBucket), min_bucket_start: i64) void {
    var i: usize = 0;
    while (i < list.items.len) {
        if (list.items[i].bucket_start < min_bucket_start) {
            allocator.free(list.items[i].provider);
            allocator.free(list.items[i].model);
            _ = list.swapRemove(i);
            continue;
        }
        i += 1;
    }
}

pub fn rebuildUsageCacheSnapshot(
    allocator: std.mem.Allocator,
    ledger_path: []const u8,
    ledger_size: u64,
    ledger_mtime_ns: i64,
    now_ts: i64,
) !UsageCacheSnapshot {
    var snapshot = emptyUsageCache(now_ts);
    snapshot.ledger_size = ledger_size;
    snapshot.ledger_mtime_ns = ledger_mtime_ns;

    var hourly_list: std.ArrayListUnmanaged(UsageCacheBucket) = .empty;
    errdefer {
        for (hourly_list.items) |row| {
            allocator.free(row.provider);
            allocator.free(row.model);
        }
        hourly_list.deinit(allocator);
    }
    var daily_list: std.ArrayListUnmanaged(UsageCacheBucket) = .empty;
    errdefer {
        for (daily_list.items) |row| {
            allocator.free(row.provider);
            allocator.free(row.model);
        }
        daily_list.deinit(allocator);
    }

    const file = std_compat.fs.openFileAbsolute(ledger_path, .{}) catch |err| switch (err) {
        error.FileNotFound => {
            snapshot.hourly = &.{};
            snapshot.daily = &.{};
            return snapshot;
        },
        else => return err,
    };
    defer file.close();

    const contents = try file.readToEndAlloc(allocator, USAGE_CACHE_MAX_LEDGER_BYTES);
    defer allocator.free(contents);

    var line_it = std.mem.splitScalar(u8, contents, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(UsageLedgerLine, allocator, line, .{
            .allocate = .alloc_if_needed,
            .ignore_unknown_fields = true,
        }) catch continue;
        defer parsed.deinit();

        const record = parsed.value;
        if (record.ts <= 0) continue;

        const provider_raw = record.provider orelse "unknown";
        const model_raw = record.model orelse "unknown";
        const provider = if (provider_raw.len > 0) provider_raw else "unknown";
        const model = if (model_raw.len > 0) model_raw else "unknown";
        const total_tokens: u64 = if (record.total_tokens > 0)
            record.total_tokens
        else
            record.prompt_tokens + record.completion_tokens;

        try upsertUsageBucket(
            allocator,
            &hourly_list,
            bucketFloor(record.ts, HOUR_SECS),
            provider,
            model,
            record.prompt_tokens,
            record.completion_tokens,
            total_tokens,
            record.ts,
        );
        try upsertUsageBucket(
            allocator,
            &daily_list,
            bucketFloor(record.ts, DAY_SECS),
            provider,
            model,
            record.prompt_tokens,
            record.completion_tokens,
            total_tokens,
            record.ts,
        );
    }

    pruneUsageBuckets(allocator, &hourly_list, now_ts - USAGE_HOURLY_RETENTION_SECS);
    pruneUsageBuckets(allocator, &daily_list, now_ts - USAGE_DAILY_RETENTION_SECS);

    snapshot.hourly = try hourly_list.toOwnedSlice(allocator);
    snapshot.daily = try daily_list.toOwnedSlice(allocator);
    return snapshot;
}

pub fn parseUsageWindow(target: []const u8) []const u8 {
    const value = query_api.valueRaw(target, "window") orelse return "24h";
    if (std.mem.eql(u8, value, "24h")) return "24h";
    if (std.mem.eql(u8, value, "7d")) return "7d";
    if (std.mem.eql(u8, value, "30d")) return "30d";
    if (std.mem.eql(u8, value, "all")) return "all";
    return "24h";
}

pub fn usageWindowMinTs(window: []const u8, now_ts: i64) ?i64 {
    if (std.mem.eql(u8, window, "all")) return null;
    if (std.mem.eql(u8, window, "24h")) return now_ts - 24 * 60 * 60;
    if (std.mem.eql(u8, window, "7d")) return now_ts - 7 * 24 * 60 * 60;
    if (std.mem.eql(u8, window, "30d")) return now_ts - 30 * 24 * 60 * 60;
    return now_ts - 24 * 60 * 60;
}

fn jsonCliConflict(
    allocator: std.mem.Allocator,
    code: []const u8,
    message: []const u8,
    stderr: ?[]const u8,
    stdout: ?[]const u8,
) ApiResponse {
    const body = managed_cli.buildJsonErrorBody(allocator, code, message, stderr, stdout) catch return helpers.serverError();
    return .{
        .status = "409 Conflict",
        .content_type = "application/json",
        .body = body,
    };
}

fn conflict(body: []const u8) ApiResponse {
    return .{
        .status = "409 Conflict",
        .content_type = "application/json",
        .body = body,
    };
}

const ParsedCronPath = struct {
    component: []const u8,
    name: []const u8,
    job_id: ?[]const u8 = null,
    action: Action,

    const Action = enum {
        collection,
        once,
        update_or_delete,
        runs,
        run,
        pause,
        resume_job,
    };
};

const ParsedCronPathOwned = struct {
    component: []u8,
    name: []u8,
    job_id: ?[]u8 = null,
    action: ParsedCronPath.Action,

    fn deinit(self: ParsedCronPathOwned, allocator: std.mem.Allocator) void {
        allocator.free(self.component);
        allocator.free(self.name);
        if (self.job_id) |job_id| allocator.free(job_id);
    }

    fn borrowed(self: ParsedCronPathOwned) ParsedCronPath {
        return .{
            .component = self.component,
            .name = self.name,
            .job_id = self.job_id,
            .action = self.action,
        };
    }
};

const LoadedCronStore = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *LoadedCronStore) void {
        self.parsed.deinit();
    }
};

fn parseCronPath(target: []const u8) ?ParsedCronPath {
    const clean = stripQuery(target);
    const prefix = "/api/instances/";
    if (!std.mem.startsWith(u8, clean, prefix)) return null;

    const rest = clean[prefix.len..];
    if (rest.len == 0) return null;

    var it = std.mem.splitScalar(u8, rest, '/');
    const component = it.next() orelse return null;
    const name = it.next() orelse return null;
    const root = it.next() orelse return null;
    if (component.len == 0 or name.len == 0 or !std.mem.eql(u8, root, "cron")) return null;

    const seg4 = it.next();
    const seg5 = it.next();
    if (it.next() != null) return null;

    if (seg4 == null) {
        return .{
            .component = component,
            .name = name,
            .action = .collection,
        };
    }

    const extra = seg4.?;
    if (extra.len == 0) return null;

    if (seg5 == null) {
        if (std.mem.eql(u8, extra, "once")) {
            return .{
                .component = component,
                .name = name,
                .action = .once,
            };
        }
        return .{
            .component = component,
            .name = name,
            .job_id = extra,
            .action = .update_or_delete,
        };
    }

    const verb = seg5.?;
    if (verb.len == 0) return null;
    const action: ParsedCronPath.Action = if (std.mem.eql(u8, verb, "run"))
        .run
    else if (std.mem.eql(u8, verb, "pause"))
        .pause
    else if (std.mem.eql(u8, verb, "resume"))
        .resume_job
    else if (std.mem.eql(u8, verb, "runs"))
        .runs
    else
        return null;

    return .{
        .component = component,
        .name = name,
        .job_id = extra,
        .action = action,
    };
}

fn parseCronPathAlloc(allocator: std.mem.Allocator, target: []const u8) !?ParsedCronPathOwned {
    const parsed = parseCronPath(target) orelse return null;

    const component = try query_api.decodePathSegmentAlloc(allocator, parsed.component);
    errdefer allocator.free(component);
    const name = try query_api.decodePathSegmentAlloc(allocator, parsed.name);
    errdefer allocator.free(name);
    const job_id = if (parsed.job_id) |value|
        try query_api.decodePathSegmentAlloc(allocator, value)
    else
        null;
    errdefer if (job_id) |owned| allocator.free(owned);

    return .{
        .component = component,
        .name = name,
        .job_id = job_id,
        .action = parsed.action,
    };
}

fn loadCronStore(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8, name: []const u8) !LoadedCronStore {
    const inst_dir = try paths.instanceDir(allocator, component, name);
    defer allocator.free(inst_dir);

    const cron_path = try std.fs.path.join(allocator, &.{ inst_dir, "cron.json" });
    defer allocator.free(cron_path);

    const raw = blk: {
        const file = std_compat.fs.openFileAbsolute(cron_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, "[]"),
            else => return err,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 4 * 1024 * 1024);
    };
    defer allocator.free(raw);

    return .{
        .parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }),
    };
}

fn cronStoreHasJobId(store: *const LoadedCronStore, job_id: []const u8) bool {
    if (store.parsed.value != .array) return false;
    for (store.parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        if (id_value == .string and std.mem.eql(u8, id_value.string, job_id)) return true;
    }
    return false;
}

fn findCronJobJson(allocator: std.mem.Allocator, store: *const LoadedCronStore, job_id: []const u8) !?[]u8 {
    if (store.parsed.value != .array) return null;
    for (store.parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        if (id_value == .string and std.mem.eql(u8, id_value.string, job_id)) {
            return try std.json.Stringify.valueAlloc(allocator, item, .{});
        }
    }
    return null;
}

fn findNewCronJobId(before: *const LoadedCronStore, after: *const LoadedCronStore) ?[]const u8 {
    if (after.parsed.value != .array) return null;
    for (after.parsed.value.array.items) |item| {
        if (item != .object) continue;
        const id_value = item.object.get("id") orelse continue;
        if (id_value != .string) continue;
        if (!cronStoreHasJobId(before, id_value.string)) return id_value.string;
    }
    return null;
}

fn cronCliBadRequest(
    allocator: std.mem.Allocator,
    code: []const u8,
    result: component_cli.RunResult,
) ApiResponse {
    const stderr_line = managed_cli.firstMeaningfulLine(result.stderr);
    const stdout_line = managed_cli.firstMeaningfulLine(result.stdout);
    const message = if (stderr_line.len > 0)
        stderr_line
    else if (stdout_line.len > 0)
        stdout_line
    else
        "cron command failed";

    const body = managed_cli.buildJsonErrorBody(allocator, code, message, result.stderr, result.stdout) catch return helpers.serverError();
    return .{
        .status = "400 Bad Request",
        .content_type = "application/json",
        .body = body,
    };
}

fn instanceCronUnsupported() ApiResponse {
    return badRequest("{\"error\":\"cron routes are only supported for nullclaw instances\"}");
}

fn instanceStatusUnsupported() ApiResponse {
    return badRequest("{\"error\":\"status route is only supported for nullclaw instances\"}");
}

fn instanceModelsUnsupported() ApiResponse {
    return badRequest("{\"error\":\"models route is only supported for nullclaw instances\"}");
}

fn handleInstanceStatus(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    _: *manager_mod.Manager,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return instanceStatusUnsupported();
    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "status", "--json" });
}

fn handleModels(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    if (!managed_cli.supports(component)) return instanceModelsUnsupported();
    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "models", "summary", "--json" });
}

fn handleCronList(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    if (!managed_cli.supports(component)) return instanceCronUnsupported();

    const captured = managed_cli.captureJson(allocator, s, paths, component, name, &.{ "cron", "list", "--json" }, .{});
    const jobs_json = switch (captured) {
        .response => |resp| return resp,
        .body => |body| body,
    };
    defer allocator.free(jobs_json);

    const body = std.fmt.allocPrint(allocator, "{{\"jobs\":{s}}}", .{jobs_json}) catch return helpers.serverError();
    return jsonOk(body);
}

fn handleCronGet(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    job_id: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return instanceCronUnsupported();
    return managed_cli.runJsonAdvanced(allocator, s, paths, component, name, &.{ "cron", "get", job_id, "--json" }, .{
        .null_is_not_found = true,
    });
}

fn handleCronRuns(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    job_id: []const u8,
    target: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return instanceCronUnsupported();
    _ = s.getInstance(component, name) orelse return notFound();

    const limit = query_api.usizeValue(target, "limit", 10);
    var limit_buf: [32]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{limit}) catch return helpers.serverError();

    return managed_cli.runJson(
        allocator,
        s,
        paths,
        component,
        name,
        &.{ "cron", "runs", job_id, "--limit", limit_str, "--json" },
    );
}

fn handleCronCreate(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    body: []const u8,
    once: bool,
) ApiResponse {
    if (!managed_cli.supports(component)) return instanceCronUnsupported();
    _ = s.getInstance(component, name) orelse return notFound();

    const CreateBody = struct {
        expression: ?[]const u8 = null,
        delay: ?[]const u8 = null,
        command: ?[]const u8 = null,
        prompt: ?[]const u8 = null,
        model: ?[]const u8 = null,
        session_target: ?[]const u8 = null,
        announce: bool = false,
        delivery_channel: ?[]const u8 = null,
        delivery_account_id: ?[]const u8 = null,
        delivery_to: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(CreateBody, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const is_agent = parsed.value.prompt != null;
    if ((parsed.value.command == null and parsed.value.prompt == null) or
        (parsed.value.command != null and parsed.value.prompt != null))
    {
        return badRequest("{\"error\":\"exactly one of command or prompt is required\"}");
    }

    const schedule_value = if (once)
        parsed.value.delay orelse return badRequest("{\"error\":\"delay is required\"}")
    else
        parsed.value.expression orelse return badRequest("{\"error\":\"expression is required\"}");

    if (once and parsed.value.expression != null) {
        return badRequest("{\"error\":\"expression is not allowed for one-shot jobs\"}");
    }
    if (!once and parsed.value.delay != null) {
        return badRequest("{\"error\":\"delay is not allowed for recurring jobs\"}");
    }
    if (!is_agent and
        (parsed.value.model != null or
            parsed.value.session_target != null or
            parsed.value.announce or
            parsed.value.delivery_channel != null or
            parsed.value.delivery_account_id != null or
            parsed.value.delivery_to != null))
    {
        return badRequest("{\"error\":\"model, session_target, and delivery fields require a prompt-based agent job\"}");
    }

    var before = loadCronStore(allocator, paths, component, name) catch return helpers.serverError();
    defer before.deinit();

    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    args.append("cron") catch return helpers.serverError();
    args.append(if (once)
        if (is_agent) "once-agent" else "once"
    else if (is_agent)
        "add-agent"
    else
        "add") catch return helpers.serverError();
    args.append(schedule_value) catch return helpers.serverError();
    args.append(if (is_agent) parsed.value.prompt.? else parsed.value.command.?) catch return helpers.serverError();
    if (parsed.value.model) |value| {
        args.append("--model") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }
    if (parsed.value.session_target) |value| {
        args.append("--session-target") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }
    if (parsed.value.announce) {
        args.append("--announce") catch return helpers.serverError();
    }
    if (parsed.value.delivery_channel) |value| {
        args.append("--channel") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }
    if (parsed.value.delivery_account_id) |value| {
        args.append("--account") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }
    if (parsed.value.delivery_to) |value| {
        args.append("--to") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }

    const captured = managed_cli.capture(allocator, s, paths, component, name, args.items);
    const result = switch (captured) {
        .response => |resp| return resp,
        .result => |value| value,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.success) return cronCliBadRequest(allocator, "cron_create_failed", result);

    var after = loadCronStore(allocator, paths, component, name) catch return helpers.serverError();
    defer after.deinit();

    const job_id = findNewCronJobId(&before, &after) orelse return helpers.serverError();
    const job_json = (findCronJobJson(allocator, &after, job_id) catch return helpers.serverError()) orelse return helpers.serverError();
    defer allocator.free(job_json);

    const response_body = std.fmt.allocPrint(allocator, "{{\"job\":{s}}}", .{job_json}) catch return helpers.serverError();
    return jsonOk(response_body);
}

fn handleCronCommandWithJob(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    job_id: []const u8,
    args: []const []const u8,
    success_status: []const u8,
    error_code: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return instanceCronUnsupported();
    _ = s.getInstance(component, name) orelse return notFound();

    var before = loadCronStore(allocator, paths, component, name) catch return helpers.serverError();
    defer before.deinit();
    if (!cronStoreHasJobId(&before, job_id)) return notFound();

    const captured = managed_cli.capture(allocator, s, paths, component, name, args);
    const result = switch (captured) {
        .response => |resp| return resp,
        .result => |value| value,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.success) return cronCliBadRequest(allocator, error_code, result);

    var after = loadCronStore(allocator, paths, component, name) catch return helpers.serverError();
    defer after.deinit();
    const job_json = (findCronJobJson(allocator, &after, job_id) catch return helpers.serverError()) orelse return notFound();
    defer allocator.free(job_json);

    const response_body = std.fmt.allocPrint(
        allocator,
        "{{\"status\":\"{s}\",\"job\":{s}}}",
        .{ success_status, job_json },
    ) catch return helpers.serverError();
    return jsonOk(response_body);
}

fn handleCronUpdate(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    job_id: []const u8,
    body: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return instanceCronUnsupported();
    _ = s.getInstance(component, name) orelse return notFound();

    const UpdateBody = struct {
        expression: ?[]const u8 = null,
        command: ?[]const u8 = null,
        prompt: ?[]const u8 = null,
        model: ?[]const u8 = null,
        enabled: ?bool = null,
        session_target: ?[]const u8 = null,
    };

    const parsed = std.json.parseFromSlice(UpdateBody, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    if (parsed.value.expression == null and
        parsed.value.command == null and
        parsed.value.prompt == null and
        parsed.value.model == null and
        parsed.value.enabled == null and
        parsed.value.session_target == null)
    {
        return badRequest("{\"error\":\"at least one field is required\"}");
    }

    var before = loadCronStore(allocator, paths, component, name) catch return helpers.serverError();
    defer before.deinit();
    if (!cronStoreHasJobId(&before, job_id)) return notFound();

    var args = std.array_list.Managed([]const u8).init(allocator);
    defer args.deinit();
    args.append("cron") catch return helpers.serverError();
    args.append("update") catch return helpers.serverError();
    args.append(job_id) catch return helpers.serverError();
    if (parsed.value.expression) |value| {
        args.append("--expression") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }
    if (parsed.value.command) |value| {
        args.append("--command") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }
    if (parsed.value.prompt) |value| {
        args.append("--prompt") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }
    if (parsed.value.model) |value| {
        args.append("--model") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }
    if (parsed.value.enabled) |value| {
        args.append(if (value) "--enable" else "--disable") catch return helpers.serverError();
    }
    if (parsed.value.session_target) |value| {
        args.append("--session-target") catch return helpers.serverError();
        args.append(value) catch return helpers.serverError();
    }

    const captured = managed_cli.capture(allocator, s, paths, component, name, args.items);
    const result = switch (captured) {
        .response => |resp| return resp,
        .result => |value| value,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.success) return cronCliBadRequest(allocator, "cron_update_failed", result);

    var after = loadCronStore(allocator, paths, component, name) catch return helpers.serverError();
    defer after.deinit();
    const job_json = (findCronJobJson(allocator, &after, job_id) catch return helpers.serverError()) orelse return notFound();
    defer allocator.free(job_json);

    const response_body = std.fmt.allocPrint(allocator, "{{\"status\":\"updated\",\"job\":{s}}}", .{job_json}) catch return helpers.serverError();
    return jsonOk(response_body);
}

fn handleCronDelete(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    job_id: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return instanceCronUnsupported();
    _ = s.getInstance(component, name) orelse return notFound();

    var before = loadCronStore(allocator, paths, component, name) catch return helpers.serverError();
    defer before.deinit();
    if (!cronStoreHasJobId(&before, job_id)) return notFound();

    const args = [_][]const u8{ "cron", "remove", job_id };
    const captured = managed_cli.capture(allocator, s, paths, component, name, &args);
    const result = switch (captured) {
        .response => |resp| return resp,
        .result => |value| value,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (!result.success) return cronCliBadRequest(allocator, "cron_remove_failed", result);

    var after = loadCronStore(allocator, paths, component, name) catch return helpers.serverError();
    defer after.deinit();
    if (cronStoreHasJobId(&after, job_id)) return helpers.serverError();

    const response_body = std.fmt.allocPrint(allocator, "{{\"status\":\"deleted\",\"id\":\"{s}\"}}", .{job_id}) catch return helpers.serverError();
    return jsonOk(response_body);
}

// ─── JSON helpers ────────────────────────────────────────────────────────────

fn pidToU64(pid: std.process.Child.Id) u64 {
    return switch (@typeInfo(@TypeOf(pid))) {
        .int => @intCast(pid),
        .pointer => @intFromPtr(pid),
        else => 0,
    };
}

fn appendInstanceJson(buf: *std.array_list.Managed(u8), entry: state_mod.InstanceEntry, snapshot: instance_runtime.Snapshot) !void {
    const status_str = @tagName(snapshot.status);
    try buf.appendSlice("{\"version\":\"");
    try appendEscaped(buf, entry.version);
    try buf.appendSlice("\",\"auto_start\":");
    try buf.appendSlice(if (entry.auto_start) "true" else "false");
    try buf.appendSlice(",\"launch_mode\":\"");
    try appendEscaped(buf, entry.launch_mode);
    try buf.appendSlice("\",\"verbose\":");
    try buf.appendSlice(if (entry.verbose) "true" else "false");
    try buf.appendSlice(",\"status\":\"");
    try buf.appendSlice(status_str);
    try buf.append('"');
    if (entry.storage_mode.len > 0) {
        try buf.appendSlice(",\"storage_mode\":\"");
        try appendEscaped(buf, entry.storage_mode);
        try buf.append('"');
    }
    if (entry.source_path.len > 0) {
        try buf.appendSlice(",\"source_path\":\"");
        try appendEscaped(buf, entry.source_path);
        try buf.append('"');
    }

    if (snapshot.pid) |pid| {
        try buf.appendSlice(",\"pid\":");
        var num_buf: [20]u8 = undefined;
        const text = try std.fmt.bufPrint(&num_buf, "{d}", .{pidToU64(pid)});
        try buf.appendSlice(text);
    }
    if (snapshot.uptime_seconds) |uptime| {
        try buf.appendSlice(",\"uptime_seconds\":");
        var num_buf: [20]u8 = undefined;
        const text = try std.fmt.bufPrint(&num_buf, "{d}", .{uptime});
        try buf.appendSlice(text);
    }
    if (snapshot.restart_count > 0) {
        try buf.appendSlice(",\"restart_count\":");
        var num_buf: [20]u8 = undefined;
        const text = try std.fmt.bufPrint(&num_buf, "{d}", .{snapshot.restart_count});
        try buf.appendSlice(text);
    }
    if (snapshot.port > 0) {
        try buf.appendSlice(",\"port\":");
        var num_buf: [10]u8 = undefined;
        const text = try std.fmt.bufPrint(&num_buf, "{d}", .{snapshot.port});
        try buf.appendSlice(text);
    }

    try buf.append('}');
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/instances — list all instances grouped by component.
pub fn handleList(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);

    buildListJson(&buf, s, manager, paths) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    return jsonOk(buf.items);
}

fn buildListJson(buf: *std.array_list.Managed(u8), s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths) !void {
    try buf.appendSlice("{\"instances\":{");

    var comp_it = s.instances.iterator();
    var first_comp = true;
    while (comp_it.next()) |comp_entry| {
        if (!first_comp) try buf.append(',');
        first_comp = false;

        try buf.append('"');
        try appendEscaped(buf, comp_entry.key_ptr.*);
        try buf.appendSlice("\":{");

        var inst_it = comp_entry.value_ptr.iterator();
        var first_inst = true;
        while (inst_it.next()) |inst_entry| {
            if (!first_inst) try buf.append(',');
            first_inst = false;

            const snapshot = instance_runtime.resolve(buf.allocator, paths, manager, comp_entry.key_ptr.*, inst_entry.key_ptr.*, inst_entry.value_ptr.*);

            try buf.append('"');
            try appendEscaped(buf, inst_entry.key_ptr.*);
            try buf.appendSlice("\":");
            try appendInstanceJson(buf, inst_entry.value_ptr.*, snapshot);
        }

        try buf.append('}');
    }

    try buf.appendSlice("}}");
}

/// GET /api/instances/{component}/{name} — detail for one instance.
pub fn handleGet(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    const entry = s.getInstance(component, name) orelse return notFound();

    const snapshot = instance_runtime.resolve(allocator, paths, manager, component, name, entry);

    var buf = std.array_list.Managed(u8).init(allocator);
    appendInstanceJson(&buf, entry, snapshot) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };
    return jsonOk(buf.items);
}

/// POST /api/instances/{component}/{name}/start
pub fn handleStart(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths, component: []const u8, name: []const u8, body: []const u8) ApiResponse {
    const entry = s.getInstance(component, name) orelse return notFound();
    if (isExternalStandaloneRunning(allocator, paths, manager, component, name, entry)) {
        return externalStandaloneConflict();
    }

    _ = nullclaw_web_channel.ensureNullclawWebChannelConfig(
        allocator,
        paths,
        s,
        component,
        name,
    ) catch return helpers.serverError();

    if (std.mem.eql(u8, component, "nullclaw")) {
        const workspace_dir = instanceWorkspaceDir(allocator, paths, component, name) catch return helpers.serverError();
        defer allocator.free(workspace_dir);
        const config_path = paths.instanceConfig(allocator, component, name) catch return helpers.serverError();
        defer allocator.free(config_path);
        _ = managed_skills.installAlwaysBundledSkills(allocator, component, workspace_dir, config_path) catch return helpers.serverError();
    }

    // Check if body overrides startup settings.
    const StartBody = struct {
        launch_mode: ?[]const u8 = null,
        verbose: ?bool = null,
    };
    var launch_cmd: []const u8 = entry.launch_mode;
    var launch_verbose = entry.verbose;
    var launch_mode_overridden = false;
    var parsed_body: ?std.json.Parsed(StartBody) = null;
    defer if (parsed_body) |*pb| pb.deinit();
    if (body.len > 0) {
        parsed_body = std.json.parseFromSlice(
            StartBody,
            allocator,
            body,
            .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
        ) catch null;
        if (parsed_body) |pb| {
            if (pb.value.launch_mode) |mode| {
                launch_cmd = mode;
                launch_mode_overridden = true;
            }
            if (pb.value.verbose) |verbose| launch_verbose = verbose;
        }
    }

    const start_binary = resolveStartBinary(allocator, s, paths, component, name, entry) catch |err| return startBinaryError(err);
    defer start_binary.deinit(allocator);
    const bin_path = start_binary.path;
    const current_version = start_binary.version;

    // Read manifest from binary to get health endpoint and port. Registry/config
    // defaults remain the deterministic path when manifest probing is unavailable.
    const known_component = registry.findKnownComponent(component);
    var health_endpoint: []const u8 = if (known_component) |known| known.default_health_endpoint else "/health";
    var port: u16 = if (known_component) |known| known.default_port else 0;
    var port_from_config: []const u8 = "";
    var manifest_launch_command: []const u8 = "";
    var manifest_launch_mode: ?[]const u8 = null;
    defer if (manifest_launch_mode) |mode| allocator.free(mode);
    const manifest_json = component_cli.exportManifest(allocator, bin_path) catch null;
    var parsed_manifest: ?std.json.Parsed(manifest_mod.Manifest) = null;
    if (manifest_json) |mj| {
        parsed_manifest = manifest_mod.parseManifest(allocator, mj) catch null;
        if (parsed_manifest) |pm| {
            health_endpoint = pm.value.health.endpoint;
            port_from_config = pm.value.health.port_from_config;
            if (pm.value.ports.len > 0) port = pm.value.ports[0].default;
            manifest_launch_command = pm.value.launch.command;
            manifest_launch_mode = launch_args_mod.fromManifestLaunch(
                allocator,
                component,
                pm.value.launch.command,
                pm.value.launch.args,
            ) catch null;
        }
    }
    defer if (manifest_json) |mj| allocator.free(mj);
    defer if (parsed_manifest) |*pm| pm.deinit();

    if (!launch_mode_overridden) {
        if (manifest_launch_mode) |mode| {
            const should_normalize_launch =
                std.mem.eql(u8, launch_cmd, manifest_launch_command) and !std.mem.eql(u8, launch_cmd, mode);
            if (should_normalize_launch) {
                launch_cmd = mode;
                _ = s.updateInstance(component, name, .{
                    .version = current_version,
                    .auto_start = entry.auto_start,
                    .launch_mode = launch_cmd,
                    .verbose = entry.verbose,
                    .storage_mode = entry.storage_mode,
                    .source_path = entry.source_path,
                }) catch {};
                s.save() catch {};
            }
        }
    }

    // Try to read actual port from instance config.json using port_from_config key.
    // If manifest probing failed, fall back to the common service port keys.
    if (port_from_config.len > 0) {
        if (instance_runtime.readPortFromConfig(allocator, paths, component, name, port_from_config)) |config_port| {
            port = config_port;
        }
    } else {
        if (instance_runtime.readPortFromConfig(allocator, paths, component, name, "port")) |config_port| {
            port = config_port;
        } else if (instance_runtime.readPortFromConfig(allocator, paths, component, name, "gateway.port")) |config_port| {
            port = config_port;
        }
    }

    var launch = launch_args_mod.resolve(allocator, launch_cmd, launch_verbose) catch return badRequest("{\"error\":\"invalid launch_mode\"}");
    defer launch.deinit();
    // The launch-mode helper decides whether this mode should be supervised via
    // an HTTP health endpoint or process liveness only.
    const effective_port = launch.effectiveHealthPort(port);

    // Resolve instance working directory so the binary can find its config.
    const inst_dir = paths.instanceDir(allocator, component, name) catch return helpers.serverError();
    defer allocator.free(inst_dir);

    manager.startInstance(component, name, bin_path, launch.argv, effective_port, health_endpoint, inst_dir, "", launch.primary_command) catch return helpers.serverError();
    return jsonOk("{\"status\":\"started\"}");
}

/// POST /api/instances/{component}/{name}/stop
pub fn handleStop(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    const entry = s.getInstance(component, name) orelse return notFound();
    if (isExternalStandaloneRunning(allocator, paths, manager, component, name, entry)) {
        return externalStandaloneConflict();
    }
    manager.stopInstance(component, name) catch return helpers.serverError();
    return jsonOk("{\"status\":\"stopped\"}");
}

/// POST /api/instances/{component}/{name}/restart
pub fn handleRestart(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths, component: []const u8, name: []const u8, body: []const u8) ApiResponse {
    const entry = s.getInstance(component, name) orelse return notFound();
    if (isExternalStandaloneRunning(allocator, paths, manager, component, name, entry)) {
        return externalStandaloneConflict();
    }
    manager.stopInstance(component, name) catch {};
    return handleStart(allocator, s, manager, paths, component, name, body);
}

/// GET /api/instances/{component}/{name}/provider-health
/// Performs a live provider credential probe for known providers.
pub fn handleProviderHealth(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    const entry = s.getInstance(component, name) orelse return notFound();

    const config_path = paths.instanceConfig(allocator, component, name) catch return helpers.serverError();
    defer allocator.free(config_path);

    const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch return .{
        .status = "404 Not Found",
        .content_type = "application/json",
        .body = "{\"error\":\"config not found\"}",
    };
    defer file.close();

    const contents = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return helpers.serverError();
    defer allocator.free(contents);

    const parsed = std.json.parseFromSlice(ProviderHealthConfig, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid config JSON\"}");
    defer parsed.deinit();

    var provider: []const u8 = "";
    var model: []const u8 = "";
    var configured = false;
    var provider_base_url: ?[]const u8 = null;

    if (parsed.value.agents) |agents| {
        if (agents.defaults) |defaults| {
            if (defaults.model) |model_cfg| {
                if (model_cfg.primary) |primary| {
                    if (primary.len > 0) {
                        if (std.mem.indexOfScalar(u8, primary, '/')) |sep| {
                            provider = primary[0..sep];
                            model = primary[sep + 1 ..];
                        } else {
                            provider = primary;
                            model = primary;
                        }
                    }
                }
            }
        }
    }

    if (parsed.value.models) |models_cfg| {
        if (models_cfg.providers) |providers| {
            if (provider.len > 0) {
                if (providers.map.get(provider)) |provider_entry| {
                    if (provider_entry.base_url) |u| {
                        if (u.len > 0) provider_base_url = u;
                    }
                    if (provider_base_url == null) {
                        if (provider_entry.api_url) |u| {
                            if (u.len > 0) provider_base_url = u;
                        }
                    }
                    if (provider_entry.api_key) |k| {
                        if (k.len > 0) {
                            configured = true;
                        }
                    }
                }
            }
            if (provider.len == 0) {
                var it = providers.map.iterator();
                while (it.next()) |provider_entry| {
                    provider = provider_entry.key_ptr.*;
                    if (provider_entry.value_ptr.base_url) |u| {
                        if (u.len > 0) provider_base_url = u;
                    }
                    if (provider_base_url == null) {
                        if (provider_entry.value_ptr.api_url) |u| {
                            if (u.len > 0) provider_base_url = u;
                        }
                    }
                    if (provider_entry.value_ptr.api_key) |k| {
                        if (k.len > 0) configured = true;
                    }
                    break;
                }
            }
            if (!configured and provider.len > 0) {
                if (providers.map.get(provider)) |provider_entry| {
                    if (provider_entry.base_url) |u| {
                        if (u.len > 0) provider_base_url = u;
                    }
                    if (provider_base_url == null) {
                        if (provider_entry.api_url) |u| {
                            if (u.len > 0) provider_base_url = u;
                        }
                    }
                    if (provider_entry.api_key) |k| {
                        if (k.len > 0) {
                            configured = true;
                        }
                    }
                }
            }
        }
    }
    if (provider.len > 0 and !providerRequiresApiKey(provider, provider_base_url)) {
        configured = true;
    }

    const running = instance_runtime.resolve(allocator, paths, manager, component, name, entry).status == .running;

    var status: []const u8 = "unknown";
    var reason: []const u8 = "not_probed";
    var live_ok = false;
    var status_code: ?u16 = null;

    if (provider.len == 0) {
        status = "error";
        reason = "provider_not_detected";
    } else if (!running) {
        status = "error";
        reason = "instance_not_running";
    } else {
        const probe = probeComponentProvider(allocator, paths, entry, component, name, provider, model);
        live_ok = probe.live_ok;
        status_code = probe.status_code;
        status = if (probe.live_ok) "ok" else "error";
        reason = probe.reason;
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    buf.appendSlice("{\"provider\":\"") catch return helpers.serverError();
    appendEscaped(&buf, provider) catch return helpers.serverError();
    buf.appendSlice("\",\"model\":\"") catch return helpers.serverError();
    appendEscaped(&buf, model) catch return helpers.serverError();
    buf.appendSlice("\",\"configured\":") catch return helpers.serverError();
    buf.appendSlice(if (configured) "true" else "false") catch return helpers.serverError();
    buf.appendSlice(",\"running\":") catch return helpers.serverError();
    buf.appendSlice(if (running) "true" else "false") catch return helpers.serverError();
    buf.appendSlice(",\"live_ok\":") catch return helpers.serverError();
    buf.appendSlice(if (live_ok) "true" else "false") catch return helpers.serverError();
    buf.appendSlice(",\"status\":\"") catch return helpers.serverError();
    appendEscaped(&buf, status) catch return helpers.serverError();
    buf.appendSlice("\",\"reason\":\"") catch return helpers.serverError();
    appendEscaped(&buf, reason) catch return helpers.serverError();
    buf.appendSlice("\"") catch return helpers.serverError();
    if (status_code) |code| {
        buf.print(",\"status_code\":{d}", .{code}) catch return helpers.serverError();
    }
    buf.appendSlice("}") catch return helpers.serverError();

    return jsonOk(buf.items);
}

/// GET /api/instances/{component}/{name}/usage?window=24h|7d|30d|all
/// Uses a persistent nullhub cache (hourly + daily buckets) rebuilt from token ledger.
pub fn handleUsage(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8, target: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();

    const now_ts = std_compat.time.timestamp();
    const window = parseUsageWindow(target);
    const min_ts = usageWindowMinTs(window, now_ts);

    const inst_dir = paths.instanceDir(allocator, component, name) catch return helpers.serverError();
    defer allocator.free(inst_dir);
    const ledger_path = resolveUsageLedgerPath(allocator, inst_dir) catch return helpers.serverError();
    defer allocator.free(ledger_path);
    const cache_path = usageCachePath(allocator, paths, component, name) catch return helpers.serverError();
    defer allocator.free(cache_path);

    var snapshot = emptyUsageCache(now_ts);
    defer snapshot.deinit(allocator);
    var has_cache = false;
    if (loadUsageCacheSnapshot(allocator, cache_path, now_ts) catch null) |loaded| {
        snapshot = loaded;
        has_cache = true;
    }

    var ledger_exists = false;
    var ledger_size: u64 = 0;
    var ledger_mtime_ns: i64 = 0;
    const ledger_file = std_compat.fs.openFileAbsolute(ledger_path, .{}) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return helpers.serverError(),
    };
    if (ledger_file) |file| {
        defer file.close();
        const stat = file.stat() catch return helpers.serverError();
        ledger_exists = true;
        ledger_size = stat.size;
        ledger_mtime_ns = @intCast(stat.mtime);
    }

    var should_rebuild = false;
    if (ledger_exists) {
        if (!has_cache) {
            should_rebuild = true;
        } else if (snapshot.ledger_size != ledger_size or snapshot.ledger_mtime_ns != ledger_mtime_ns) {
            should_rebuild = true;
        }
    } else if (has_cache) {
        snapshot.deinit(allocator);
        snapshot = emptyUsageCache(now_ts);
        has_cache = false;
    }

    if (should_rebuild) {
        if (has_cache) snapshot.deinit(allocator);
        snapshot = rebuildUsageCacheSnapshot(allocator, ledger_path, ledger_size, ledger_mtime_ns, now_ts) catch return helpers.serverError();
        has_cache = true;
        writeUsageCacheSnapshot(allocator, cache_path, &snapshot) catch {};
    }

    var aggregates: std.StringHashMapUnmanaged(UsageAggregate) = .{};
    defer {
        var it_cleanup = aggregates.iterator();
        while (it_cleanup.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.provider);
            allocator.free(entry.value_ptr.model);
        }
        aggregates.deinit(allocator);
    }

    var total_prompt: u64 = 0;
    var total_completion: u64 = 0;
    var total_tokens: u64 = 0;
    var total_requests: u64 = 0;

    const source_buckets = if (isShortUsageWindow(window)) snapshot.hourly else snapshot.daily;
    for (source_buckets) |record| {
        if (min_ts) |cutoff| {
            if (record.last_used < cutoff) continue;
        }

        const provider = if (record.provider.len > 0) record.provider else "unknown";
        const model = if (record.model.len > 0) record.model else "unknown";
        const record_total: u64 = if (record.total_tokens > 0)
            record.total_tokens
        else
            record.prompt_tokens + record.completion_tokens;

        total_prompt += record.prompt_tokens;
        total_completion += record.completion_tokens;
        total_tokens += record_total;
        const req_count: u64 = if (record.requests > 0) record.requests else 1;
        total_requests += req_count;

        const key = std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ provider, model }) catch continue;
        if (aggregates.getPtr(key)) |agg| {
            allocator.free(key);
            agg.prompt_tokens += record.prompt_tokens;
            agg.completion_tokens += record.completion_tokens;
            agg.total_tokens += record_total;
            agg.requests += req_count;
            if (record.last_used > agg.last_used) agg.last_used = record.last_used;
        } else {
            const provider_copy = allocator.dupe(u8, provider) catch {
                allocator.free(key);
                continue;
            };
            errdefer allocator.free(provider_copy);
            const model_copy = allocator.dupe(u8, model) catch {
                allocator.free(key);
                allocator.free(provider_copy);
                continue;
            };
            errdefer allocator.free(model_copy);

            aggregates.put(allocator, key, .{
                .provider = provider_copy,
                .model = model_copy,
                .prompt_tokens = record.prompt_tokens,
                .completion_tokens = record.completion_tokens,
                .total_tokens = record_total,
                .requests = req_count,
                .last_used = record.last_used,
            }) catch {
                allocator.free(key);
                allocator.free(provider_copy);
                allocator.free(model_copy);
            };
        }
    }

    var buf = std.array_list.Managed(u8).init(allocator);
    buf.appendSlice("{\"window\":\"") catch return helpers.serverError();
    appendEscaped(&buf, window) catch return helpers.serverError();
    buf.print("\",\"generated_at\":{d},\"rows\":[", .{now_ts}) catch return helpers.serverError();

    var it = aggregates.iterator();
    var first_row = true;
    while (it.next()) |entry| {
        if (!first_row) buf.append(',') catch return helpers.serverError();
        first_row = false;

        const row = entry.value_ptr.*;
        buf.appendSlice("{\"provider\":\"") catch return helpers.serverError();
        appendEscaped(&buf, row.provider) catch return helpers.serverError();
        buf.appendSlice("\",\"model\":\"") catch return helpers.serverError();
        appendEscaped(&buf, row.model) catch return helpers.serverError();
        buf.appendSlice("\",\"prompt_tokens\":") catch return helpers.serverError();
        buf.print("{d}", .{row.prompt_tokens}) catch return helpers.serverError();
        buf.appendSlice(",\"completion_tokens\":") catch return helpers.serverError();
        buf.print("{d}", .{row.completion_tokens}) catch return helpers.serverError();
        buf.appendSlice(",\"total_tokens\":") catch return helpers.serverError();
        buf.print("{d}", .{row.total_tokens}) catch return helpers.serverError();
        buf.appendSlice(",\"requests\":") catch return helpers.serverError();
        buf.print("{d}", .{row.requests}) catch return helpers.serverError();
        buf.appendSlice(",\"last_used\":") catch return helpers.serverError();
        buf.print("{d}", .{row.last_used}) catch return helpers.serverError();
        buf.appendSlice("}") catch return helpers.serverError();
    }

    buf.appendSlice("],\"totals\":{\"prompt_tokens\":") catch return helpers.serverError();
    buf.print("{d}", .{total_prompt}) catch return helpers.serverError();
    buf.appendSlice(",\"completion_tokens\":") catch return helpers.serverError();
    buf.print("{d}", .{total_completion}) catch return helpers.serverError();
    buf.appendSlice(",\"total_tokens\":") catch return helpers.serverError();
    buf.print("{d}", .{total_tokens}) catch return helpers.serverError();
    buf.appendSlice(",\"requests\":") catch return helpers.serverError();
    buf.print("{d}", .{total_requests}) catch return helpers.serverError();
    buf.appendSlice("}}") catch return helpers.serverError();

    return jsonOk(buf.items);
}

/// GET /api/instances/{component}/{name}/history?limit=N&offset=N
/// GET /api/instances/{component}/{name}/history?session_id=...&limit=N&offset=N
pub fn handleHistory(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8, target: []const u8) ApiResponse {
    const session_id = query_api.valueAlloc(allocator, target, "session_id") catch return helpers.serverError();
    defer if (session_id) |value| allocator.free(value);

    const limit = query_api.usizeValue(target, "limit", if (session_id != null) 100 else 50);
    const offset = query_api.usizeValue(target, "offset", 0);

    var limit_buf: [32]u8 = undefined;
    var offset_buf: [32]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{limit}) catch return helpers.serverError();
    const offset_str = std.fmt.bufPrint(&offset_buf, "{d}", .{offset}) catch return helpers.serverError();

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);

    args.append(allocator, "history") catch return helpers.serverError();
    if (session_id) |value| {
        if (value.len == 0) return badRequest("{\"error\":\"session_id is required\"}");
        args.append(allocator, "show") catch return helpers.serverError();
        args.append(allocator, value) catch return helpers.serverError();
    } else {
        args.append(allocator, "list") catch return helpers.serverError();
    }
    args.append(allocator, "--limit") catch return helpers.serverError();
    args.append(allocator, limit_str) catch return helpers.serverError();
    args.append(allocator, "--offset") catch return helpers.serverError();
    args.append(allocator, offset_str) catch return helpers.serverError();
    args.append(allocator, "--json") catch return helpers.serverError();

    return managed_cli.runJson(allocator, s, paths, component, name, args.items);
}

/// GET /api/instances/{component}/{name}/onboarding
pub fn handleOnboarding(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ApiResponse {
    if (s.getInstance(component, name) == null) return notFound();

    var status = readNullclawOnboardingStatus(allocator, paths, component, name) catch
        return helpers.serverError();
    defer status.deinit(allocator);

    const body = std.json.Stringify.valueAlloc(allocator, .{
        .supported = status.supported,
        .pending = status.pending,
        .completed = status.completed,
        .bootstrap_exists = status.bootstrap_exists,
        .bootstrap_seeded_at = status.bootstrap_seeded_at,
        .onboarding_completed_at = status.onboarding_completed_at,
        .starter_message = if (status.supported) "Wake up, my friend!" else null,
    }, .{}) catch return helpers.serverError();

    return jsonOk(body);
}

/// GET /api/instances/{component}/{name}/memory?stats=1
/// GET /api/instances/{component}/{name}/memory?key=...
/// GET /api/instances/{component}/{name}/memory?q=...&limit=N
/// GET /api/instances/{component}/{name}/memory?query=...&limit=N
/// GET /api/instances/{component}/{name}/memory?category=...&limit=N&offset=N&include_internal=1
pub fn handleMemory(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8, target: []const u8) ApiResponse {
    const key = query_api.valueAlloc(allocator, target, "key") catch return helpers.serverError();
    defer if (key) |value| allocator.free(value);
    const search_query_q = query_api.valueAlloc(allocator, target, "q") catch return helpers.serverError();
    defer if (search_query_q) |value| allocator.free(value);
    const search_query = query_api.valueAlloc(allocator, target, "query") catch return helpers.serverError();
    defer if (search_query) |value| allocator.free(value);
    const category = query_api.valueAlloc(allocator, target, "category") catch return helpers.serverError();
    defer if (category) |value| allocator.free(value);
    const session_id = query_api.valueAlloc(allocator, target, "session_id") catch return helpers.serverError();
    defer if (session_id) |value| allocator.free(value);
    const effective_query = if (search_query_q) |value| value else search_query;
    const include_internal = query_api.boolValue(target, "include_internal");

    const default_limit: usize = if (effective_query != null) 6 else 20;
    const limit = query_api.usizeValue(target, "limit", default_limit);
    const offset = query_api.usizeValue(target, "offset", 0);

    var limit_buf: [32]u8 = undefined;
    const limit_str = std.fmt.bufPrint(&limit_buf, "{d}", .{limit}) catch return helpers.serverError();
    var offset_buf: [32]u8 = undefined;
    const offset_str = std.fmt.bufPrint(&offset_buf, "{d}", .{offset}) catch return helpers.serverError();

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);

    args.append(allocator, "memory") catch return helpers.serverError();
    if (query_api.boolValue(target, "stats")) {
        args.append(allocator, "stats") catch return helpers.serverError();
        args.append(allocator, "--json") catch return helpers.serverError();
        return managed_cli.runJson(allocator, s, paths, component, name, args.items);
    }

    if (key) |value| {
        if (value.len == 0) return badRequest("{\"error\":\"key is required\"}");
        if (session_id) |session| {
            if (session.len == 0) return badRequest("{\"error\":\"session_id is required\"}");
        }
        args.append(allocator, "get") catch return helpers.serverError();
        args.append(allocator, value) catch return helpers.serverError();
        if (session_id) |session| {
            args.append(allocator, "--session") catch return helpers.serverError();
            args.append(allocator, session) catch return helpers.serverError();
        }
        args.append(allocator, "--json") catch return helpers.serverError();
        return managed_cli.runJsonAdvanced(allocator, s, paths, component, name, args.items, .{
            .null_is_not_found = true,
        });
    }

    if (effective_query) |value| {
        if (value.len == 0) return badRequest("{\"error\":\"query is required\"}");
        args.append(allocator, "search") catch return helpers.serverError();
        args.append(allocator, value) catch return helpers.serverError();
        args.append(allocator, "--limit") catch return helpers.serverError();
        args.append(allocator, limit_str) catch return helpers.serverError();
        if (session_id) |session| {
            if (session.len == 0) return badRequest("{\"error\":\"session_id is required\"}");
            args.append(allocator, "--session") catch return helpers.serverError();
            args.append(allocator, session) catch return helpers.serverError();
        }
        args.append(allocator, "--json") catch return helpers.serverError();
        return managed_cli.runJson(allocator, s, paths, component, name, args.items);
    }

    args.append(allocator, "list") catch return helpers.serverError();
    if (category) |value| {
        if (value.len > 0) {
            args.append(allocator, "--category") catch return helpers.serverError();
            args.append(allocator, value) catch return helpers.serverError();
        }
    }
    if (session_id) |session| {
        if (session.len == 0) return badRequest("{\"error\":\"session_id is required\"}");
        args.append(allocator, "--session") catch return helpers.serverError();
        args.append(allocator, session) catch return helpers.serverError();
    }
    if (include_internal) {
        args.append(allocator, "--include-internal") catch return helpers.serverError();
    }
    args.append(allocator, "--limit") catch return helpers.serverError();
    args.append(allocator, limit_str) catch return helpers.serverError();
    if (offset > 0) {
        args.append(allocator, "--offset") catch return helpers.serverError();
        args.append(allocator, offset_str) catch return helpers.serverError();
    }
    args.append(allocator, "--json") catch return helpers.serverError();
    return managed_cli.runJson(allocator, s, paths, component, name, args.items);
}

fn handleMemoryWrite(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    method: []const u8,
    target: []const u8,
    body: []const u8,
) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();

    const parsed = std.json.parseFromSlice(struct {
        key: ?[]const u8 = null,
        content: ?[]const u8 = null,
        category: ?[]const u8 = null,
        session_id: ?[]const u8 = null,
    }, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const key_query = query_api.valueAlloc(allocator, target, "key") catch return helpers.serverError();
    defer if (key_query) |value| allocator.free(value);
    const session_query = query_api.valueAlloc(allocator, target, "session_id") catch return helpers.serverError();
    defer if (session_query) |value| allocator.free(value);

    const key = if (key_query) |value| if (value.len > 0) value else null else if (parsed.value.key) |value| if (value.len > 0) value else null else null;
    if (key == null) return badRequest("{\"error\":\"key is required\"}");

    const session_id = if (session_query) |value| if (value.len > 0) value else null else if (parsed.value.session_id) |value| if (value.len > 0) value else null else null;

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    args.append(allocator, "memory") catch return helpers.serverError();

    if (std.mem.eql(u8, method, "POST")) {
        if (parsed.value.content == null) return badRequest("{\"error\":\"content is required\"}");
        args.append(allocator, "store") catch return helpers.serverError();
        args.append(allocator, key.?) catch return helpers.serverError();
        args.append(allocator, parsed.value.content.?) catch return helpers.serverError();
    } else if (std.mem.eql(u8, method, "PATCH")) {
        if (parsed.value.content == null) return badRequest("{\"error\":\"content is required\"}");
        args.append(allocator, "update") catch return helpers.serverError();
        args.append(allocator, key.?) catch return helpers.serverError();
        args.append(allocator, parsed.value.content.?) catch return helpers.serverError();
    } else if (std.mem.eql(u8, method, "DELETE")) {
        args.append(allocator, "delete") catch return helpers.serverError();
        args.append(allocator, key.?) catch return helpers.serverError();
    } else {
        return methodNotAllowed();
    }

    if (parsed.value.category) |value| {
        if (value.len > 0) {
            args.append(allocator, "--category") catch return helpers.serverError();
            args.append(allocator, value) catch return helpers.serverError();
        }
    }
    if (session_id) |value| {
        args.append(allocator, "--session") catch return helpers.serverError();
        args.append(allocator, value) catch return helpers.serverError();
    }
    args.append(allocator, "--json") catch return helpers.serverError();
    return managed_cli.runJsonAdvanced(allocator, s, paths, component, name, args.items, .{
        .not_found_error_codes = if (std.mem.eql(u8, method, "PATCH"))
            &.{"memory_not_found"}
        else
            &.{},
    });
}

fn handleMemoryMaintenance(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    subcommand: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"memory maintenance is only supported for nullclaw instances\"}");
    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "memory", subcommand, "--json" });
}

fn handleDoctor(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"doctor is only supported for nullclaw instances\"}");
    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "doctor", "--json" });
}

fn handleCapabilities(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"capabilities are only supported for nullclaw instances\"}");
    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "capabilities", "--json" });
}

fn handleMcp(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8, target: []const u8) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"mcp inspection is only supported for nullclaw instances\"}");
    const server_name = query_api.valueAlloc(allocator, target, "name") catch return helpers.serverError();
    defer if (server_name) |value| allocator.free(value);

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    args.append(allocator, "mcp") catch return helpers.serverError();
    if (server_name) |value| {
        if (value.len == 0) return badRequest("{\"error\":\"name is required\"}");
        args.append(allocator, "info") catch return helpers.serverError();
        args.append(allocator, value) catch return helpers.serverError();
    } else {
        args.append(allocator, "list") catch return helpers.serverError();
    }
    args.append(allocator, "--json") catch return helpers.serverError();
    return managed_cli.runJsonAdvanced(allocator, s, paths, component, name, args.items, .{
        .not_found_error_codes = if (server_name != null)
            &.{"mcp_not_found"}
        else
            &.{},
    });
}

fn handleModelsAction(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    method: []const u8,
    target: []const u8,
) ApiResponse {
    if (!std.mem.eql(u8, method, "GET") and !std.mem.eql(u8, method, "POST")) return methodNotAllowed();
    if (!managed_cli.supports(component)) return instanceModelsUnsupported();

    if (std.mem.eql(u8, method, "POST")) {
        return .{
            .status = "501 Not Implemented",
            .content_type = "application/json",
            .body = "{\"error\":\"models refresh remains CLI-only for managed instances\"}",
        };
    }

    const model_name = query_api.valueAlloc(allocator, target, "name") catch return helpers.serverError();
    defer if (model_name) |value| allocator.free(value);
    if (model_name) |value| {
        if (value.len == 0) return badRequest("{\"error\":\"name is required\"}");
        return managed_cli.runJson(allocator, s, paths, component, name, &.{ "models", "info", value, "--json" });
    }
    return handleModels(allocator, s, paths, component, name);
}

fn handleAgentInvoke(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    body: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"agent route is only supported for nullclaw instances\"}");

    const parsed = std.json.parseFromSlice(struct {
        message: ?[]const u8 = null,
        session_key: ?[]const u8 = null,
        provider: ?[]const u8 = null,
        model: ?[]const u8 = null,
        temperature: ?[]const u8 = null,
        agent: ?[]const u8 = null,
    }, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const message = parsed.value.message orelse return badRequest("{\"error\":\"message is required\"}");
    if (message.len == 0) return badRequest("{\"error\":\"message is required\"}");

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    args.append(allocator, "agent") catch return helpers.serverError();
    args.append(allocator, "invoke") catch return helpers.serverError();
    args.append(allocator, "--message") catch return helpers.serverError();
    args.append(allocator, message) catch return helpers.serverError();
    if (parsed.value.session_key) |value| {
        if (value.len > 0) {
            args.append(allocator, "--session") catch return helpers.serverError();
            args.append(allocator, value) catch return helpers.serverError();
        }
    }
    if (parsed.value.provider) |value| {
        if (value.len > 0) {
            args.append(allocator, "--provider") catch return helpers.serverError();
            args.append(allocator, value) catch return helpers.serverError();
        }
    }
    if (parsed.value.model) |value| {
        if (value.len > 0) {
            args.append(allocator, "--model") catch return helpers.serverError();
            args.append(allocator, value) catch return helpers.serverError();
        }
    }
    if (parsed.value.temperature) |value| {
        if (value.len > 0) {
            args.append(allocator, "--temperature") catch return helpers.serverError();
            args.append(allocator, value) catch return helpers.serverError();
        }
    }
    if (parsed.value.agent) |value| {
        if (value.len > 0) {
            args.append(allocator, "--agent") catch return helpers.serverError();
            args.append(allocator, value) catch return helpers.serverError();
        }
    }
    args.append(allocator, "--json") catch return helpers.serverError();
    return managed_cli.runJson(allocator, s, paths, component, name, args.items);
}

fn handleAgentSessions(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    method: []const u8,
    target: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"agent sessions are only supported for nullclaw instances\"}");
    const session_id = query_api.valueAlloc(allocator, target, "session_id") catch return helpers.serverError();
    defer if (session_id) |value| allocator.free(value);

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    args.append(allocator, "agent") catch return helpers.serverError();
    args.append(allocator, "sessions") catch return helpers.serverError();

    if (std.mem.eql(u8, method, "GET")) {
        if (session_id) |value| {
            if (value.len == 0) return badRequest("{\"error\":\"session_id is required\"}");
            args.append(allocator, "get") catch return helpers.serverError();
            args.append(allocator, value) catch return helpers.serverError();
        } else {
            args.append(allocator, "list") catch return helpers.serverError();
        }
    } else if (std.mem.eql(u8, method, "DELETE")) {
        if (session_id == null or session_id.?.len == 0) return badRequest("{\"error\":\"session_id is required\"}");
        args.append(allocator, "terminate") catch return helpers.serverError();
        args.append(allocator, session_id.?) catch return helpers.serverError();
    } else {
        return methodNotAllowed();
    }

    args.append(allocator, "--json") catch return helpers.serverError();
    return managed_cli.runJsonAdvanced(allocator, s, paths, component, name, args.items, .{
        .not_found_error_codes = if (session_id != null)
            &.{"session_not_found"}
        else
            &.{},
    });
}

fn handleConfigSet(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    body: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"config mutation is only supported for nullclaw instances\"}");

    const parsed = std.json.parseFromSlice(struct {
        path: ?[]const u8 = null,
        value: ?std.json.Value = null,
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const path_value = parsed.value.path orelse return badRequest("{\"error\":\"path is required\"}");
    const raw_value = parsed.value.value orelse return badRequest("{\"error\":\"value is required\"}");
    const raw_json = std.json.Stringify.valueAlloc(allocator, raw_value, .{}) catch return helpers.serverError();
    defer allocator.free(raw_json);

    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "config", "set", path_value, raw_json, "--json" });
}

fn handleConfigUnset(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    body: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"config mutation is only supported for nullclaw instances\"}");

    const parsed = std.json.parseFromSlice(struct {
        path: ?[]const u8 = null,
    }, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const path_value = parsed.value.path orelse return badRequest("{\"error\":\"path is required\"}");
    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "config", "unset", path_value, "--json" });
}

fn handleConfigReload(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"config reload is only supported for nullclaw instances\"}");
    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "config", "reload", "--json" });
}

fn handleConfigValidate(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    body: []const u8,
) ApiResponse {
    if (!managed_cli.supports(component)) return badRequest("{\"error\":\"config validate is only supported for nullclaw instances\"}");
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        return managed_cli.runJson(allocator, s, paths, component, name, &.{ "config", "validate", "--json" });
    }
    return managed_cli.runJson(allocator, s, paths, component, name, &.{ "config", "validate", body, "--json" });
}

fn instanceWorkspaceDir(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8, name: []const u8) ![]u8 {
    const inst_dir = try paths.instanceDir(allocator, component, name);
    defer allocator.free(inst_dir);
    return try std.fs.path.join(allocator, &.{ inst_dir, "workspace" });
}

fn handleSkillsCatalog(allocator: std.mem.Allocator, component: []const u8) ApiResponse {
    const bundled = managed_skills.catalogForComponent(component);
    var entries = std.array_list.Managed(managed_skills.CatalogEntry).init(allocator);
    defer entries.deinit();
    for (bundled) |skill| {
        entries.append(skill.entry) catch return helpers.serverError();
    }
    const body = std.json.Stringify.valueAlloc(allocator, entries.items, .{
        .emit_null_optional_fields = false,
    }) catch return helpers.serverError();
    return jsonOk(body);
}

fn handleChannels(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    channel_type: ?[]const u8,
) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();
    if (!managed_cli.supports(component)) {
        return badRequest("{\"error\":\"channel inspection is only supported for nullclaw instances\"}");
    }

    return if (channel_type) |value|
        managed_cli.runJsonAdvanced(allocator, s, paths, component, name, &.{ "channel", "info", value, "--json" }, .{
            .not_found_error_codes = &.{"channel_type_not_found"},
        })
    else
        managed_cli.runJson(allocator, s, paths, component, name, &.{ "channel", "list", "--json" });
}

fn handleSkillsInstall(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    body: []const u8,
) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();
    if (!std.mem.eql(u8, component, "nullclaw")) {
        return badRequest("{\"error\":\"skill installation is only supported for nullclaw instances\"}");
    }

    const parsed = std.json.parseFromSlice(struct {
        bundled: ?[]const u8 = null,
        clawhub_slug: ?[]const u8 = null,
        source: ?[]const u8 = null,
        url: ?[]const u8 = null,
        name: ?[]const u8 = null,
    }, allocator, body, .{
        .ignore_unknown_fields = true,
    }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const bundled_name = if (parsed.value.bundled) |value| if (value.len > 0) value else null else null;
    const clawhub_slug = if (parsed.value.clawhub_slug) |value| if (value.len > 0) value else null else null;
    const source = if (parsed.value.source) |value| if (value.len > 0) value else null else null;
    const url = if (parsed.value.url) |value| if (value.len > 0) value else null else null;
    const skill_query = if (parsed.value.name) |value| if (value.len > 0) value else null else null;

    var selected: usize = 0;
    if (bundled_name != null) selected += 1;
    if (clawhub_slug != null) selected += 1;
    if (source != null) selected += 1;
    if (url != null) selected += 1;
    if (skill_query != null) selected += 1;
    if (selected != 1) {
        return badRequest("{\"error\":\"provide exactly one of bundled, clawhub_slug, source, url, or name\"}");
    }

    if (bundled_name) |value| {
        const workspace_dir = instanceWorkspaceDir(allocator, paths, component, name) catch return helpers.serverError();
        defer allocator.free(workspace_dir);
        const disposition = managed_skills.installBundledSkill(allocator, workspace_dir, value) catch |err| switch (err) {
            error.SkillNotFound => return notFound(),
            else => return helpers.serverError(),
        };
        const config_path = paths.instanceConfig(allocator, component, name) catch return helpers.serverError();
        defer allocator.free(config_path);
        const restart_required = managed_skills.syncBundledSkillRuntime(allocator, config_path, value) catch |err| switch (err) {
            error.SkillNotFound => return notFound(),
            else => return helpers.serverError(),
        };
        const resp_body = std.json.Stringify.valueAlloc(allocator, .{
            .status = @tagName(disposition),
            .bundled = value,
            .restart_required = restart_required,
        }, .{}) catch return helpers.serverError();
        return jsonOk(resp_body);
    }

    if (clawhub_slug) |value| {
        const workspace_dir = instanceWorkspaceDir(allocator, paths, component, name) catch return helpers.serverError();
        defer allocator.free(workspace_dir);

        const result = std_compat.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "clawhub", "install", value },
            .cwd = workspace_dir,
            .max_output_bytes = 64 * 1024,
        }) catch |err| switch (err) {
            error.FileNotFound => return jsonCliConflict(
                allocator,
                "clawhub_not_available",
                "clawhub CLI is not installed on the nullhub host",
                null,
                null,
            ),
            else => return jsonCliConflict(
                allocator,
                "clawhub_exec_failed",
                "Failed to execute clawhub install",
                null,
                null,
            ),
        };
        defer {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
        }

        const success = switch (result.term) {
            .exited => |code| code == 0,
            else => false,
        };
        if (!success) {
            return jsonCliConflict(
                allocator,
                "clawhub_install_failed",
                "clawhub install failed",
                result.stderr,
                result.stdout,
            );
        }

        const resp_body = std.json.Stringify.valueAlloc(allocator, .{
            .status = "installed",
            .clawhub_slug = value,
        }, .{}) catch return helpers.serverError();
        return jsonOk(resp_body);
    }

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    args.append(allocator, "skills") catch return helpers.serverError();
    args.append(allocator, "install") catch return helpers.serverError();
    if (skill_query) |value| {
        args.append(allocator, "--name") catch return helpers.serverError();
        args.append(allocator, value) catch return helpers.serverError();
    } else {
        args.append(allocator, if (source) |value| value else url.?) catch return helpers.serverError();
    }

    const captured = managed_cli.capture(allocator, s, paths, component, name, args.items);
    const result = switch (captured) {
        .response => |resp| return resp,
        .result => |value| value,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.success) {
        return jsonCliConflict(
            allocator,
            "skills_install_failed",
            if (skill_query != null) "Failed to install skill from registry search" else "Failed to install skill from source",
            result.stderr,
            result.stdout,
        );
    }

    const resp_body = if (skill_query) |value|
        std.json.Stringify.valueAlloc(allocator, .{
            .status = "installed",
            .name = value,
        }, .{}) catch return helpers.serverError()
    else if (source) |value|
        std.json.Stringify.valueAlloc(allocator, .{
            .status = "installed",
            .source = value,
        }, .{}) catch return helpers.serverError()
    else
        std.json.Stringify.valueAlloc(allocator, .{
            .status = "installed",
            .source = url.?,
        }, .{}) catch return helpers.serverError();
    return jsonOk(resp_body);
}

fn handleSkillsRemove(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    target: []const u8,
) ApiResponse {
    if (!std.mem.eql(u8, component, "nullclaw")) {
        return badRequest("{\"error\":\"skill removal is only supported for nullclaw instances\"}");
    }
    const skill_name = query_api.valueAlloc(allocator, target, "name") catch return helpers.serverError();
    defer if (skill_name) |value| allocator.free(value);
    if (skill_name == null or skill_name.?.len == 0) {
        return badRequest("{\"error\":\"name is required\"}");
    }

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);
    args.append(allocator, "skills") catch return helpers.serverError();
    args.append(allocator, "remove") catch return helpers.serverError();
    args.append(allocator, skill_name.?) catch return helpers.serverError();

    const captured = managed_cli.capture(allocator, s, paths, component, name, args.items);
    const result = switch (captured) {
        .response => |resp| return resp,
        .result => |value| value,
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.success) {
        return jsonCliConflict(
            allocator,
            "skills_remove_failed",
            "Failed to remove skill",
            result.stderr,
            result.stdout,
        );
    }

    const resp_body = std.json.Stringify.valueAlloc(allocator, .{
        .status = "removed",
        .name = skill_name.?,
    }, .{}) catch return helpers.serverError();
    return jsonOk(resp_body);
}

/// GET /api/instances/{component}/{name}/skills
/// GET /api/instances/{component}/{name}/skills?name=...
/// GET /api/instances/{component}/{name}/skills?catalog=1
pub fn handleSkills(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, name: []const u8, target: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();
    if (query_api.boolValue(target, "catalog")) return handleSkillsCatalog(allocator, component);
    const skill_name = query_api.valueAlloc(allocator, target, "name") catch return helpers.serverError();
    defer if (skill_name) |value| allocator.free(value);

    var args: std.ArrayListUnmanaged([]const u8) = .empty;
    defer args.deinit(allocator);

    args.append(allocator, "skills") catch return helpers.serverError();
    if (skill_name) |value| {
        if (value.len == 0) return badRequest("{\"error\":\"name is required\"}");
        args.append(allocator, "info") catch return helpers.serverError();
        args.append(allocator, value) catch return helpers.serverError();
    } else {
        args.append(allocator, "list") catch return helpers.serverError();
    }
    args.append(allocator, "--json") catch return helpers.serverError();
    return managed_cli.runJsonAdvanced(allocator, s, paths, component, name, args.items, .{
        .null_is_not_found = skill_name != null,
    });
}

const DeleteDependent = struct {
    component: []const u8,
    name: []const u8,
    relation: []const u8,
};

const DeleteDependencyList = struct {
    items: std.ArrayListUnmanaged(DeleteDependent) = .empty,

    fn append(
        self: *DeleteDependencyList,
        allocator: std.mem.Allocator,
        component: []const u8,
        name: []const u8,
        relation: []const u8,
    ) !void {
        const owned_name = try allocator.dupe(u8, name);
        errdefer allocator.free(owned_name);
        try self.items.append(allocator, .{
            .component = component,
            .name = owned_name,
            .relation = relation,
        });
    }

    fn deinit(self: *DeleteDependencyList, allocator: std.mem.Allocator) void {
        for (self.items.items) |dep| allocator.free(dep.name);
        self.items.deinit(allocator);
        self.* = .{};
    }
};

const DeleteImpact = struct {
    dependents: DeleteDependencyList = .{},
    nullwatch: ?integration_mod.NullWatchConfig = null,
    nulltickets: ?integration_mod.NullTicketsConfig = null,

    fn deinit(self: *DeleteImpact, allocator: std.mem.Allocator) void {
        self.dependents.deinit(allocator);
        if (self.nullwatch) |*cfg| integration_mod.deinitNullWatchConfig(allocator, cfg);
        if (self.nulltickets) |*cfg| integration_mod.deinitNullTicketsConfig(allocator, cfg);
        self.* = .{};
    }
};

fn collectDeleteImpact(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) !DeleteImpact {
    var impact: DeleteImpact = .{};
    errdefer impact.deinit(allocator);

    if (std.mem.eql(u8, component, "nullwatch")) {
        impact.nullwatch = try integration_mod.loadNullWatchConfig(allocator, paths, name) orelse return impact;
        const watch_cfg = impact.nullwatch.?;

        if (try s.instanceNames("nullclaw")) |claw_names| {
            defer s.allocator.free(claw_names);
            for (claw_names) |claw_name| {
                var link = integration_mod.loadNullClawTelemetryLink(allocator, paths, claw_name) catch |err| switch (err) {
                    error.NotFound => continue,
                    else => return err,
                };
                defer link.deinit(allocator);

                if (integration_mod.findNullWatchByEndpoint(&.{watch_cfg}, link.endpoint) != null) {
                    try impact.dependents.append(allocator, "nullclaw", claw_name, "telemetry");
                }
            }
        }
    } else if (std.mem.eql(u8, component, "nulltickets")) {
        impact.nulltickets = try integration_mod.loadNullTicketsConfig(allocator, paths, name) orelse return impact;
        const tickets_cfg = impact.nulltickets.?;

        if (try s.instanceNames("nullboiler")) |boiler_names| {
            defer s.allocator.free(boiler_names);
            for (boiler_names) |boiler_name| {
                var boiler_cfg = try integration_mod.loadNullBoilerConfig(allocator, paths, boiler_name) orelse continue;
                defer integration_mod.deinitNullBoilerConfig(allocator, &boiler_cfg);

                if (integration_mod.matchNullTicketsTarget(boiler_cfg, &.{tickets_cfg}) != null) {
                    try impact.dependents.append(allocator, "nullboiler", boiler_name, "tracker");
                }
            }
        }
    }

    return impact;
}

fn deleteDependencyConflict(allocator: std.mem.Allocator, dependents: []const DeleteDependent) ApiResponse {
    const body = std.json.Stringify.valueAlloc(allocator, .{
        .@"error" = "instance has dependent links",
        .force_required = true,
        .dependents = dependents,
    }, .{}) catch return helpers.serverError();

    return .{
        .status = "409 Conflict",
        .content_type = "application/json",
        .body = body,
    };
}

fn unlinkNullClawTelemetryForDeletedWatch(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    claw_name: []const u8,
    watch_cfg: integration_mod.NullWatchConfig,
) !bool {
    var link = integration_mod.loadNullClawTelemetryLink(allocator, paths, claw_name) catch |err| switch (err) {
        error.NotFound => return false,
        else => return err,
    };
    defer link.deinit(allocator);
    if (integration_mod.findNullWatchByEndpoint(&.{watch_cfg}, link.endpoint) == null) return false;

    const config_path = try paths.instanceConfig(allocator, "nullclaw", claw_name);
    defer allocator.free(config_path);
    const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const config_bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(config_bytes);

    var parsed_config = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed_config.deinit();
    if (parsed_config.value != .object) return error.InvalidConfig;

    if (parsed_config.value.object.getPtr("diagnostics")) |diagnostics_value| {
        if (diagnostics_value.* == .object) {
            if (jsonString(diagnostics_value.object, "backend")) |backend| {
                if (std.mem.eql(u8, backend, "otel") or std.mem.eql(u8, backend, "otlp")) {
                    try diagnostics_value.object.put(allocator, "backend", .{ .string = "jsonl" });
                }
            }
            _ = diagnostics_value.object.swapRemove("otel");
        }
    }

    try writeJsonConfigValue(allocator, config_path, parsed_config.value);
    return true;
}

fn unlinkNullBoilerTrackerForDeletedTickets(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    boiler_name: []const u8,
    tickets_cfg: integration_mod.NullTicketsConfig,
) !bool {
    var boiler_cfg = try integration_mod.loadNullBoilerConfig(allocator, paths, boiler_name) orelse return false;
    defer integration_mod.deinitNullBoilerConfig(allocator, &boiler_cfg);
    if (integration_mod.matchNullTicketsTarget(boiler_cfg, &.{tickets_cfg}) == null) return false;

    const config_path = try paths.instanceConfig(allocator, "nullboiler", boiler_name);
    defer allocator.free(config_path);
    const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    defer file.close();

    const config_bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(config_bytes);

    var parsed_config = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed_config.deinit();
    if (parsed_config.value != .object) return error.InvalidConfig;

    _ = parsed_config.value.object.swapRemove("tracker");
    try writeJsonConfigValue(allocator, config_path, parsed_config.value);
    return true;
}

fn unlinkDeleteImpact(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8, impact: DeleteImpact) !void {
    if (std.mem.eql(u8, component, "nullwatch")) {
        const watch_cfg = impact.nullwatch orelse return;
        for (impact.dependents.items.items) |dep| {
            if (!std.mem.eql(u8, dep.component, "nullclaw")) continue;
            _ = try unlinkNullClawTelemetryForDeletedWatch(allocator, paths, dep.name, watch_cfg);
        }
    } else if (std.mem.eql(u8, component, "nulltickets")) {
        const tickets_cfg = impact.nulltickets orelse return;
        for (impact.dependents.items.items) |dep| {
            if (!std.mem.eql(u8, dep.component, "nullboiler")) continue;
            _ = try unlinkNullBoilerTrackerForDeletedTickets(allocator, paths, dep.name, tickets_cfg);
        }
    }
}

fn restartRunningDeleteDependents(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    paths: paths_mod.Paths,
    impact: DeleteImpact,
) void {
    for (impact.dependents.items.items) |dep| {
        const status = manager.getStatus(dep.component, dep.name) orelse continue;
        if (status.status != .running) continue;

        const resp = handleRestart(allocator, s, manager, paths, dep.component, dep.name, "");
        if (!std.mem.eql(u8, resp.status, "200 OK")) {
            std.log.warn("unlinked dependent {s}/{s} but failed to restart after delete: {s}", .{
                dep.component,
                dep.name,
                resp.status,
            });
        }
    }
}

fn restoreDeletedInstance(
    s: *state_mod.State,
    component: []const u8,
    name: []const u8,
    rollback_version: []const u8,
    rollback_auto_start: bool,
    rollback_launch_mode: []const u8,
    rollback_verbose: bool,
    rollback_storage_mode: []const u8,
    rollback_source_path: []const u8,
    inst_dir: []const u8,
    hidden_inst_dir: ?[]const u8,
) void {
    _ = s.addInstance(component, name, .{
        .version = rollback_version,
        .auto_start = rollback_auto_start,
        .launch_mode = rollback_launch_mode,
        .verbose = rollback_verbose,
        .storage_mode = rollback_storage_mode,
        .source_path = rollback_source_path,
    }) catch {};
    _ = s.save() catch {};
    if (hidden_inst_dir) |path| {
        std_compat.fs.renameAbsolute(path, inst_dir) catch {};
    }
}

/// DELETE /api/instances/{component}/{name}
pub fn handleDelete(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    target: []const u8,
) ApiResponse {
    const existing = s.getInstance(component, name) orelse return notFound();
    const rollback_version = allocator.dupe(u8, existing.version) catch return helpers.serverError();
    defer allocator.free(rollback_version);
    const rollback_auto_start = existing.auto_start;
    const rollback_launch_mode = allocator.dupe(u8, existing.launch_mode) catch return helpers.serverError();
    defer allocator.free(rollback_launch_mode);
    const rollback_verbose = existing.verbose;
    const rollback_storage_mode = if (existing.storage_mode.len > 0)
        allocator.dupe(u8, existing.storage_mode) catch return helpers.serverError()
    else
        "";
    defer if (rollback_storage_mode.len > 0) allocator.free(rollback_storage_mode);
    const rollback_source_path = if (existing.source_path.len > 0)
        allocator.dupe(u8, existing.source_path) catch return helpers.serverError()
    else
        "";
    defer if (rollback_source_path.len > 0) allocator.free(rollback_source_path);

    var delete_impact = collectDeleteImpact(allocator, s, paths, component, name) catch return helpers.serverError();
    defer delete_impact.deinit(allocator);
    const force = query_api.boolValue(target, "force");
    if (delete_impact.dependents.items.items.len > 0 and !force) {
        return deleteDependencyConflict(allocator, delete_impact.dependents.items.items);
    }

    const inst_dir = paths.instanceDir(allocator, component, name) catch return helpers.serverError();
    defer allocator.free(inst_dir);

    manager.stopInstance(component, name) catch {};
    const hidden_inst_dir = hideInstanceDirForDelete(allocator, inst_dir) catch return helpers.serverError();
    defer if (hidden_inst_dir) |path| allocator.free(path);

    if (!s.removeInstance(component, name)) {
        if (hidden_inst_dir) |path| {
            std_compat.fs.renameAbsolute(path, inst_dir) catch {};
        }
        return notFound();
    }
    s.save() catch {
        restoreDeletedInstance(s, component, name, rollback_version, rollback_auto_start, rollback_launch_mode, rollback_verbose, rollback_storage_mode, rollback_source_path, inst_dir, hidden_inst_dir);
        return helpers.serverError();
    };

    if (delete_impact.dependents.items.items.len > 0) {
        unlinkDeleteImpact(allocator, paths, component, delete_impact) catch {
            restoreDeletedInstance(s, component, name, rollback_version, rollback_auto_start, rollback_launch_mode, rollback_verbose, rollback_storage_mode, rollback_source_path, inst_dir, hidden_inst_dir);
            _ = s.save() catch {};
            return helpers.serverError();
        };
        restartRunningDeleteDependents(allocator, s, manager, paths, delete_impact);
    }

    if (hidden_inst_dir) |path| {
        std_compat.fs.deleteTreeAbsolute(path) catch |err| {
            std.log.warn("deleted instance {s}/{s} but failed to clean hidden dir '{s}': {s}", .{
                component,
                name,
                path,
                @errorName(err),
            });
        };
    }

    return jsonOk("{\"status\":\"deleted\"}");
}

fn hideInstanceDirForDelete(allocator: std.mem.Allocator, inst_dir: []const u8) !?[]const u8 {
    std_compat.fs.accessAbsolute(inst_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };

    const parent = std.fs.path.dirname(inst_dir) orelse return error.InvalidPath;
    const base = std.fs.path.basename(inst_dir);
    const ts = @as(u64, @intCast(@max(0, std_compat.time.milliTimestamp())));

    var attempt: u32 = 0;
    while (attempt < 1024) : (attempt += 1) {
        const hidden_path = try std.fmt.allocPrint(allocator, "{s}/.{s}.deleted-{d}-{d}", .{
            parent,
            base,
            ts,
            attempt,
        });
        errdefer allocator.free(hidden_path);

        std_compat.fs.renameAbsolute(inst_dir, hidden_path) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return hidden_path;
    }

    return error.PathAlreadyExists;
}

fn findInstalledBinaryVersion(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8) ?[]const u8 {
    const bin_dir = std.fmt.allocPrint(allocator, "{s}/bin", .{paths.root}) catch return null;
    defer allocator.free(bin_dir);

    var dir = std_compat.fs.openDirAbsolute(bin_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    const prefix = std.fmt.allocPrint(allocator, "{s}-", .{component}) catch return null;
    defer allocator.free(prefix);

    var best_version: ?[]const u8 = null;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;

        var version = entry.name[prefix.len..];
        if (builtin.os.tag == .windows and std.mem.endsWith(u8, version, ".exe")) {
            version = version[0 .. version.len - 4];
        }
        if (version.len == 0) continue;

        const candidate_path = std.fs.path.join(allocator, &.{ bin_dir, entry.name }) catch continue;
        defer allocator.free(candidate_path);
        std_compat.fs.accessAbsolute(candidate_path, .{}) catch continue;

        if (best_version == null or std.mem.order(u8, version, best_version.?) == .gt) {
            const owned_version = allocator.dupe(u8, version) catch continue;
            if (best_version) |owned| allocator.free(owned);
            best_version = owned_version;
        }
    }

    return best_version;
}

fn downloadLatestBinaryVersion(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8) ?[]const u8 {
    const known = registry.findKnownComponent(component) orelse return null;
    var release = registry.fetchLatestRelease(allocator, known.repo) catch return null;
    defer release.deinit();

    const platform_key = comptime platform.detect().toString();
    const asset = registry.findAssetForComponentPlatform(allocator, release.value, component, platform_key) orelse return null;

    paths.ensureDirs() catch return null;
    const bin_path = paths.binary(allocator, component, release.value.tag_name) catch return null;
    defer allocator.free(bin_path);

    downloader.downloadIfMissing(allocator, asset.browser_download_url, bin_path) catch return null;
    return allocator.dupe(u8, release.value.tag_name) catch null;
}

fn resolveImportBinaryVersion(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8) ?[]const u8 {
    if (local_binary.stageDevLocal(allocator, paths, component)) |dest_bin| {
        allocator.free(dest_bin);
        return allocator.dupe(u8, local_binary.dev_local_version) catch null;
    }
    if (findInstalledBinaryVersion(allocator, paths, component)) |version| return version;
    return downloadLatestBinaryVersion(allocator, paths, component);
}

const ImportRequest = struct {
    path: []const u8 = "",
    name: []const u8 = "",
};

const ParsedImportConfig = struct {
    instance_name: ?[]const u8 = null,
};

fn duplicateImportRequest(parsed: ImportRequest, allocator: std.mem.Allocator) !ImportRequest {
    return .{
        .path = try allocator.dupe(u8, parsed.path),
        .name = try allocator.dupe(u8, parsed.name),
    };
}

fn deinitImportRequest(allocator: std.mem.Allocator, req: ImportRequest) void {
    allocator.free(req.path);
    allocator.free(req.name);
}

fn loadImportRequest(allocator: std.mem.Allocator, body: []const u8) !ImportRequest {
    if (std.mem.trim(u8, body, &std.ascii.whitespace).len == 0) {
        return .{
            .path = try allocator.dupe(u8, ""),
            .name = try allocator.dupe(u8, ""),
        };
    }

    const parsed = try std.json.parseFromSlice(ImportRequest, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return duplicateImportRequest(parsed.value, allocator);
}

fn resolveDefaultImportSourceDir(allocator: std.mem.Allocator, home: []const u8, component: []const u8) ![]u8 {
    const dot_name = try std.fmt.allocPrint(allocator, ".{s}", .{component});
    defer allocator.free(dot_name);
    return std.fs.path.join(allocator, &.{ home, dot_name });
}

fn resolveImportSourceDir(allocator: std.mem.Allocator, home: []const u8, component: []const u8, req: ImportRequest) ![]u8 {
    if (req.path.len > 0) return allocator.dupe(u8, req.path);
    return resolveDefaultImportSourceDir(allocator, home, component);
}

fn validateImportSourceDir(allocator: std.mem.Allocator, source_dir: []const u8) ?[]const u8 {
    std_compat.fs.accessAbsolute(source_dir, .{}) catch return "{\"error\":\"path does not exist\"}";

    const config_path = std.fs.path.join(allocator, &.{ source_dir, "config.json" }) catch return "{\"error\":\"config.json not found at path\"}";
    defer allocator.free(config_path);

    std_compat.fs.accessAbsolute(config_path, .{}) catch return "{\"error\":\"config.json not found at path\"}";
    return null;
}

fn readImportConfig(allocator: std.mem.Allocator, source_dir: []const u8) !ParsedImportConfig {
    const config_path = try std.fs.path.join(allocator, &.{ source_dir, "config.json" });
    defer allocator.free(config_path);

    const file = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(ParsedImportConfig, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    return .{
        .instance_name = if (parsed.value.instance_name) |name|
            try allocator.dupe(u8, name)
        else
            null,
    };
}

fn deinitParsedImportConfig(allocator: std.mem.Allocator, cfg: ParsedImportConfig) void {
    if (cfg.instance_name) |name| allocator.free(name);
}

fn isFilesystemSafeImportName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    if (std.mem.eql(u8, name, "import") or std.mem.eql(u8, name, "standalone")) return false;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return false;
    for (name) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == '.';
        if (!safe) return false;
    }
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    return true;
}

fn parseLocalImportOrdinal(name: []const u8) ?usize {
    const prefixes = [_][]const u8{ "local-import-", "Local Import #" };
    inline for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            return std.fmt.parseUnsigned(usize, name[prefix.len..], 10) catch null;
        }
    }
    return null;
}

fn nextLocalImportName(allocator: std.mem.Allocator, s: *state_mod.State, component: []const u8) ![]u8 {
    const names = try s.instanceNames(component);
    defer if (names) |owned_names| s.allocator.free(owned_names);

    var next_number: usize = 1;
    if (names) |owned_names| {
        for (owned_names) |existing_name| {
            const n = parseLocalImportOrdinal(existing_name) orelse continue;
            if (n >= next_number) next_number = n + 1;
        }
    }

    return std.fmt.allocPrint(allocator, "local-import-{d}", .{next_number});
}

fn resolveImportInstanceName(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    component: []const u8,
    req: ImportRequest,
    cfg: ParsedImportConfig,
) ![]u8 {
    if (req.name.len > 0) return allocator.dupe(u8, req.name);
    if (cfg.instance_name) |name| return allocator.dupe(u8, name);
    if (req.path.len == 0) return allocator.dupe(u8, "default");
    return nextLocalImportName(allocator, s, component);
}

fn invalidImportNameResponse(allocator: std.mem.Allocator, name: []const u8) ApiResponse {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice("{\"error\":\"invalid or duplicate instance name: ") catch return helpers.serverError();
    appendEscaped(&buf, name) catch return helpers.serverError();
    buf.appendSlice("\"}") catch return helpers.serverError();
    const body = buf.toOwnedSlice() catch return helpers.serverError();
    return badRequest(body);
}

fn buildImportResponse(allocator: std.mem.Allocator, instance_name: []const u8, source_dir: []const u8) ![]u8 {
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();

    try buf.appendSlice("{\"status\":\"imported\",\"instance\":\"");
    try appendEscaped(&buf, instance_name);
    try buf.appendSlice("\",\"path\":\"");
    try appendEscaped(&buf, source_dir);
    try buf.appendSlice("\"}");
    return buf.toOwnedSlice();
}

fn hasStandaloneInstallAtPath(allocator: std.mem.Allocator, source_dir: []const u8) bool {
    return validateImportSourceDir(allocator, source_dir) == null;
}

fn isStandaloneImported(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    component: []const u8,
    standalone_dir: []const u8,
) bool {
    const real_standalone_dir = std_compat.fs.realpathAlloc(allocator, standalone_dir) catch return false;
    defer allocator.free(real_standalone_dir);

    const names = s.instanceNames(component) catch return false;
    defer if (names) |owned_names| s.allocator.free(owned_names);

    if (names) |owned_names| {
        for (owned_names) |name| {
            const entry = s.getInstance(component, name) orelse continue;
            if (!std.mem.eql(u8, entry.storage_mode, imported_standalone_storage_mode)) continue;
            if (entry.source_path.len == 0) continue;

            const real_source_dir = std_compat.fs.realpathAlloc(allocator, entry.source_path) catch continue;
            defer allocator.free(real_source_dir);
            if (std.mem.eql(u8, real_source_dir, real_standalone_dir)) return true;
        }
    }

    return false;
}

fn buildStandaloneResponse(
    allocator: std.mem.Allocator,
    standalone_dir: ?[]const u8,
    already_imported: bool,
) ![]u8 {
    if (standalone_dir == null) return allocator.dupe(u8, "{\"standalone\":false}");

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("{\"standalone\":true,\"standalone_path\":\"");
    try appendEscaped(&buf, standalone_dir.?);
    try buf.appendSlice("\",\"already_imported\":");
    try buf.appendSlice(if (already_imported) "true" else "false");
    try buf.appendSlice("}");
    return buf.toOwnedSlice();
}

pub fn handleStandalone(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8) ApiResponse {
    _ = paths;
    const home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch blk: {
        if (builtin.os.tag == .windows) {
            break :blk std_compat.process.getEnvVarOwned(allocator, "USERPROFILE") catch return helpers.serverError();
        }
        return helpers.serverError();
    };
    defer allocator.free(home);

    const standalone_dir = resolveDefaultImportSourceDir(allocator, home, component) catch return helpers.serverError();
    defer allocator.free(standalone_dir);

    if (!hasStandaloneInstallAtPath(allocator, standalone_dir)) {
        const body = buildStandaloneResponse(allocator, null, false) catch return helpers.serverError();
        return jsonOk(body);
    }

    const already_imported = isStandaloneImported(allocator, s, component, standalone_dir);
    const body = buildStandaloneResponse(allocator, standalone_dir, already_imported) catch return helpers.serverError();
    return jsonOk(body);
}

/// POST /api/instances/{component}/import — import a standalone installation.
/// Links the external standalone home into NullHub state without taking ownership
/// of its files. A runnable binary is staged so the managed instance can start.
pub fn handleImport(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8, body: []const u8) ApiResponse {
    const req = loadImportRequest(allocator, body) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer deinitImportRequest(allocator, req);

    const home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch blk: {
        if (builtin.os.tag == .windows) {
            break :blk std_compat.process.getEnvVarOwned(allocator, "USERPROFILE") catch return helpers.serverError();
        }
        return helpers.serverError();
    };
    defer allocator.free(home);

    const source_dir = resolveImportSourceDir(allocator, home, component, req) catch return helpers.serverError();
    defer allocator.free(source_dir);

    if (validateImportSourceDir(allocator, source_dir)) |error_body| {
        const is_default_path = req.path.len == 0;
        if (is_default_path and std.mem.eql(u8, error_body, "{\"error\":\"path does not exist\"}")) {
            return notFound();
        }
        return badRequest(error_body);
    }

    const parsed_config = readImportConfig(allocator, source_dir) catch return badRequest("{\"error\":\"config.json is not valid JSON\"}");
    defer deinitParsedImportConfig(allocator, parsed_config);

    const instance_name = resolveImportInstanceName(allocator, s, component, req, parsed_config) catch return helpers.serverError();
    defer allocator.free(instance_name);

    if (!isFilesystemSafeImportName(instance_name) or s.getInstance(component, instance_name) != null) {
        return invalidImportNameResponse(allocator, instance_name);
    }

    // 2. Create instance directory structure
    const inst_dir = paths.instanceDir(allocator, component, instance_name) catch return helpers.serverError();
    defer allocator.free(inst_dir);
    if (std_compat.fs.accessAbsolute(inst_dir, .{})) |_| {
        return invalidImportNameResponse(allocator, instance_name);
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => return helpers.serverError(),
    }

    // Ensure parent component dir exists
    const comp_dir = std.fs.path.join(allocator, &.{ paths.root, "instances", component }) catch return helpers.serverError();
    defer allocator.free(comp_dir);
    std_compat.fs.makeDirAbsolute(comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return helpers.serverError(),
    };

    // 3. Stage or reuse a runnable binary before mutating the instance path.
    const version = resolveImportBinaryVersion(allocator, paths, component) orelse return helpers.serverError();
    defer allocator.free(version);

    // 4. Symlink the entire standalone dir as the instance dir
    //    ~/.nullclaw -> ~/.nullhub/instances/nullclaw/{name}
    //    This preserves all data in place (config, auth, workspace, state, logs)
    std_compat.fs.symLinkAbsolute(source_dir, inst_dir, .{ .is_directory = true }) catch return helpers.serverError();

    // 5. Register in state
    s.addInstance(component, instance_name, .{
        .version = version,
        .auto_start = false,
        .launch_mode = defaultLaunchModeForComponent(component),
        .verbose = false,
        .storage_mode = imported_standalone_storage_mode,
        .source_path = source_dir,
    }) catch {
        std_compat.fs.deleteFileAbsolute(inst_dir) catch {};
        return helpers.serverError();
    };
    s.save() catch {
        _ = s.removeInstance(component, instance_name);
        std_compat.fs.deleteFileAbsolute(inst_dir) catch {};
        return helpers.serverError();
    };

    // Best effort: registration must also provision the component's declared
    // UI modules, otherwise an import into an already-running hub still needs
    // a restart (or a manual API call) before the UI is available.
    if (registry.findKnownComponent(component)) |comp| {
        orchestrator.ensureComponentUiModules(allocator, paths, comp);
    }

    const response_body = buildImportResponse(allocator, instance_name, source_dir) catch return helpers.serverError();
    return jsonOk(response_body);
}

/// PATCH /api/instances/{component}/{name} — update settings (auto_start).
pub fn handlePatch(s: *state_mod.State, component: []const u8, name: []const u8, body: []const u8) ApiResponse {
    const entry = s.getInstance(component, name) orelse return notFound();

    // Parse the JSON body to extract instance startup settings.
    const parsed = std.json.parseFromSlice(
        struct {
            auto_start: ?bool = null,
            launch_mode: ?[]const u8 = null,
            verbose: ?bool = null,
        },
        s.allocator,
        body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return badRequest("{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const new_auto_start = parsed.value.auto_start orelse entry.auto_start;
    const new_launch_mode = parsed.value.launch_mode orelse entry.launch_mode;
    const new_verbose = parsed.value.verbose orelse entry.verbose;

    var validated_launch = launch_args_mod.resolve(s.allocator, new_launch_mode, new_verbose) catch
        return badRequest("{\"error\":\"invalid launch_mode\"}");
    validated_launch.deinit();

    _ = s.updateInstance(component, name, .{
        .version = entry.version,
        .auto_start = new_auto_start,
        .launch_mode = new_launch_mode,
        .verbose = new_verbose,
        .storage_mode = entry.storage_mode,
        .source_path = entry.source_path,
    }) catch return .{
        .status = "500 Internal Server Error",
        .content_type = "application/json",
        .body = "{\"error\":\"internal error\"}",
    };

    s.save() catch return helpers.serverError();

    return jsonOk("{\"status\":\"updated\"}");
}

fn handleIntegrationGet(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    mutex: *std_compat.sync.Mutex,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) ApiResponse {
    if (std.mem.eql(u8, component, "nullclaw")) {
        var link = integration_mod.loadNullClawTelemetryLink(allocator, paths, name) catch |err| switch (err) {
            error.NotFound => return notFound(),
            else => return helpers.serverError(),
        };
        defer link.deinit(allocator);
        const watches = listNullWatchLocked(allocator, mutex, s, paths) catch return helpers.serverError();
        defer integration_mod.deinitNullWatchConfigs(allocator, watches);
        const linked = integration_mod.findNullWatchByEndpoint(watches, link.endpoint);

        var watch_options: std.ArrayListUnmanaged(WatchIntegrationOption) = .empty;
        defer watch_options.deinit(allocator);
        for (watches) |watch| {
            const is_running = blk: {
                const status = getStatusLocked(mutex, manager, "nullwatch", watch.name) orelse break :blk false;
                break :blk status.status == .running;
            };
            watch_options.append(allocator, .{
                .name = watch.name,
                .host = watch.host,
                .port = watch.port,
                .running = is_running,
            }) catch return helpers.serverError();
        }

        const body = std.json.Stringify.valueAlloc(allocator, .{
            .kind = "nullclaw",
            .configured = link.configured,
            .linked_watch = if (linked) |watch| .{
                .name = watch.name,
                .host = watch.host,
                .port = watch.port,
            } else null,
            .available_watches = watch_options.items,
            .current_link = if (link.endpoint) |endpoint| .{
                .endpoint = endpoint,
                .service_name = link.service_name orelse "",
                .auth_header = link.auth_configured,
                .source_header = link.source_header_configured,
            } else null,
        }, .{ .emit_null_optional_fields = false }) catch return helpers.serverError();
        return jsonOk(body);
    }

    if (std.mem.eql(u8, component, "nullwatch")) {
        var watch_cfg = integration_mod.loadNullWatchConfig(allocator, paths, name) catch null orelse return notFound();
        defer integration_mod.deinitNullWatchConfig(allocator, &watch_cfg);

        const claw_names_opt = blk: {
            mutex.lock();
            defer mutex.unlock();
            break :blk s.instanceNames("nullclaw") catch return helpers.serverError();
        };
        defer if (claw_names_opt) |claw_names| s.allocator.free(claw_names);

        var claw_options: std.ArrayListUnmanaged(ClawIntegrationOption) = .empty;
        defer claw_options.deinit(allocator);
        if (claw_names_opt) |claw_names| {
            for (claw_names) |claw_name| {
                const is_running = blk: {
                    const status = getStatusLocked(mutex, manager, "nullclaw", claw_name) orelse break :blk false;
                    break :blk status.status == .running;
                };
                const is_linked = blk: {
                    var link = integration_mod.loadNullClawTelemetryLink(allocator, paths, claw_name) catch break :blk false;
                    defer link.deinit(allocator);
                    break :blk integration_mod.findNullWatchByEndpoint(&.{watch_cfg}, link.endpoint) != null;
                };
                claw_options.append(allocator, .{
                    .name = claw_name,
                    .running = is_running,
                    .linked = is_linked,
                }) catch return helpers.serverError();
            }
        }

        const body = std.json.Stringify.valueAlloc(allocator, .{
            .kind = "nullwatch",
            .watch = .{
                .name = watch_cfg.name,
                .host = watch_cfg.host,
                .port = watch_cfg.port,
            },
            .available_claws = claw_options.items,
        }, .{ .emit_null_optional_fields = false }) catch return helpers.serverError();
        return jsonOk(body);
    }

    if (std.mem.eql(u8, component, "nullboiler")) {
        var boiler_cfg = integration_mod.loadNullBoilerConfig(allocator, paths, name) catch null orelse return notFound();
        defer integration_mod.deinitNullBoilerConfig(allocator, &boiler_cfg);
        const trackers = listNullTicketsLocked(allocator, mutex, s, paths) catch return helpers.serverError();
        defer integration_mod.deinitNullTicketsConfigs(allocator, trackers);
        const linked = integration_mod.matchNullTicketsTarget(boiler_cfg, trackers);

        var tracker_options: std.ArrayListUnmanaged(TrackerIntegrationOption) = .empty;
        defer {
            for (tracker_options.items) |option| {
                deinitPipelineSummaries(allocator, option.pipelines);
            }
            tracker_options.deinit(allocator);
        }

        for (trackers) |tracker| {
            const is_running = blk: {
                const status = getStatusLocked(mutex, manager, "nulltickets", tracker.name) orelse break :blk false;
                break :blk status.status == .running;
            };
            var pipelines = blk: {
                if (!is_running) break :blk allocator.alloc(PipelineSummary, 0) catch return helpers.serverError();
                const url = buildInstanceUrl(allocator, tracker.port, "/pipelines") orelse break :blk allocator.alloc(PipelineSummary, 0) catch return helpers.serverError();
                defer allocator.free(url);
                break :blk fetchPipelineSummaries(allocator, url, tracker.api_token) orelse (allocator.alloc(PipelineSummary, 0) catch return helpers.serverError());
            };
            errdefer deinitPipelineSummaries(allocator, pipelines);
            tracker_options.append(allocator, .{
                .name = tracker.name,
                .port = tracker.port,
                .running = is_running,
                .pipelines = pipelines,
            }) catch return helpers.serverError();
            pipelines = &.{};
        }

        const boiler_runtime = getStatusLocked(mutex, manager, "nullboiler", name);
        var tracker_status = blk: {
            const status = boiler_runtime orelse break :blk null;
            if (status.status != .running) break :blk null;
            const url = buildInstanceUrl(allocator, boiler_cfg.port, "/tracker/status") orelse break :blk null;
            defer allocator.free(url);
            break :blk fetchJsonValue(allocator, url, boiler_cfg.api_token);
        };
        defer if (tracker_status) |*value| value.deinit(allocator);

        var queue_status = blk: {
            const linked_tracker = linked orelse break :blk null;
            const status = getStatusLocked(mutex, manager, "nulltickets", linked_tracker.name) orelse break :blk null;
            if (status.status != .running) break :blk null;
            const url = buildInstanceUrl(allocator, linked_tracker.port, "/ops/queue") orelse break :blk null;
            defer allocator.free(url);
            break :blk fetchJsonValue(allocator, url, linked_tracker.api_token);
        };
        defer if (queue_status) |*value| value.deinit(allocator);

        const body = std.json.Stringify.valueAlloc(allocator, .{
            .kind = "nullboiler",
            .instance = .{
                .name = boiler_cfg.name,
                .port = boiler_cfg.port,
                .running = if (boiler_runtime) |status| status.status == .running else false,
                .token_configured = boiler_cfg.api_token != null,
            },
            .configured = boiler_cfg.tracker != null,
            .configured_tracker = if (boiler_cfg.tracker) |tracker| .{
                .url = tracker.url,
                .agent_id = tracker.agent_id,
                .token_configured = tracker.api_token != null,
                .max_concurrent_tasks = tracker.max_concurrent_tasks,
            } else null,
            .linked_tracker = if (linked) |tracker| .{
                .name = tracker.name,
                .port = tracker.port,
            } else null,
            .available_trackers = tracker_options.items,
            .current_link = if (boiler_cfg.tracker) |tracker| if (tracker.workflow) |workflow| .{
                .pipeline_id = workflow.pipeline_id,
                .claim_role = workflow.claim_role,
                .success_trigger = workflow.success_trigger,
                .max_concurrent_tasks = tracker.max_concurrent_tasks,
                .agent_id = tracker.agent_id,
                .workflow_file = workflow.file_name,
            } else null else null,
            .tracker = if (tracker_status) |value| value.parsed.value else null,
            .queue = if (queue_status) |value| value.parsed.value else null,
        }, .{ .emit_null_optional_fields = false }) catch return helpers.serverError();
        return jsonOk(body);
    }

    if (std.mem.eql(u8, component, "nulltickets")) {
        var tickets_cfg = integration_mod.loadNullTicketsConfig(allocator, paths, name) catch null orelse return notFound();
        defer integration_mod.deinitNullTicketsConfig(allocator, &tickets_cfg);
        const boilers = listNullBoilersLocked(allocator, mutex, s, paths) catch return helpers.serverError();
        defer integration_mod.deinitNullBoilerConfigs(allocator, boilers);

        const LinkedBoilerRuntime = struct {
            name: []const u8,
            port: u16,
            tracker: ?FetchedJsonValue = null,
        };
        const LinkedBoilerView = struct {
            name: []const u8,
            port: u16,
            tracker: ?std.json.Value = null,
        };

        var linked_boilers: std.ArrayListUnmanaged(LinkedBoilerRuntime) = .empty;
        defer {
            for (linked_boilers.items) |*boiler| {
                if (boiler.tracker) |*tracker| tracker.deinit(allocator);
            }
            linked_boilers.deinit(allocator);
        }

        for (boilers) |boiler| {
            const linked = integration_mod.matchNullTicketsTarget(boiler, &.{tickets_cfg}) orelse continue;
            _ = linked;
            var tracker_value = blk: {
                const status = getStatusLocked(mutex, manager, "nullboiler", boiler.name) orelse break :blk null;
                if (status.status != .running) break :blk null;
                const url = buildInstanceUrl(allocator, boiler.port, "/tracker/status") orelse break :blk null;
                defer allocator.free(url);
                break :blk fetchJsonValue(allocator, url, boiler.api_token);
            };
            errdefer if (tracker_value) |*value| value.deinit(allocator);
            linked_boilers.append(allocator, .{
                .name = boiler.name,
                .port = boiler.port,
                .tracker = tracker_value,
            }) catch return helpers.serverError();
            tracker_value = null;
        }

        var queue = blk: {
            const status = getStatusLocked(mutex, manager, "nulltickets", name) orelse break :blk null;
            if (status.status != .running) break :blk null;
            const url = buildInstanceUrl(allocator, tickets_cfg.port, "/ops/queue") orelse break :blk null;
            defer allocator.free(url);
            break :blk fetchJsonValue(allocator, url, tickets_cfg.api_token);
        };
        defer if (queue) |*value| value.deinit(allocator);
        const tickets_runtime = getStatusLocked(mutex, manager, "nulltickets", name);

        var linked_boiler_views: std.ArrayListUnmanaged(LinkedBoilerView) = .empty;
        defer linked_boiler_views.deinit(allocator);
        for (linked_boilers.items) |boiler| {
            linked_boiler_views.append(allocator, .{
                .name = boiler.name,
                .port = boiler.port,
                .tracker = if (boiler.tracker) |tracker| tracker.parsed.value else null,
            }) catch return helpers.serverError();
        }

        const body = std.json.Stringify.valueAlloc(allocator, .{
            .kind = "nulltickets",
            .instance = .{
                .name = tickets_cfg.name,
                .port = tickets_cfg.port,
                .running = if (tickets_runtime) |status| status.status == .running else false,
                .token_configured = tickets_cfg.api_token != null,
            },
            .queue = if (queue) |value| value.parsed.value else null,
            .linked_boilers = linked_boiler_views.items,
        }, .{ .emit_null_optional_fields = false }) catch return helpers.serverError();
        return jsonOk(body);
    }

    return notFound();
}

fn linkNullClawTelemetry(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    mutex: *std_compat.sync.Mutex,
    paths: paths_mod.Paths,
    claw_name: []const u8,
    watch_cfg: integration_mod.NullWatchConfig,
) ApiResponse {
    integration_mod.linkNullClawToNullWatch(allocator, paths, claw_name, watch_cfg) catch |err| switch (err) {
        error.NotFound => return notFound(),
        else => return helpers.serverError(),
    };

    if (getStatusLocked(mutex, manager, "nullclaw", claw_name)) |status| {
        if (status.status == .running) {
            mutex.lock();
            defer mutex.unlock();
            return handleRestart(allocator, s, manager, paths, "nullclaw", claw_name, "");
        }
    }

    return jsonOk("{\"status\":\"linked\"}");
}

const NullBoilerLinkRequest = struct {
    tickets: integration_mod.NullTicketsConfig,
    pipeline_id: []const u8,
    claim_role: []const u8,
    success_trigger: []const u8,
    max_concurrent_tasks: ?u32 = null,

    fn deinit(self: *NullBoilerLinkRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.success_trigger);
        allocator.free(self.claim_role);
        allocator.free(self.pipeline_id);
        integration_mod.deinitNullTicketsConfig(allocator, &self.tickets);
        self.* = undefined;
    }
};

const NullBoilerLinkRequestError = error{
    InvalidJson,
    TrackerInstanceRequired,
    PipelineIdRequired,
    TrackerNotFound,
    OutOfMemory,
};

fn parseNullBoilerLinkRequest(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    body: []const u8,
) NullBoilerLinkRequestError!NullBoilerLinkRequest {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;

    const obj = parsed.value.object;
    const tracker_name = jsonString(obj, "tracker_instance") orelse return error.TrackerInstanceRequired;
    if (tracker_name.len == 0) return error.TrackerInstanceRequired;
    const pipeline_id = jsonString(obj, "pipeline_id") orelse return error.PipelineIdRequired;
    if (pipeline_id.len == 0) return error.PipelineIdRequired;

    var tickets = (integration_mod.loadNullTicketsConfig(allocator, paths, tracker_name) catch null) orelse
        return error.TrackerNotFound;
    errdefer integration_mod.deinitNullTicketsConfig(allocator, &tickets);

    const pipeline_id_owned = try allocator.dupe(u8, pipeline_id);
    errdefer allocator.free(pipeline_id_owned);
    const claim_role = try allocator.dupe(u8, nonEmptyJsonStringOrDefault(obj, "claim_role", "coder"));
    errdefer allocator.free(claim_role);
    const success_trigger = try allocator.dupe(u8, nonEmptyJsonStringOrDefault(obj, "success_trigger", "complete"));

    return .{
        .tickets = tickets,
        .pipeline_id = pipeline_id_owned,
        .claim_role = claim_role,
        .success_trigger = success_trigger,
        .max_concurrent_tasks = parseOptionalPositiveU32(obj.get("max_concurrent_tasks")),
    };
}

fn nonEmptyJsonStringOrDefault(obj: std.json.ObjectMap, key: []const u8, default_value: []const u8) []const u8 {
    const value = jsonString(obj, key) orelse return default_value;
    return if (value.len > 0) value else default_value;
}

fn parseOptionalPositiveU32(value: ?std.json.Value) ?u32 {
    const raw = value orelse return null;
    return switch (raw) {
        .integer => if (raw.integer > 0 and raw.integer <= std.math.maxInt(u32)) @as(?u32, @intCast(raw.integer)) else null,
        .string => |text| blk: {
            const parsed = std.fmt.parseInt(u32, text, 10) catch break :blk null;
            break :blk if (parsed > 0) parsed else null;
        },
        else => null,
    };
}

fn handleIntegrationPost(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    mutex: *std_compat.sync.Mutex,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    body: []const u8,
) ApiResponse {
    if (std.mem.eql(u8, component, "nullclaw")) {
        const watch_cfg = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
            defer parsed.deinit();
            if (parsed.value != .object) return badRequest("{\"error\":\"invalid JSON body\"}");
            const watch_name = if (parsed.value.object.get("watch_instance")) |value|
                if (value == .string and value.string.len > 0) value.string else null
            else
                null;
            if (watch_name == null) return badRequest("{\"error\":\"watch_instance is required\"}");
            break :blk integration_mod.loadNullWatchConfig(allocator, paths, watch_name.?) catch null orelse return notFound();
        };
        defer {
            var owned_cfg = watch_cfg;
            integration_mod.deinitNullWatchConfig(allocator, &owned_cfg);
        }

        return linkNullClawTelemetry(allocator, s, manager, mutex, paths, name, watch_cfg);
    }

    if (std.mem.eql(u8, component, "nullwatch")) {
        const claw_name = blk: {
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
            defer parsed.deinit();
            if (parsed.value != .object) return badRequest("{\"error\":\"invalid JSON body\"}");
            const value = if (parsed.value.object.get("claw_instance")) |item|
                if (item == .string and item.string.len > 0) item.string else null
            else
                null;
            if (value == null) return badRequest("{\"error\":\"claw_instance is required\"}");
            break :blk allocator.dupe(u8, value.?) catch return helpers.serverError();
        };
        defer allocator.free(claw_name);

        var watch_cfg = integration_mod.loadNullWatchConfig(allocator, paths, name) catch null orelse return notFound();
        defer integration_mod.deinitNullWatchConfig(allocator, &watch_cfg);
        return linkNullClawTelemetry(allocator, s, manager, mutex, paths, claw_name, watch_cfg);
    }

    if (!std.mem.eql(u8, component, "nullboiler")) return badRequest("{\"error\":\"integration updates are only supported for nullclaw, nullwatch, and nullboiler\"}");

    var tracker_cfg = parseNullBoilerLinkRequest(allocator, paths, body) catch |err| switch (err) {
        error.InvalidJson => return badRequest("{\"error\":\"invalid JSON body\"}"),
        error.TrackerInstanceRequired => return badRequest("{\"error\":\"tracker_instance is required\"}"),
        error.PipelineIdRequired => return badRequest("{\"error\":\"pipeline_id is required\"}"),
        error.TrackerNotFound => return notFound(),
        error.OutOfMemory => return helpers.serverError(),
    };
    defer tracker_cfg.deinit(allocator);

    const tracker_runtime = getStatusLocked(mutex, manager, "nulltickets", tracker_cfg.tickets.name);
    if (tracker_runtime != null and tracker_runtime.?.status == .running) {
        const pipelines_url = buildInstanceUrl(allocator, tracker_cfg.tickets.port, "/pipelines") orelse return helpers.serverError();
        defer allocator.free(pipelines_url);
        if (fetchPipelineSummaries(allocator, pipelines_url, tracker_cfg.tickets.api_token)) |pipelines| {
            defer deinitPipelineSummaries(allocator, pipelines);
            var matched = false;
            for (pipelines) |pipeline| {
                if (!std.mem.eql(u8, pipeline.id, tracker_cfg.pipeline_id)) continue;
                matched = true;
                if (pipeline.roles.len > 0 and !pipelineContainsString(pipeline.roles, tracker_cfg.claim_role)) {
                    return badRequest("{\"error\":\"claim_role is not valid for the selected pipeline\"}");
                }
                if (pipeline.triggers.len > 0 and !pipelineContainsString(pipeline.triggers, tracker_cfg.success_trigger)) {
                    return badRequest("{\"error\":\"success_trigger is not valid for the selected pipeline\"}");
                }
                break;
            }
            if (!matched) {
                return badRequest("{\"error\":\"pipeline_id was not found in the selected tracker\"}");
            }
        }
    }

    integration_mod.linkNullBoilerToNullTickets(allocator, paths, name, .{
        .tickets = tracker_cfg.tickets,
        .pipeline_id = tracker_cfg.pipeline_id,
        .claim_role = tracker_cfg.claim_role,
        .success_trigger = tracker_cfg.success_trigger,
        .max_concurrent_tasks = tracker_cfg.max_concurrent_tasks,
    }) catch |err| switch (err) {
        error.NotFound => return notFound(),
        else => return helpers.serverError(),
    };

    if (getStatusLocked(mutex, manager, "nullboiler", name)) |status| {
        if (status.status == .running) {
            mutex.lock();
            defer mutex.unlock();
            return handleRestart(allocator, s, manager, paths, "nullboiler", name, "");
        }
    }

    return jsonOk("{\"status\":\"linked\"}");
}

// ─── Top-level dispatcher ────────────────────────────────────────────────────

pub fn isIntegrationPath(target: []const u8) bool {
    const parsed = parsePath(target) orelse return false;
    return parsed.action != null and std.mem.eql(u8, parsed.action.?, "integration");
}

pub fn isTicketsActionPath(target: []const u8) bool {
    const parsed = parsePath(target) orelse return false;
    return parsed.action != null and std.mem.eql(u8, parsed.action.?, "tickets");
}

/// Route an `/api/instances` request. Called from server.zig.
/// `method` is the HTTP verb, `target` is the full request path,
/// `body` is the (possibly empty) request body.
pub fn dispatch(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    manager: *manager_mod.Manager,
    mutex: *std_compat.sync.Mutex,
    paths: paths_mod.Paths,
    method: []const u8,
    target: []const u8,
    body: []const u8,
) ?ApiResponse {
    // Exact match for the collection endpoint.
    if (std.mem.eql(u8, stripQuery(target), "/api/instances")) {
        if (std.mem.eql(u8, method, "GET")) return handleList(allocator, s, manager, paths);
        return methodNotAllowed();
    }

    const parsed_cron_owned = parseCronPathAlloc(allocator, target) catch |err| switch (err) {
        error.InvalidPathSegment => return badRequest("{\"error\":\"invalid path segment\"}"),
        else => return helpers.serverError(),
    };
    if (parsed_cron_owned) |parsed_cron_storage| {
        defer parsed_cron_storage.deinit(allocator);
        const parsed_cron = parsed_cron_storage.borrowed();
        return switch (parsed_cron.action) {
            .collection => if (std.mem.eql(u8, method, "GET"))
                handleCronList(allocator, s, paths, parsed_cron.component, parsed_cron.name)
            else if (std.mem.eql(u8, method, "POST"))
                handleCronCreate(allocator, s, paths, parsed_cron.component, parsed_cron.name, body, false)
            else
                methodNotAllowed(),
            .once => if (std.mem.eql(u8, method, "POST"))
                handleCronCreate(allocator, s, paths, parsed_cron.component, parsed_cron.name, body, true)
            else
                methodNotAllowed(),
            .update_or_delete => if (std.mem.eql(u8, method, "PATCH"))
                handleCronUpdate(allocator, s, paths, parsed_cron.component, parsed_cron.name, parsed_cron.job_id.?, body)
            else if (std.mem.eql(u8, method, "DELETE"))
                handleCronDelete(allocator, s, paths, parsed_cron.component, parsed_cron.name, parsed_cron.job_id.?)
            else if (std.mem.eql(u8, method, "GET"))
                handleCronGet(allocator, s, paths, parsed_cron.component, parsed_cron.name, parsed_cron.job_id.?)
            else
                methodNotAllowed(),
            .runs => if (std.mem.eql(u8, method, "GET"))
                handleCronRuns(allocator, s, paths, parsed_cron.component, parsed_cron.name, parsed_cron.job_id.?, target)
            else
                methodNotAllowed(),
            .run => if (std.mem.eql(u8, method, "POST"))
                handleCronCommandWithJob(
                    allocator,
                    s,
                    paths,
                    parsed_cron.component,
                    parsed_cron.name,
                    parsed_cron.job_id.?,
                    &.{ "cron", "run", parsed_cron.job_id.? },
                    "ran",
                    "cron_run_failed",
                )
            else
                methodNotAllowed(),
            .pause => if (std.mem.eql(u8, method, "POST"))
                handleCronCommandWithJob(
                    allocator,
                    s,
                    paths,
                    parsed_cron.component,
                    parsed_cron.name,
                    parsed_cron.job_id.?,
                    &.{ "cron", "pause", parsed_cron.job_id.? },
                    "paused",
                    "cron_pause_failed",
                )
            else
                methodNotAllowed(),
            .resume_job => if (std.mem.eql(u8, method, "POST"))
                handleCronCommandWithJob(
                    allocator,
                    s,
                    paths,
                    parsed_cron.component,
                    parsed_cron.name,
                    parsed_cron.job_id.?,
                    &.{ "cron", "resume", parsed_cron.job_id.? },
                    "resumed",
                    "cron_resume_failed",
                )
            else
                methodNotAllowed(),
        };
    }

    const parsed_channels_owned = parseChannelsPathAlloc(allocator, target) catch |err| switch (err) {
        error.InvalidPathSegment => return badRequest("{\"error\":\"invalid path segment\"}"),
        else => return helpers.serverError(),
    };
    if (parsed_channels_owned) |parsed_channels_storage| {
        defer parsed_channels_storage.deinit(allocator);
        const parsed_channels = parsed_channels_storage.borrowed();
        if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
        return handleChannels(allocator, s, paths, parsed_channels.component, parsed_channels.name, parsed_channels.channel_type);
    }

    const parsed_owned = parsePathAlloc(allocator, target) catch |err| switch (err) {
        error.InvalidPathSegment => return badRequest("{\"error\":\"invalid path segment\"}"),
        else => return helpers.serverError(),
    };
    const parsed_storage = parsed_owned orelse return null;
    defer parsed_storage.deinit(allocator);
    const parsed = parsed_storage.borrowed();

    if (parsed.action) |action| {
        if (std.mem.eql(u8, action, "status")) {
            if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
            return handleInstanceStatus(allocator, s, manager, paths, parsed.component, parsed.name);
        }
        if (std.mem.eql(u8, action, "doctor")) {
            if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
            return handleDoctor(allocator, s, paths, parsed.component, parsed.name);
        }
        if (std.mem.eql(u8, action, "capabilities")) {
            if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
            return handleCapabilities(allocator, s, paths, parsed.component, parsed.name);
        }
        if (std.mem.eql(u8, action, "mcp")) {
            if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
            return handleMcp(allocator, s, paths, parsed.component, parsed.name, target);
        }
        if (std.mem.eql(u8, action, "models")) {
            return handleModelsAction(allocator, s, paths, parsed.component, parsed.name, method, target);
        }
        if (std.mem.eql(u8, action, "provider-health")) {
            if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
            return handleProviderHealth(allocator, s, manager, paths, parsed.component, parsed.name);
        }
        if (std.mem.eql(u8, action, "usage")) {
            if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
            return handleUsage(allocator, s, paths, parsed.component, parsed.name, target);
        }
        if (std.mem.eql(u8, action, "history")) {
            if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
            return handleHistory(allocator, s, paths, parsed.component, parsed.name, target);
        }
        if (std.mem.eql(u8, action, "onboarding")) {
            if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
            return handleOnboarding(allocator, s, paths, parsed.component, parsed.name);
        }
        if (std.mem.eql(u8, action, "memory")) {
            if (std.mem.eql(u8, method, "GET")) return handleMemory(allocator, s, paths, parsed.component, parsed.name, target);
            if (std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "PATCH") or std.mem.eql(u8, method, "DELETE")) {
                return handleMemoryWrite(allocator, s, paths, parsed.component, parsed.name, method, target, body);
            }
            return methodNotAllowed();
        }
        if (std.mem.eql(u8, action, "memory-reindex")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return handleMemoryMaintenance(allocator, s, paths, parsed.component, parsed.name, "reindex");
        }
        if (std.mem.eql(u8, action, "memory-drain-outbox")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return handleMemoryMaintenance(allocator, s, paths, parsed.component, parsed.name, "drain-outbox");
        }
        if (std.mem.eql(u8, action, "agent")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return handleAgentInvoke(allocator, s, paths, parsed.component, parsed.name, body);
        }
        if (std.mem.eql(u8, action, "agent-sessions")) {
            return handleAgentSessions(allocator, s, paths, parsed.component, parsed.name, method, target);
        }
        if (std.mem.eql(u8, action, "skills")) {
            if (std.mem.eql(u8, method, "GET")) return handleSkills(allocator, s, paths, parsed.component, parsed.name, target);
            if (std.mem.eql(u8, method, "POST")) return handleSkillsInstall(allocator, s, paths, parsed.component, parsed.name, body);
            if (std.mem.eql(u8, method, "DELETE")) return handleSkillsRemove(allocator, s, paths, parsed.component, parsed.name, target);
            return methodNotAllowed();
        }
        if (std.mem.eql(u8, action, "config-set")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return handleConfigSet(allocator, s, paths, parsed.component, parsed.name, body);
        }
        if (std.mem.eql(u8, action, "config-unset")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return handleConfigUnset(allocator, s, paths, parsed.component, parsed.name, body);
        }
        if (std.mem.eql(u8, action, "config-reload")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return handleConfigReload(allocator, s, paths, parsed.component, parsed.name);
        }
        if (std.mem.eql(u8, action, "config-validate")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return handleConfigValidate(allocator, s, paths, parsed.component, parsed.name, body);
        }
        if (std.mem.eql(u8, action, "integration")) {
            if (std.mem.eql(u8, method, "GET")) return handleIntegrationGet(allocator, s, manager, mutex, paths, parsed.component, parsed.name);
            if (std.mem.eql(u8, method, "POST")) return handleIntegrationPost(allocator, s, manager, mutex, paths, parsed.component, parsed.name, body);
            return methodNotAllowed();
        }
        if (std.mem.eql(u8, action, "tickets")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return handleNullTicketsAction(allocator, s, manager, mutex, paths, parsed.component, parsed.name, body);
        }

        // Remaining actions are POST-only.
        if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();

        if (std.mem.eql(u8, action, "start")) return handleStart(allocator, s, manager, paths, parsed.component, parsed.name, body);
        if (std.mem.eql(u8, action, "stop")) return handleStop(allocator, s, manager, paths, parsed.component, parsed.name);
        if (std.mem.eql(u8, action, "restart")) return handleRestart(allocator, s, manager, paths, parsed.component, parsed.name, body);

        return notFound();
    }

    // POST /api/instances/{component}/import — import standalone installation
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, parsed.name, "import")) {
        return handleImport(allocator, s, paths, parsed.component, body);
    }

    if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, parsed.name, "standalone")) {
        return handleStandalone(allocator, s, paths, parsed.component);
    }

    // No action — CRUD on the instance itself.
    if (std.mem.eql(u8, method, "GET")) return handleGet(allocator, s, manager, paths, parsed.component, parsed.name);
    if (std.mem.eql(u8, method, "DELETE")) return handleDelete(allocator, s, manager, paths, parsed.component, parsed.name, target);
    if (std.mem.eql(u8, method, "PATCH")) return handlePatch(s, parsed.component, parsed.name, body);

    return methodNotAllowed();
}

// ─── Tests ───────────────────────────────────────────────────────────────────

const TestManagerCtx = struct {
    fixture: test_helpers.TempPaths,
    manager: manager_mod.Manager,
    mutex: std_compat.sync.Mutex = .{},
    paths: paths_mod.Paths,

    fn init(allocator: std.mem.Allocator) TestManagerCtx {
        const fixture = test_helpers.TempPaths.init(allocator) catch @panic("TempPaths.init failed");
        return .{
            .fixture = fixture,
            .paths = fixture.paths,
            .manager = manager_mod.Manager.init(allocator, fixture.paths),
            .mutex = .{},
        };
    }

    fn deinit(self: *TestManagerCtx, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.manager.deinit();
        self.fixture.deinit();
    }
};

test "component default launch mode uses registry metadata" {
    try std.testing.expectEqualStrings("gateway", defaultLaunchModeForComponent("nullclaw"));
    try std.testing.expectEqualStrings("serve", defaultLaunchModeForComponent("nullwatch"));
    try std.testing.expectEqualStrings("gateway", defaultLaunchModeForComponent("unknown-component"));
}

test "pipeline summaries accept wrapped lists and JSON string definitions" {
    const allocator = std.testing.allocator;
    const raw =
        \\{
        \\  "pipelines": [{
        \\    "id": "pipe-dev",
        \\    "name": "Development",
        \\    "definition": "{\"states\":{\"claim\":{\"agent_role\":\"reviewer\"},\"build\":{\"agent_role\":\"coder\"}},\"transitions\":[{\"trigger\":\"complete\"},{\"trigger\":\"needs_review\"}]}"
        \\  }]
        \\}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const items = pipelineItemsFromValue(parsed.value) orelse @panic("pipelines missing");
    try std.testing.expectEqual(@as(usize, 1), items.len);

    const summary = try parsePipelineSummary(allocator, items[0]);
    defer deinitPipelineSummary(allocator, summary);
    try std.testing.expectEqualStrings("pipe-dev", summary.id);
    try std.testing.expectEqualStrings("Development", summary.name);
    try std.testing.expect(pipelineContainsString(summary.roles, "reviewer"));
    try std.testing.expect(pipelineContainsString(summary.roles, "coder"));
    try std.testing.expect(pipelineContainsString(summary.triggers, "complete"));
    try std.testing.expect(pipelineContainsString(summary.triggers, "needs_review"));
}

test "parseOptionalPositiveU32 rejects zero values" {
    try std.testing.expect(parseOptionalPositiveU32(std.json.Value{ .integer = 0 }) == null);
    try std.testing.expect(parseOptionalPositiveU32(std.json.Value{ .string = "0" }) == null);
    try std.testing.expect(parseOptionalPositiveU32(std.json.Value{ .string = "" }) == null);
    try std.testing.expectEqual(@as(?u32, 4), parseOptionalPositiveU32(std.json.Value{ .integer = 4 }));
    try std.testing.expectEqual(@as(?u32, 5), parseOptionalPositiveU32(std.json.Value{ .string = "5" }));
}

fn writeTestInstanceConfig(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    json: []const u8,
) !void {
    try paths.ensureDirs();
    const inst_dir = try paths.instanceDir(allocator, component, name);
    defer allocator.free(inst_dir);
    try ensurePath(inst_dir);

    const config_path = try paths.instanceConfig(allocator, component, name);
    defer allocator.free(config_path);
    const file = try std_compat.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);
    try file.writeAll("\n");
}

fn writeAbsoluteFile(path: []const u8, contents: []const u8) !void {
    const file = try std_compat.fs.createFileAbsolute(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(contents);
}

fn setTestHomeEnv(home: []const u8) !void {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    if (std.c.setenv("HOME", home.ptr, 1) != 0) return error.Unexpected;
}

fn restoreTestHomeEnv(previous_home: ?[]const u8) void {
    if (comptime builtin.os.tag == .windows) return;
    if (previous_home) |home| {
        _ = std.c.setenv("HOME", home.ptr, 1);
    } else {
        _ = std.c.unsetenv("HOME");
    }
}

fn withTestHome(
    allocator: std.mem.Allocator,
    home: []const u8,
    comptime callback: *const fn (std.mem.Allocator) anyerror!void,
) !void {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const previous_home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (previous_home) |value| allocator.free(value);
    defer restoreTestHomeEnv(previous_home);

    try setTestHomeEnv(home);
    try callback(allocator);
}

fn readAbsoluteSymlinkTarget(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: [std_compat.fs.max_path_bytes]u8 = undefined;
    const len = try std.Io.Dir.readLinkAbsolute(std_compat.io(), path, &buf);
    return allocator.dupe(u8, buf[0..len]);
}

fn parseImportResponse(allocator: std.mem.Allocator, body: []const u8) !struct {
    status: []const u8,
    instance: []const u8,
    path: []const u8,
} {
    const parsed = try std.json.parseFromSlice(struct {
        status: []const u8,
        instance: []const u8,
        path: []const u8,
    }, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return parsed.value;
}

fn parseStandaloneResponse(allocator: std.mem.Allocator, body: []const u8) !struct {
    standalone: bool,
    standalone_path: ?[]const u8 = null,
    already_imported: ?bool = null,
} {
    const parsed = try std.json.parseFromSlice(struct {
        standalone: bool,
        standalone_path: ?[]const u8 = null,
        already_imported: ?bool = null,
    }, allocator, body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    return parsed.value;
}

fn createStandaloneImportSource(
    allocator: std.mem.Allocator,
    fixture: test_helpers.TempPaths,
    relative_dir: []const u8,
    config_json: []const u8,
) ![]const u8 {
    const source_dir = try fixture.path(allocator, relative_dir);
    errdefer allocator.free(source_dir);
    try ensurePath(source_dir);

    const config_path = try std.fs.path.join(allocator, &.{ source_dir, "config.json" });
    defer allocator.free(config_path);
    try writeAbsoluteFile(config_path, config_json);
    return source_dir;
}

test "handleImport with custom path imports and registers instance" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const source_dir = try createStandaloneImportSource(allocator, state_fixture, "custom-nullclaw", "{\"instance_name\":\"config-name\",\"gateway\":{\"port\":3000}}\n");
    defer allocator.free(source_dir);

    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"name\":\"review-bot\"}}", .{source_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    const parsed = try parseImportResponse(allocator, resp.body);
    try std.testing.expectEqualStrings("imported", parsed.status);
    try std.testing.expectEqualStrings("review-bot", parsed.instance);
    try std.testing.expectEqualStrings(source_dir, parsed.path);

    const entry = s.getInstance("nullclaw", "review-bot").?;
    try std.testing.expectEqualStrings(local_binary.dev_local_version, entry.version);
    try std.testing.expect(!entry.auto_start);
    try std.testing.expectEqualStrings(imported_standalone_storage_mode, entry.storage_mode);
    try std.testing.expectEqualStrings(source_dir, entry.source_path);

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "review-bot");
    defer allocator.free(inst_dir);
    const link_target = try readAbsoluteSymlinkTarget(allocator, inst_dir);
    defer allocator.free(link_target);
    try std.testing.expectEqualStrings(source_dir, link_target);
}

test "handleImport without body imports default path as default" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const home_dir = try state_fixture.path(allocator, "home");
    defer allocator.free(home_dir);
    try ensurePath(home_dir);
    const dot_dir = try std.fs.path.join(allocator, &.{ home_dir, ".nullclaw" });
    defer allocator.free(dot_dir);
    try ensurePath(dot_dir);
    const config_path = try std.fs.path.join(allocator, &.{ dot_dir, "config.json" });
    defer allocator.free(config_path);
    try writeAbsoluteFile(config_path, "{\"gateway\":{\"port\":3000}}\n");

    const previous_home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (previous_home) |value| allocator.free(value);
    defer restoreTestHomeEnv(previous_home);
    try setTestHomeEnv(home_dir);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", "");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    const parsed = try parseImportResponse(allocator, resp.body);
    try std.testing.expectEqualStrings("default", parsed.instance);
    try std.testing.expectEqualStrings(dot_dir, parsed.path);
    try std.testing.expect(s.getInstance("nullclaw", "default") != null);
}

test "handleImport reads instance_name from config when name omitted" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const source_dir = try createStandaloneImportSource(allocator, state_fixture, "config-named", "{\"instance_name\":\"from-config\",\"gateway\":{\"port\":3000}}\n");
    defer allocator.free(source_dir);
    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{source_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    const parsed = try parseImportResponse(allocator, resp.body);
    try std.testing.expectEqualStrings("from-config", parsed.instance);
    try std.testing.expect(s.getInstance("nullclaw", "from-config") != null);
}

test "handleImport auto generates local import name when config lacks one" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Local Import #1", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "local-import-2", .{ .version = "1.0.0" });

    const source_dir = try createStandaloneImportSource(allocator, state_fixture, "generated-name", "{\"gateway\":{\"port\":3000}}\n");
    defer allocator.free(source_dir);
    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{source_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    const parsed = try parseImportResponse(allocator, resp.body);
    try std.testing.expectEqualStrings("local-import-3", parsed.instance);
    try std.testing.expect(s.getInstance("nullclaw", "local-import-3") != null);
}

test "handleImport returns error for missing path" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const missing_dir = try state_fixture.path(allocator, "missing-dir");
    defer allocator.free(missing_dir);
    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{missing_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"path does not exist\"}", resp.body);
}

test "handleImport returns error for missing config json at path" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const source_dir = try state_fixture.path(allocator, "no-config");
    defer allocator.free(source_dir);
    try ensurePath(source_dir);
    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{source_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"config.json not found at path\"}", resp.body);
}

test "handleImport returns error for invalid config json" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const source_dir = try createStandaloneImportSource(allocator, state_fixture, "invalid-config", "{not-json}\n");
    defer allocator.free(source_dir);
    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\"}}", .{source_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"config.json is not valid JSON\"}", resp.body);
}

test "handleImport returns error for duplicate instance name" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "review-bot", .{ .version = "1.0.0" });
    const source_dir = try createStandaloneImportSource(allocator, state_fixture, "duplicate-name", "{\"gateway\":{\"port\":3000}}\n");
    defer allocator.free(source_dir);
    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"name\":\"review-bot\"}}", .{source_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"invalid or duplicate instance name: review-bot\"}", resp.body);
}

test "handleImport returns error for invalid instance name" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const source_dir = try createStandaloneImportSource(allocator, state_fixture, "invalid-name", "{\"gateway\":{\"port\":3000}}\n");
    defer allocator.free(source_dir);
    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"name\":\"../bad\"}}", .{source_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"invalid or duplicate instance name: ../bad\"}", resp.body);
}

test "handleImport rejects route-reserved instance names" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const source_dir = try createStandaloneImportSource(allocator, state_fixture, "reserved-name", "{\"gateway\":{\"port\":3000}}\n");
    defer allocator.free(source_dir);
    const body = try std.fmt.allocPrint(allocator, "{{\"path\":\"{s}\",\"name\":\"standalone\"}}", .{source_dir});
    defer allocator.free(body);

    const resp = handleImport(allocator, &s, mctx.paths, "nullclaw", body);
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"invalid or duplicate instance name: standalone\"}", resp.body);
}

test "handleStandalone returns standalone false when default install is missing" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const home_dir = try state_fixture.path(allocator, "home-missing");
    defer allocator.free(home_dir);
    try ensurePath(home_dir);

    const previous_home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (previous_home) |value| allocator.free(value);
    defer restoreTestHomeEnv(previous_home);
    try setTestHomeEnv(home_dir);

    const resp = handleStandalone(allocator, &s, mctx.paths, "nullclaw");
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const parsed = try parseStandaloneResponse(allocator, resp.body);
    try std.testing.expect(!parsed.standalone);
    try std.testing.expect(parsed.standalone_path == null);
    try std.testing.expect(parsed.already_imported == null);
}

test "handleStandalone returns default path when install exists and is not imported" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const home_dir = try state_fixture.path(allocator, "home-standalone");
    defer allocator.free(home_dir);
    try ensurePath(home_dir);
    const dot_dir = try std.fs.path.join(allocator, &.{ home_dir, ".nullclaw" });
    defer allocator.free(dot_dir);
    try ensurePath(dot_dir);
    const config_path = try std.fs.path.join(allocator, &.{ dot_dir, "config.json" });
    defer allocator.free(config_path);
    try writeAbsoluteFile(config_path, "{\"gateway\":{\"port\":3000}}\n");

    const previous_home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (previous_home) |value| allocator.free(value);
    defer restoreTestHomeEnv(previous_home);
    try setTestHomeEnv(home_dir);

    const resp = handleStandalone(allocator, &s, mctx.paths, "nullclaw");
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const parsed = try parseStandaloneResponse(allocator, resp.body);
    try std.testing.expect(parsed.standalone);
    try std.testing.expectEqualStrings(dot_dir, parsed.standalone_path.?);
    try std.testing.expectEqual(@as(?bool, false), parsed.already_imported);
}

test "handleStandalone returns already imported after default import" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const home_dir = try state_fixture.path(allocator, "home-imported");
    defer allocator.free(home_dir);
    try ensurePath(home_dir);
    const dot_dir = try std.fs.path.join(allocator, &.{ home_dir, ".nullclaw" });
    defer allocator.free(dot_dir);
    try ensurePath(dot_dir);
    const config_path = try std.fs.path.join(allocator, &.{ dot_dir, "config.json" });
    defer allocator.free(config_path);
    try writeAbsoluteFile(config_path, "{\"gateway\":{\"port\":3000}}\n");

    const previous_home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch null;
    defer if (previous_home) |value| allocator.free(value);
    defer restoreTestHomeEnv(previous_home);
    try setTestHomeEnv(home_dir);

    const import_resp = handleImport(allocator, &s, mctx.paths, "nullclaw", "");
    defer allocator.free(import_resp.body);
    try std.testing.expectEqualStrings("200 OK", import_resp.status);

    const standalone_resp = handleStandalone(allocator, &s, mctx.paths, "nullclaw");
    defer allocator.free(standalone_resp.body);
    try std.testing.expectEqualStrings("200 OK", standalone_resp.status);

    const parsed = try parseStandaloneResponse(allocator, standalone_resp.body);
    try std.testing.expect(parsed.standalone);
    try std.testing.expectEqualStrings(dot_dir, parsed.standalone_path.?);
    try std.testing.expectEqual(@as(?bool, true), parsed.already_imported);
}

test "nullclaw gateway config patches generic gateway capabilities" {
    const allocator = std.testing.allocator;
    var fixture = try test_helpers.TempPaths.init(allocator);
    defer fixture.deinit();

    try writeTestInstanceConfig(
        allocator,
        fixture.paths,
        "nullclaw",
        "hat",
        "{\"gateway\":{\"port\":43123,\"max_body_size_bytes\":1024},\"a2a\":{\"enabled\":false},\"memory\":{\"profile\":\"minimal_none\",\"backend\":\"none\",\"auto_save\":false}}",
    );

    var access = try nullclaw_gateway_config.ensureConfig(allocator, fixture.paths, "nullclaw", "hat", .{});
    defer access.deinit(allocator);
    const token = access.token.?;
    try std.testing.expect(std.mem.startsWith(u8, token, nullclaw_gateway_config.token_prefix));
    try std.testing.expect(access.changed);

    const config_path = try fixture.paths.instanceConfig(allocator, "nullclaw", "hat");
    defer allocator.free(config_path);
    const file = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    const gateway = parsed.value.object.get("gateway").?.object;
    const a2a = parsed.value.object.get("a2a").?.object;
    try std.testing.expect(gateway.get("require_pairing").?.bool);
    try std.testing.expect(gateway.get("max_body_size_bytes").?.integer >= nullclaw_gateway_config.min_body_size);
    try std.testing.expect(gateway.get("request_timeout_secs").?.integer >= nullclaw_gateway_config.min_timeout_secs);
    try std.testing.expect(a2a.get("enabled").?.bool);
    try std.testing.expect(a2a.get("multi_modal").?.bool);

    const expected_hash = try nullclaw_gateway_config.hashGatewayTokenAlloc(allocator, token);
    defer allocator.free(expected_hash);
    const paired_tokens = gateway.get("paired_tokens").?.array.items;
    try std.testing.expectEqual(@as(usize, 1), paired_tokens.len);
    try std.testing.expectEqualStrings(expected_hash, paired_tokens[0].string);
    try std.testing.expect(!nullclaw_gateway_config.isNullhubGatewayToken(paired_tokens[0].string));

    const token_path = try nullclaw_gateway_config.gatewayTokenPath(allocator, fixture.paths, "nullclaw", "hat");
    defer allocator.free(token_path);
    const token_file = try std_compat.fs.openFileAbsolute(token_path, .{});
    defer token_file.close();
    const stored_token_bytes = try token_file.readToEndAlloc(allocator, 16 * 1024);
    defer allocator.free(stored_token_bytes);
    try std.testing.expectEqualStrings(token, std.mem.trim(u8, stored_token_bytes, " \t\r\n"));

    var access2 = try nullclaw_gateway_config.ensureConfig(allocator, fixture.paths, "nullclaw", "hat", .{});
    defer access2.deinit(allocator);
    try std.testing.expectEqualStrings(token, access2.token.?);
    try std.testing.expect(!access2.changed);

    var loaded = try nullclaw_gateway_config.loadAccess(allocator, fixture.paths, "nullclaw", "hat");
    defer loaded.deinit(allocator);
    try std.testing.expectEqualStrings(token, loaded.token.?);
}

test "buildAgentStreamA2aBody translates managed agent request to A2A message stream" {
    const allocator = std.testing.allocator;
    const body = try buildAgentStreamA2aBody(
        allocator,
        "{\"message\":\"hello \\\"world\\\"\",\"session_key\":\"interview-1\",\"request_id\":\"req-1\",\"message_id\":\"msg-1\",\"provider\":\"ignored\"}",
    );
    defer allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"method\":\"message/stream\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"id\":\"req-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messageId\":\"msg-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"contextId\":\"interview-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"hello \\\\\"world\\\\\"\"") != null);
    try std.testing.expect(isGatewayProxyPath("/api/instances/nullclaw/hat/agent-stream"));
    try std.testing.expect(isGatewayProxyPath("/api/instances/nullclaw/hat/a2a"));
    try std.testing.expect(isGatewayProxyPath("/api/instances/nullclaw/hat/a2a-stream"));
    try std.testing.expect(isGatewayProxyPath("/api/instances/nullclaw/hat/transcribe"));
    try std.testing.expect(isGatewayProxyPath("/api/instances/nullclaw/Opencode%20Go/a2a"));
    try std.testing.expect(!isGatewayProxyPath("/api/instances/nullclaw/name%2Fwith%2Fslash/a2a"));
    try std.testing.expect(!isGatewayProxyPath("/api/instances/nullclaw/name%GG/a2a"));
}

fn writeTestTrackerWorkflow(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    boiler_name: []const u8,
    file_name: []const u8,
    pipeline_id: []const u8,
    claim_role: []const u8,
    success_trigger: []const u8,
) !void {
    const inst_dir = try paths.instanceDir(allocator, "nullboiler", boiler_name);
    defer allocator.free(inst_dir);
    const workflows_dir = try std.fs.path.join(allocator, &.{ inst_dir, "workflows" });
    defer allocator.free(workflows_dir);
    try ensurePath(workflows_dir);

    const workflow_path = try std.fs.path.join(allocator, &.{ workflows_dir, file_name });
    defer allocator.free(workflow_path);
    const rendered = try std.json.Stringify.valueAlloc(allocator, .{
        .id = "wf-test",
        .pipeline_id = pipeline_id,
        .claim_roles = &.{claim_role},
        .execution = "subprocess",
        .prompt_template = "Task {{task.id}}: {{task.title}}",
        .on_success = .{
            .transition_to = success_trigger,
        },
    }, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(rendered);

    const file = try std_compat.fs.createFileAbsolute(workflow_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(rendered);
    try file.writeAll("\n");
}

fn writeTestBinary(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    version: []const u8,
    script: []const u8,
) !void {
    try paths.ensureDirs();
    const bin_path = try paths.binary(allocator, component, version);
    defer allocator.free(bin_path);

    const file = try std_compat.fs.createFileAbsolute(bin_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(script);
    if (comptime std_compat.fs.has_executable_bit) {
        try file.chmod(0o755);
    }
}

fn writeTestCronStore(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    json: []const u8,
) !void {
    const inst_dir = try paths.instanceDir(allocator, component, name);
    defer allocator.free(inst_dir);
    try ensurePath(inst_dir);

    const cron_path = try std.fs.path.join(allocator, &.{ inst_dir, "cron.json" });
    defer allocator.free(cron_path);

    const file = try std_compat.fs.createFileAbsolute(cron_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(json);
    try file.writeAll("\n");
}

test "parsePath: component and name" {
    const p = parsePath("/api/instances/nullclaw/my-agent").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
    try std.testing.expect(p.action == null);
}

test "parsePath: component, name, and action" {
    const p = parsePath("/api/instances/nullclaw/my-agent/start").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("my-agent", p.name);
    try std.testing.expectEqualStrings("start", p.action.?);
}

test "parsePath: provider-health action" {
    const p = parsePath("/api/instances/nullclaw/default/provider-health").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expectEqualStrings("provider-health", p.action.?);
}

test "parsePath: usage action with query string" {
    const p = parsePath("/api/instances/nullclaw/default/usage?window=7d").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expectEqualStrings("usage", p.action.?);
}

test "parsePath: onboarding action" {
    const p = parsePath("/api/instances/nullclaw/default/onboarding").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expectEqualStrings("onboarding", p.action.?);
}

test "parsePathAlloc decodes percent-encoded names" {
    const allocator = std.testing.allocator;
    const parsed = (try parsePathAlloc(allocator, "/api/instances/nullclaw/Opencode%20Go/provider-health")).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("nullclaw", parsed.component);
    try std.testing.expectEqualStrings("Opencode Go", parsed.name);
    try std.testing.expectEqualStrings("provider-health", parsed.action.?);
}

test "parsePathAlloc decodes additional percent-encoded special characters" {
    const allocator = std.testing.allocator;
    const parsed = (try parsePathAlloc(allocator, "/api/instances/nullclaw/NullClaw%20MiMo%20%28beta%29%20%231/status")).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("nullclaw", parsed.component);
    try std.testing.expectEqualStrings("NullClaw MiMo (beta) #1", parsed.name);
    try std.testing.expectEqualStrings("status", parsed.action.?);
}

test "parsePathAlloc rejects malformed percent-encoded names" {
    try std.testing.expectError(
        error.InvalidPathSegment,
        parsePathAlloc(std.testing.allocator, "/api/instances/nullclaw/name%GG/status"),
    );
}

test "parseChannelsPathAlloc decodes percent-encoded names" {
    const allocator = std.testing.allocator;
    const parsed = (try parseChannelsPathAlloc(allocator, "/api/instances/nullclaw/Opencode%20Go/channels/telegram")).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("nullclaw", parsed.component);
    try std.testing.expectEqualStrings("Opencode Go", parsed.name);
    try std.testing.expectEqualStrings("telegram", parsed.channel_type.?);
}

test "parseChannelsPath: collection route" {
    const p = parseChannelsPath("/api/instances/nullclaw/default/channels").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expect(p.channel_type == null);
}

test "parseChannelsPath: detail route" {
    const p = parseChannelsPath("/api/instances/nullclaw/default/channels/telegram").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expectEqualStrings("telegram", p.channel_type.?);
}

test "parseCronPath: collection route" {
    const p = parseCronPath("/api/instances/nullclaw/default/cron").?;
    try std.testing.expectEqualStrings("nullclaw", p.component);
    try std.testing.expectEqualStrings("default", p.name);
    try std.testing.expectEqual(p.action, .collection);
}

test "parseCronPath: run route" {
    const p = parseCronPath("/api/instances/nullclaw/default/cron/job-1/run").?;
    try std.testing.expectEqualStrings("job-1", p.job_id.?);
    try std.testing.expectEqual(p.action, .run);
}

test "parseCronPathAlloc decodes percent-encoded names and job ids" {
    const allocator = std.testing.allocator;
    const parsed = (try parseCronPathAlloc(allocator, "/api/instances/nullclaw/Opencode%20Go/cron/job%201/run")).?;
    defer parsed.deinit(allocator);

    try std.testing.expectEqualStrings("nullclaw", parsed.component);
    try std.testing.expectEqualStrings("Opencode Go", parsed.name);
    try std.testing.expectEqualStrings("job 1", parsed.job_id.?);
    try std.testing.expectEqual(parsed.action, .run);
}

test "parseCronPath: rejects unknown verb" {
    try std.testing.expect(parseCronPath("/api/instances/nullclaw/default/cron/job-1/nope") == null);
}

test "parseUsageWindow defaults to 24h" {
    try std.testing.expectEqualStrings("24h", parseUsageWindow("/api/instances/nullclaw/default/usage"));
}

test "parseUsageWindow accepts supported values" {
    try std.testing.expectEqualStrings("24h", parseUsageWindow("/api/instances/nullclaw/default/usage?window=24h"));
    try std.testing.expectEqualStrings("7d", parseUsageWindow("/api/instances/nullclaw/default/usage?window=7d"));
    try std.testing.expectEqualStrings("30d", parseUsageWindow("/api/instances/nullclaw/default/usage?window=30d"));
    try std.testing.expectEqualStrings("all", parseUsageWindow("/api/instances/nullclaw/default/usage?window=all"));
}

test "query value decoding handles percent-encoded and plus-separated values" {
    const allocator = std.testing.allocator;
    const value = (try query_api.valueAlloc(allocator, "/api/instances/nullclaw/default/memory?query=hello+world%2Fskills", "query")).?;
    defer allocator.free(value);
    try std.testing.expectEqualStrings("hello world/skills", value);
}

test "parseAnyHttpStatusCode extracts first valid http code" {
    try std.testing.expectEqual(@as(?u16, 200), parseAnyHttpStatusCode("{\"x\":1}\n200\n"));
    try std.testing.expectEqual(@as(?u16, 401), parseAnyHttpStatusCode("status=401 unauthorized"));
    try std.testing.expectEqual(@as(?u16, null), parseAnyHttpStatusCode("not-a-code"));
}

test "isAllowedNullTicketsAction allows only safe tracker actions" {
    try std.testing.expect(isAllowedNullTicketsAction(.GET, "/pipelines"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/pipelines"));
    try std.testing.expect(isAllowedNullTicketsAction(.GET, "/tasks?limit=8"));
    try std.testing.expect(isAllowedNullTicketsAction(.GET, "/tasks/task-a/dependencies"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/tasks/task-a/assignments"));
    try std.testing.expect(isAllowedNullTicketsAction(.DELETE, "/tasks/task-a/assignments/agent-a"));
    try std.testing.expect(isAllowedNullTicketsAction(.GET, "/ops/queue"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/tasks"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/leases/claim"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/leases/lease-a/heartbeat"));
    try std.testing.expect(isAllowedNullTicketsAction(.GET, "/runs/run-a/events?limit=20"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/runs/run-a/events"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/runs/run-a/transition"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/runs/run-a/fail"));
    try std.testing.expect(isAllowedNullTicketsAction(.GET, "/artifacts?task_id=task-a"));
    try std.testing.expect(isAllowedNullTicketsAction(.POST, "/artifacts"));

    try std.testing.expect(!isAllowedNullTicketsAction(.POST, "/store/default/key"));
    try std.testing.expect(!isAllowedNullTicketsAction(.DELETE, "/tasks/task-a"));
    try std.testing.expect(!isAllowedNullTicketsAction(.GET, "http://127.0.0.1:1/tasks"));
    try std.testing.expect(!isAllowedNullTicketsAction(.GET, "/tasks\n/evil"));
    try std.testing.expect(!isAllowedNullTicketsAction(.POST, "/tasks?limit=1"));
    try std.testing.expect(!isAllowedNullTicketsAction(.POST, "/runs/run-a/events?limit=1"));
    try std.testing.expect(!isAllowedNullTicketsAction(.POST, "/leases/lease-a/heartbeat?ttl=1"));
}

test "classifyNullTicketsAction separates instance and lease scoped auth" {
    try std.testing.expectEqual(NullTicketsActionAuthMode.instance_token, classifyNullTicketsAction(.GET, "/tasks?limit=8").?);
    try std.testing.expectEqual(NullTicketsActionAuthMode.instance_token, classifyNullTicketsAction(.POST, "/leases/claim").?);
    try std.testing.expectEqual(NullTicketsActionAuthMode.lease_token, classifyNullTicketsAction(.POST, "/leases/lease-a/heartbeat").?);
    try std.testing.expectEqual(NullTicketsActionAuthMode.lease_token, classifyNullTicketsAction(.POST, "/runs/run-a/events").?);
    try std.testing.expect(classifyNullTicketsAction(.POST, "/runs/run-a/events?limit=1") == null);
    try std.testing.expect(classifyNullTicketsAction(.POST, "/store/default/key") == null);
}

test "nullTicketsForwardedToken does not mix admin and lease credentials" {
    try std.testing.expectEqualStrings(
        "admin-token",
        nullTicketsForwardedToken(.instance_token, "admin-token", "lease-token").?,
    );
    try std.testing.expectEqualStrings(
        "lease-token",
        nullTicketsForwardedToken(.lease_token, "admin-token", "lease-token").?,
    );
    try std.testing.expect(nullTicketsForwardedToken(.lease_token, "admin-token", null) == null);
    try std.testing.expect(nullTicketsForwardedToken(.lease_token, "admin-token", "") == null);
}

test "actionStatus preserves expired lease status" {
    try std.testing.expectEqualStrings("410 Gone", actionStatus(410));
}

test "classifyProbeFailure maps status codes" {
    const unauthorized = classifyProbeFailure(401, "", "");
    try std.testing.expectEqualStrings("invalid_api_key", unauthorized.reason);
    const forbidden = classifyProbeFailure(403, "", "");
    try std.testing.expectEqualStrings("forbidden", forbidden.reason);
    const limited = classifyProbeFailure(429, "", "");
    try std.testing.expectEqualStrings("rate_limited", limited.reason);
    const unavailable = classifyProbeFailure(503, "", "");
    try std.testing.expectEqualStrings("provider_unavailable", unavailable.reason);
}

test "classifyProbeFailure maps stderr hints" {
    const unauthorized = classifyProbeFailure(null, "", "Unauthorized");
    try std.testing.expectEqualStrings("invalid_api_key", unauthorized.reason);
    const network = classifyProbeFailure(null, "", "connection timeout");
    try std.testing.expectEqualStrings("network_error", network.reason);
}

test "canonicalProbeReason keeps stable reason slices" {
    try std.testing.expectEqualStrings("ok", canonicalProbeReason("ok", true));
    try std.testing.expectEqualStrings("invalid_api_key", canonicalProbeReason("invalid_api_key", false));
    try std.testing.expectEqualStrings("auth_check_failed", canonicalProbeReason("unexpected_reason", false));
    try std.testing.expectEqualStrings("ok", canonicalProbeReason("unexpected_reason", true));
}

test "parsePath: rejects bare /api/instances/" {
    try std.testing.expect(parsePath("/api/instances/") == null);
}

test "parsePath: rejects wrong prefix" {
    try std.testing.expect(parsePath("/api/other/foo/bar") == null);
}

test "parsePath: rejects too many segments" {
    try std.testing.expect(parsePath("/api/instances/a/b/c/d") == null);
}

test "parseChannelsPath: rejects extra segments" {
    try std.testing.expect(parseChannelsPath("/api/instances/nullclaw/default/channels/telegram/extra") == null);
}

test "parsePath: component only (no name) returns null" {
    try std.testing.expect(parsePath("/api/instances/nullclaw") == null);
}

test "handleList returns valid JSON structure" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });
    try s.addInstance("nullclaw", "staging", .{ .version = "2026.3.1", .auto_start = false });

    const resp = handleList(allocator, &s, &mctx.manager);
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("application/json", resp.content_type);

    // Verify it is valid JSON by parsing it.
    const parsed = try std.json.parseFromSlice(
        struct {
            instances: std.json.ArrayHashMap(std.json.ArrayHashMap(struct {
                version: []const u8,
                auto_start: bool,
                launch_mode: []const u8 = "gateway",
                verbose: bool = false,
                status: []const u8,
            })),
        },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    // Check the nullclaw component exists with two instances.
    const nullclaw = parsed.value.instances.map.get("nullclaw").?;
    try std.testing.expectEqual(@as(usize, 2), nullclaw.map.count());

    const agent = nullclaw.map.get("my-agent").?;
    try std.testing.expectEqualStrings("2026.3.1", agent.version);
    try std.testing.expect(agent.auto_start == true);
}

test "handleGet returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const resp = handleGet(allocator, &s, &mctx.manager, "nonexistent", "nope");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", resp.body);
}

test "handleGet returns instance detail JSON" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.3.1", .auto_start = true });

    const resp = handleGet(allocator, &s, &mctx.manager, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);

    // Parse and verify JSON content.
    const parsed = try std.json.parseFromSlice(
        struct {
            version: []const u8,
            auto_start: bool,
            launch_mode: []const u8 = "gateway",
            verbose: bool = false,
            status: []const u8,
        },
        allocator,
        resp.body,
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    try std.testing.expectEqualStrings("2026.3.1", parsed.value.version);
    try std.testing.expect(parsed.value.auto_start == true);
    try std.testing.expectEqualStrings("stopped", parsed.value.status);
}

test "handleInstanceStatus uses nullclaw CLI when available" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "status" ] && [ "$2" = "--json" ]; then
        \\  printf '%s\n' '{"version":"1.0.0","pid":1234,"uptime_seconds":42,"overall_status":"ok","components":{"gateway":{"status":"ok","updated_at":"2026-04-17T00:00:00Z","last_ok":"2026-04-17T00:00:00Z","last_error":null,"restart_count":0}}}'
        \\  exit 0
        \\fi
        \\exit 64
        ,
    );

    const resp = handleInstanceStatus(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"pid\":1234") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"overall_status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"components\":{\"gateway\"") != null);
}

test "handleInstanceStatus returns gateway error when managed CLI is unavailable" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "2026.4.17" });

    const resp = handleInstanceStatus(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("502 Bad Gateway", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"component_binary_missing\"") != null);
}

test "handleStart returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const resp = handleStart(allocator, &s, &mctx.manager, mctx.paths, "nope", "nope", "");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "handleStart returns 500 when binary does not exist" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    // The binary is absent from the isolated test root, so startInstance
    // will fail and the handler returns 500.
    const resp = handleStart(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent", "");
    try std.testing.expectEqualStrings("500 Internal Server Error", resp.status);
}

test "handleStart keeps gateway instances on their HTTP health port" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .launch_mode = "gateway" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "my-agent", "{\"gateway\":{\"port\":43123}}");
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "--export-manifest" ]; then
        \\  printf '%s\n' '{"launch":{"command":"gateway","args":[]},"health":{"endpoint":"/health","port_from_config":"gateway.port"},"ports":[{"name":"gateway","config_key":"gateway.port","default":3000,"protocol":"http"}]}'
        \\  exit 0
        \\fi
        \\sleep 60
        ,
    );

    const resp = handleStart(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const status = mctx.manager.getStatus("nullclaw", "my-agent").?;
    try std.testing.expectEqual(manager_mod.Status.starting, status.status);
    try std.testing.expectEqual(@as(u16, 43123), status.port);

    mctx.manager.stopInstance("nullclaw", "my-agent") catch {};
}

test "handleStart normalizes manifest binary command to runnable launch args" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "watch", .{ .version = "1.0.0", .launch_mode = "nullwatch" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "watch", "{\"port\":43124}");
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullwatch",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "--export-manifest" ]; then
        \\  printf '%s\n' '{"launch":{"command":"nullwatch","args":["serve"]},"health":{"endpoint":"/health","port_from_config":"port"},"ports":[{"name":"api","config_key":"port","default":7710,"protocol":"http"}]}'
        \\  exit 0
        \\fi
        \\sleep 60
        ,
    );

    const resp = handleStart(allocator, &s, &mctx.manager, mctx.paths, "nullwatch", "watch", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const entry = s.getInstance("nullwatch", "watch").?;
    try std.testing.expectEqualStrings("serve", entry.launch_mode);

    const status = mctx.manager.getStatus("nullwatch", "watch").?;
    try std.testing.expectEqual(manager_mod.Status.starting, status.status);
    try std.testing.expectEqual(@as(u16, 43124), status.port);
    const inst = mctx.manager.instances.get("nullwatch/watch").?;
    try std.testing.expectEqual(@as(usize, 1), inst.launch_args.len);
    try std.testing.expectEqualStrings("serve", inst.launch_args[0]);

    mctx.manager.stopInstance("nullwatch", "watch") catch {};
}

test "handleStart preserves explicit launch mode when it differs from manifest mode" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "watch", .{ .version = "1.0.0", .launch_mode = "gateway" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "watch", "{\"port\":43125}");
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullwatch",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "--export-manifest" ]; then
        \\  printf '%s\n' '{"launch":{"command":"nullwatch","args":["serve"]},"health":{"endpoint":"/health","port_from_config":"port"},"ports":[{"name":"api","config_key":"port","default":7710,"protocol":"http"}]}'
        \\  exit 0
        \\fi
        \\sleep 60
        ,
    );

    const resp = handleStart(allocator, &s, &mctx.manager, mctx.paths, "nullwatch", "watch", "");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const entry = s.getInstance("nullwatch", "watch").?;
    try std.testing.expectEqualStrings("gateway", entry.launch_mode);
    const inst = mctx.manager.instances.get("nullwatch/watch").?;
    try std.testing.expectEqualStrings("gateway", inst.launch_args[0]);

    mctx.manager.stopInstance("nullwatch", "watch") catch {};
}

test "handleStop returns 200 for existing instance" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handleStop(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"stopped\"}", resp.body);
}

test "handleRestart returns 500 when binary does not exist" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    // Binary doesn't exist so startInstance fails => 500
    const resp = handleRestart(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent", "");
    try std.testing.expectEqualStrings("500 Internal Server Error", resp.status);
}

test "handleDelete removes instance" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"deleted\"}", resp.body);

    // Verify it was actually removed.
    try std.testing.expect(s.getInstance("nullclaw", "my-agent") == null);
}

test "dispatch gets instance with percent-encoded name" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.0" });

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "GET",
        "/api/instances/nullclaw/Opencode%20Go",
        "",
    ).?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Opencode Go") != null);
}

test "dispatch deletes instance with percent-encoded name" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.0" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "Opencode Go", "{\"gateway\":{\"port\":3000}}");

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "DELETE",
        "/api/instances/nullclaw/Opencode%20Go",
        "",
    ).?;

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"deleted\"}", resp.body);
    try std.testing.expect(s.getInstance("nullclaw", "Opencode Go") == null);
}

test "handleDelete removes instance directory from active path" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "my-agent", "{\"gateway\":{\"port\":3000}}");

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst_dir);

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    std_compat.fs.accessAbsolute(inst_dir, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    @panic("expected instance directory to be removed");
}

test "handleDelete restores instance when state save fails" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();

    const bad_state_path = try state_fixture.path(allocator, "missing/state.json");
    defer allocator.free(bad_state_path);

    var s = state_mod.State.init(allocator, bad_state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "my-agent", "{\"gateway\":{\"port\":3000}}");

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst_dir);

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent");
    try std.testing.expectEqualStrings("500 Internal Server Error", resp.status);
    try std.testing.expect(s.getInstance("nullclaw", "my-agent") != null);
    try std_compat.fs.accessAbsolute(inst_dir, .{});
}

test "handleDelete returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nope", "nope", "/api/instances/nope/nope");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "handleDelete blocks nulltickets while nullboiler is linked" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nulltickets", "tracker-a", .{ .version = "1.0.0" });
    try s.addInstance("nullboiler", "boiler-a", .{ .version = "1.0.0" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nulltickets", "tracker-a", "{\"port\":7711,\"api_token\":\"admin-token\"}");
    try writeTestInstanceConfig(allocator, mctx.paths, "nullboiler", "boiler-a", "{\"port\":8811,\"tracker\":{\"url\":\"http://127.0.0.1:7711\",\"api_token\":\"admin-token\"}}");

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nulltickets", "tracker-a", "/api/instances/nulltickets/tracker-a");
    try std.testing.expectEqualStrings("409 Conflict", resp.status);
    defer allocator.free(resp.body);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"force_required\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"boiler-a\"") != null);
    try std.testing.expect(s.getInstance("nulltickets", "tracker-a") != null);
}

test "handleDelete force unlinks nullboiler before deleting nulltickets" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nulltickets", "tracker-a", .{ .version = "1.0.0" });
    try s.addInstance("nullboiler", "boiler-a", .{ .version = "1.0.0" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nulltickets", "tracker-a", "{\"port\":7711,\"api_token\":\"admin-token\"}");
    try writeTestInstanceConfig(allocator, mctx.paths, "nullboiler", "boiler-a", "{\"port\":8811,\"tracker\":{\"url\":\"http://127.0.0.1:7711\",\"api_token\":\"admin-token\",\"agent_id\":\"worker\"}}");

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nulltickets", "tracker-a", "/api/instances/nulltickets/tracker-a?force=1");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(s.getInstance("nulltickets", "tracker-a") == null);
    try std.testing.expect(s.getInstance("nullboiler", "boiler-a") != null);

    const config_path = try mctx.paths.instanceConfig(allocator, "nullboiler", "boiler-a");
    defer allocator.free(config_path);
    const config_bytes = try std.fs.readFileAbsolute(allocator, config_path, 1024 * 1024);
    defer allocator.free(config_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("tracker") == null);
}

test "handleDelete blocks nullwatch while nullclaw telemetry is linked" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "observer-a", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "agent-a", .{ .version = "1.0.0" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "observer-a", "{\"port\":7712,\"api_token\":\"watch-token\"}");
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "agent-a", "{\"diagnostics\":{\"backend\":\"otel\",\"otel\":{\"endpoint\":\"http://127.0.0.1:7712\",\"service_name\":\"nullclaw/agent-a\"}}}");

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nullwatch", "observer-a", "/api/instances/nullwatch/observer-a");
    try std.testing.expectEqualStrings("409 Conflict", resp.status);
    defer allocator.free(resp.body);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"force_required\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"agent-a\"") != null);
    try std.testing.expect(s.getInstance("nullwatch", "observer-a") != null);
}

test "handleDelete force unlinks nullclaw telemetry before deleting nullwatch" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "observer-a", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "agent-a", .{ .version = "1.0.0" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "observer-a", "{\"port\":7712,\"api_token\":\"watch-token\"}");
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "agent-a", "{\"diagnostics\":{\"backend\":\"otel\",\"log_tool_calls\":true,\"otel\":{\"endpoint\":\"http://127.0.0.1:7712\",\"service_name\":\"nullclaw/agent-a\",\"headers\":{\"Authorization\":\"Bearer watch-token\"}}}}");

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nullwatch", "observer-a", "/api/instances/nullwatch/observer-a?force=1");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(s.getInstance("nullwatch", "observer-a") == null);
    try std.testing.expect(s.getInstance("nullclaw", "agent-a") != null);

    const config_path = try mctx.paths.instanceConfig(allocator, "nullclaw", "agent-a");
    defer allocator.free(config_path);
    const config_bytes = try std.fs.readFileAbsolute(allocator, config_path, 1024 * 1024);
    defer allocator.free(config_bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const diagnostics = parsed.value.object.get("diagnostics").?.object;
    try std.testing.expectEqualStrings("jsonl", diagnostics.get("backend").?.string);
    try std.testing.expect(diagnostics.get("log_tool_calls").?.bool);
    try std.testing.expect(diagnostics.get("otel") == null);
}

test "handlePatch updates auto_start" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .auto_start = false });

    const resp = handlePatch(&s, "nullclaw", "my-agent", "{\"auto_start\":true}");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const entry = s.getInstance("nullclaw", "my-agent").?;
    try std.testing.expect(entry.auto_start == true);
}

test "handlePatch returns 404 for missing instance" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    const resp = handlePatch(&s, "nope", "nope", "{\"auto_start\":true}");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "handlePatch returns 400 for invalid JSON" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handlePatch(&s, "nullclaw", "my-agent", "not-json");
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);
}

test "handlePatch updates launch_mode" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handlePatch(&s, "nullclaw", "my-agent", "{\"launch_mode\":\"agent\"}");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const entry = s.getInstance("nullclaw", "my-agent").?;
    try std.testing.expectEqualStrings("agent", entry.launch_mode);
}

test "handlePatch normalizes service component launch_mode" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addInstance("nullboiler", "default", .{ .version = "1.0.0", .launch_mode = "server" });

    const resp = handlePatch(&s, "nullboiler", "default", "{\"launch_mode\":\"nullboiler\"}");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const entry = s.getInstance("nullboiler", "default").?;
    try std.testing.expectEqualStrings("server", entry.launch_mode);
}

test "handlePatch rejects invalid launch_mode" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handlePatch(&s, "nullclaw", "my-agent", "{\"launch_mode\":\"   \"}");
    try std.testing.expectEqualStrings("400 Bad Request", resp.status);

    const entry = s.getInstance("nullclaw", "my-agent").?;
    try std.testing.expectEqualStrings("gateway", entry.launch_mode);
}

test "handlePatch updates verbose startup flag" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = handlePatch(&s, "nullclaw", "my-agent", "{\"verbose\":true}");
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const entry = s.getInstance("nullclaw", "my-agent").?;
    try std.testing.expect(entry.verbose);
}

test "handleGet includes launch_mode in JSON" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .launch_mode = "agent" });

    const resp = handleGet(allocator, &s, &mctx.manager, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"launch_mode\":\"agent\"") != null);
}

test "handleGet includes verbose in JSON" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0", .verbose = true });

    const resp = handleGet(allocator, &s, &mctx.manager, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"verbose\":true") != null);
}

test "dispatch routes GET /api/instances" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "nullclaw") != null);
}

test "dispatch routes POST start action" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    // Binary doesn't exist so start returns 500
    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/start", "").?;
    try std.testing.expectEqualStrings("500 Internal Server Error", resp.status);
}

test "dispatch routes GET provider-health action" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    // No config file exists in this test fixture, so health action returns 404.
    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/provider-health", "").?;
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "dispatch routes GET status action" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "status" ] && [ "$2" = "--json" ]; then
        \\  printf '%s\n' '{"version":"1.0.0","pid":321,"uptime_seconds":7,"overall_status":"starting","components":{}}'
        \\  exit 0
        \\fi
        \\exit 64
        ,
    );

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/status", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"uptime_seconds\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"overall_status\":\"starting\"") != null);
}

test "dispatch routes GET models action returns gateway error when CLI is unavailable" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/models", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("502 Bad Gateway", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"component_binary_missing\"") != null);
}

test "dispatch routes GET models action via nullclaw CLI when available" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "models" ] && [ "$2" = "summary" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '{"default_provider":"openai","default_model":"openai/gpt-5","providers":[{"name":"openai","has_key":true},{"name":"ollama","has_key":false}]}'
        \\  exit 0
        \\fi
        \\exit 64
        ,
    );

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/models", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"default_provider\":\"openai\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"default_model\":\"openai/gpt-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"ollama\",\"has_key\":false") != null);
}

test "dispatch routes GET models action rejects malformed CLI JSON" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.1-invalid" });
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.1-invalid",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "models" ] && [ "$2" = "summary" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '"default_provider":"openai"}'
        \\  exit 0
        \\fi
        \\exit 64
        ,
    );

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/models", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("502 Bad Gateway", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"invalid_cli_response\"") != null);
}

test "dispatch routes GET cron action returns gateway error when CLI is unavailable" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/cron", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("502 Bad Gateway", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"component_binary_missing\"") != null);
}

test "dispatch routes GET cron action via nullclaw CLI when available" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "cron" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '[{"id":"job-cli","expression":"*/10 * * * *","command":"echo cli","paused":false,"one_shot":false}]'
        \\  exit 0
        \\fi
        \\exit 64
        ,
    );

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/cron", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"jobs\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job-cli\"") != null);
}

test "dispatch routes GET cron action with percent-encoded instance name" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.0" });
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "cron" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '[{"id":"job-cli","expression":"*/10 * * * *","command":"echo cli","paused":false,"one_shot":false}]'
        \\  exit 0
        \\fi
        \\exit 64
        ,
    );

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/Opencode%20Go/cron", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"jobs\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job-cli\"") != null);
}

test "dispatch routes POST cron create action" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "cron" ] && [ "$2" = "add" ]; then
        \\  home="${NULLCLAW_HOME:?}"
        \\  cat > "${home}/cron.json" <<EOF
        \\[{"id":"job-1","expression":"$3","command":"$4","paused":false,"one_shot":false}]
        \\EOF
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        ,
    );

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/cron",
        "{\"expression\":\"*/5 * * * *\",\"command\":\"echo hello\"}",
    ).?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"job\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"command\":\"echo hello\"") != null);
}

test "dispatch routes POST cron pause action with percent-encoded instance name" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.0" });
    const cron_path = try std.fs.path.join(allocator, &.{ mctx.paths.root, "instances", "nullclaw", "Opencode Go", "cron.json" });
    defer allocator.free(cron_path);
    try ensurePath(std.fs.path.dirname(cron_path).?);
    const cron_file = try std_compat.fs.createFileAbsolute(cron_path, .{ .truncate = true });
    defer cron_file.close();
    try cron_file.writeAll(
        \\[
        \\  {"id":"job 1","expression":"*/20 * * * *","command":"echo go heartbeat","paused":false,"one_shot":false,"job_type":"shell","enabled":true,"delete_after_run":false}
        \\]
    );

    try writeTestBinary(
        allocator,
        mctx.paths,
        "nullclaw",
        "1.0.0",
        \\#!/bin/sh
        \\set -eu
        \\home="${NULLCLAW_HOME:?}"
        \\if [ "$1" = "cron" ] && [ "$2" = "pause" ] && [ "$3" = "job 1" ]; then
        \\  cat > "${home}/cron.json" <<'EOF'
        \\[
        \\  {"id":"job 1","expression":"*/20 * * * *","command":"echo go heartbeat","paused":true,"one_shot":false,"job_type":"shell","enabled":true,"delete_after_run":false}
        \\]
        \\EOF
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        ,
    );

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/Opencode%20Go/cron/job%201/pause",
        "",
    ).?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"paused\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"id\":\"job 1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"paused\":true") != null);
}

test "handleOnboarding reports pending bootstrap for fresh nullclaw workspace" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst_dir);
    const workspace_dir = try std.fs.path.join(allocator, &.{ inst_dir, "workspace" });
    defer allocator.free(workspace_dir);
    try ensurePath(workspace_dir);

    const bootstrap_path = try std.fs.path.join(allocator, &.{ workspace_dir, "BOOTSTRAP.md" });
    defer allocator.free(bootstrap_path);
    const bootstrap_file = try std_compat.fs.createFileAbsolute(bootstrap_path, .{ .truncate = true });
    defer bootstrap_file.close();
    try bootstrap_file.writeAll("# bootstrap\n");

    const resp = handleOnboarding(allocator, &s, mctx.paths, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"pending\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"starter_message\":\"Wake up, my friend!\"") != null);
}

test "handleOnboarding reports pending bootstrap from workspace state without disk bootstrap file" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst_dir);
    const workspace_dir = try std.fs.path.join(allocator, &.{ inst_dir, "workspace" });
    defer allocator.free(workspace_dir);
    try ensurePath(workspace_dir);

    const workspace_state_path = try nullclawWorkspaceStatePath(allocator, workspace_dir);
    defer allocator.free(workspace_state_path);
    try ensurePath(std.fs.path.dirname(workspace_state_path).?);
    const state_file = try std_compat.fs.createFileAbsolute(workspace_state_path, .{ .truncate = true });
    defer state_file.close();
    try state_file.writeAll(
        "{\n  \"bootstrap_seeded_at\": \"2026-03-13T01:17:17Z\"\n}\n",
    );

    const resp = handleOnboarding(allocator, &s, mctx.paths, "nullclaw", "my-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"bootstrap_exists\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"pending\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"completed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"bootstrap_seeded_at\":\"2026-03-13T01:17:17Z\"") != null);
}

test "handleOnboarding stays idle when workspace bootstrap state is absent" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "empty-agent", .{ .version = "1.0.4" });

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "empty-agent");
    defer allocator.free(inst_dir);
    const workspace_dir = try std.fs.path.join(allocator, &.{ inst_dir, "workspace" });
    defer allocator.free(workspace_dir);
    try ensurePath(workspace_dir);

    const resp = handleOnboarding(allocator, &s, mctx.paths, "nullclaw", "empty-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"bootstrap_exists\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"pending\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"completed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"bootstrap_seeded_at\":null") != null);
}

test "dispatch routes GET onboarding action" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst_dir);
    const workspace_dir = try std.fs.path.join(allocator, &.{ inst_dir, "workspace" });
    defer allocator.free(workspace_dir);
    try ensurePath(workspace_dir);

    const workspace_state_path = try nullclawWorkspaceStatePath(allocator, workspace_dir);
    defer allocator.free(workspace_state_path);
    try ensurePath(std.fs.path.dirname(workspace_state_path).?);
    const state_file = try std_compat.fs.createFileAbsolute(workspace_state_path, .{ .truncate = true });
    defer state_file.close();
    try state_file.writeAll(
        "{\n  \"bootstrap_seeded_at\": \"2026-03-13T01:17:17Z\",\n  \"onboarding_completed_at\": \"2026-03-13T01:30:41Z\"\n}\n",
    );

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/onboarding", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"completed\":true") != null);
}

test "dispatch routes GET integration action for linked nullboiler" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nulltickets", "tracker-a", .{ .version = "1.0.0" });
    try s.addInstance("nullboiler", "boiler-a", .{ .version = "1.0.0" });

    try writeTestInstanceConfig(allocator, mctx.paths, "nulltickets", "tracker-a", "{\"port\":7711,\"api_token\":\"admin-token\"}");
    try writeTestInstanceConfig(
        allocator,
        mctx.paths,
        "nullboiler",
        "boiler-a",
        "{\"port\":8811,\"tracker\":{\"url\":\"http://127.0.0.1:7711\",\"api_token\":\"admin-token\",\"agent_id\":\"boiler-a\",\"workflows_dir\":\"workflows\",\"concurrency\":{\"max_concurrent_tasks\":2}}}",
    );
    try writeTestTrackerWorkflow(allocator, mctx.paths, "boiler-a", "dev-tasks.json", "pipe-dev", "reviewer", "complete");

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullboiler/boiler-a/integration", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("nullboiler", parsed.value.object.get("kind").?.string);
    const linked = parsed.value.object.get("linked_tracker").?.object;
    try std.testing.expectEqualStrings("tracker-a", linked.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 7711), linked.get("port").?.integer);
    const current_link = parsed.value.object.get("current_link").?.object;
    try std.testing.expectEqualStrings("pipe-dev", current_link.get("pipeline_id").?.string);
    try std.testing.expectEqualStrings("reviewer", current_link.get("claim_role").?.string);
    try std.testing.expectEqualStrings("complete", current_link.get("success_trigger").?.string);
    try std.testing.expectEqual(@as(i64, 2), current_link.get("max_concurrent_tasks").?.integer);
}

test "dispatch routes GET integration action with percent-encoded instance name" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "observer-a", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.0" });

    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "observer-a", "{\"host\":\"127.0.0.1\",\"port\":7711,\"api_token\":\"watch-token\"}");
    try writeTestInstanceConfig(
        allocator,
        mctx.paths,
        "nullclaw",
        "Opencode Go",
        "{\"diagnostics\":{\"backend\":\"otel\",\"otel\":{\"endpoint\":\"http://127.0.0.1:7711\",\"service_name\":\"nullclaw/Opencode Go\",\"headers\":{\"Authorization\":\"Bearer watch-token\",\"x-nullwatch-source\":\"nullclaw\"}}}}",
    );

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/Opencode%20Go/integration", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"kind\":\"nullclaw\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"observer-a\"") != null);
}

test "dispatch routes nulltickets tickets action to managed instances only" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nulltickets", "tracker-a", .{ .version = "1.0.0" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nulltickets", "tracker-a", "{\"port\":7711,\"api_token\":\"admin-token\"}");

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nulltickets/tracker-a/tickets",
        "{\"method\":\"GET\",\"path\":\"/tasks?limit=8\"}",
    ).?;

    try std.testing.expectEqualStrings("409 Conflict", resp.status);
    try std.testing.expectEqualStrings("{\"error\":\"nulltickets instance is not running\"}", resp.body);

    const unsupported = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nulltickets/tracker-a/tickets",
        "{\"method\":\"POST\",\"path\":\"/store/default/key\"}",
    ).?;
    try std.testing.expectEqualStrings("400 Bad Request", unsupported.status);
}

test "dispatch routes GET integration action for nullclaw nullwatch telemetry" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "observer-a", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "observer-a", "{\"host\":\"127.0.0.1\",\"port\":7711,\"api_token\":\"watch-token\"}");
    try writeTestInstanceConfig(
        allocator,
        mctx.paths,
        "nullclaw",
        "my-agent",
        "{\"diagnostics\":{\"backend\":\"otel\",\"otel\":{\"endpoint\":\"http://127.0.0.1:7711\",\"service_name\":\"nullclaw/my-agent\",\"headers\":{\"Authorization\":\"Bearer watch-token\",\"x-nullwatch-source\":\"nullclaw\"}}}}",
    );

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/integration", "").?;
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("nullclaw", parsed.value.object.get("kind").?.string);
    try std.testing.expect(parsed.value.object.get("configured").?.bool);
    const linked = parsed.value.object.get("linked_watch").?.object;
    try std.testing.expectEqualStrings("observer-a", linked.get("name").?.string);
    try std.testing.expectEqual(@as(i64, 7711), linked.get("port").?.integer);
    const current_link = parsed.value.object.get("current_link").?.object;
    try std.testing.expectEqualStrings("http://127.0.0.1:7711", current_link.get("endpoint").?.string);
    try std.testing.expectEqualStrings("nullclaw/my-agent", current_link.get("service_name").?.string);
    try std.testing.expect(current_link.get("auth_header").?.bool);
    try std.testing.expect(current_link.get("source_header").?.bool);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.object.get("available_watches").?.array.items.len);
}

test "dispatch routes POST integration action for nullclaw links nullwatch" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "observer-a", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "observer-a", "{\"host\":\"0.0.0.0\",\"port\":7712,\"api_token\":\"watch-token\"}");
    try writeTestInstanceConfig(
        allocator,
        mctx.paths,
        "nullclaw",
        "my-agent",
        "{\"diagnostics\":{\"backend\":\"jsonl\",\"log_tool_calls\":true,\"otel\":{\"service_name\":\"nullclaw\",\"headers\":{\"Authorization\":\"Bearer old\"}}}}",
    );

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/integration",
        "{\"watch_instance\":\"observer-a\"}",
    ).?;
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const config_path = try mctx.paths.instanceConfig(allocator, "nullclaw", "my-agent");
    defer allocator.free(config_path);
    const config_bytes = try std.fs.readFileAbsolute(allocator, config_path, 1024 * 1024);
    defer allocator.free(config_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const diagnostics = parsed.value.object.get("diagnostics").?.object;
    try std.testing.expectEqualStrings("otel", diagnostics.get("backend").?.string);
    try std.testing.expect(diagnostics.get("log_tool_calls").?.bool);
    const otel = diagnostics.get("otel").?.object;
    try std.testing.expectEqualStrings("http://127.0.0.1:7712", otel.get("endpoint").?.string);
    try std.testing.expectEqualStrings("nullclaw/my-agent", otel.get("service_name").?.string);
    const headers = otel.get("headers").?.object;
    try std.testing.expectEqualStrings("Bearer watch-token", headers.get("Authorization").?.string);
    try std.testing.expectEqualStrings("nullclaw", headers.get("x-nullwatch-source").?.string);
}

test "dispatch routes GET integration action for nullwatch lists linked nullclaws" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "observer-a", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "linked-agent", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "plain-agent", .{ .version = "1.0.0" });

    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "observer-a", "{\"port\":7711}");
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "linked-agent", "{\"diagnostics\":{\"backend\":\"otel\",\"otel\":{\"endpoint\":\"http://127.0.0.1:7711\",\"service_name\":\"nullclaw/linked-agent\"}}}");
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "plain-agent", "{\"diagnostics\":{\"backend\":\"jsonl\"}}");

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullwatch/observer-a/integration", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    try std.testing.expectEqualStrings("nullwatch", parsed.value.object.get("kind").?.string);
    const claws = parsed.value.object.get("available_claws").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), claws.len);

    var linked_found = false;
    var plain_found = false;
    for (claws) |claw| {
        const obj = claw.object;
        if (std.mem.eql(u8, obj.get("name").?.string, "linked-agent")) {
            linked_found = obj.get("linked").?.bool;
        }
        if (std.mem.eql(u8, obj.get("name").?.string, "plain-agent")) {
            plain_found = !obj.get("linked").?.bool;
        }
    }
    try std.testing.expect(linked_found);
    try std.testing.expect(plain_found);
}

test "dispatch routes POST integration action for nullwatch links selected nullclaw" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullwatch", "observer-a", .{ .version = "1.0.0" });
    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    try writeTestInstanceConfig(allocator, mctx.paths, "nullwatch", "observer-a", "{\"port\":7713}");
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "my-agent", "{\"diagnostics\":{\"backend\":\"jsonl\"}}");

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullwatch/observer-a/integration",
        "{\"claw_instance\":\"my-agent\"}",
    ).?;
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const config_path = try mctx.paths.instanceConfig(allocator, "nullclaw", "my-agent");
    defer allocator.free(config_path);
    const config_bytes = try std.fs.readFileAbsolute(allocator, config_path, 1024 * 1024);
    defer allocator.free(config_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const diagnostics = parsed.value.object.get("diagnostics").?.object;
    try std.testing.expectEqualStrings("otel", diagnostics.get("backend").?.string);
    const otel = diagnostics.get("otel").?.object;
    try std.testing.expectEqualStrings("http://127.0.0.1:7713", otel.get("endpoint").?.string);
    try std.testing.expectEqualStrings("nullclaw/my-agent", otel.get("service_name").?.string);
}

test "dispatch routes POST integration action for nullboiler" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nulltickets", "tracker-a", .{ .version = "1.0.0" });
    try s.addInstance("nullboiler", "boiler-a", .{ .version = "1.0.0" });

    try writeTestInstanceConfig(allocator, mctx.paths, "nulltickets", "tracker-a", "{\"port\":7711,\"api_token\":\"admin-token\"}");
    try writeTestInstanceConfig(allocator, mctx.paths, "nullboiler", "boiler-a", "{\"port\":8811}");

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullboiler/boiler-a/integration",
        "{\"tracker_instance\":\"tracker-a\",\"pipeline_id\":\"pipe-dev\",\"claim_role\":\"reviewer\",\"success_trigger\":\"complete\",\"max_concurrent_tasks\":3}",
    ).?;
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const config_path = try mctx.paths.instanceConfig(allocator, "nullboiler", "boiler-a");
    defer allocator.free(config_path);
    const file = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const config_bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(config_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const tracker = parsed.value.object.get("tracker").?.object;
    try std.testing.expectEqualStrings("http://127.0.0.1:7711", tracker.get("url").?.string);
    try std.testing.expectEqualStrings("admin-token", tracker.get("api_token").?.string);
    try std.testing.expectEqualStrings("workflows", tracker.get("workflows_dir").?.string);
    const concurrency = tracker.get("concurrency").?.object;
    try std.testing.expectEqual(@as(i64, 3), concurrency.get("max_concurrent_tasks").?.integer);

    const workflow_path = try std.fs.path.join(allocator, &.{ mctx.paths.root, "instances", "nullboiler", "boiler-a", "workflows", integration_mod.managed_workflow_file_name });
    defer allocator.free(workflow_path);
    const workflow_file = try std_compat.fs.openFileAbsolute(workflow_path, .{});
    defer workflow_file.close();
    const workflow = try workflow_file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(workflow);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "\"pipeline_id\": \"pipe-dev\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "\"claim_roles\": [\n    \"reviewer\"\n  ]") != null);
    try std.testing.expect(std.mem.indexOf(u8, workflow, "\"transition_to\": \"complete\"") != null);
}

test "dispatch integration relink preserves advanced tracker config and custom workflows" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nulltickets", "tracker-a", .{ .version = "1.0.0" });
    try s.addInstance("nullboiler", "boiler-a", .{ .version = "1.0.0" });

    try writeTestInstanceConfig(allocator, mctx.paths, "nulltickets", "tracker-a", "{\"port\":7711,\"api_token\":\"admin-token\"}");
    try writeTestInstanceConfig(
        allocator,
        mctx.paths,
        "nullboiler",
        "boiler-a",
        "{\"port\":8811,\"tracker\":{\"url\":\"http://127.0.0.1:7701\",\"api_token\":\"stale-token\",\"agent_id\":\"custom-agent\",\"workflows_dir\":\"custom-workflows\",\"poll_interval_ms\":9000,\"lease_ttl_ms\":222000,\"heartbeat_interval_ms\":44000,\"workspace\":{\"root\":\"../workspaces\"},\"subprocess\":{\"base_port\":9300},\"concurrency\":{\"max_concurrent_tasks\":7,\"per_pipeline\":{\"pipe-old\":2}}}}",
    );

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullboiler", "boiler-a");
    defer allocator.free(inst_dir);
    const workflows_dir = try std.fs.path.join(allocator, &.{ inst_dir, "custom-workflows" });
    defer allocator.free(workflows_dir);
    try ensurePath(workflows_dir);

    const custom_workflow_path = try std.fs.path.join(allocator, &.{ workflows_dir, "manual.json" });
    defer allocator.free(custom_workflow_path);
    {
        const file = try std_compat.fs.createFileAbsolute(custom_workflow_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\{
            \\  "id": "wf-manual",
            \\  "pipeline_id": "pipe-manual",
            \\  "claim_roles": ["reviewer"],
            \\  "execution": "subprocess",
            \\  "prompt_template": "Manual workflow",
            \\  "on_success": { "transition_to": "approved" }
            \\}
            \\
        );
    }

    const generated_workflow_path = try std.fs.path.join(allocator, &.{ workflows_dir, "pipe-old.json" });
    defer allocator.free(generated_workflow_path);
    {
        const rendered = try std.json.Stringify.valueAlloc(allocator, .{
            .id = "wf-pipe-old-coder",
            .pipeline_id = "pipe-old",
            .claim_roles = &.{"coder"},
            .execution = "subprocess",
            .prompt_template = integration_mod.default_tracker_prompt_template,
            .on_success = .{
                .transition_to = "complete",
            },
        }, .{
            .whitespace = .indent_2,
            .emit_null_optional_fields = false,
        });
        defer allocator.free(rendered);

        const file = try std_compat.fs.createFileAbsolute(generated_workflow_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(rendered);
        try file.writeAll("\n");
    }

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullboiler/boiler-a/integration",
        "{\"tracker_instance\":\"tracker-a\",\"pipeline_id\":\"pipe-dev\",\"claim_role\":\"reviewer\",\"success_trigger\":\"complete\"}",
    ).?;
    try std.testing.expectEqualStrings("200 OK", resp.status);

    const config_path = try mctx.paths.instanceConfig(allocator, "nullboiler", "boiler-a");
    defer allocator.free(config_path);
    const file = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer file.close();
    const config_bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(config_bytes);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();

    const tracker = parsed.value.object.get("tracker").?.object;
    try std.testing.expectEqualStrings("http://127.0.0.1:7711", tracker.get("url").?.string);
    try std.testing.expectEqualStrings("admin-token", tracker.get("api_token").?.string);
    try std.testing.expectEqualStrings("custom-agent", tracker.get("agent_id").?.string);
    try std.testing.expectEqualStrings("custom-workflows", tracker.get("workflows_dir").?.string);
    try std.testing.expectEqual(@as(i64, 9000), tracker.get("poll_interval_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 222000), tracker.get("lease_ttl_ms").?.integer);
    try std.testing.expectEqual(@as(i64, 44000), tracker.get("heartbeat_interval_ms").?.integer);
    try std.testing.expect(tracker.get("workspace") != null);
    try std.testing.expect(tracker.get("subprocess") != null);

    const concurrency = tracker.get("concurrency").?.object;
    try std.testing.expectEqual(@as(i64, 7), concurrency.get("max_concurrent_tasks").?.integer);
    try std.testing.expect(concurrency.get("per_pipeline") != null);

    const managed_workflow_path = try std.fs.path.join(allocator, &.{ workflows_dir, integration_mod.managed_workflow_file_name });
    defer allocator.free(managed_workflow_path);
    const managed_file = try std_compat.fs.openFileAbsolute(managed_workflow_path, .{});
    managed_file.close();

    const custom_file = try std_compat.fs.openFileAbsolute(custom_workflow_path, .{});
    custom_file.close();

    try std.testing.expectError(error.FileNotFound, std_compat.fs.openFileAbsolute(generated_workflow_path, .{}));
}

test "dispatch provider-health rejects POST" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/provider-health", "").?;
    try std.testing.expectEqualStrings("405 Method Not Allowed", resp.status);
}

test "handleUsage aggregates provider/model rows" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "usage-agent", .{ .version = "1.0.0" });

    try mctx.paths.ensureDirs();
    const comp_dir = try std.fs.path.join(allocator, &.{ mctx.paths.root, "instances", "nullclaw" });
    defer allocator.free(comp_dir);
    std_compat.fs.makeDirAbsolute(comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "usage-agent");
    defer allocator.free(inst_dir);
    std_compat.fs.makeDirAbsolute(inst_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const ledger_path = try std.fs.path.join(allocator, &.{ inst_dir, "llm_usage.jsonl" });
    defer allocator.free(ledger_path);
    var ledger = try std_compat.fs.createFileAbsolute(ledger_path, .{ .truncate = true });
    defer ledger.close();
    var writer_buf: [512]u8 = undefined;
    var fw = ledger.writer(&writer_buf);
    const w = &fw.interface;
    try w.writeAll("{\"ts\":1700000000,\"provider\":\"openrouter\",\"model\":\"anthropic/claude-sonnet-4\",\"prompt_tokens\":100,\"completion_tokens\":50,\"total_tokens\":150,\"success\":true}\n");
    try w.writeAll("{\"ts\":1700000001,\"provider\":\"openrouter\",\"model\":\"anthropic/claude-sonnet-4\",\"prompt_tokens\":20,\"completion_tokens\":10,\"total_tokens\":30,\"success\":true}\n");
    try w.flush();

    const resp = handleUsage(allocator, &s, mctx.paths, "nullclaw", "usage-agent", "/api/instances/nullclaw/usage-agent/usage?window=all");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"provider\":\"openrouter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"total_tokens\":180") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"requests\":2") != null);
}

test "handleUsage refreshes cache immediately when ledger changes" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "usage-agent-cache", .{ .version = "1.0.0" });

    try mctx.paths.ensureDirs();
    const comp_dir = try std.fs.path.join(allocator, &.{ mctx.paths.root, "instances", "nullclaw" });
    defer allocator.free(comp_dir);
    std_compat.fs.makeDirAbsolute(comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "usage-agent-cache");
    defer allocator.free(inst_dir);
    std_compat.fs.makeDirAbsolute(inst_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };

    const ledger_path = try std.fs.path.join(allocator, &.{ inst_dir, TOKEN_USAGE_LEDGER_FILENAME });
    defer allocator.free(ledger_path);
    var ledger = try std_compat.fs.createFileAbsolute(ledger_path, .{ .truncate = true });
    defer ledger.close();
    var writer_buf: [512]u8 = undefined;
    var fw = ledger.writer(&writer_buf);
    const w = &fw.interface;
    try w.writeAll("{\"ts\":1700001000,\"provider\":\"openrouter\",\"model\":\"anthropic/claude-sonnet-4\",\"prompt_tokens\":1,\"completion_tokens\":1,\"total_tokens\":2,\"success\":true}\n");
    try w.flush();

    const first = handleUsage(allocator, &s, mctx.paths, "nullclaw", "usage-agent-cache", "/api/instances/nullclaw/usage-agent-cache/usage?window=all");
    defer allocator.free(first.body);
    try std.testing.expectEqualStrings("200 OK", first.status);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"requests\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body, "\"total_tokens\":2") != null);

    // Append one more row and verify the next read reflects it immediately.
    try ledger.seekFromEnd(0);
    try w.writeAll("{\"ts\":1700001001,\"provider\":\"openrouter\",\"model\":\"anthropic/claude-sonnet-4\",\"prompt_tokens\":2,\"completion_tokens\":1,\"total_tokens\":3,\"success\":true}\n");
    try w.flush();

    const second = handleUsage(allocator, &s, mctx.paths, "nullclaw", "usage-agent-cache", "/api/instances/nullclaw/usage-agent-cache/usage?window=all");
    defer allocator.free(second.body);
    try std.testing.expectEqualStrings("200 OK", second.status);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "\"requests\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body, "\"total_tokens\":5") != null);
}

test "dispatch routes GET usage action" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/usage?window=all", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"rows\":[]") != null);
}

test "handleHistory returns CLI JSON and passes instance home" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.0" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "history" ] && [ "$2" = "list" ]; then
        \\  if [ -z "$NULLCLAW_HOME" ]; then
        \\    echo "missing home" >&2
        \\    exit 1
        \\  fi
        \\  printf '%s\n' '{"total":1,"limit":50,"offset":0,"sessions":[{"session_id":"s-1","message_count":2,"first_message_at":"2026-03-10T10:00:00Z","last_message_at":"2026-03-10T10:01:00Z"}]}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "history" ] && [ "$2" = "show" ]; then
        \\  printf '{"session_id":"%s","total":2,"limit":100,"offset":0,"messages":[{"role":"user","content":"hi","created_at":"2026-03-10T10:00:00Z"}]}\n' "$3"
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.0", script);

    const list_resp = handleHistory(allocator, &s, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/history?limit=50&offset=0");
    defer allocator.free(list_resp.body);
    try std.testing.expectEqualStrings("200 OK", list_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, list_resp.body, "\"session_id\":\"s-1\"") != null);

    const show_resp = handleHistory(allocator, &s, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/history?session_id=s-1&limit=100&offset=0");
    defer allocator.free(show_resp.body);
    try std.testing.expectEqualStrings("200 OK", show_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, show_resp.body, "\"session_id\":\"s-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, show_resp.body, "\"role\":\"user\"") != null);
}

test "dispatch routes GET history action with percent-encoded instance name" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.0" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "history" ] && [ "$2" = "list" ]; then
        \\  printf '%s\n' '{"total":1,"limit":50,"offset":0,"sessions":[{"session_id":"s-1","message_count":2,"first_message_at":"2026-03-10T10:00:00Z","last_message_at":"2026-03-10T10:01:00Z"}]}'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.0", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/Opencode%20Go/history?limit=50&offset=0", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"session_id\":\"s-1\"") != null);
}

test "handleMemory wraps CLI failures as JSON errors" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.1" });
    const script =
        \\#!/bin/sh
        \\echo "Unknown memory command" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.1", script);

    const resp = handleMemory(allocator, &s, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/memory?stats=1");
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("502 Bad Gateway", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"cli_command_failed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "Unknown memory command") != null);
}

test "handleMemory forwards q alias session_id and include_internal" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2-q" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "memory" ] && [ "$2" = "search" ] && [ "$3" = "hello" ] && [ "$4" = "--limit" ] && [ "$5" = "3" ] && [ "$6" = "--session" ] && [ "$7" = "s-1" ] && [ "$8" = "--json" ]; then
        \\  printf '%s\n' '[]'
        \\  exit 0
        \\fi
        \\if [ "$1" = "memory" ] && [ "$2" = "list" ] && [ "$3" = "--category" ] && [ "$4" = "core" ] && [ "$5" = "--session" ] && [ "$6" = "s-2" ] && [ "$7" = "--include-internal" ] && [ "$8" = "--limit" ] && [ "$9" = "2" ] && [ "${10}" = "--json" ]; then
        \\  printf '%s\n' '[]'
        \\  exit 0
        \\fi
        \\if [ "$1" = "memory" ] && [ "$2" = "list" ] && [ "$3" = "--category" ] && [ "$4" = "core" ] && [ "$5" = "--limit" ] && [ "$6" = "2" ] && [ "$7" = "--offset" ] && [ "$8" = "5" ] && [ "$9" = "--json" ]; then
        \\  printf '%s\n' '[]'
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-q", script);

    const search_resp = handleMemory(allocator, &s, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/memory?q=hello&limit=3&session_id=s-1");
    defer allocator.free(search_resp.body);
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expectEqualStrings("[]", search_resp.body);

    const list_resp = handleMemory(allocator, &s, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/memory?category=core&limit=2&include_internal=1&session_id=s-2");
    defer allocator.free(list_resp.body);
    try std.testing.expectEqualStrings("200 OK", list_resp.status);
    try std.testing.expectEqualStrings("[]", list_resp.body);

    const paged_resp = handleMemory(allocator, &s, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/memory?category=core&limit=2&offset=5");
    defer allocator.free(paged_resp.body);
    try std.testing.expectEqualStrings("200 OK", paged_resp.status);
    try std.testing.expectEqualStrings("[]", paged_resp.body);
}

test "handleMemory get returns 404 when CLI reports null" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2-null" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "memory" ] && [ "$2" = "get" ] && [ "$3" = "missing" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' 'null'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-null", script);

    const resp = handleMemory(allocator, &s, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/memory?key=missing");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "handleMemoryWrite maps missing update to 404" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2-patch" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "memory" ] && [ "$2" = "update" ]; then
        \\  printf '%s\n' '{"error":"memory_not_found","message":"Memory entry not found"}'
        \\  exit 1
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-patch", script);

    const resp = handleMemoryWrite(
        allocator,
        &s,
        mctx.paths,
        "nullclaw",
        "my-agent",
        "PATCH",
        "/api/instances/nullclaw/my-agent/memory",
        "{\"key\":\"missing\",\"content\":\"updated\"}",
    );
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"memory_not_found\"") != null);
}

test "dispatch routes memory maintenance actions" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2-maint" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "memory" ] && [ "$2" = "reindex" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '{"reindexed":2,"skipped":false}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "memory" ] && [ "$2" = "drain-outbox" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '{"drained":4}'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-maint", script);

    const reindex_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/memory-reindex", "").?;
    defer allocator.free(reindex_resp.body);
    try std.testing.expectEqualStrings("200 OK", reindex_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, reindex_resp.body, "\"reindexed\":2") != null);

    const drain_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/memory-drain-outbox", "").?;
    defer allocator.free(drain_resp.body);
    try std.testing.expectEqualStrings("200 OK", drain_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, drain_resp.body, "\"drained\":4") != null);
}

test "dispatch routes GET skills action" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "skills" ] && [ "$2" = "list" ]; then
        \\  printf '%s\n' '[{"name":"checks","version":"1.0.0","description":"Checks","author":"","enabled":true,"always":false,"available":true,"missing_deps":"","path":"/tmp/checks","source":"workspace","instructions_bytes":42}]'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/skills", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"checks\"") != null);
}

test "handleSkills returns 404 when CLI detail returns null" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2-skill-null" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "skills" ] && [ "$2" = "info" ] && [ "$3" = "missing" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' 'null'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-skill-null", script);

    const resp = handleSkills(allocator, &s, mctx.paths, "nullclaw", "my-agent", "/api/instances/nullclaw/my-agent/skills?name=missing");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "dispatch routes GET skills action with percent-encoded instance name" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.2-skill-null" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "skills" ] && [ "$2" = "info" ] && [ "$3" = "missing" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' 'null'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-skill-null", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/Opencode%20Go/skills?name=missing", "").?;
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
}

test "dispatch routes GET channels action" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "channel" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '[{"type":"telegram","account_id":"main","configured":true,"status":"ok"}]'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/channels", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"type\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"account_id\":\"main\"") != null);
}

test "dispatch routes GET channels action with percent-encoded instance name" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.2" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "channel" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '[{"type":"telegram","account_id":"main","configured":true,"status":"ok"}]'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/Opencode%20Go/channels", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"type\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"account_id\":\"main\"") != null);
}

test "dispatch routes GET channel detail with percent-encoded instance name" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.2-detail" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "channel" ] && [ "$2" = "info" ] && [ "$3" = "telegram" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"type":"telegram","status":"ok","accounts":[{"account_id":"main","configured":true,"status":"ok"}]}'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-detail", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/Opencode%20Go/channels/telegram", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"type\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"account_id\":\"main\"") != null);
}

test "dispatch routes GET channel detail maps missing type to 404" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2-missing" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "channel" ] && [ "$2" = "info" ] && [ "$3" = "telegram" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"error":"channel_type_not_found","message":"Unknown channel type"}'
        \\  exit 1
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-missing", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/channels/telegram", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"channel_type_not_found\"") != null);
}

test "dispatch routes GET channel detail via nullclaw CLI when available" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2-detail" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "channel" ] && [ "$2" = "info" ] && [ "$3" = "telegram" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"type":"telegram","status":"ok","accounts":[{"account_id":"main","configured":true,"status":"ok"}]}'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.2-detail", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/channels/telegram", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"type\":\"telegram\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"account_id\":\"main\"") != null);
}

test "dispatch routes GET skills catalog" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2" });

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/skills?catalog=1", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"nullhub-admin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"install_kind\":\"bundled\"") != null);
}

test "dispatch routes POST bundled skill install" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.2" });
    try writeTestInstanceConfig(allocator, mctx.paths, "nullclaw", "my-agent", "{\"autonomy\":{\"level\":\"supervised\"}}");

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/skills",
        "{\"bundled\":\"nullhub-admin\"}",
    ).?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"bundled\":\"nullhub-admin\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"restart_required\":true") != null);

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst_dir);
    const skill_path = try std.fs.path.join(allocator, &.{ inst_dir, "workspace", "skills", "nullhub-admin", "SKILL.md" });
    defer allocator.free(skill_path);
    const installed = std.fs.readFileAbsolute(allocator, skill_path, 64 * 1024) catch @panic("missing skill");
    defer allocator.free(installed);
    try std.testing.expect(std.mem.indexOf(u8, installed, "nullhub api <METHOD> <PATH>") != null);

    const config_path = try mctx.paths.instanceConfig(allocator, "nullclaw", "my-agent");
    defer allocator.free(config_path);
    const config = try std.fs.readFileAbsolute(allocator, config_path, 64 * 1024);
    defer allocator.free(config);
    try std.testing.expect(std.mem.indexOf(u8, config, "\"nullhub *\"") != null);
}

test "dispatch routes DELETE skills action" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.3" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "skills" ] && [ "$2" = "remove" ] && [ "$3" = "nullhub-admin" ]; then
        \\  printf '%s\n' 'Removed skill: nullhub-admin'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.3", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "DELETE", "/api/instances/nullclaw/my-agent/skills?name=nullhub-admin", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"status\":\"removed\"") != null);
}

test "dispatch routes POST source install returns conflict on CLI failure" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.4" });
    const script =
        \\#!/bin/sh
        \\echo "network blocked" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.4", script);

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/skills",
        "{\"source\":\"https://example.com/skill.git\"}",
    ).?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("409 Conflict", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"error\":\"skills_install_failed\"") != null);
}

test "dispatch routes POST registry skill install alias" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.5" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "skills" ] && [ "$2" = "install" ] && [ "$3" = "--name" ] && [ "$4" = "news-digest" ]; then
        \\  printf '%s\n' 'Skill installed from registry search: news-digest'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.5", script);

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/skills",
        "{\"name\":\"news-digest\"}",
    ).?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"news-digest\"") != null);
}

test "dispatch routes POST url skill install alias" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.6" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "skills" ] && [ "$2" = "install" ] && [ "$3" = "https://example.com/skill.git" ]; then
        \\  printf '%s\n' 'Skill installed from: https://example.com/skill.git'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.6", script);

    const resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/skills",
        "{\"url\":\"https://example.com/skill.git\"}",
    ).?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"source\":\"https://example.com/skill.git\"") != null);
}

test "dispatch routes cron detail and lifecycle actions" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.7" });
    try writeTestCronStore(
        allocator,
        mctx.paths,
        "nullclaw",
        "my-agent",
        "[{\"id\":\"job-1\",\"expression\":\"*/5 * * * *\",\"command\":\"echo hello\",\"paused\":false,\"one_shot\":false}]",
    );
    const script =
        \\#!/bin/sh
        \\set -eu
        \\home="${NULLCLAW_HOME:?}"
        \\if [ "$1" = "cron" ] && [ "$2" = "get" ] && [ "$3" = "job-1" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"id":"job-1","expression":"*/5 * * * *","command":"echo hello","paused":false,"one_shot":false}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "cron" ] && [ "$2" = "runs" ] && [ "$3" = "job-1" ] && [ "$4" = "--limit" ] && [ "$5" = "5" ] && [ "$6" = "--json" ]; then
        \\  printf '%s\n' '{"runs":[{"id":1,"job_id":"job-1","started_at_s":100,"finished_at_s":101,"status":"ok","output":"done","duration_ms":250}],"total":1}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "cron" ] && [ "$2" = "once" ] && [ "$3" = "5m" ] && [ "$4" = "echo later" ]; then
        \\  cat > "${home}/cron.json" <<EOF
        \\[{"id":"job-1","expression":"*/5 * * * *","command":"echo hello","paused":false,"one_shot":false},{"id":"job-2","expression":"@once","command":"echo later","paused":false,"one_shot":true}]
        \\EOF
        \\  exit 0
        \\fi
        \\if [ "$1" = "cron" ] && [ "$2" = "run" ] && [ "$3" = "job-1" ]; then
        \\  exit 0
        \\fi
        \\if [ "$1" = "cron" ] && [ "$2" = "pause" ] && [ "$3" = "job-1" ]; then
        \\  cat > "${home}/cron.json" <<EOF
        \\[{"id":"job-1","expression":"*/5 * * * *","command":"echo hello","paused":true,"one_shot":false},{"id":"job-2","expression":"@once","command":"echo later","paused":false,"one_shot":true}]
        \\EOF
        \\  exit 0
        \\fi
        \\if [ "$1" = "cron" ] && [ "$2" = "resume" ] && [ "$3" = "job-1" ]; then
        \\  cat > "${home}/cron.json" <<EOF
        \\[{"id":"job-1","expression":"*/5 * * * *","command":"echo hello","paused":false,"one_shot":false},{"id":"job-2","expression":"@once","command":"echo later","paused":false,"one_shot":true}]
        \\EOF
        \\  exit 0
        \\fi
        \\if [ "$1" = "cron" ] && [ "$2" = "update" ] && [ "$3" = "job-1" ] && [ "$4" = "--expression" ] && [ "$5" = "0 * * * *" ] && [ "$6" = "--command" ] && [ "$7" = "echo updated" ]; then
        \\  cat > "${home}/cron.json" <<EOF
        \\[{"id":"job-1","expression":"0 * * * *","command":"echo updated","paused":false,"one_shot":false},{"id":"job-2","expression":"@once","command":"echo later","paused":false,"one_shot":true}]
        \\EOF
        \\  exit 0
        \\fi
        \\if [ "$1" = "cron" ] && [ "$2" = "remove" ] && [ "$3" = "job-1" ]; then
        \\  cat > "${home}/cron.json" <<EOF
        \\[{"id":"job-2","expression":"@once","command":"echo later","paused":false,"one_shot":true}]
        \\EOF
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.7", script);

    const get_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/cron/job-1", "").?;
    defer allocator.free(get_resp.body);
    try std.testing.expectEqualStrings("200 OK", get_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, get_resp.body, "\"id\":\"job-1\"") != null);

    const runs_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/cron/job-1/runs?limit=5", "").?;
    defer allocator.free(runs_resp.body);
    try std.testing.expectEqualStrings("200 OK", runs_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, runs_resp.body, "\"duration_ms\":250") != null);

    const once_resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/cron/once",
        "{\"delay\":\"5m\",\"command\":\"echo later\"}",
    ).?;
    defer allocator.free(once_resp.body);
    try std.testing.expectEqualStrings("200 OK", once_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, once_resp.body, "\"id\":\"job-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, once_resp.body, "\"one_shot\":true") != null);

    const run_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/cron/job-1/run", "").?;
    defer allocator.free(run_resp.body);
    try std.testing.expectEqualStrings("200 OK", run_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, run_resp.body, "\"status\":\"ran\"") != null);

    const pause_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/cron/job-1/pause", "").?;
    defer allocator.free(pause_resp.body);
    try std.testing.expectEqualStrings("200 OK", pause_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, pause_resp.body, "\"paused\":true") != null);

    const resume_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/cron/job-1/resume", "").?;
    defer allocator.free(resume_resp.body);
    try std.testing.expectEqualStrings("200 OK", resume_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resume_resp.body, "\"paused\":false") != null);

    const update_resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "PATCH",
        "/api/instances/nullclaw/my-agent/cron/job-1",
        "{\"expression\":\"0 * * * *\",\"command\":\"echo updated\"}",
    ).?;
    defer allocator.free(update_resp.body);
    try std.testing.expectEqualStrings("200 OK", update_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, update_resp.body, "\"status\":\"updated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, update_resp.body, "\"command\":\"echo updated\"") != null);

    const delete_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "DELETE", "/api/instances/nullclaw/my-agent/cron/job-1", "").?;
    defer allocator.free(delete_resp.body);
    try std.testing.expectEqualStrings("200 OK", delete_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, delete_resp.body, "\"status\":\"deleted\"") != null);
}

test "dispatch routes config mutation actions" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.8" });
    const script =
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "config" ] && [ "$2" = "set" ] && [ "$3" = "gateway.port" ] && [ "$4" = "43123" ] && [ "$5" = "--json" ]; then
        \\  printf '%s\n' '{"action":"set","path":"gateway.port","changed":true,"applied":true,"requires_restart":false,"old_value":3000,"new_value":43123,"backup_path":null}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "config" ] && [ "$2" = "unset" ] && [ "$3" = "channels.telegram" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"action":"unset","path":"channels.telegram","changed":true,"applied":true,"requires_restart":true,"old_value":{"enabled":true},"new_value":null,"backup_path":null}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "config" ] && [ "$2" = "reload" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '{"reloaded":true,"live_applied":false,"message":"config.json re-read from disk; restart running daemons to apply changes"}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "config" ] && [ "$2" = "validate" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"valid":true}'
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.8", script);

    const set_resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/config-set",
        "{\"path\":\"gateway.port\",\"value\":43123}",
    ).?;
    defer allocator.free(set_resp.body);
    try std.testing.expectEqualStrings("200 OK", set_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, set_resp.body, "\"new_value\":43123") != null);

    const unset_resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/config-unset",
        "{\"path\":\"channels.telegram\"}",
    ).?;
    defer allocator.free(unset_resp.body);
    try std.testing.expectEqualStrings("200 OK", unset_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, unset_resp.body, "\"action\":\"unset\"") != null);

    const reload_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/config-reload", "").?;
    defer allocator.free(reload_resp.body);
    try std.testing.expectEqualStrings("200 OK", reload_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, reload_resp.body, "\"reloaded\":true") != null);

    const validate_resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/config-validate",
        "{\"gateway\":{\"port\":43123}}",
    ).?;
    defer allocator.free(validate_resp.body);
    try std.testing.expectEqualStrings("200 OK", validate_resp.status);
    try std.testing.expectEqualStrings("{\"valid\":true}\n", validate_resp.body);
}

test "dispatch routes doctor capabilities mcp and models detail" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.9" });
    const script =
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "doctor" ] && [ "$2" = "--json" ]; then
        \\  printf '%s\n' '{"ready":true,"overall_status":"ok","components":{"gateway":{"status":"ok","pid":123,"uptime_seconds":10,"restart_count":0,"last_ok":"2026-04-17T00:00:00Z","last_error":null}}}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "capabilities" ] && [ "$2" = "--json" ]; then
        \\  printf '%s\n' '{"channels":["telegram"],"tools":["memory_store"],"tools_detail":[{"name":"memory_store","runtime_loaded":true}],"memory_engines":["sqlite"],"active_backend":"sqlite"}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "mcp" ] && [ "$2" = "list" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '[{"name":"context7","transport":"stdio","command":"npx","args":["-y","@upstash/context7-mcp"],"env_keys":["CONTEXT7_API_KEY"],"tool_count":7}]'
        \\  exit 0
        \\fi
        \\if [ "$1" = "mcp" ] && [ "$2" = "info" ] && [ "$3" = "context7" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"name":"context7","transport":"stdio","command":"npx","args":["-y","@upstash/context7-mcp"],"env_keys":["CONTEXT7_API_KEY"],"tool_count":7}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "models" ] && [ "$2" = "info" ] && [ "$3" = "openai/gpt-5" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"name":"openai/gpt-5","provider":"openai","canonical_name":"openai/gpt-5","context_window":null}'
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.9", script);

    const doctor_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/doctor", "").?;
    defer allocator.free(doctor_resp.body);
    try std.testing.expectEqualStrings("200 OK", doctor_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, doctor_resp.body, "\"ready\":true") != null);

    const capabilities_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/capabilities", "").?;
    defer allocator.free(capabilities_resp.body);
    try std.testing.expectEqualStrings("200 OK", capabilities_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, capabilities_resp.body, "\"tools\":[\"memory_store\"]") != null);

    const mcp_list_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/mcp", "").?;
    defer allocator.free(mcp_list_resp.body);
    try std.testing.expectEqualStrings("200 OK", mcp_list_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, mcp_list_resp.body, "\"name\":\"context7\"") != null);

    const mcp_info_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/mcp?name=context7", "").?;
    defer allocator.free(mcp_info_resp.body);
    try std.testing.expectEqualStrings("200 OK", mcp_info_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, mcp_info_resp.body, "\"tool_count\":7") != null);

    const model_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/models?name=openai%2Fgpt-5", "").?;
    defer allocator.free(model_resp.body);
    try std.testing.expectEqualStrings("200 OK", model_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, model_resp.body, "\"provider\":\"openai\"") != null);

    const refresh_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/models", "").?;
    try std.testing.expectEqualStrings("501 Not Implemented", refresh_resp.status);
}

test "dispatch routes agent invoke stream and sessions" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.10" });
    const script =
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "agent" ] && [ "$2" = "invoke" ] && [ "$3" = "--message" ] && [ "$4" = "hello" ] && [ "$5" = "--session" ] && [ "$6" = "s-1" ] && [ "$7" = "--provider" ] && [ "$8" = "openai" ] && [ "$9" = "--model" ] && [ "${10}" = "gpt-5" ] && [ "${11}" = "--temperature" ] && [ "${12}" = "0.3" ] && [ "${13}" = "--agent" ] && [ "${14}" = "helper" ] && [ "${15}" = "--json" ]; then
        \\  printf '%s\n' '{"session":"s-1","response":"world","turn_count":2}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "agent" ] && [ "$2" = "sessions" ] && [ "$3" = "list" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"sessions":[{"session_key":"s-1","created_at":"2026-04-17T00:00:00Z","last_active":"2026-04-17T00:01:00Z","turn_count":1,"turn_running":false}],"total":1}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "agent" ] && [ "$2" = "sessions" ] && [ "$3" = "get" ] && [ "$4" = "s-1" ] && [ "$5" = "--json" ]; then
        \\  printf '%s\n' '{"session_key":"s-1","created_at":"2026-04-17T00:00:00Z","last_active":"2026-04-17T00:01:00Z","turn_count":1,"turn_running":false}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "agent" ] && [ "$2" = "sessions" ] && [ "$3" = "terminate" ] && [ "$4" = "s-1" ] && [ "$5" = "--json" ]; then
        \\  printf '%s\n' '{"session_key":"s-1","terminated":true}'
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.10", script);

    const invoke_resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/agent",
        "{\"message\":\"hello\",\"session_key\":\"s-1\",\"provider\":\"openai\",\"model\":\"gpt-5\",\"temperature\":\"0.3\",\"agent\":\"helper\"}",
    ).?;
    defer allocator.free(invoke_resp.body);
    try std.testing.expectEqualStrings("200 OK", invoke_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, invoke_resp.body, "\"response\":\"world\"") != null);

    const list_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/agent-sessions", "").?;
    defer allocator.free(list_resp.body);
    try std.testing.expectEqualStrings("200 OK", list_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, list_resp.body, "\"session_key\":\"s-1\"") != null);

    const get_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/agent-sessions?session_id=s-1", "").?;
    defer allocator.free(get_resp.body);
    try std.testing.expectEqualStrings("200 OK", get_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, get_resp.body, "\"turn_count\":1") != null);

    const delete_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "DELETE", "/api/instances/nullclaw/my-agent/agent-sessions?session_id=s-1", "").?;
    defer allocator.free(delete_resp.body);
    try std.testing.expectEqualStrings("200 OK", delete_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, delete_resp.body, "\"terminated\":true") != null);
}

test "dispatch routes agent sessions with percent-encoded instance name" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "Opencode Go", .{ .version = "1.0.10" });
    const script =
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "agent" ] && [ "$2" = "sessions" ] && [ "$3" = "list" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"sessions":[{"session_key":"s-1","created_at":"2026-04-17T00:00:00Z","last_active":"2026-04-17T00:01:00Z","turn_count":1,"turn_running":false}],"total":1}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "agent" ] && [ "$2" = "sessions" ] && [ "$3" = "get" ] && [ "$4" = "s-1" ] && [ "$5" = "--json" ]; then
        \\  printf '%s\n' '{"session_key":"s-1","created_at":"2026-04-17T00:00:00Z","last_active":"2026-04-17T00:01:00Z","turn_count":1,"turn_running":false}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "agent" ] && [ "$2" = "sessions" ] && [ "$3" = "terminate" ] && [ "$4" = "s-1" ] && [ "$5" = "--json" ]; then
        \\  printf '%s\n' '{"session_key":"s-1","terminated":true}'
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.10", script);

    const list_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/Opencode%20Go/agent-sessions", "").?;
    defer allocator.free(list_resp.body);
    try std.testing.expectEqualStrings("200 OK", list_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, list_resp.body, "\"session_key\":\"s-1\"") != null);

    const get_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/Opencode%20Go/agent-sessions?session_id=s-1", "").?;
    defer allocator.free(get_resp.body);
    try std.testing.expectEqualStrings("200 OK", get_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, get_resp.body, "\"turn_count\":1") != null);

    const delete_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "DELETE", "/api/instances/nullclaw/Opencode%20Go/agent-sessions?session_id=s-1", "").?;
    defer allocator.free(delete_resp.body);
    try std.testing.expectEqualStrings("200 OK", delete_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, delete_resp.body, "\"terminated\":true") != null);
}

test "dispatch routes memory write read stats and search actions" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.11" });
    const script =
        \\#!/bin/sh
        \\set -eu
        \\if [ "$1" = "memory" ] && [ "$2" = "store" ] && [ "$3" = "fact" ] && [ "$4" = "hello" ] && [ "$5" = "--category" ] && [ "$6" = "conversation" ] && [ "$7" = "--session" ] && [ "$8" = "s-1" ] && [ "$9" = "--json" ]; then
        \\  printf '%s\n' '{"action":"store","entry":{"key":"fact","category":"conversation","timestamp":"2026-04-17T00:00:00Z","content":"hello","session_id":"s-1"}}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "memory" ] && [ "$2" = "get" ] && [ "$3" = "fact" ] && [ "$4" = "--session" ] && [ "$5" = "s-1" ] && [ "$6" = "--json" ]; then
        \\  printf '%s\n' '{"key":"fact","category":"conversation","timestamp":"2026-04-17T00:00:00Z","content":"hello","session_id":"s-1"}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "memory" ] && [ "$2" = "update" ] && [ "$3" = "fact" ] && [ "$4" = "updated" ] && [ "$5" = "--category" ] && [ "$6" = "conversation" ] && [ "$7" = "--session" ] && [ "$8" = "s-1" ] && [ "$9" = "--json" ]; then
        \\  printf '%s\n' '{"action":"update","entry":{"key":"fact","category":"conversation","timestamp":"2026-04-17T00:00:01Z","content":"updated","session_id":"s-1"}}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "memory" ] && [ "$2" = "delete" ] && [ "$3" = "fact" ] && [ "$4" = "--session" ] && [ "$5" = "s-1" ] && [ "$6" = "--json" ]; then
        \\  printf '%s\n' '{"key":"fact","session_id":"s-1","deleted":true}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "memory" ] && [ "$2" = "stats" ] && [ "$3" = "--json" ]; then
        \\  printf '%s\n' '{"backend":"sqlite","retrieval":"hybrid","vector":"sqlite","embedding":"disabled","rollout":"primary","sync":"inline","sources":1,"fallback":"none","entries":1,"vector_entries":0,"outbox_pending":0}'
        \\  exit 0
        \\fi
        \\if [ "$1" = "memory" ] && [ "$2" = "search" ] && [ "$3" = "hello" ] && [ "$4" = "--limit" ] && [ "$5" = "3" ] && [ "$6" = "--session" ] && [ "$7" = "s-1" ] && [ "$8" = "--json" ]; then
        \\  printf '%s\n' '[{"key":"fact","category":"conversation","snippet":"hello","source":"primary","source_path":"memory://fact","final_score":0.9,"start_line":1,"end_line":1,"created_at":0,"keyword_rank":1,"vector_score":null}]'
        \\  exit 0
        \\fi
        \\echo "unexpected args: $*" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.11", script);

    const store_resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "POST",
        "/api/instances/nullclaw/my-agent/memory",
        "{\"key\":\"fact\",\"content\":\"hello\",\"category\":\"conversation\",\"session_id\":\"s-1\"}",
    ).?;
    defer allocator.free(store_resp.body);
    try std.testing.expectEqualStrings("200 OK", store_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, store_resp.body, "\"action\":\"store\"") != null);

    const get_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/memory?key=fact&session_id=s-1", "").?;
    defer allocator.free(get_resp.body);
    try std.testing.expectEqualStrings("200 OK", get_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, get_resp.body, "\"content\":\"hello\"") != null);

    const update_resp = dispatch(
        allocator,
        &s,
        &mctx.manager,
        &mctx.mutex,
        mctx.paths,
        "PATCH",
        "/api/instances/nullclaw/my-agent/memory?key=fact&session_id=s-1",
        "{\"content\":\"updated\",\"category\":\"conversation\"}",
    ).?;
    defer allocator.free(update_resp.body);
    try std.testing.expectEqualStrings("200 OK", update_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, update_resp.body, "\"action\":\"update\"") != null);

    const stats_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/memory?stats=1", "").?;
    defer allocator.free(stats_resp.body);
    try std.testing.expectEqualStrings("200 OK", stats_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, stats_resp.body, "\"backend\":\"sqlite\"") != null);

    const search_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/memory?q=hello&limit=3&session_id=s-1", "").?;
    defer allocator.free(search_resp.body);
    try std.testing.expectEqualStrings("200 OK", search_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, search_resp.body, "\"snippet\":\"hello\"") != null);

    const delete_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "DELETE", "/api/instances/nullclaw/my-agent/memory?key=fact&session_id=s-1", "").?;
    defer allocator.free(delete_resp.body);
    try std.testing.expectEqualStrings("200 OK", delete_resp.status);
    try std.testing.expect(std.mem.indexOf(u8, delete_resp.body, "\"deleted\":true") != null);
}

test "dispatch routes GET skill detail action" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;

    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "my-agent", .{ .version = "1.0.12" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "skills" ] && [ "$2" = "info" ] && [ "$3" = "checks" ] && [ "$4" = "--json" ]; then
        \\  printf '%s\n' '{"name":"checks","version":"1.0.0","description":"Checks","author":"nullclaw","enabled":true,"always":false,"available":true,"missing_deps":"","path":"/tmp/checks","source":"workspace","instructions_bytes":42}'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.12", script);

    const resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/instances/nullclaw/my-agent/skills?name=checks", "").?;
    defer allocator.free(resp.body);
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"name\":\"checks\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"instructions_bytes\":42") != null);
}

test "dispatch returns null for non-matching path" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try std.testing.expect(dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "GET", "/api/other", "") == null);
}
