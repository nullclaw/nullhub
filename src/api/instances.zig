const std = @import("std");
const std_compat = @import("compat");
const builtin = @import("builtin");
const state_mod = @import("../core/state.zig");
const manager_mod = @import("../supervisor/manager.zig");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");
const local_binary = @import("../core/local_binary.zig");
const component_cli = @import("../core/component_cli.zig");
const integration_mod = @import("../core/integration.zig");
const launch_args_mod = @import("../core/launch_args.zig");
const managed_skills = @import("../managed_skills.zig");
const manifest_mod = @import("../core/manifest.zig");
const managed_cli = @import("managed_cli.zig");
const nullclaw_web_channel = @import("../core/nullclaw_web_channel.zig");
const query_api = @import("query.zig");
const test_helpers = @import("../test_helpers.zig");

const ApiResponse = helpers.ApiResponse;
const appendEscaped = helpers.appendEscaped;
const jsonOk = helpers.jsonOk;
const notFound = helpers.notFound;
const badRequest = helpers.badRequest;
const methodNotAllowed = helpers.methodNotAllowed;

const default_tracker_prompt_template =
    "Task {{task.id}}: {{task.title}}\n\n{{task.description}}\n\nMetadata:\n{{task.metadata}}";

// ─── Helpers ─────────────────────────────────────────────────────────────────

/// Read a port value from an instance's config.json using a dot-separated key
/// (e.g. "gateway.port" → config["gateway"]["port"]).
fn readPortFromConfig(allocator: std.mem.Allocator, paths: paths_mod.Paths, component: []const u8, name: []const u8, dot_key: []const u8) ?u16 {
    const config_path = paths.instanceConfig(allocator, component, name) catch return null;
    defer allocator.free(config_path);

    const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch return null;
    defer file.close();
    const contents = file.readToEndAlloc(allocator, 4 * 1024 * 1024) catch return null;
    defer allocator.free(contents);

    // Parse as generic JSON and walk the dot-path
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    var current = parsed.value;
    var it = std.mem.splitScalar(u8, dot_key, '.');
    while (it.next()) |segment| {
        switch (current) {
            .object => |obj| {
                current = obj.get(segment) orelse return null;
            },
            else => return null,
        }
    }

    switch (current) {
        .integer => |v| return if (v >= 0 and v <= 65535) @intCast(v) else null,
        else => return null,
    }
}

const InstanceSnapshot = struct {
    status: manager_mod.Status,
    pid: ?std.process.Child.Id = null,
    uptime_seconds: ?u64 = null,
    restart_count: u32 = 0,
    port: u16 = 0,
};

fn deriveStandaloneSnapshot(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
    entry: state_mod.InstanceEntry,
) ?InstanceSnapshot {
    if (!std.mem.eql(u8, component, "nullclaw")) return null;

    const inst_dir = paths.instanceDir(allocator, component, name) catch return null;
    defer allocator.free(inst_dir);
    const real_dir = std_compat.fs.realpathAlloc(allocator, inst_dir) catch return null;
    defer allocator.free(real_dir);

    const home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch return null;
    defer allocator.free(home);
    const standalone_root = std.fmt.allocPrint(allocator, "{s}/.{s}", .{ home, component }) catch return null;
    defer allocator.free(standalone_root);

    if (!std.mem.eql(u8, real_dir, standalone_root)) return null;
    if (!std.mem.eql(u8, entry.launch_mode, "gateway")) return null;

    const port = readPortFromConfig(allocator, paths, component, name, "gateway.port") orelse 0;
    if (port == 0) return null;

    const health = @import("../supervisor/health.zig").check(allocator, "127.0.0.1", port, "/health");
    return .{
        .status = if (health.ok) .running else .stopped,
        .port = port,
    };
}

