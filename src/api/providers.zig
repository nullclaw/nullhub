const std = @import("std");
const std_compat = @import("compat");
const state_mod = @import("../core/state.zig");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");
const wizard_api = @import("wizard.zig");
const query_mod = @import("query.zig");

const appendEscaped = helpers.appendEscaped;

// ─── Path Parsing ────────────────────────────────────────────────────────────

/// Check if path matches /api/providers or /api/providers/...
pub fn isProvidersPath(target: []const u8) bool {
    return std.mem.eql(u8, target, "/api/providers") or
        std.mem.startsWith(u8, target, "/api/providers?") or
        std.mem.startsWith(u8, target, "/api/providers/");
}

/// Extract provider ID from /api/providers/{id} or /api/providers/{id}/validate
pub fn extractProviderId(target: []const u8) ?u32 {
    const prefix = "/api/providers/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    // Get the segment before any slash
    const segment = if (std.mem.indexOfScalar(u8, rest, '/')) |slash_pos|
        rest[0..slash_pos]
    else
        rest;
    return std.fmt.parseInt(u32, segment, 10) catch null;
}

/// Check if path matches /api/providers/{id}/validate
pub fn isValidatePath(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "/api/providers/") and
        std.mem.endsWith(u8, target, "/validate");
}

/// Check if ?reveal=true is in the query string
pub fn hasRevealParam(target: []const u8) bool {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    return std.mem.indexOf(u8, target[query_start..], "reveal=true") != null;
}

/// Check if path matches /api/providers/probe-models
pub fn isProbeModelsPath(target: []const u8) bool {
    return std.mem.eql(u8, target, "/api/providers/probe-models") or
        std.mem.startsWith(u8, target, "/api/providers/probe-models?");
}

// ─── Handlers ────────────────────────────────────────────────────────────────

/// GET /api/providers — list all saved providers
pub fn handleList(allocator: std.mem.Allocator, state: *state_mod.State, reveal: bool) ![]const u8 {
    const providers = state.savedProviders();

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("{\"providers\":[");

    for (providers, 0..) |sp, idx| {
        if (idx > 0) try buf.append(',');
        try appendProviderJson(&buf, sp, reveal);
    }

    try buf.appendSlice("]}");
    return buf.toOwnedSlice();
}

