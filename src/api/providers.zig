const std = @import("std");
const std_compat = @import("compat");
const state_mod = @import("../core/state.zig");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");
const wizard_api = @import("wizard.zig");

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

    // Custom providers (base_url set) bypass the nullclaw probe: the probe is
    // designed for known providers and can misclassify valid responses from
    // arbitrary OpenAI-compatible endpoints. Credential validation for custom
    // endpoints will be handled via the /models probe (added in a follow-up).
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
    }

    const validated_with = validated_with_buf orelse "";

    try state.addSavedProvider(.{
        .provider = parsed.value.provider,
        .api_key = parsed.value.api_key,
        .model = parsed.value.model,
        .base_url = parsed.value.base_url,
        .validated_with = validated_with,
    });

    // Record validation attempt if we validated
    if (validated_ok) {
        const providers = state.savedProviders();
        const new_id = providers[providers.len - 1].id;
        try persistValidationAttempt(allocator, state, new_id, validated_with, true);
    } else {
        try state.save();
    }

    // Return the saved provider
    const providers = state.savedProviders();
    const new_id = providers[providers.len - 1].id;
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
            // Custom provider: update fields directly without probe and clear
            // stale probe metadata from any previous standard-provider state.
            _ = try state.updateSavedProvider(id, .{
                .name = parsed.value.name,
                .api_key = parsed.value.api_key,
                .model = parsed.value.model,
                .base_url = parsed.value.base_url,
                .validated_at = "",
                .validated_with = "",
                .last_validation_at = "",
                .last_validation_ok = false,
            });
        }
    } else {
        // Name-only update
        _ = try state.updateSavedProvider(id, .{ .name = parsed.value.name });
    }

    try state.save();

    const sp = state.getSavedProvider(id).?;
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

    // Custom providers are validated via the /models endpoint (not yet implemented).
    // Return a clear response rather than running the nullclaw probe against an
    // arbitrary endpoint that the probe was not designed for.
    if (existing.base_url.len > 0) {
        return try allocator.dupe(u8, "{\"live_ok\":false,\"reason\":\"custom endpoint — validation via /models not yet available\"}");
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
        .provider = "infini-ai",
        .api_key = "sk-cp-test",
        .model = "minimax-m2.7",
        .base_url = "https://cloud.infini-ai.com/maas/coding/v1",
    });

    const json = try handleList(allocator, &s, true);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"base_url\":\"https://cloud.infini-ai.com/maas/coding/v1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"infini-ai\"") != null);
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
        \\{"provider":"local-llm","api_key":"sk-test","model":"llama3","base_url":"http://127.0.0.1:5801/v1"}
    ;
    const json = try handleCreate(allocator, body, &s, paths);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"base_url\":\"http://127.0.0.1:5801/v1\"") != null);
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

test "handleValidate for custom provider returns probe-not-applicable message" {
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
        .base_url = "http://127.0.0.1:5801/v1",
    });

    const paths = paths_mod.Paths.init(allocator, tmp) catch @panic("Paths.init");
    const json = try handleValidate(allocator, 1, &s, paths);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"live_ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "custom endpoint") != null);
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
    try std.testing.expectEqualStrings("", provider.last_validation_at);
    try std.testing.expect(!provider.last_validation_ok);
}