fn resolveInstanceSnapshot(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    manager: *manager_mod.Manager,
    component: []const u8,
    name: []const u8,
    entry: state_mod.InstanceEntry,
) InstanceSnapshot {
    if (manager.getStatus(component, name)) |st| {
        return .{
            .status = st.status,
            .pid = st.pid,
            .uptime_seconds = st.uptime_seconds,
            .restart_count = st.restart_count,
            .port = st.port,
        };
    }
    if (deriveStandaloneSnapshot(allocator, paths, component, name, entry)) |snapshot| return snapshot;
    return .{ .status = .stopped };
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

const NullclawBootstrapMemoryProbe = struct {
    exists: bool = false,
    timestamp: ?[]u8 = null,

    fn deinit(self: *NullclawBootstrapMemoryProbe, allocator: std.mem.Allocator) void {
        if (self.timestamp) |value| allocator.free(value);
        self.* = .{};
    }

    fn takeTimestamp(self: *NullclawBootstrapMemoryProbe) ?[]u8 {
        const value = self.timestamp;
        self.timestamp = null;
        return value;
    }
};

const nullclaw_bootstrap_memory_key = "__bootstrap.prompt.BOOTSTRAP.md";

fn fileExistsAbsolute(path: []const u8) bool {
    std_compat.fs.accessAbsolute(path, .{}) catch return false;
    return true;
}

fn nullclawWorkspaceStatePath(allocator: std.mem.Allocator, workspace_dir: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ workspace_dir, ".nullclaw", "workspace-state.json" });
}

fn probeNullclawBootstrapInMemory(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
    paths: paths_mod.Paths,
    component: []const u8,
    name: []const u8,
) NullclawBootstrapMemoryProbe {
    const args = [_][]const u8{
        "memory",
        "get",
        nullclaw_bootstrap_memory_key,
        "--json",
    };
    const stdout = managed_cli.tryRunJsonSuccess(allocator, s, paths, component, name, &args) orelse return .{};
    defer allocator.free(stdout);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return .{};
    defer parsed.deinit();

    switch (parsed.value) {
        .null => return .{},
        .object => |obj| {
            var probe = NullclawBootstrapMemoryProbe{ .exists = true };
            if (obj.get("timestamp")) |timestamp_value| {
                if (timestamp_value == .string and timestamp_value.string.len > 0) {
                    probe.timestamp = allocator.dupe(u8, timestamp_value.string) catch null;
                }
            }
            return probe;
        },
        else => return .{},
    }
}

fn readNullclawOnboardingStatus(
    allocator: std.mem.Allocator,
    s: *state_mod.State,
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

    var bootstrap_probe = NullclawBootstrapMemoryProbe{};
    if (!status.completed and !status.bootstrap_exists) {
        bootstrap_probe = probeNullclawBootstrapInMemory(allocator, s, paths, component, name);
        if (status.bootstrap_seeded_at == null) {
            status.bootstrap_seeded_at = bootstrap_probe.takeTimestamp();
        }
    }
    defer bootstrap_probe.deinit(allocator);

    status.pending = !status.completed and (status.bootstrap_exists or status.bootstrap_seeded_at != null or bootstrap_probe.exists);
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
    if (parsed.value != .array) return null;

    var list: std.ArrayListUnmanaged(PipelineSummary) = .empty;
    errdefer deinitPipelineSummaries(allocator, list.items);
    defer list.deinit(allocator);

    for (parsed.value.array.items) |item| {
        const summary = parsePipelineSummary(allocator, item) catch continue;
        list.append(allocator, summary) catch {
            deinitPipelineSummary(allocator, summary);
            return null;
        };
    }

    return list.toOwnedSlice(allocator) catch null;
}

fn parsePipelineSummary(allocator: std.mem.Allocator, value: std.json.Value) !PipelineSummary {
    if (value != .object) return error.InvalidPipelineSummary;
    const obj = value.object;
    const definition = obj.get("definition") orelse return error.InvalidPipelineSummary;
    if (definition != .object) return error.InvalidPipelineSummary;

    return .{
        .id = try allocator.dupe(u8, jsonStringOrEmpty(obj, "id")),
        .name = try allocator.dupe(u8, jsonStringOrEmpty(obj, "name")),
        .roles = try collectPipelineRoles(allocator, definition),
        .triggers = try collectPipelineTriggers(allocator, definition),
    };
}