/// POST /api/providers — validate and save a new provider
pub fn handleCreate(
    allocator: std.mem.Allocator,
    body: []const u8,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    const parsed = std.json.parseFromSlice(struct {
        provider: []const u8,
        api_key: []const u8 = "",
        model: []const u8 = "",
        base_url: []const u8 = "",
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    // Custom providers (base_url set) use the OpenAI-compatible /models probe:
    // the nullclaw probe only understands known provider names.
    const is_custom = parsed.value.base_url.len > 0;
    var validated_ok = false;
    var validated_with_buf: ?[]const u8 = null;
    defer if (validated_with_buf) |s| allocator.free(s);

    if (!is_custom) {
        // Standard provider: validate via nullclaw probe
        const component_name = findProviderProbeComponent(allocator, state) orelse
            return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate providers\"}");
        defer allocator.free(component_name);

        const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
            return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
        defer allocator.free(bin_path);

        const probe_result = probeProvider(allocator, component_name, bin_path, parsed.value.provider, parsed.value.api_key, parsed.value.model, parsed.value.base_url);
        defer probe_result.deinit(allocator);
        if (!probe_result.live_ok) {
            var buf = std.array_list.Managed(u8).init(allocator);
            errdefer buf.deinit();
            try buf.appendSlice("{\"error\":\"Provider validation failed: ");
            try appendEscaped(&buf, probe_result.reason);
            try buf.appendSlice("\"}");
            return buf.toOwnedSlice();
        }
        validated_ok = true;
        validated_with_buf = try allocator.dupe(u8, component_name);
    } else {
        // Custom provider: probe the /models endpoint; always save regardless of result.
        var models_probe = probeModels(allocator, parsed.value.base_url, parsed.value.api_key);
        defer models_probe.deinit(allocator);
        validated_ok = models_probe.live_ok;
        if (validated_ok) {
            validated_with_buf = try allocator.dupe(u8, "models-probe");
        }
    }

    const validated_with = validated_with_buf orelse "";

    try state.addSavedProvider(.{
        .provider = parsed.value.provider,
        .api_key = parsed.value.api_key,
        .model = parsed.value.model,
        .base_url = parsed.value.base_url,
        .validated_with = validated_with,
    });

    // Record validation result
    const providers_list = state.savedProviders();
    const new_id = providers_list[providers_list.len - 1].id;
    if (validated_ok) {
        try persistValidationAttempt(allocator, state, new_id, validated_with, true);
    } else {
        if (is_custom) {
            // Custom probe ran but failed — record the attempt so the UI shows status.
            const now = try nowIso8601(allocator);
            defer allocator.free(now);
            _ = try state.updateSavedProvider(new_id, .{
                .last_validation_at = now,
                .last_validation_ok = false,
            });
        }
        try state.save();
    }

    // Sync credentials to all live nullclaw instances
    const sp_for_sync = state.getSavedProvider(new_id).?;
    syncProviderToInstances(allocator, state, paths, sp_for_sync.provider, sp_for_sync.api_key, sp_for_sync.base_url);

    // Return the saved provider
    const sp = state.getSavedProvider(new_id).?;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try appendProviderJson(&buf, sp, true);
    return buf.toOwnedSlice();
}

/// PUT /api/providers/{id} — update a saved provider
pub fn handleUpdate(
    allocator: std.mem.Allocator,
    id: u32,
    body: []const u8,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    const existing = state.getSavedProvider(id) orelse return try allocator.dupe(u8, "{\"error\":\"provider not found\"}");

    const parsed = std.json.parseFromSlice(struct {
        name: ?[]const u8 = null,
        api_key: ?[]const u8 = null,
        model: ?[]const u8 = null,
        base_url: ?[]const u8 = null,
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    const credentials_changed = (parsed.value.api_key != null and
        !std.mem.eql(u8, parsed.value.api_key.?, existing.api_key)) or
        (parsed.value.model != null and
            !std.mem.eql(u8, parsed.value.model.?, existing.model)) or
        (parsed.value.base_url != null and
            !std.mem.eql(u8, parsed.value.base_url.?, existing.base_url));

    if (credentials_changed) {
        const effective_key = parsed.value.api_key orelse existing.api_key;
        const effective_model = parsed.value.model orelse existing.model;
        const effective_base_url = parsed.value.base_url orelse existing.base_url;

        // Custom providers (base_url set) bypass the nullclaw probe — see handleCreate.
        const is_custom = effective_base_url.len > 0;
        if (!is_custom) {
            // Standard provider: re-validate via nullclaw probe
            const component_name = findProviderProbeComponent(allocator, state) orelse
                return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate providers\"}");
            defer allocator.free(component_name);

            const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
                return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
            defer allocator.free(bin_path);

            const probe_result = probeProvider(allocator, component_name, bin_path, existing.provider, effective_key, effective_model, effective_base_url);
            defer probe_result.deinit(allocator);
            const now = try nowIso8601(allocator);
            defer allocator.free(now);
            if (!probe_result.live_ok) {
                _ = try state.updateSavedProvider(id, .{
                    .last_validation_at = now,
                    .last_validation_ok = false,
                });
                try state.save();
                var buf = std.array_list.Managed(u8).init(allocator);
                errdefer buf.deinit();
                try buf.appendSlice("{\"error\":\"Provider validation failed: ");
                try appendEscaped(&buf, probe_result.reason);
                try buf.appendSlice("\"}");
                return buf.toOwnedSlice();
            }

            _ = try state.updateSavedProvider(id, .{
                .name = parsed.value.name,
                .api_key = parsed.value.api_key,
                .model = parsed.value.model,
                .base_url = parsed.value.base_url,
                .validated_at = now,
                .validated_with = component_name,
                .last_validation_at = now,
                .last_validation_ok = true,
            });
        } else {
            // Custom provider: probe /models endpoint; always update regardless of result.
            var models_probe = probeModels(allocator, effective_base_url, effective_key);
            defer models_probe.deinit(allocator);
            const now = try nowIso8601(allocator);
            defer allocator.free(now);
            _ = try state.updateSavedProvider(id, .{
                .name = parsed.value.name,
                .api_key = parsed.value.api_key,
                .model = parsed.value.model,
                .base_url = parsed.value.base_url,
                .validated_at = if (models_probe.live_ok) now else "",
                .validated_with = if (models_probe.live_ok) "models-probe" else "",
                .last_validation_at = now,
                .last_validation_ok = models_probe.live_ok,
            });
        }
    } else {
        // Name-only update
        _ = try state.updateSavedProvider(id, .{ .name = parsed.value.name });
    }

    try state.save();

    const sp = state.getSavedProvider(id).?;
    syncProviderToInstances(allocator, state, paths, sp.provider, sp.api_key, sp.base_url);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try appendProviderJson(&buf, sp, true);
    return buf.toOwnedSlice();
}

/// DELETE /api/providers/{id}
pub fn handleDelete(allocator: std.mem.Allocator, id: u32, state: *state_mod.State) ![]const u8 {
    if (!state.removeSavedProvider(id)) {
        return try allocator.dupe(u8, "{\"error\":\"provider not found\"}");
    }
    try state.save();
    return allocator.dupe(u8, "{\"status\":\"ok\"}");
}

/// POST /api/providers/{id}/validate — re-validate existing provider
pub fn handleValidate(
    allocator: std.mem.Allocator,
    id: u32,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    const existing = state.getSavedProvider(id) orelse return try allocator.dupe(u8, "{\"error\":\"provider not found\"}");

    // Custom providers: validate via the /models endpoint instead of nullclaw probe.
    if (existing.base_url.len > 0) {
        var models_probe = probeModels(allocator, existing.base_url, existing.api_key);
        defer models_probe.deinit(allocator);

        try persistValidationAttempt(allocator, state, id, "models-probe", models_probe.live_ok);

        var buf = std.array_list.Managed(u8).init(allocator);
        errdefer buf.deinit();
        try buf.appendSlice("{\"live_ok\":");
        try buf.appendSlice(if (models_probe.live_ok) "true" else "false");
        try buf.appendSlice(",\"reason\":\"");
        try appendEscaped(&buf, models_probe.reason);
        try buf.appendSlice("\"}");
        return buf.toOwnedSlice();
    }

    const component_name = findProviderProbeComponent(allocator, state) orelse
        return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate providers\"}");
    defer allocator.free(component_name);

    const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
        return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
    defer allocator.free(bin_path);

    const probe_result = probeProvider(allocator, component_name, bin_path, existing.provider, existing.api_key, existing.model, existing.base_url);
    defer probe_result.deinit(allocator);

    try persistValidationAttempt(allocator, state, id, component_name, probe_result.live_ok);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("{\"live_ok\":");
    try buf.appendSlice(if (probe_result.live_ok) "true" else "false");
    try buf.appendSlice(",\"reason\":\"");
    try appendEscaped(&buf, probe_result.reason);
    try buf.appendSlice("\"}");
    return buf.toOwnedSlice();
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

// ── /models probe ──────────────────────────────────────────────────────────

/// Result of probing an OpenAI-compatible /models endpoint.
const ModelsProbeResult = struct {
    live_ok: bool,
    /// Static string literal — never allocated, never freed.
    reason: []const u8,
    /// Owned JSON array string of model IDs, e.g. `["gpt-4","gpt-3.5-turbo"]`.
    /// Always valid JSON; `"[]"` when the probe failed or returned no data.
    model_ids_json: []u8,

    fn deinit(self: *ModelsProbeResult, allocator: std.mem.Allocator) void {
        if (self.model_ids_json.len > 0) allocator.free(self.model_ids_json);
    }
};

/// Build the models URL from a base_url (appends `/models`).
fn buildModelsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    if (std.mem.endsWith(u8, base_url, "/")) {
        return std.fmt.allocPrint(allocator, "{s}models", .{base_url});
    }
    return std.fmt.allocPrint(allocator, "{s}/models", .{base_url});
}

fn emptyModelIdsJson(allocator: std.mem.Allocator) ![]u8 {
    return allocator.dupe(u8, "[]");
}

/// Parse `data[].id` strings from an OpenAI-compatible /models JSON response.
/// Returns a JSON array string like `["gpt-4","llama3"]`. Caller owns the result.
fn parseModelIdsJson(allocator: std.mem.Allocator, body: []const u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return emptyModelIdsJson(allocator);
    defer parsed.deinit();

    const data = switch (parsed.value) {
        .object => |obj| obj.get("data") orelse return emptyModelIdsJson(allocator),
        else => return emptyModelIdsJson(allocator),
    };
    const items = switch (data) {
        .array => |arr| arr.items,
        else => return emptyModelIdsJson(allocator),
    };

    var out = std.array_list.Managed(u8).init(allocator);
    errdefer out.deinit();
    try out.append('[');
    var first = true;
    for (items) |item| {
        const id_val = switch (item) {
            .object => |obj| obj.get("id") orelse continue,
            else => continue,
        };
        const id_str = switch (id_val) {
            .string => |s| s,
            else => continue,
        };
        if (!first) try out.append(',');
        first = false;
        try out.append('"');
        try appendEscaped(&out, id_str);
        try out.append('"');
    }
    try out.append(']');
    return out.toOwnedSlice();
}

/// Probe an OpenAI-compatible `/models` endpoint using the given key.
fn probeModels(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
) ModelsProbeResult {
    const empty_models = emptyModelIdsJson(allocator) catch return .{
        .live_ok = false,
        .reason = "alloc_failed",
        .model_ids_json = &.{},
    };

    const url = buildModelsUrl(allocator, base_url) catch return .{
        .live_ok = false,
        .reason = "url_build_failed",
        .model_ids_json = empty_models,
    };
    defer allocator.free(url);

    var client: std.http.Client = .{ .allocator = allocator, .io = std_compat.io() };
    defer client.deinit();

    var response_body: std.Io.Writer.Allocating = .init(allocator);
    defer response_body.deinit();

    var auth_header_value: ?[]u8 = null;
    defer if (auth_header_value) |value| allocator.free(value);
    var header_buf: [1]std.http.Header = undefined;
    const extra_headers: []const std.http.Header = if (api_key.len > 0) blk: {
        const value = std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key}) catch
            return .{ .live_ok = false, .reason = "alloc_failed", .model_ids_json = empty_models };
        auth_header_value = value;
        header_buf[0] = .{ .name = "Authorization", .value = value };
        break :blk header_buf[0..];
    } else &.{};

    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &response_body.writer,
        .extra_headers = extra_headers,
    }) catch return .{ .live_ok = false, .reason = "network_error", .model_ids_json = empty_models };

    const status_code = @intFromEnum(result.status);
    if (status_code == 401 or status_code == 403) {
        return .{ .live_ok = false, .reason = "auth_failed", .model_ids_json = empty_models };
    }
    if (status_code < 200 or status_code >= 300) {
        return .{ .live_ok = false, .reason = "http_error", .model_ids_json = empty_models };
    }

    const bytes = response_body.toOwnedSlice() catch return .{
        .live_ok = true,
        .reason = "",
        .model_ids_json = empty_models,
    };
    defer allocator.free(bytes);

    const model_ids_json = parseModelIdsJson(allocator, bytes) catch return .{
        .live_ok = true,
        .reason = "",
        .model_ids_json = empty_models,
    };
    allocator.free(empty_models);

    return .{
        .live_ok = true,
        .reason = "",
        .model_ids_json = model_ids_json,
    };
}

fn handleProbeModelsFromValues(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    api_key: []const u8,
) ![]const u8 {
    var probe = probeModels(allocator, base_url, api_key);
    defer probe.deinit(allocator);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("{\"live_ok\":");
    try buf.appendSlice(if (probe.live_ok) "true" else "false");
    try buf.appendSlice(",\"reason\":\"");
    try appendEscaped(&buf, probe.reason);
    try buf.appendSlice("\",\"models\":");
    if (probe.model_ids_json.len > 0) {
        try buf.appendSlice(probe.model_ids_json);
    } else {
        try buf.appendSlice("[]");
    }
    try buf.append('}');
    return buf.toOwnedSlice();
}

/// GET /api/providers/probe-models?base_url=...&api_key=...
/// Probes an OpenAI-compatible endpoint's /models endpoint and returns the
/// list of available model IDs. Used by the frontend before saving a provider.
pub fn handleProbeModels(allocator: std.mem.Allocator, target: []const u8) ![]const u8 {
    const base_url = (try query_mod.valueAlloc(allocator, target, "base_url")) orelse
        return try allocator.dupe(u8, "{\"error\":\"base_url is required\"}");
    defer allocator.free(base_url);

    const api_key = (try query_mod.valueAlloc(allocator, target, "api_key")) orelse
        try allocator.dupe(u8, "");
    defer allocator.free(api_key);

    return handleProbeModelsFromValues(allocator, base_url, api_key);
}