fn collectPipelineRoles(allocator: std.mem.Allocator, definition: std.json.Value) ![]const []const u8 {
    if (definition != .object) return allocator.alloc([]const u8, 0);
    const states_val = definition.object.get("states") orelse return allocator.alloc([]const u8, 0);
    if (states_val != .object) return allocator.alloc([]const u8, 0);

    var list: std.ArrayListUnmanaged([]const u8) = .empty;
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
    try list.append(allocator, try allocator.dupe(u8, value));
}

fn deinitPipelineSummary(allocator: std.mem.Allocator, summary: PipelineSummary) void {
    allocator.free(summary.id);
    allocator.free(summary.name);
    for (summary.roles) |role| allocator.free(role);
    allocator.free(summary.roles);
    for (summary.triggers) |trigger| allocator.free(trigger);
    allocator.free(summary.triggers);
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

fn ensureObjectField(
    allocator: std.mem.Allocator,
    parent: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.ObjectMap {
    if (parent.getPtr(key)) |value_ptr| {
        if (value_ptr.* != .object) {
            value_ptr.* = .{ .object = .empty };
        }
        return &value_ptr.object;
    }

    try parent.put(allocator, key, .{ .object = .empty });
    return &parent.getPtr(key).?.object;
}

fn resolvePathFromConfig(allocator: std.mem.Allocator, config_path: []const u8, value: []const u8) ![]const u8 {
    if (value.len == 0 or std.fs.path.isAbsolute(value)) return allocator.dupe(u8, value);
    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    return std.fs.path.resolve(allocator, &.{ config_dir, value });
}

fn isNullHubManagedWorkflow(
    allocator: std.mem.Allocator,
    workflow_path: []const u8,
) bool {
    const file = std_compat.fs.openFileAbsolute(workflow_path, .{}) catch return false;
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch return false;
    defer allocator.free(bytes);

    const parsed = std.json.parseFromSlice(struct {
        id: []const u8 = "",
        execution: []const u8 = "",
        prompt_template: ?[]const u8 = null,
    }, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return false;
    defer parsed.deinit();

    return std.mem.startsWith(u8, parsed.value.id, "wf-") and
        std.mem.eql(u8, parsed.value.execution, "subprocess") and
        parsed.value.prompt_template != null and
        std.mem.eql(u8, parsed.value.prompt_template.?, default_tracker_prompt_template);
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

const ParsedChannelsPath = struct {
    component: []const u8,
    name: []const u8,
    channel_type: ?[]const u8,
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
pub const LEGACY_USAGE_LEDGER_FILENAME = "llm_usage.jsonl";
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
    const preferred = try std.fs.path.join(allocator, &.{ inst_dir, TOKEN_USAGE_LEDGER_FILENAME });
    std_compat.fs.accessAbsolute(preferred, .{}) catch {
        const legacy = try std.fs.path.join(allocator, &.{ inst_dir, LEGACY_USAGE_LEDGER_FILENAME });
        if (std_compat.fs.accessAbsolute(legacy, .{})) |_| {
            allocator.free(preferred);
            return legacy;
        } else |_| {}
        allocator.free(legacy);
    };
    return preferred;
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

fn appendInstanceJson(buf: *std.array_list.Managed(u8), entry: state_mod.InstanceEntry, snapshot: InstanceSnapshot) !void {
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

            const snapshot = resolveInstanceSnapshot(buf.allocator, paths, manager, comp_entry.key_ptr.*, inst_entry.key_ptr.*, inst_entry.value_ptr.*);

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

    const snapshot = resolveInstanceSnapshot(allocator, paths, manager, component, name, entry);

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
            if (pb.value.launch_mode) |mode| launch_cmd = mode;
            if (pb.value.verbose) |verbose| launch_verbose = verbose;
        }
    }

    // Resolve binary path
    const bin_path = paths.binary(allocator, component, entry.version) catch return helpers.serverError();
    defer allocator.free(bin_path);

    // Read manifest from binary to get health endpoint and port
    var health_endpoint: []const u8 = "/health";
    var port: u16 = 0;
    var port_from_config: []const u8 = "";
    const manifest_json = component_cli.exportManifest(allocator, bin_path) catch null;
    var parsed_manifest: ?std.json.Parsed(manifest_mod.Manifest) = null;
    if (manifest_json) |mj| {
        parsed_manifest = manifest_mod.parseManifest(allocator, mj) catch null;
        if (parsed_manifest) |pm| {
            health_endpoint = pm.value.health.endpoint;
            port_from_config = pm.value.health.port_from_config;
            if (pm.value.ports.len > 0) port = pm.value.ports[0].default;
        }
    }
    defer if (manifest_json) |mj| allocator.free(mj);
    defer if (parsed_manifest) |*pm| pm.deinit();

    // Try to read actual port from instance config.json using port_from_config key
    if (port_from_config.len > 0) {
        if (readPortFromConfig(allocator, paths, component, name, port_from_config)) |config_port| {
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
pub fn handleStop(s: *state_mod.State, manager: *manager_mod.Manager, component: []const u8, name: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();
    manager.stopInstance(component, name) catch return helpers.serverError();
    return jsonOk("{\"status\":\"stopped\"}");
}

/// POST /api/instances/{component}/{name}/restart
pub fn handleRestart(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths, component: []const u8, name: []const u8, body: []const u8) ApiResponse {
    _ = s.getInstance(component, name) orelse return notFound();
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

    const running = blk: {
        if (manager.getStatus(component, name)) |st| {
            break :blk st.status == .running;
        }
        break :blk false;
    };

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

    var status = readNullclawOnboardingStatus(allocator, s, paths, component, name) catch
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

/// DELETE /api/instances/{component}/{name}
pub fn handleDelete(allocator: std.mem.Allocator, s: *state_mod.State, manager: *manager_mod.Manager, paths: paths_mod.Paths, component: []const u8, name: []const u8) ApiResponse {
    const existing = s.getInstance(component, name) orelse return notFound();
    const rollback_version = allocator.dupe(u8, existing.version) catch return helpers.serverError();
    defer allocator.free(rollback_version);
    const rollback_launch_mode = allocator.dupe(u8, existing.launch_mode) catch return helpers.serverError();
    defer allocator.free(rollback_launch_mode);

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
        _ = s.addInstance(component, name, .{
            .version = rollback_version,
            .auto_start = existing.auto_start,
            .launch_mode = rollback_launch_mode,
            .verbose = existing.verbose,
        }) catch {};
        _ = s.save() catch {};
        if (hidden_inst_dir) |path| {
            std_compat.fs.renameAbsolute(path, inst_dir) catch {};
        }
        return helpers.serverError();
    };

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

/// POST /api/instances/{component}/import — import a standalone installation.
/// Copies config and data from ~/.{component}/ into the nullhub instance directory.
/// The binary will be downloaded via the normal install flow on first start.
pub fn handleImport(allocator: std.mem.Allocator, s: *state_mod.State, paths: paths_mod.Paths, component: []const u8) ApiResponse {
    const home = std_compat.process.getEnvVarOwned(allocator, "HOME") catch blk: {
        if (builtin.os.tag == .windows) {
            break :blk std_compat.process.getEnvVarOwned(allocator, "USERPROFILE") catch return helpers.serverError();
        }
        return helpers.serverError();
    };
    defer allocator.free(home);

    // 1. Verify standalone dir exists
    const dot_dir = std.fmt.allocPrint(allocator, "{s}/.{s}", .{ home, component }) catch return helpers.serverError();
    defer allocator.free(dot_dir);
    std_compat.fs.accessAbsolute(dot_dir, .{}) catch return notFound();

    // 2. Create instance directory structure
    const inst_dir = paths.instanceDir(allocator, component, "default") catch return helpers.serverError();
    defer allocator.free(inst_dir);

    // Ensure parent component dir exists
    const comp_dir = std.fs.path.join(allocator, &.{ paths.root, "instances", component }) catch return helpers.serverError();
    defer allocator.free(comp_dir);
    std_compat.fs.makeDirAbsolute(comp_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return helpers.serverError(),
    };

    // 3. Symlink the entire standalone dir as the instance dir
    //    ~/.nullclaw → ~/.nullhub/instances/nullclaw/default
    //    This preserves all data in place (config, auth, workspace, state, logs)
    std_compat.fs.deleteFileAbsolute(inst_dir) catch {};
    std_compat.fs.deleteTreeAbsolute(inst_dir) catch {};
    std_compat.fs.symLinkAbsolute(dot_dir, inst_dir, .{ .is_directory = true }) catch return helpers.serverError();

    // 4. Stage binary — copy from local dev build or leave for download on start
    const version = blk: {
        if (local_binary.find(allocator, component)) |src_bin| {
            defer allocator.free(src_bin);
            const ver = "dev-local";
            const dest_bin = paths.binary(allocator, component, ver) catch break :blk "standalone";
            defer allocator.free(dest_bin);
            std_compat.fs.deleteFileAbsolute(dest_bin) catch {};
            std_compat.fs.copyFileAbsolute(src_bin, dest_bin, .{}) catch break :blk "standalone";
            if (comptime std_compat.fs.has_executable_bit) {
                // Make executable on platforms that support executable bits.
                if (std_compat.fs.openFileAbsolute(dest_bin, .{ .mode = .read_only })) |f| {
                    defer f.close();
                    f.chmod(0o755) catch {};
                } else |_| {}
            }
            break :blk ver;
        }
        break :blk "standalone";
    };

    // 5. Register in state
    s.addInstance(component, "default", .{
        .version = version,
        .auto_start = false,
        .verbose = false,
    }) catch return helpers.serverError();
    s.save() catch return helpers.serverError();

    return jsonOk("{\"status\":\"imported\",\"instance\":\"default\"}");
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

        var tracker_status = blk: {
            const status = getStatusLocked(mutex, manager, "nullboiler", name) orelse break :blk null;
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
            .configured = boiler_cfg.tracker != null,
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
            .queue = if (queue) |value| value.parsed.value else null,
            .linked_boilers = linked_boiler_views.items,
        }, .{ .emit_null_optional_fields = false }) catch return helpers.serverError();
        return jsonOk(body);
    }

    return notFound();
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
    if (!std.mem.eql(u8, component, "nullboiler")) return badRequest("{\"error\":\"integration updates are only supported for nullboiler\"}");

    const tracker_cfg = blk: {
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
            .allocate = .alloc_always,
            .ignore_unknown_fields = true,
        }) catch return badRequest("{\"error\":\"invalid JSON body\"}");
        defer parsed.deinit();
        if (parsed.value != .object) return badRequest("{\"error\":\"invalid JSON body\"}");
        const tracker_name = if (parsed.value.object.get("tracker_instance")) |value|
            if (value == .string and value.string.len > 0) value.string else null
        else
            null;
        if (tracker_name == null) return badRequest("{\"error\":\"tracker_instance is required\"}");
        const pipeline_id = if (parsed.value.object.get("pipeline_id")) |value|
            if (value == .string and value.string.len > 0) value.string else null
        else
            null;
        if (pipeline_id == null) return badRequest("{\"error\":\"pipeline_id is required\"}");
        const cfg = integration_mod.loadNullTicketsConfig(allocator, paths, tracker_name.?) catch null orelse return notFound();
        break :blk .{
            .tickets = cfg,
            .pipeline_id = pipeline_id.?,
            .claim_role = if (parsed.value.object.get("claim_role")) |value|
                if (value == .string and value.string.len > 0) value.string else "coder"
            else
                "coder",
            .success_trigger = if (parsed.value.object.get("success_trigger")) |value|
                if (value == .string and value.string.len > 0) value.string else "complete"
            else
                "complete",
            .max_concurrent_tasks = if (parsed.value.object.get("max_concurrent_tasks")) |value|
                switch (value) {
                    .integer => if (value.integer > 0 and value.integer <= std.math.maxInt(u32)) @as(?u32, @intCast(value.integer)) else null,
                    .string => std.fmt.parseInt(u32, value.string, 10) catch null,
                    else => null,
                }
            else
                null,
        };
    };
    defer {
        var owned_cfg = tracker_cfg.tickets;
        integration_mod.deinitNullTicketsConfig(allocator, &owned_cfg);
    }

    var existing = integration_mod.loadNullBoilerConfig(allocator, paths, name) catch null orelse return notFound();
    defer integration_mod.deinitNullBoilerConfig(allocator, &existing);

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

    const config_path = paths.instanceConfig(allocator, "nullboiler", name) catch return helpers.serverError();
    defer allocator.free(config_path);
    const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch return helpers.serverError();
    defer file.close();
    const config_bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch return helpers.serverError();
    defer allocator.free(config_bytes);

    var parsed_config = std.json.parseFromSlice(std.json.Value, allocator, config_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return helpers.serverError();
    defer parsed_config.deinit();
    if (parsed_config.value != .object) return helpers.serverError();

    const tracker_map = ensureObjectField(allocator, &parsed_config.value.object, "tracker") catch return helpers.serverError();
    const tracker_url = std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}", .{tracker_cfg.tickets.port}) catch return helpers.serverError();
    tracker_map.put(allocator, "url", .{ .string = tracker_url }) catch return helpers.serverError();
    if (tracker_cfg.tickets.api_token) |token| {
        tracker_map.put(allocator, "api_token", .{ .string = token }) catch return helpers.serverError();
    } else {
        _ = tracker_map.swapRemove("api_token");
    }
    if (jsonString(tracker_map.*, "agent_id")) |agent_id| {
        if (agent_id.len == 0) {
            tracker_map.put(allocator, "agent_id", .{ .string = if (existing.tracker) |tracker| tracker.agent_id else name }) catch return helpers.serverError();
        }
    } else {
        tracker_map.put(allocator, "agent_id", .{ .string = if (existing.tracker) |tracker| tracker.agent_id else name }) catch return helpers.serverError();
    }
    if (jsonString(tracker_map.*, "workflows_dir")) |workflows_dir| {
        if (workflows_dir.len == 0) {
            tracker_map.put(allocator, "workflows_dir", .{ .string = "workflows" }) catch return helpers.serverError();
        }
    } else {
        tracker_map.put(allocator, "workflows_dir", .{ .string = "workflows" }) catch return helpers.serverError();
    }

    const concurrency_map = ensureObjectField(allocator, tracker_map, "concurrency") catch return helpers.serverError();
    if (tracker_cfg.max_concurrent_tasks) |max_concurrent_tasks| {
        concurrency_map.put(allocator, "max_concurrent_tasks", .{ .integer = max_concurrent_tasks }) catch return helpers.serverError();
    } else if (concurrency_map.get("max_concurrent_tasks") == null) {
        concurrency_map.put(allocator, "max_concurrent_tasks", .{ .integer = if (existing.tracker) |tracker| tracker.max_concurrent_tasks else 1 }) catch return helpers.serverError();
    }

    const workflows_dir_value = jsonStringOrEmpty(tracker_map.*, "workflows_dir");
    const rendered = std.json.Stringify.valueAlloc(allocator, parsed_config.value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    }) catch return helpers.serverError();
    defer allocator.free(rendered);

    const out = std_compat.fs.createFileAbsolute(config_path, .{ .truncate = true }) catch return helpers.serverError();
    defer out.close();
    out.writeAll(rendered) catch return helpers.serverError();
    out.writeAll("\n") catch return helpers.serverError();

    const workflows_dir = resolvePathFromConfig(allocator, config_path, workflows_dir_value) catch return helpers.serverError();
    defer allocator.free(workflows_dir);

    ensureTrackerWorkflowFile(
        allocator,
        config_path,
        workflows_dir,
        if (existing.tracker) |tracker| if (tracker.workflow) |workflow| workflow.file_name else null else null,
        tracker_cfg.pipeline_id,
        tracker_cfg.claim_role,
        tracker_cfg.success_trigger,
    ) catch return helpers.serverError();

    if (getStatusLocked(mutex, manager, "nullboiler", name)) |status| {
        if (status.status == .running) {
            mutex.lock();
            defer mutex.unlock();
            return handleRestart(allocator, s, manager, paths, "nullboiler", name, "");
        }
    }

    return jsonOk("{\"status\":\"linked\"}");
}

fn ensureTrackerWorkflowFile(
    allocator: std.mem.Allocator,
    config_path: []const u8,
    workflows_dir: []const u8,
    previous_workflow_file: ?[]const u8,
    pipeline_id: []const u8,
    claim_role: []const u8,
    success_trigger: []const u8,
) !void {
    try ensurePath(workflows_dir);

    if (previous_workflow_file) |file_name| {
        if (!std.mem.eql(u8, file_name, integration_mod.managed_workflow_file_name)) {
            const previous_path = try std.fs.path.join(allocator, &.{ workflows_dir, file_name });
            defer allocator.free(previous_path);
            if (isNullHubManagedWorkflow(allocator, previous_path)) {
                std_compat.fs.deleteFileAbsolute(previous_path) catch {};
            }
        }
    }

    const config_dir = std.fs.path.dirname(config_path) orelse return error.InvalidPath;
    const legacy_path = try std.fs.path.join(allocator, &.{ config_dir, integration_mod.legacy_workflow_file_name });
    defer allocator.free(legacy_path);
    std_compat.fs.deleteFileAbsolute(legacy_path) catch {};

    const legacy_workflows_path = try std.fs.path.join(allocator, &.{ workflows_dir, integration_mod.legacy_workflow_file_name });
    defer allocator.free(legacy_workflows_path);
    std_compat.fs.deleteFileAbsolute(legacy_workflows_path) catch {};

    const workflow_path = try std.fs.path.join(allocator, &.{ workflows_dir, integration_mod.managed_workflow_file_name });
    defer allocator.free(workflow_path);

    const rendered = try std.json.Stringify.valueAlloc(allocator, .{
        .id = try std.fmt.allocPrint(allocator, "wf-{s}-{s}", .{ pipeline_id, claim_role }),
        .pipeline_id = pipeline_id,
        .claim_roles = &.{claim_role},
        .execution = "subprocess",
        .prompt_template = default_tracker_prompt_template,
        .on_success = .{
            .transition_to = success_trigger,
        },
    }, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(rendered);

    const file_out = try std_compat.fs.createFileAbsolute(workflow_path, .{ .truncate = true });
    defer file_out.close();
    try file_out.writeAll(rendered);
    try file_out.writeAll("\n");
}

// ─── Top-level dispatcher ────────────────────────────────────────────────────

pub fn isIntegrationPath(target: []const u8) bool {
    const parsed = parsePath(target) orelse return false;
    return parsed.action != null and std.mem.eql(u8, parsed.action.?, "integration");
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

    if (parseCronPath(target)) |parsed_cron| {
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

    if (parseChannelsPath(target)) |parsed_channels| {
        if (!std.mem.eql(u8, method, "GET")) return methodNotAllowed();
        return handleChannels(allocator, s, paths, parsed_channels.component, parsed_channels.name, parsed_channels.channel_type);
    }

    const parsed = parsePath(target) orelse return null;

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
        if (std.mem.eql(u8, action, "agent-stream")) {
            if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();
            return .{
                .status = "501 Not Implemented",
                .content_type = "application/json",
                .body = "{\"error\":\"streaming agent sessions are not supported; use POST /agent\"}",
            };
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

        // Remaining actions are POST-only.
        if (!std.mem.eql(u8, method, "POST")) return methodNotAllowed();

        if (std.mem.eql(u8, action, "start")) return handleStart(allocator, s, manager, paths, parsed.component, parsed.name, body);
        if (std.mem.eql(u8, action, "stop")) return handleStop(s, manager, parsed.component, parsed.name);
        if (std.mem.eql(u8, action, "restart")) return handleRestart(allocator, s, manager, paths, parsed.component, parsed.name, body);

        return notFound();
    }

    // POST /api/instances/{component}/import — import standalone installation
    if (std.mem.eql(u8, method, "POST") and std.mem.eql(u8, parsed.name, "import")) {
        return handleImport(allocator, s, paths, parsed.component);
    }

    // No action — CRUD on the instance itself.
    if (std.mem.eql(u8, method, "GET")) return handleGet(allocator, s, manager, paths, parsed.component, parsed.name);
    if (std.mem.eql(u8, method, "DELETE")) return handleDelete(allocator, s, manager, paths, parsed.component, parsed.name);
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

    const resp = handleStop(&s, &mctx.manager, "nullclaw", "my-agent");
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

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent");
    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expectEqualStrings("{\"status\":\"deleted\"}", resp.body);

    // Verify it was actually removed.
    try std.testing.expect(s.getInstance("nullclaw", "my-agent") == null);
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

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent");
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

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nullclaw", "my-agent");
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

    const resp = handleDelete(allocator, &s, &mctx.manager, mctx.paths, "nope", "nope");
    try std.testing.expectEqualStrings("404 Not Found", resp.status);
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

test "handleOnboarding falls back to CLI bootstrap memory for legacy sqlite workspace" {
    const allocator = std.testing.allocator;
    var state_fixture = try test_helpers.TempPaths.init(allocator);
    defer state_fixture.deinit();
    const state_path = try state_fixture.paths.state(allocator);
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    var mctx = TestManagerCtx.init(allocator);
    defer mctx.deinit(allocator);

    try s.addInstance("nullclaw", "legacy-agent", .{ .version = "1.0.3" });
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "memory" ] && [ "$2" = "get" ] && [ "$3" = "__bootstrap.prompt.BOOTSTRAP.md" ]; then
        \\  if [ -z "$NULLCLAW_HOME" ]; then
        \\    echo "missing home" >&2
        \\    exit 1
        \\  fi
        \\  printf '%s\n' '{"key":"__bootstrap.prompt.BOOTSTRAP.md","category":"core","timestamp":"2026-03-13T02:37:27Z","content":"# bootstrap","session_id":null}'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.3", script);

    const inst_dir = try mctx.paths.instanceDir(allocator, "nullclaw", "legacy-agent");
    defer allocator.free(inst_dir);
    const workspace_dir = try std.fs.path.join(allocator, &.{ inst_dir, "workspace" });
    defer allocator.free(workspace_dir);
    try ensurePath(workspace_dir);

    const resp = handleOnboarding(allocator, &s, mctx.paths, "nullclaw", "legacy-agent");
    defer allocator.free(resp.body);

    try std.testing.expectEqualStrings("200 OK", resp.status);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"bootstrap_exists\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"pending\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"completed\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"bootstrap_seeded_at\":\"2026-03-13T02:37:27Z\"") != null);
}

test "handleOnboarding stays idle when legacy sqlite bootstrap memory is absent" {
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
    const script =
        \\#!/bin/sh
        \\if [ "$1" = "memory" ] && [ "$2" = "get" ] && [ "$3" = "__bootstrap.prompt.BOOTSTRAP.md" ]; then
        \\  printf '%s\n' 'null'
        \\  exit 0
        \\fi
        \\echo "unexpected args" >&2
        \\exit 1
        \\
    ;
    try writeTestBinary(allocator, mctx.paths, "nullclaw", "1.0.4", script);

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

    const legacy_workflow_path = try std.fs.path.join(allocator, &.{ mctx.paths.root, "instances", "nullboiler", "boiler-a", "tracker-workflow.json" });
    defer allocator.free(legacy_workflow_path);
    try std.testing.expectError(error.FileNotFound, std_compat.fs.openFileAbsolute(legacy_workflow_path, .{}));
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
            .prompt_template = default_tracker_prompt_template,
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

test "handleMemory wraps legacy CLI failures as JSON errors" {
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

    const stream_resp = dispatch(allocator, &s, &mctx.manager, &mctx.mutex, mctx.paths, "POST", "/api/instances/nullclaw/my-agent/agent-stream", "").?;
    try std.testing.expectEqualStrings("501 Not Implemented", stream_resp.status);

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