/// POST /api/providers/probe-models
/// Body: {"base_url":"...","api_key":"..."}; api_key may be empty for local endpoints.
pub fn handleProbeModelsBody(allocator: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(struct {
        base_url: []const u8,
        api_key: []const u8 = "",
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}");
    defer parsed.deinit();

    if (parsed.value.base_url.len == 0) {
        return try allocator.dupe(u8, "{\"error\":\"base_url is required\"}");
    }

    return handleProbeModelsFromValues(allocator, parsed.value.base_url, parsed.value.api_key);
}

// ─── Instance Config Sync ────────────────────────────────────────────────────

/// Sync provider credentials (api_key + base_url) into every registered
/// nullclaw instance's config.json.  Best-effort: per-instance errors are
/// silently swallowed so a corrupt config on one instance doesn't block others.
fn syncProviderToInstances(
    allocator: std.mem.Allocator,
    state: *state_mod.State,
    paths: paths_mod.Paths,
    provider: []const u8,
    api_key: []const u8,
    base_url: []const u8,
) void {
    const names = state.instanceNames("nullclaw") catch return;
    defer if (names) |list| allocator.free(list);
    const list = names orelse return;
    for (list) |name| {
        syncProviderToInstance(allocator, paths, name, provider, api_key, base_url) catch {};
    }
}

fn syncProviderToInstance(
    allocator: std.mem.Allocator,
    paths: paths_mod.Paths,
    instance_name: []const u8,
    provider: []const u8,
    api_key: []const u8,
    base_url: []const u8,
) !void {
    const config_path = try paths.instanceConfig(allocator, "nullclaw", instance_name);
    defer allocator.free(config_path);

    // Read existing config or fall back to empty object if the file is missing.
    const contents = blk: {
        const file = std_compat.fs.openFileAbsolute(config_path, .{}) catch |err| switch (err) {
            error.FileNotFound => break :blk try allocator.dupe(u8, "{}"),
            else => return err,
        };
        defer file.close();
        break :blk try file.readToEndAlloc(allocator, 8 * 1024 * 1024);
    };
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const ja = parsed.arena.allocator();

    if (parsed.value != .object) return error.InvalidConfig;
    const root = &parsed.value.object;

    // Navigate/create: root → models → providers → <provider>
    const models_obj = try ensureObjectInMap(ja, root, "models");
    const providers_obj = try ensureObjectInMap(ja, models_obj, "providers");
    const provider_obj = try ensureObjectInMap(ja, providers_obj, provider);

    // Set api_key (string bytes are state-owned, outlive the arena)
    try provider_obj.put(ja, "api_key", .{ .string = api_key });

    // Set base_url only when present (mirrors writeMinimalProviderConfig behaviour)
    if (base_url.len > 0) {
        try provider_obj.put(ja, "base_url", .{ .string = base_url });
    } else {
        _ = provider_obj.orderedRemove("base_url");
    }

    // Serialize and write back
    const rendered = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{
        .whitespace = .indent_2,
        .emit_null_optional_fields = false,
    });
    defer allocator.free(rendered);

    const out = try std_compat.fs.createFileAbsolute(config_path, .{ .truncate = true });
    defer out.close();
    try out.writeAll(rendered);
    try out.writeAll("\n");
}

fn ensureObjectInMap(
    allocator: std.mem.Allocator,
    obj: *std.json.ObjectMap,
    key: []const u8,
) !*std.json.ObjectMap {
    const gop = try obj.getOrPut(allocator, key);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .object = .empty };
        return &gop.value_ptr.object;
    }
    if (gop.value_ptr.* != .object) {
        gop.value_ptr.* = .{ .object = .empty };
    }
    return &gop.value_ptr.object;
}

fn findProviderProbeComponent(allocator: std.mem.Allocator, state: *state_mod.State) ?[]const u8 {
    const names = state.instanceNames("nullclaw") catch return null;
    defer if (names) |list| allocator.free(list);
    if (names) |list| {
        if (list.len > 0) {
            return allocator.dupe(u8, "nullclaw") catch null;
        }
    }
    return null;
}

fn probeProvider(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    provider: []const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
) wizard_api.ProviderProbeResult {
    // Create temp dir for minimal config
    const tmp_dir = paths_mod.uniqueTempPathAlloc(allocator, "nullhub-provider-validate", "") catch
        return .{ .live_ok = false, .reason = "tmp_dir_failed" };
    defer {
        std_compat.fs.deleteTreeAbsolute(tmp_dir) catch {};
        allocator.free(tmp_dir);
    }
    std_compat.fs.makeDirAbsolute(tmp_dir) catch return .{ .live_ok = false, .reason = "tmp_dir_failed" };

    wizard_api.writeMinimalProviderConfigPub(allocator, tmp_dir, provider, api_key, base_url) catch
        return .{ .live_ok = false, .reason = "config_write_failed" };

    return wizard_api.probeProviderViaComponentBinaryPub(allocator, component_name, binary_path, tmp_dir, provider, model);
}

fn maskApiKey(buf: *std.array_list.Managed(u8), key: []const u8) !void {
    if (key.len <= 8) {
        try buf.appendSlice("***");
    } else {
        try buf.appendSlice(key[0..4]);
        try buf.appendSlice("...");
        try buf.appendSlice(key[key.len - 4 ..]);
    }
}

fn persistValidationAttempt(
    allocator: std.mem.Allocator,
    state: *state_mod.State,
    id: u32,
    component_name: []const u8,
    live_ok: bool,
) !void {
    const now = try nowIso8601(allocator);
    defer allocator.free(now);

    _ = try state.updateSavedProvider(id, .{
        .validated_at = if (live_ok) now else null,
        .validated_with = if (live_ok) component_name else null,
        .last_validation_at = now,
        .last_validation_ok = live_ok,
    });
    try state.save();
}

fn appendProviderJson(buf: *std.array_list.Managed(u8), sp: state_mod.SavedProvider, reveal: bool) !void {
    try buf.appendSlice("{\"id\":\"sp_");
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{sp.id}) catch "0";
    try buf.appendSlice(id_str);
    try buf.appendSlice("\"");
    try buf.appendSlice(",\"name\":\"");
    try appendEscaped(buf, sp.name);
    try buf.appendSlice("\",\"provider\":\"");
    try appendEscaped(buf, sp.provider);
    try buf.appendSlice("\",\"api_key\":\"");
    if (reveal) {
        try appendEscaped(buf, sp.api_key);
    } else {
        try maskApiKey(buf, sp.api_key);
    }
    try buf.appendSlice("\",\"model\":\"");
    try appendEscaped(buf, sp.model);
    try buf.appendSlice("\",\"base_url\":\"");
    try appendEscaped(buf, sp.base_url);
    try buf.appendSlice("\",\"validated_at\":\"");
    try appendEscaped(buf, sp.validated_at);
    try buf.appendSlice("\",\"validated_with\":\"");
    try appendEscaped(buf, sp.validated_with);
    try buf.appendSlice("\",\"last_validation_at\":\"");
    try appendEscaped(buf, sp.last_validation_at);
    try buf.appendSlice("\",\"last_validation_ok\":");
    try buf.appendSlice(if (sp.last_validation_ok) "true" else "false");
    try buf.appendSlice("}");
}

pub fn nowIso8601(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std_compat.time.timestamp();
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(0, timestamp)) };
    const day = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "isProvidersPath matches correct paths" {
    try std.testing.expect(isProvidersPath("/api/providers"));
    try std.testing.expect(isProvidersPath("/api/providers?reveal=true"));
    try std.testing.expect(isProvidersPath("/api/providers/1"));
    try std.testing.expect(isProvidersPath("/api/providers/1/validate"));
    try std.testing.expect(!isProvidersPath("/api/wizard"));
    try std.testing.expect(!isProvidersPath("/api/provider"));
}

test "extractProviderId parses correctly" {
    try std.testing.expectEqual(@as(?u32, 1), extractProviderId("/api/providers/1"));
    try std.testing.expectEqual(@as(?u32, 42), extractProviderId("/api/providers/42"));
    try std.testing.expectEqual(@as(?u32, 5), extractProviderId("/api/providers/5/validate"));
    try std.testing.expectEqual(@as(?u32, null), extractProviderId("/api/providers"));
    try std.testing.expectEqual(@as(?u32, null), extractProviderId("/api/providers/abc"));
}

test "isValidatePath matches only validate suffix" {
    try std.testing.expect(isValidatePath("/api/providers/1/validate"));
    try std.testing.expect(!isValidatePath("/api/providers/1"));
    try std.testing.expect(!isValidatePath("/api/providers"));
}

test "hasRevealParam detects reveal query param" {
    try std.testing.expect(hasRevealParam("/api/providers?reveal=true"));
    try std.testing.expect(!hasRevealParam("/api/providers"));
    try std.testing.expect(!hasRevealParam("/api/providers?reveal=false"));
}

test "handleList returns empty array for no providers" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-provider-test-list.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    const json = try handleList(allocator, &s, false);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"providers\":[]}", json);
}

test "handleList masks api_key by default" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-provider-test-mask.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "sk-or-1234567890abcdef" });

    const json = try handleList(allocator, &s, false);
    defer allocator.free(json);
    // Should contain masked key, not the full key
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-o...cdef") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-or-1234567890abcdef") == null);
}

test "handleList reveals api_key when requested" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-provider-test-reveal.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "sk-or-1234567890abcdef" });

    const json = try handleList(allocator, &s, true);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "sk-or-1234567890abcdef") != null);
}

test "handleList includes base_url for openai-compatible provider" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-provider-test-baseurl.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{
        .provider = "custom-llm",
        .api_key = "sk-test-key",
        .model = "test-model",
        .base_url = "https://example.com/v1",
    });

    const json = try handleList(allocator, &s, true);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"base_url\":\"https://example.com/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"custom-llm\"") != null);
}

test "handleList includes empty base_url for standard provider" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-provider-test-baseurl-empty.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "sk-or-xxx" });

    const json = try handleList(allocator, &s, true);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"base_url\":\"\"") != null);
}

test "findProviderProbeComponent prefers installed nullclaw" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-provider-test-probe-component.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addInstance("nullclaw", "instance-1", .{ .version = "v2026.3.8" });

    const component = findProviderProbeComponent(allocator, &s) orelse @panic("expected nullclaw probe component");
    defer allocator.free(component);
    try std.testing.expectEqualStrings("nullclaw", component);
}

test "findProviderProbeComponent returns null without nullclaw instances" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-provider-test-probe-component-empty.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addInstance("nullboiler", "worker-a", .{ .version = "v1.0.0" });

    try std.testing.expect(findProviderProbeComponent(allocator, &s) == null);
}

test "handleDelete removes provider" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-provider-test-delete";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(path);

    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key1" });

    const json = try handleDelete(allocator, 1, &s);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", json);
    try std.testing.expectEqual(@as(usize, 0), s.savedProviders().len);
}

test "handleDelete returns error for unknown id" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-provider-test-del-unknown.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    const json = try handleDelete(allocator, 99, &s);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"error\":\"provider not found\"}", json);
}

test "maskApiKey masks long keys" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try maskApiKey(&buf, "sk-or-1234567890abcdef");
    try std.testing.expectEqualStrings("sk-o...cdef", buf.items);
}

test "maskApiKey masks short keys" {
    const allocator = std.testing.allocator;
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try maskApiKey(&buf, "short");
    try std.testing.expectEqualStrings("***", buf.items);
}

test "nowIso8601 returns valid format" {
    const allocator = std.testing.allocator;
    const ts = try nowIso8601(allocator);
    defer allocator.free(ts);
    // Should be like "2026-03-11T12:00:00Z"
    try std.testing.expectEqual(@as(usize, 20), ts.len);
    try std.testing.expect(ts[4] == '-');
    try std.testing.expect(ts[7] == '-');
    try std.testing.expect(ts[10] == 'T');
    try std.testing.expect(ts[19] == 'Z');
}

test "handleCreate with base_url saves without requiring nullclaw probe" {
    // Regression: custom providers with a base_url must not block on the
    // nullclaw probe — the probe is designed for known providers and can
    // misclassify valid responses from arbitrary OpenAI-compatible endpoints.
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-provider-test-custom-create";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);

    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    // No nullclaw instance installed — would normally block standard providers
    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");

    const body =
        \\{"provider":"local-llm","api_key":"sk-test","model":"llama3","base_url":"http://127.0.0.1:19999/v1"}
    ;
    const json = try handleCreate(allocator, body, &s, paths);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"base_url\":\"http://127.0.0.1:19999/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"local-llm\"") != null);
    try std.testing.expectEqual(@as(usize, 1), s.savedProviders().len);
}

test "handleCreate with base_url persists custom provider" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-provider-test-custom-create-persist";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);

    {
        var s = state_mod.State.init(allocator, state_path);
        defer s.deinit();

        const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");
        const body =
            \\{"provider":"local-llm","api_key":"sk-test","model":"llama3","base_url":"http://127.0.0.1:5801/v1"}
        ;
        const json = try handleCreate(allocator, body, &s, paths);
        defer allocator.free(json);

        try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") == null);
    }

    var loaded = try state_mod.State.load(allocator, state_path);
    defer loaded.deinit();

    const providers = loaded.savedProviders();
    try std.testing.expectEqual(@as(usize, 1), providers.len);
    try std.testing.expectEqualStrings("local-llm", providers[0].provider);
    try std.testing.expectEqualStrings("http://127.0.0.1:5801/v1", providers[0].base_url);
}

test "handleCreate without base_url requires nullclaw instance" {
    // Standard providers (no base_url) must require an installed nullclaw
    // instance to run the probe.
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-provider-test-standard-create";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);

    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    // No nullclaw instance installed
    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");

    const body =
        \\{"provider":"openrouter","api_key":"sk-or-test"}
    ;
    const json = try handleCreate(allocator, body, &s, paths);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") != null);
    try std.testing.expectEqual(@as(usize, 0), s.savedProviders().len);
}

test "handleValidate for custom provider uses models probe (not nullclaw)" {
    // Regression: handleValidate for a custom provider must not require a nullclaw
    // instance — it uses the /models probe directly. The probe will fail here
    // (no server at 19999) but the key point is we get a live_ok + reason response,
    // NOT the old "custom endpoint — validation via /models not yet available" placeholder.
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-provider-test-validate-custom";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);

    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addSavedProvider(.{
        .provider = "local-llm",
        .api_key = "sk-test",
        .base_url = "http://127.0.0.1:19999/v1",
    });

    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");
    const json = try handleValidate(allocator, 1, &s, paths);
    defer allocator.free(json);

    // Must return a probe result (live_ok present), never the old placeholder string.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"live_ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "not yet available") == null);
    // No nullclaw probe: no "Install a nullclaw instance" error expected.
    try std.testing.expect(std.mem.indexOf(u8, json, "Install a nullclaw instance") == null);
    // Probe should fail (19999 is not running in tests)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"live_ok\":false") != null);
}

test "buildModelsUrl appends /models with and without trailing slash" {
    const allocator = std.testing.allocator;

    const a = try buildModelsUrl(allocator, "https://api.example.com/v1");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("https://api.example.com/v1/models", a);

    const b = try buildModelsUrl(allocator, "https://api.example.com/v1/");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("https://api.example.com/v1/models", b);
}

test "parseModelIdsJson extracts data[].id strings" {
    const allocator = std.testing.allocator;
    const body =
        \\{"object":"list","data":[{"id":"gpt-4","object":"model"},{"id":"gpt-3.5-turbo","object":"model"}]}
    ;
    const result = try parseModelIdsJson(allocator, body);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[\"gpt-4\",\"gpt-3.5-turbo\"]", result);
}

test "parseModelIdsJson returns empty array for invalid JSON" {
    const allocator = std.testing.allocator;
    const result = try parseModelIdsJson(allocator, "not json");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "parseModelIdsJson returns empty array for missing data field" {
    const allocator = std.testing.allocator;
    const result = try parseModelIdsJson(allocator, "{\"object\":\"list\"}");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("[]", result);
}

test "isProbeModelsPath matches correct paths" {
    try std.testing.expect(isProbeModelsPath("/api/providers/probe-models"));
    try std.testing.expect(isProbeModelsPath("/api/providers/probe-models?base_url=x&api_key=y"));
    try std.testing.expect(!isProbeModelsPath("/api/providers/1"));
    try std.testing.expect(!isProbeModelsPath("/api/providers"));
    try std.testing.expect(!isProbeModelsPath("/api/providers/probe-modelsX"));
}

test "handleProbeModels returns error when base_url missing" {
    const allocator = std.testing.allocator;
    const json = try handleProbeModels(allocator, "/api/providers/probe-models?api_key=sk-test");
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "base_url") != null);
}

test "handleProbeModels allows missing api_key for local endpoints" {
    const allocator = std.testing.allocator;
    const json = try handleProbeModels(allocator, "/api/providers/probe-models?base_url=http%3A%2F%2F127.0.0.1%3A19999%2Fv1");
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"live_ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"models\":[]") != null);
}

test "handleProbeModelsBody returns error when base_url missing" {
    const allocator = std.testing.allocator;
    const json = try handleProbeModelsBody(allocator, "{\"api_key\":\"sk-test\"}");
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "base_url") != null);
}

test "handleProbeModels returns live_ok false for unreachable endpoint" {
    const allocator = std.testing.allocator;
    // Port 19999 should not be running anything in CI
    const json = try handleProbeModels(allocator, "/api/providers/probe-models?base_url=http%3A%2F%2F127.0.0.1%3A19999%2Fv1&api_key=sk-test");
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"live_ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"models\":[]") != null);
}

test "handleCreate custom provider records last_validation_at after probe attempt" {
    // When a custom provider is created, a /models probe is attempted. Even if it
    // fails (no server), last_validation_at must be set in the saved state.
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-provider-test-custom-create-ts";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);

    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");

    const body =
        \\{"provider":"local-llm","api_key":"sk-test","model":"llama3","base_url":"http://127.0.0.1:19998/v1"}
    ;
    const json = try handleCreate(allocator, body, &s, paths);
    defer allocator.free(json);

    // Must save successfully (no error)
    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") == null);
    try std.testing.expectEqual(@as(usize, 1), s.savedProviders().len);

    // last_validation_at must be set (probe was attempted)
    const sp = s.savedProviders()[0];
    try std.testing.expect(sp.last_validation_at.len > 0);
    // last_validation_ok must be false (port 19998 not running)
    try std.testing.expect(!sp.last_validation_ok);
}

// ─── syncProviderToInstances tests ───────────────────────────────────────────

fn makeInstanceDir(tmp: []const u8) !void {
    var buf: [512]u8 = undefined;
    const instances = try std.fmt.bufPrint(&buf, "{s}/instances", .{tmp});
    std_compat.fs.makeDirAbsolute(instances) catch |e| if (e != error.PathAlreadyExists) return e;
    const nullclaw = try std.fmt.bufPrint(&buf, "{s}/instances/nullclaw", .{tmp});
    std_compat.fs.makeDirAbsolute(nullclaw) catch |e| if (e != error.PathAlreadyExists) return e;
    const default = try std.fmt.bufPrint(&buf, "{s}/instances/nullclaw/default", .{tmp});
    std_compat.fs.makeDirAbsolute(default) catch |e| if (e != error.PathAlreadyExists) return e;
}

test "syncProviderToInstances writes provider creds into instance config" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-sync-test-write";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    try s.addInstance("nullclaw", "default", .{ .version = "v2026.1.0" });

    try makeInstanceDir(tmp);

    // Write an existing config with an unrelated key
    const config_path = try std.fmt.allocPrint(allocator, "{s}/instances/nullclaw/default/config.json", .{tmp});
    defer allocator.free(config_path);
    {
        const f = try std_compat.fs.createFileAbsolute(config_path, .{});
        defer f.close();
        try f.writeAll("{\"port\":9100}\n");
    }

    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");
    syncProviderToInstances(allocator, &s, paths, "custom-llm", "sk-abc123", "https://example.com/v1");

    // Read back and verify credentials are present
    const f2 = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer f2.close();
    const result = try f2.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"custom-llm\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sk-abc123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"https://example.com/v1\"") != null);
    // Existing key must not be clobbered
    try std.testing.expect(std.mem.indexOf(u8, result, "\"port\"") != null);
}

test "syncProviderToInstances omits base_url when empty" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-sync-test-no-baseurl";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    try s.addInstance("nullclaw", "default", .{ .version = "v2026.1.0" });

    try makeInstanceDir(tmp);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/instances/nullclaw/default/config.json", .{tmp});
    defer allocator.free(config_path);
    {
        const f = try std_compat.fs.createFileAbsolute(config_path, .{});
        defer f.close();
        try f.writeAll("{}\n");
    }

    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");
    syncProviderToInstances(allocator, &s, paths, "openrouter", "sk-or-key", "");

    const f2 = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer f2.close();
    const result = try f2.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"openrouter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sk-or-key\"") != null);
    // base_url must not appear when empty
    try std.testing.expect(std.mem.indexOf(u8, result, "\"base_url\"") == null);
}

test "syncProviderToInstances removes stale base_url when empty" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-sync-test-clear-baseurl";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    try s.addInstance("nullclaw", "default", .{ .version = "v2026.1.0" });

    try makeInstanceDir(tmp);

    const config_path = try std.fmt.allocPrint(allocator, "{s}/instances/nullclaw/default/config.json", .{tmp});
    defer allocator.free(config_path);
    {
        const f = try std_compat.fs.createFileAbsolute(config_path, .{});
        defer f.close();
        try f.writeAll("{\"models\":{\"providers\":{\"openrouter\":{\"api_key\":\"old\",\"base_url\":\"https://old.example.com/v1\"}}}}\n");
    }

    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");
    syncProviderToInstances(allocator, &s, paths, "openrouter", "sk-or-key", "");

    const f2 = try std_compat.fs.openFileAbsolute(config_path, .{});
    defer f2.close();
    const result = try f2.readToEndAlloc(allocator, 64 * 1024);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\"openrouter\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"sk-or-key\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"base_url\"") == null);
}

test "syncProviderToInstances is no-op when no nullclaw instances" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-sync-test-noop";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);
    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();
    // No nullclaw instances registered

    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");
    // Should not panic or error when there are no instances
    syncProviderToInstances(allocator, &s, paths, "openrouter", "sk-key", "");
}

test "handleUpdate custom provider clears stale validation metadata" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-provider-test-update-custom-clears-validation";
    std_compat.fs.deleteTreeAbsolute(tmp) catch {};
    std_compat.fs.makeDirAbsolute(tmp) catch {};
    defer std_compat.fs.deleteTreeAbsolute(tmp) catch {};

    const state_path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(state_path);

    var s = state_mod.State.init(allocator, state_path);
    defer s.deinit();

    try s.addSavedProvider(.{
        .provider = "local-llm",
        .api_key = "old-key",
        .base_url = "http://127.0.0.1:5801/v1",
        .validated_with = "nullclaw",
    });
    _ = try s.updateSavedProvider(1, .{
        .validated_at = "2026-03-11T18:59:00Z",
        .last_validation_at = "2026-03-14T11:22:33Z",
        .last_validation_ok = true,
    });

    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");
    const json = try handleUpdate(allocator, 1, "{\"api_key\":\"new-key\"}", &s, paths);
    defer allocator.free(json);

    const provider = s.getSavedProvider(1).?;
    try std.testing.expectEqualStrings("new-key", provider.api_key);
    try std.testing.expectEqualStrings("", provider.validated_at);
    try std.testing.expectEqualStrings("", provider.validated_with);
    try std.testing.expect(provider.last_validation_at.len > 0);
    try std.testing.expect(!std.mem.eql(u8, "2026-03-14T11:22:33Z", provider.last_validation_at));
    try std.testing.expect(!provider.last_validation_ok);
}
