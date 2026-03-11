# Saved Providers Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Save validated AI provider credentials in NullHub for reuse across bot creation, with a dedicated Providers management page.

**Architecture:** Extend `state.json` with a `saved_providers` array. New `src/api/providers.zig` handles CRUD + validation endpoints. New `/providers` frontend route for management. Wizard ProviderList gains "Use Saved" dropdown and auto-save on validation.

**Tech Stack:** Zig 0.15.2 backend, Svelte 5 + SvelteKit frontend, file-based JSON storage.

**Spec:** `docs/superpowers/specs/2026-03-11-saved-providers-design.md`

---

## File Structure

### Backend (Zig)

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `src/core/state.zig` | Add `SavedProvider` struct, extend `JsonState` and `State` with `saved_providers` list + CRUD methods |
| Create | `src/api/providers.zig` | All `/api/providers` endpoint handlers: list, create, update, delete, re-validate |
| Modify | `src/server.zig` | Register provider routes, import `providers_api` |
| Modify | `src/root.zig` | Register `providers_api` for test discovery |
| Modify | `src/api/wizard.zig` | Add auto-save call after successful provider validation |

### Frontend (Svelte)

| Action | File | Responsibility |
|--------|------|----------------|
| Modify | `ui/src/lib/api/client.ts` | Add provider CRUD API methods |
| Create | `ui/src/routes/providers/+page.svelte` | Providers management page |
| Modify | `ui/src/lib/components/Sidebar.svelte` | Add "Providers" nav link |
| Modify | `ui/src/lib/components/ProviderList.svelte` | Add "Use Saved" dropdown |
| Modify | `ui/src/lib/components/WizardRenderer.svelte` | Auto-save after validation |

---

## Chunk 1: Backend — State Layer

### Task 1: Add SavedProvider struct and State CRUD methods

**Files:**
- Modify: `src/core/state.zig:1-263` (struct definitions and State methods)

- [ ] **Step 1: Write tests for SavedProvider CRUD**

Add after line 561 in `src/core/state.zig`:

```zig
test "add saved provider, save, load, verify round-trip" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    {
        var s = State.init(allocator, path);
        defer s.deinit();

        try s.addSavedProvider(.{
            .provider = "openrouter",
            .api_key = "sk-or-xxx",
            .model = "anthropic/claude-sonnet-4",
            .validated_with = "nullclaw",
        });

        const providers = s.savedProviders();
        try std.testing.expectEqual(@as(usize, 1), providers.len);
        try std.testing.expectEqualStrings("openrouter", providers[0].provider);
        try std.testing.expectEqualStrings("sk-or-xxx", providers[0].api_key);
        try std.testing.expectEqualStrings("anthropic/claude-sonnet-4", providers[0].model);
        try std.testing.expectEqualStrings("OpenRouter #1", providers[0].name);
        try std.testing.expectEqual(@as(u32, 1), providers[0].id);

        try s.save();
    }

    {
        var s = try State.load(allocator, path);
        defer s.deinit();

        const providers = s.savedProviders();
        try std.testing.expectEqual(@as(usize, 1), providers.len);
        try std.testing.expectEqualStrings("openrouter", providers[0].provider);
        try std.testing.expectEqualStrings("sk-or-xxx", providers[0].api_key);
        try std.testing.expectEqualStrings("OpenRouter #1", providers[0].name);
        try std.testing.expectEqual(@as(u32, 1), providers[0].id);
    }
}

test "auto-generated name increments per provider type" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key1" });
    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key2" });
    try s.addSavedProvider(.{ .provider = "anthropic", .api_key = "key3" });

    const providers = s.savedProviders();
    try std.testing.expectEqual(@as(usize, 3), providers.len);
    try std.testing.expectEqualStrings("OpenRouter #1", providers[0].name);
    try std.testing.expectEqualStrings("OpenRouter #2", providers[1].name);
    try std.testing.expectEqualStrings("Anthropic #1", providers[2].name);
}

test "update saved provider name only" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key1" });
    const updated = try s.updateSavedProvider(1, .{ .name = "My Work Key" });
    try std.testing.expect(updated);

    const providers = s.savedProviders();
    try std.testing.expectEqualStrings("My Work Key", providers[0].name);
}

test "update saved provider api_key" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "old-key" });
    const updated = try s.updateSavedProvider(1, .{ .api_key = "new-key" });
    try std.testing.expect(updated);

    const providers = s.savedProviders();
    try std.testing.expectEqualStrings("new-key", providers[0].api_key);
}

test "remove saved provider" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key1" });
    try s.addSavedProvider(.{ .provider = "anthropic", .api_key = "key2" });

    try std.testing.expect(s.removeSavedProvider(1));
    try std.testing.expect(!s.removeSavedProvider(99));

    const providers = s.savedProviders();
    try std.testing.expectEqual(@as(usize, 1), providers.len);
    try std.testing.expectEqualStrings("anthropic", providers[0].provider);
}

test "find saved provider by id" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key1" });
    try s.addSavedProvider(.{ .provider = "anthropic", .api_key = "key2" });

    const found = s.getSavedProvider(2);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("anthropic", found.?.provider);

    try std.testing.expect(s.getSavedProvider(99) == null);
}

test "saved providers coexist with instances in save/load" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    {
        var s = State.init(allocator, path);
        defer s.deinit();

        try s.addInstance("nullclaw", "bot1", .{ .version = "1.0.0" });
        try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key1" });
        try s.save();
    }

    {
        var s = try State.load(allocator, path);
        defer s.deinit();

        try std.testing.expect(s.getInstance("nullclaw", "bot1") != null);
        try std.testing.expectEqual(@as(usize, 1), s.savedProviders().len);
    }
}

test "next provider id after removals" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key1" }); // id=1
    try s.addSavedProvider(.{ .provider = "anthropic", .api_key = "key2" }); // id=2
    _ = s.removeSavedProvider(1);
    try s.addSavedProvider(.{ .provider = "ollama", .api_key = "" }); // id=3 (not 1)

    const providers = s.savedProviders();
    try std.testing.expectEqual(@as(usize, 2), providers.len);
    try std.testing.expectEqual(@as(u32, 2), providers[0].id);
    try std.testing.expectEqual(@as(u32, 3), providers[1].id);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | head -30`
Expected: compilation errors — `addSavedProvider`, `savedProviders`, etc. not found.

- [ ] **Step 3: Add SavedProvider struct and provider label map**

Add after `InstanceEntry` (after line 9) in `src/core/state.zig`:

```zig
pub const SavedProvider = struct {
    id: u32, // serialized as "sp_{id}" in JSON for wire format
    name: []const u8,
    provider: []const u8,
    api_key: []const u8,
    model: []const u8 = "",
    validated_at: []const u8 = "",
    validated_with: []const u8 = "",
};

/// Input for adding a new saved provider (id and name are auto-generated).
pub const SavedProviderInput = struct {
    provider: []const u8,
    api_key: []const u8,
    model: []const u8 = "",
    validated_with: []const u8 = "",
};

/// Optional fields for updating a saved provider. Empty string = no change.
pub const SavedProviderUpdate = struct {
    name: []const u8 = "",
    api_key: []const u8 = "",
    model: []const u8 = "",
    validated_at: []const u8 = "",
    validated_with: []const u8 = "",
};

fn providerLabel(provider: []const u8) []const u8 {
    const map = .{
        .{ "openrouter", "OpenRouter" },
        .{ "anthropic", "Anthropic" },
        .{ "openai", "OpenAI" },
        .{ "google", "Google" },
        .{ "mistral", "Mistral" },
        .{ "groq", "Groq" },
        .{ "deepseek", "DeepSeek" },
        .{ "cohere", "Cohere" },
        .{ "ollama", "Ollama" },
        .{ "lm-studio", "LM Studio" },
        .{ "claude-cli", "Claude CLI" },
        .{ "codex-cli", "Codex CLI" },
        .{ "together", "Together" },
        .{ "fireworks", "Fireworks" },
        .{ "perplexity", "Perplexity" },
        .{ "xai", "xAI" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, provider, pair[0])) return pair[1];
    }
    return provider;
}
```

- [ ] **Step 4: Extend JsonState for serialization**

Replace `JsonState` struct (lines 14-16) with:

```zig
const JsonState = struct {
    instances: std.json.ArrayHashMap(std.json.ArrayHashMap(InstanceEntry)),
    saved_providers: []const SavedProvider = &.{},
};
```

- [ ] **Step 5: Add saved_providers field and CRUD methods to State**

Add a new field to the `State` struct (after line 29):

```zig
    saved_providers: std.ArrayList(SavedProvider),
```

Update `State.init` (line 33-38) to also initialize the ArrayList:

```zig
    pub fn init(allocator: std.mem.Allocator, path: []const u8) State {
        return .{
            .allocator = allocator,
            .instances = ComponentMap.init(allocator),
            .saved_providers = std.ArrayList(SavedProvider).init(allocator),
            .path = allocator.dupe(u8, path) catch @panic("OOM"),
        };
    }
```

Add cleanup to `State.deinit` (after line 54 `self.instances.deinit();`):

```zig
        for (self.saved_providers.items) |sp| {
            self.allocator.free(sp.name);
            self.allocator.free(sp.provider);
            self.allocator.free(sp.api_key);
            if (sp.model.len > 0) self.allocator.free(sp.model);
            if (sp.validated_at.len > 0) self.allocator.free(sp.validated_at);
            if (sp.validated_with.len > 0) self.allocator.free(sp.validated_with);
        }
        self.saved_providers.deinit();
```

Add to `State.load` (after `state.instances` is populated, before `return state;` at line 115) — load saved_providers from parsed JSON:

```zig
        for (parsed.value.saved_providers) |sp| {
            const owned = SavedProvider{
                .id = sp.id,
                .name = try allocator.dupe(u8, sp.name),
                .provider = try allocator.dupe(u8, sp.provider),
                .api_key = try allocator.dupe(u8, sp.api_key),
                .model = if (sp.model.len > 0) try allocator.dupe(u8, sp.model) else "",
                .validated_at = if (sp.validated_at.len > 0) try allocator.dupe(u8, sp.validated_at) else "",
                .validated_with = if (sp.validated_with.len > 0) try allocator.dupe(u8, sp.validated_with) else "",
            };
            try state.saved_providers.append(owned);
        }
```

Update `State.save` — build `JsonState` with saved_providers. After `const json_state = JsonState{ .instances = json_outer };` (line 145), replace with:

```zig
        const json_state = JsonState{
            .instances = json_outer,
            .saved_providers = self.saved_providers.items,
        };
```

Add CRUD methods to `State` (before the closing `};` at line 263):

```zig
    /// Return the current saved providers slice (read-only view).
    pub fn savedProviders(self: *State) []const SavedProvider {
        return self.saved_providers.items;
    }

    /// Find a saved provider by ID. Returns null if not found.
    pub fn getSavedProvider(self: *State, id: u32) ?SavedProvider {
        for (self.saved_providers.items) |sp| {
            if (sp.id == id) return sp;
        }
        return null;
    }

    /// Add a new saved provider. Auto-generates id and name.
    pub fn addSavedProvider(self: *State, input: SavedProviderInput) !void {
        const id = self.nextProviderId();
        const name = try self.generateProviderName(input.provider);
        errdefer self.allocator.free(name);

        const sp = SavedProvider{
            .id = id,
            .name = name,
            .provider = try self.allocator.dupe(u8, input.provider),
            .api_key = try self.allocator.dupe(u8, input.api_key),
            .model = if (input.model.len > 0) try self.allocator.dupe(u8, input.model) else "",
            .validated_at = "",
            .validated_with = if (input.validated_with.len > 0) try self.allocator.dupe(u8, input.validated_with) else "",
        };
        try self.saved_providers.append(sp);
    }

    /// Update an existing saved provider. Empty strings in update = no change.
    pub fn updateSavedProvider(self: *State, id: u32, update: SavedProviderUpdate) !bool {
        for (self.saved_providers.items) |*sp| {
            if (sp.id == id) {
                if (update.name.len > 0) {
                    const new_name = try self.allocator.dupe(u8, update.name);
                    self.allocator.free(sp.name);
                    sp.name = new_name;
                }
                if (update.api_key.len > 0) {
                    const new_key = try self.allocator.dupe(u8, update.api_key);
                    self.allocator.free(sp.api_key);
                    sp.api_key = new_key;
                }
                if (update.model.len > 0) {
                    const new_model = try self.allocator.dupe(u8, update.model);
                    if (sp.model.len > 0) self.allocator.free(sp.model);
                    sp.model = new_model;
                }
                if (update.validated_at.len > 0) {
                    const new_ts = try self.allocator.dupe(u8, update.validated_at);
                    if (sp.validated_at.len > 0) self.allocator.free(sp.validated_at);
                    sp.validated_at = new_ts;
                }
                if (update.validated_with.len > 0) {
                    const new_vw = try self.allocator.dupe(u8, update.validated_with);
                    if (sp.validated_with.len > 0) self.allocator.free(sp.validated_with);
                    sp.validated_with = new_vw;
                }
                return true;
            }
        }
        return false;
    }

    /// Remove a saved provider by ID. Returns true if found and removed.
    pub fn removeSavedProvider(self: *State, id: u32) bool {
        for (self.saved_providers.items, 0..) |sp, i| {
            if (sp.id == id) {
                self.allocator.free(sp.name);
                self.allocator.free(sp.provider);
                self.allocator.free(sp.api_key);
                if (sp.model.len > 0) self.allocator.free(sp.model);
                if (sp.validated_at.len > 0) self.allocator.free(sp.validated_at);
                if (sp.validated_with.len > 0) self.allocator.free(sp.validated_with);
                _ = self.saved_providers.orderedRemove(i);
                return true;
            }
        }
        return false;
    }

    /// Check if a saved provider with matching provider+api_key+model already exists.
    pub fn hasSavedProvider(self: *State, provider: []const u8, api_key: []const u8, model: []const u8) bool {
        for (self.saved_providers.items) |sp| {
            if (std.mem.eql(u8, sp.provider, provider) and
                std.mem.eql(u8, sp.api_key, api_key) and
                std.mem.eql(u8, sp.model, model))
            {
                return true;
            }
        }
        return false;
    }

    fn nextProviderId(self: *State) u32 {
        var max_id: u32 = 0;
        for (self.saved_providers.items) |sp| {
            if (sp.id > max_id) max_id = sp.id;
        }
        return max_id + 1;
    }

    fn generateProviderName(self: *State, provider: []const u8) ![]const u8 {
        const label = providerLabel(provider);
        var count: u32 = 0;
        for (self.saved_providers.items) |sp| {
            if (std.mem.eql(u8, sp.provider, provider)) count += 1;
        }
        return std.fmt.allocPrint(self.allocator, "{s} #{d}", .{ label, count + 1 });
    }
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | tail -5`
Expected: All tests pass, including the new saved provider tests.

- [ ] **Step 7: Commit**

```bash
git add src/core/state.zig
git commit -m "feat: add SavedProvider to State with CRUD methods and tests"
```

---

## Chunk 2: Backend — Providers API

### Task 2: Create providers API handler

**Files:**
- Create: `src/api/providers.zig`

- [ ] **Step 1: Write tests for providers API path parsing and response building**

Create `src/api/providers.zig` with tests first:

```zig
const std = @import("std");
const state_mod = @import("../core/state.zig");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");
const registry = @import("../installer/registry.zig");
const component_cli = @import("../core/component_cli.zig");
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
    return std.mem.indexOf(u8, target, "reveal=true") != null;
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
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return "{\"error\":\"invalid JSON body\"}";
    defer parsed.deinit();

    // Find an installed component binary
    const component_name = findAnyInstalledComponent(allocator, state, paths) orelse
        return "{\"error\":\"Install a component first to validate providers\"}";

    const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
        return "{\"error\":\"component binary not found\"}";
    defer allocator.free(bin_path);

    // Validate via probe
    const probe_result = probeProvider(allocator, component_name, bin_path, parsed.value.provider, parsed.value.api_key, parsed.value.model, "");
    if (!probe_result.live_ok) {
        var buf = std.array_list.Managed(u8).init(allocator);
        errdefer buf.deinit();
        try buf.appendSlice("{\"error\":\"validation_failed\",\"reason\":\"");
        try appendEscaped(&buf, probe_result.reason);
        try buf.appendSlice("\"}");
        return buf.toOwnedSlice();
    }

    // Save to state
    try state.addSavedProvider(.{
        .provider = parsed.value.provider,
        .api_key = parsed.value.api_key,
        .model = parsed.value.model,
        .validated_with = component_name,
    });

    // Update validated_at on the just-added provider
    const providers = state.savedProviders();
    const new_id = providers[providers.len - 1].id;
    const now = nowIso8601(allocator) catch "";
    if (now.len > 0) {
        _ = state.updateSavedProvider(new_id, .{ .validated_at = now }) catch {};
        allocator.free(now);
    }

    try state.save();

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
    const existing = state.getSavedProvider(id) orelse return "{\"error\":\"provider not found\"}";

    const parsed = std.json.parseFromSlice(struct {
        name: []const u8 = "",
        api_key: []const u8 = "",
        model: []const u8 = "",
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return "{\"error\":\"invalid JSON body\"}";
    defer parsed.deinit();

    const credentials_changed = (parsed.value.api_key.len > 0 and !std.mem.eql(u8, parsed.value.api_key, existing.api_key)) or
        (parsed.value.model.len > 0 and !std.mem.eql(u8, parsed.value.model, existing.model));

    if (credentials_changed) {
        // Re-validate
        const component_name = findAnyInstalledComponent(allocator, state, paths) orelse
            return "{\"error\":\"Install a component first to validate providers\"}";

        const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
            return "{\"error\":\"component binary not found\"}";
        defer allocator.free(bin_path);

        const effective_key = if (parsed.value.api_key.len > 0) parsed.value.api_key else existing.api_key;
        const effective_model = if (parsed.value.model.len > 0) parsed.value.model else existing.model;

        const probe_result = probeProvider(allocator, component_name, bin_path, existing.provider, effective_key, effective_model, "");
        if (!probe_result.live_ok) {
            var buf = std.array_list.Managed(u8).init(allocator);
            errdefer buf.deinit();
            try buf.appendSlice("{\"error\":\"validation_failed\",\"reason\":\"");
            try appendEscaped(&buf, probe_result.reason);
            try buf.appendSlice("\"}");
            return buf.toOwnedSlice();
        }

        const now = nowIso8601(allocator) catch "";
        defer if (now.len > 0) allocator.free(now);

        _ = try state.updateSavedProvider(id, .{
            .name = parsed.value.name,
            .api_key = parsed.value.api_key,
            .model = parsed.value.model,
            .validated_at = now,
            .validated_with = component_name,
        });
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
        return "{\"error\":\"provider not found\"}";
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
    const existing = state.getSavedProvider(id) orelse return "{\"error\":\"provider not found\"}";

    const component_name = findAnyInstalledComponent(allocator, state, paths) orelse
        return "{\"error\":\"Install a component first to validate providers\"}";

    const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
        return "{\"error\":\"component binary not found\"}";
    defer allocator.free(bin_path);

    const probe_result = probeProvider(allocator, component_name, bin_path, existing.provider, existing.api_key, existing.model, "");

    if (probe_result.live_ok) {
        const now = try nowIso8601(allocator);
        defer allocator.free(now);
        _ = try state.updateSavedProvider(id, .{ .validated_at = now, .validated_with = component_name });
        try state.save();
    }

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

fn findAnyInstalledComponent(allocator: std.mem.Allocator, state: *state_mod.State, paths: paths_mod.Paths) ?[]const u8 {
    _ = paths;
    const keys = state.componentNames() catch return null;
    defer allocator.free(keys);
    if (keys.len == 0) return null;

    // Sort alphabetically and return first
    std.mem.sort([]const u8, keys, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lessThan);

    return keys[0];
}

fn probeProvider(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    provider: []const u8,
    api_key: []const u8,
    model: []const u8,
    base_url: []const u8,
) struct { live_ok: bool, reason: []const u8 } {
    // Create temp dir for minimal config
    const timestamp = @abs(std.time.milliTimestamp());
    const tmp_dir = std.fmt.allocPrint(allocator, "/tmp/nullhub-provider-validate-{d}", .{timestamp}) catch
        return .{ .live_ok = false, .reason = "tmp_dir_failed" };
    defer {
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        allocator.free(tmp_dir);
    }
    std.fs.makeDirAbsolute(tmp_dir) catch return .{ .live_ok = false, .reason = "tmp_dir_failed" };

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
    try buf.appendSlice("\",\"validated_at\":\"");
    try appendEscaped(buf, sp.validated_at);
    try buf.appendSlice("\",\"validated_with\":\"");
    try appendEscaped(buf, sp.validated_with);
    try buf.appendSlice("\"}");
}

fn nowIso8601(allocator: std.mem.Allocator) ![]const u8 {
    const timestamp = std.time.timestamp();
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

test "handleDelete removes provider" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-provider-test-delete";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    std.fs.makeDirAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

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
```

- [ ] **Step 2: Run tests to verify they compile and pass**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | tail -5`
Expected: Compilation error because `wizard_api.findOrFetchComponentBinaryPub`, `writeMinimalProviderConfigPub`, and `probeProviderViaComponentBinaryPub` don't exist yet. That's fine — the path parsing and helper tests should work once we add the missing public wrappers.

- [ ] **Step 3: Expose helper functions from wizard.zig**

Add public wrappers at the bottom of `src/api/wizard.zig` (before the tests section), exposing the private helpers needed by providers.zig:

```zig
// ─── Public wrappers for providers API ───────────────────────────────────────

pub fn findOrFetchComponentBinaryPub(allocator: std.mem.Allocator, component: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    return findOrFetchComponentBinary(allocator, component, paths);
}

pub fn writeMinimalProviderConfigPub(allocator: std.mem.Allocator, dir: []const u8, provider: []const u8, api_key: []const u8, base_url: []const u8) !void {
    return writeMinimalProviderConfig(allocator, dir, provider, api_key, base_url);
}

pub fn probeProviderViaComponentBinaryPub(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    instance_home: []const u8,
    provider: []const u8,
    model: []const u8,
) struct { live_ok: bool, reason: []const u8 } {
    return probeProviderViaComponentBinary(allocator, component_name, binary_path, instance_home, provider, model);
}
```

- [ ] **Step 4: Register providers_api in root.zig**

Add to `src/root.zig` (after `pub const wizard_api = ...` on line 31):

```zig
pub const providers_api = @import("api/providers.zig");
```

Add inside the test block (after `_ = wizard_api;` on line 64):

```zig
    _ = providers_api;
```

- [ ] **Step 5: Run all tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 6: Commit**

```bash
git add src/api/providers.zig src/api/wizard.zig src/root.zig
git commit -m "feat: add providers API handler with path parsing, CRUD, and validation"
```

### Task 3: Register provider routes in server.zig

**Files:**
- Modify: `src/server.zig:1-19` (imports) and `src/server.zig:333-744` (route function)

- [ ] **Step 1: Add import**

Add after line 16 (`const wizard_api = ...`):

```zig
const providers_api = @import("api/providers.zig");
```

- [ ] **Step 2: Add provider routes**

Add before the `// Config API` comment (line 649) in the `route` function:

```zig
        // Providers API — /api/providers[/{id}[/validate]]
        if (providers_api.isProvidersPath(target)) {
            if (std.mem.eql(u8, target, "/api/providers") or std.mem.startsWith(u8, target, "/api/providers?")) {
                if (std.mem.eql(u8, method, "GET")) {
                    const reveal = providers_api.hasRevealParam(target);
                    if (providers_api.handleList(allocator, self.state, reveal)) |json| {
                        return jsonResponse(json);
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "POST")) {
                    if (providers_api.handleCreate(allocator, body, self.state, self.paths)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "422 Unprocessable Entity" else "201 Created";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
            }
            // Routes with ID: /api/providers/{id} and /api/providers/{id}/validate
            if (providers_api.extractProviderId(target)) |id| {
                if (providers_api.isValidatePath(target)) {
                    if (std.mem.eql(u8, method, "POST")) {
                        if (providers_api.handleValidate(allocator, id, self.state, self.paths)) |json| {
                            return jsonResponse(json);
                        } else |_| {
                            return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                        }
                    }
                    return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
                }
                if (std.mem.eql(u8, method, "PUT")) {
                    if (providers_api.handleUpdate(allocator, id, body, self.state, self.paths)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "422 Unprocessable Entity" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "DELETE")) {
                    if (providers_api.handleDelete(allocator, id, self.state)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "404 Not Found" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
            }
        }
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/server.zig src/api/providers.zig
git commit -m "feat: register provider API routes in server"
```

### Task 4: Add auto-save to wizard validation

**Files:**
- Modify: `src/api/wizard.zig:509-561` (handleValidateProviders)

- [ ] **Step 1: Update handleValidateProviders signature to accept state**

Change the function signature at line 509:

```zig
pub fn handleValidateProviders(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
    state: *state_mod.State,
) ?[]const u8 {
```

After the validation loop (after line 559 `buf.appendSlice("]}") catch return null;`), add auto-save logic:

```zig
    // Auto-save validated providers
    for (parsed.value.providers) |prov| {
        // Check if validation passed for this provider
        const was_ok = blk: {
            // We just built the JSON — check if this provider had live_ok=true
            // Re-probe to get result (cheap since we already validated)
            const result = probeProviderViaComponentBinary(allocator, component_name, bin_path, tmp_dir, prov.provider, prov.model);
            break :blk result.live_ok;
        };
        if (was_ok and !state.hasSavedProvider(prov.provider, prov.api_key, prov.model)) {
            state.addSavedProvider(.{
                .provider = prov.provider,
                .api_key = prov.api_key,
                .model = prov.model,
                .validated_with = component_name,
            }) catch {};
        }
    }
    state.save() catch {};
```

**Wait — re-probing is wasteful. Better approach:** collect results during the validation loop. Refactor:

Replace the validation loop (lines 547-559) with:

```zig
    // Track validation results for auto-save
    const ProbeResult = struct { live_ok: bool };
    var probe_results = std.ArrayList(ProbeResult).init(allocator);
    defer probe_results.deinit();

    for (parsed.value.providers, 0..) |prov, idx| {
        if (idx > 0) buf.append(',') catch return null;

        writeMinimalProviderConfig(allocator, tmp_dir, prov.provider, prov.api_key, prov.base_url) catch {
            appendProviderResult(&buf, prov.provider, false, "config_write_failed") catch return null;
            probe_results.append(.{ .live_ok = false }) catch return null;
            continue;
        };

        const result = probeProviderViaComponentBinary(allocator, component_name, bin_path, tmp_dir, prov.provider, prov.model);
        appendProviderResult(&buf, prov.provider, result.live_ok, result.reason) catch return null;
        probe_results.append(.{ .live_ok = result.live_ok }) catch return null;
    }

    buf.appendSlice("]}") catch return null;

    // Auto-save validated providers
    for (parsed.value.providers, 0..) |prov, idx| {
        if (idx < probe_results.items.len and probe_results.items[idx].live_ok) {
            if (!state.hasSavedProvider(prov.provider, prov.api_key, prov.model)) {
                state.addSavedProvider(.{
                    .provider = prov.provider,
                    .api_key = prov.api_key,
                    .model = prov.model,
                    .validated_with = component_name,
                }) catch {};
            }
        }
    }
    state.save() catch {};

    return buf.toOwnedSlice() catch null;
```

Note: this `return` replaces the existing `return buf.toOwnedSlice() catch null;` at line 560 — the original return is now inside this refactored block.

- [ ] **Step 2: Update the route call in server.zig to pass state**

In `src/server.zig`, the call to `handleValidateProviders` (around line 524) needs the extra `self.state` argument:

```zig
                if (wizard_api.handleValidateProviders(allocator, comp_name, body, self.paths, self.state)) |json| {
```

- [ ] **Step 3: Run tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 4: Commit**

```bash
git add src/api/wizard.zig src/server.zig
git commit -m "feat: auto-save validated providers from wizard flow"
```

---

## Chunk 3: Frontend — API Client and Providers Page

### Task 5: Add provider API methods to client.ts

**Files:**
- Modify: `ui/src/lib/api/client.ts`

- [ ] **Step 1: Add provider CRUD methods**

Add before the closing `};` of the `api` object (before line 96):

```typescript
  // Saved providers
  getSavedProviders: (reveal = false) =>
    request<any>(`/providers${reveal ? '?reveal=true' : ''}`),
  createSavedProvider: (data: { provider: string; api_key: string; model?: string }) =>
    request<any>('/providers', { method: 'POST', body: JSON.stringify(data) }),
  updateSavedProvider: (id: number, data: { name?: string; api_key?: string; model?: string }) =>
    request<any>(`/providers/${id}`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteSavedProvider: (id: number) =>
    request<any>(`/providers/${id}`, { method: 'DELETE' }),
  revalidateSavedProvider: (id: number) =>
    request<any>(`/providers/${id}/validate`, { method: 'POST' }),
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/lib/api/client.ts
git commit -m "feat: add saved provider API methods to frontend client"
```

### Task 6: Create Providers page

**Files:**
- Create: `ui/src/routes/providers/+page.svelte`

- [ ] **Step 1: Create the providers route directory**

Run: `mkdir -p ui/src/routes/providers`

- [ ] **Step 2: Create the Providers page component**

Create `ui/src/routes/providers/+page.svelte`:

```svelte
<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "$lib/api/client";

  const PROVIDER_OPTIONS = [
    { value: "openrouter", label: "OpenRouter (multi-provider, recommended)", recommended: true },
    { value: "anthropic", label: "Anthropic" },
    { value: "openai", label: "OpenAI" },
    { value: "google", label: "Google AI" },
    { value: "mistral", label: "Mistral" },
    { value: "groq", label: "Groq" },
    { value: "deepseek", label: "DeepSeek" },
    { value: "cohere", label: "Cohere" },
    { value: "together", label: "Together AI" },
    { value: "fireworks", label: "Fireworks AI" },
    { value: "perplexity", label: "Perplexity" },
    { value: "xai", label: "xAI" },
    { value: "ollama", label: "Ollama (local)" },
    { value: "lm-studio", label: "LM Studio (local)" },
    { value: "claude-cli", label: "Claude CLI (local)" },
    { value: "codex-cli", label: "Codex CLI (local)" },
  ];
  const LOCAL_PROVIDERS = ["ollama", "lm-studio", "claude-cli", "codex-cli"];

  let providers = $state<any[]>([]);
  let loading = $state(true);
  let error = $state("");
  let message = $state("");

  // Add form state
  let showAddForm = $state(false);
  let addForm = $state({ provider: "openrouter", api_key: "", model: "" });
  let addValidating = $state(false);
  let addError = $state("");

  // Edit state
  let editingId = $state<number | null>(null);
  let editForm = $state({ name: "", api_key: "", model: "" });
  let editValidating = $state(false);
  let editError = $state("");

  // Re-validate state
  let revalidatingId = $state<number | null>(null);

  let hasComponents = $state(false);

  onMount(async () => {
    await loadProviders();
    try {
      const status = await api.getStatus();
      hasComponents = Object.keys(status.instances || {}).length > 0;
    } catch {}
  });

  async function loadProviders() {
    loading = true;
    error = "";
    try {
      const data = await api.getSavedProviders();
      providers = data.providers || [];
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  async function handleAdd() {
    addValidating = true;
    addError = "";
    try {
      await api.createSavedProvider({
        provider: addForm.provider,
        api_key: addForm.api_key,
        model: addForm.model || undefined,
      });
      showAddForm = false;
      addForm = { provider: "openrouter", api_key: "", model: "" };
      message = "Provider saved";
      setTimeout(() => (message = ""), 3000);
      await loadProviders();
    } catch (e) {
      addError = (e as Error).message;
    } finally {
      addValidating = false;
    }
  }

  function startEdit(p: any) {
    editingId = p.id;
    editForm = { name: p.name, api_key: "", model: p.model };
  }

  function cancelEdit() {
    editingId = null;
  }

  async function saveEdit(id: number) {
    editValidating = true;
    editError = "";
    try {
      const payload: any = {};
      if (editForm.name) payload.name = editForm.name;
      if (editForm.api_key) payload.api_key = editForm.api_key;
      if (editForm.model) payload.model = editForm.model;
      await api.updateSavedProvider(id, payload);
      editingId = null;
      message = "Provider updated";
      setTimeout(() => (message = ""), 3000);
      await loadProviders();
    } catch (e) {
      editError = (e as Error).message;
    } finally {
      editValidating = false;
    }
  }

  async function handleDelete(id: number) {
    try {
      await api.deleteSavedProvider(id);
      message = "Provider deleted";
      setTimeout(() => (message = ""), 3000);
      await loadProviders();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  async function handleRevalidate(id: number) {
    revalidatingId = id;
    try {
      await api.revalidateSavedProvider(id);
      message = "Validation passed";
      setTimeout(() => (message = ""), 5000);
      await loadProviders();
    } catch (e) {
      message = `Validation failed: ${(e as Error).message}`;
      setTimeout(() => (message = ""), 5000);
    } finally {
      revalidatingId = null;
    }
  }

  function isLocal(provider: string) {
    return LOCAL_PROVIDERS.includes(provider);
  }

  function getProviderLabel(value: string) {
    return PROVIDER_OPTIONS.find((p) => p.value === value)?.label || value;
  }

  function formatDate(iso: string) {
    if (!iso) return "";
    try {
      return new Date(iso).toLocaleDateString(undefined, {
        year: "numeric", month: "short", day: "numeric",
        hour: "2-digit", minute: "2-digit",
      });
    } catch { return iso; }
  }
</script>

<div class="providers-page">
  <div class="page-header">
    <h1>Providers</h1>
    {#if hasComponents}
      <button class="primary-btn" onclick={() => (showAddForm = !showAddForm)}>
        {showAddForm ? "Cancel" : "+ Add Provider"}
      </button>
    {/if}
  </div>

  {#if message}
    <div class="message">{message}</div>
  {/if}

  {#if error}
    <div class="error-message">{error}</div>
  {/if}

  {#if !hasComponents}
    <div class="empty-state">
      <p>Install a component first to add providers.</p>
      <a href="/install" class="link-btn">Install Component</a>
    </div>
  {:else if showAddForm}
    <div class="add-form">
      <h2>Add Provider</h2>
      <div class="field">
        <label for="add-provider">Provider</label>
        <select id="add-provider" bind:value={addForm.provider}>
          {#each PROVIDER_OPTIONS as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>
      {#if !isLocal(addForm.provider)}
        <div class="field">
          <label for="add-api-key">API Key</label>
          <input id="add-api-key" type="password" bind:value={addForm.api_key} placeholder="Enter API key..." />
        </div>
      {/if}
      <div class="field">
        <label for="add-model">Model (optional)</label>
        <input id="add-model" type="text" bind:value={addForm.model} placeholder="e.g. anthropic/claude-sonnet-4" />
      </div>
      {#if addError}
        <div class="error-message">{addError}</div>
      {/if}
      <button class="primary-btn" onclick={handleAdd} disabled={addValidating}>
        {addValidating ? "Validating..." : "Validate & Save"}
      </button>
    </div>
  {/if}

  {#if loading}
    <p class="loading">Loading providers...</p>
  {:else if providers.length === 0 && hasComponents}
    <div class="empty-state">
      <p>No saved providers yet. Add one above or install a component — providers are saved automatically during setup.</p>
    </div>
  {:else}
    <div class="provider-grid">
      {#each providers as p}
        <div class="provider-card">
          {#if editingId === p.id}
            <div class="edit-form">
              <div class="field">
                <label for="edit-name-{p.id}">Name</label>
                <input id="edit-name-{p.id}" type="text" bind:value={editForm.name} />
              </div>
              {#if !isLocal(p.provider)}
                <div class="field">
                  <label for="edit-key-{p.id}">API Key (leave empty to keep current)</label>
                  <input id="edit-key-{p.id}" type="password" bind:value={editForm.api_key} placeholder="Leave empty to keep current" />
                </div>
              {/if}
              <div class="field">
                <label for="edit-model-{p.id}">Model</label>
                <input id="edit-model-{p.id}" type="text" bind:value={editForm.model} placeholder="e.g. anthropic/claude-sonnet-4" />
              </div>
              {#if editError}
                <div class="error-message">{editError}</div>
              {/if}
              <div class="edit-actions">
                <button class="primary-btn" onclick={() => saveEdit(p.id)} disabled={editValidating}>
                  {editValidating ? "Saving..." : "Save"}
                </button>
                <button class="btn" onclick={cancelEdit}>Cancel</button>
              </div>
            </div>
          {:else}
            <div class="card-header">
              <div class="card-title">
                <span class="status-dot" class:validated={!!p.validated_at} class:not-validated={!p.validated_at}></span>
                <h3>{p.name}</h3>
              </div>
              <span class="provider-type">{getProviderLabel(p.provider)}</span>
            </div>
            <div class="card-body">
              <div class="card-field">
                <span class="label">API Key</span>
                <code>{p.api_key}</code>
              </div>
              <div class="card-field">
                <span class="label">Model</span>
                <code>{p.model || "No default model"}</code>
              </div>
              {#if p.validated_at}
                <div class="card-field">
                  <span class="label">Validated</span>
                  <span>{formatDate(p.validated_at)}</span>
                </div>
              {/if}
            </div>
            <div class="card-actions">
              <button class="btn" onclick={() => handleRevalidate(p.id)} disabled={revalidatingId === p.id}>
                {revalidatingId === p.id ? "Validating..." : "Re-validate"}
              </button>
              <button class="btn" onclick={() => startEdit(p)}>Edit</button>
              <button class="btn danger" onclick={() => handleDelete(p.id)}>Delete</button>
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  .providers-page {
    max-width: 800px;
    margin: 0 auto;
    padding: 2rem;
  }

  .page-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 2rem;
  }

  h1 {
    font-size: 1.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 2px;
    color: var(--accent);
    text-shadow: var(--text-glow);
  }

  h2 {
    font-size: 1.125rem;
    font-weight: 700;
    margin-bottom: 1rem;
    color: var(--accent-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .add-form, .provider-card {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 1.25rem;
    margin-bottom: 1rem;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
  }

  .add-form {
    margin-bottom: 2rem;
  }

  .field {
    margin-bottom: 1rem;
  }

  .field label {
    display: block;
    font-size: 0.75rem;
    color: var(--fg-dim);
    margin-bottom: 0.35rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .field input, .field select {
    width: 100%;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 0.5rem 0.75rem;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
  }

  .field input:focus, .field select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .card-header {
    display: flex;
    justify-content: space-between;
    align-items: center;
    margin-bottom: 1rem;
  }

  .card-title {
    display: flex;
    align-items: center;
    gap: 0.5rem;
  }

  .card-title h3 {
    font-size: 1rem;
    font-weight: 700;
    color: var(--fg);
  }

  .provider-type {
    font-size: 0.75rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .status-dot {
    width: 8px;
    height: 8px;
    border-radius: 50%;
    flex-shrink: 0;
  }

  .status-dot.validated {
    background: var(--success, #4a4);
    box-shadow: 0 0 6px var(--success, #4a4);
  }

  .status-dot.not-validated {
    background: var(--warning, #ca0);
    box-shadow: 0 0 6px var(--warning, #ca0);
  }

  .card-body {
    margin-bottom: 1rem;
  }

  .card-field {
    display: flex;
    justify-content: space-between;
    align-items: center;
    padding: 0.375rem 0;
    border-bottom: 1px dashed color-mix(in srgb, var(--border) 40%, transparent);
  }

  .card-field:last-child {
    border-bottom: none;
  }

  .card-field .label {
    font-size: 0.75rem;
    color: var(--fg-dim);
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .card-field code {
    font-family: var(--font-mono);
    font-size: 0.8125rem;
    color: var(--fg);
  }

  .card-actions, .edit-actions {
    display: flex;
    gap: 0.5rem;
  }

  .btn {
    padding: 0.375rem 0.875rem;
    background: var(--bg-surface);
    color: var(--accent);
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }

  .btn:hover:not(:disabled) {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow: 0 0 10px var(--border-glow);
  }

  .btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .btn.danger {
    color: var(--error, #e55);
    border-color: color-mix(in srgb, var(--error, #e55) 50%, transparent);
  }

  .btn.danger:hover:not(:disabled) {
    border-color: var(--error, #e55);
    box-shadow: 0 0 10px color-mix(in srgb, var(--error, #e55) 30%, transparent);
  }

  .primary-btn {
    padding: 0.5rem 1.25rem;
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
    text-shadow: var(--text-glow);
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    box-shadow: 0 0 15px var(--border-glow);
  }

  .primary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }

  .message {
    padding: 0.875rem 1.25rem;
    background: color-mix(in srgb, var(--success) 10%, transparent);
    border: 1px solid var(--success);
    border-radius: 2px;
    font-size: 0.875rem;
    font-weight: bold;
    color: var(--success);
    margin-bottom: 1.5rem;
    box-shadow: 0 0 10px color-mix(in srgb, var(--success) 30%, transparent);
  }

  .error-message {
    padding: 0.875rem 1.25rem;
    background: color-mix(in srgb, var(--error, #e55) 10%, transparent);
    border: 1px solid var(--error, #e55);
    border-radius: 2px;
    font-size: 0.875rem;
    color: var(--error, #e55);
    margin-bottom: 1rem;
  }

  .empty-state {
    text-align: center;
    padding: 3rem;
    color: var(--fg-dim);
  }

  .empty-state p {
    margin-bottom: 1rem;
    font-family: var(--font-mono);
  }

  .link-btn {
    color: var(--accent);
    text-decoration: none;
    border: 1px solid var(--accent);
    padding: 0.5rem 1.25rem;
    border-radius: 2px;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-size: 0.875rem;
    transition: all 0.2s ease;
  }

  .link-btn:hover {
    background: color-mix(in srgb, var(--accent) 15%, transparent);
    box-shadow: 0 0 10px var(--border-glow);
  }

  .loading {
    color: var(--fg-dim);
    font-family: var(--font-mono);
    text-align: center;
    padding: 2rem;
  }

  .provider-grid {
    display: flex;
    flex-direction: column;
    gap: 0.75rem;
  }

  .edit-form {
    padding: 0.5rem 0;
  }
</style>
```

- [ ] **Step 3: Commit**

```bash
git add ui/src/routes/providers/+page.svelte
git commit -m "feat: add Providers management page"
```

### Task 7: Add Providers link to Sidebar

**Files:**
- Modify: `ui/src/lib/components/Sidebar.svelte` (insert after line 52, before `nav-bottom`)

- [ ] **Step 1: Add Providers nav section**

After the Instances nav-section closing `</div>` (line 52), add a new nav-section before `<div class="nav-bottom">`:

```svelte
  <div class="nav-section">
    <a href="/providers" class:active={currentPath === "/providers"}>Providers</a>
  </div>
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/lib/components/Sidebar.svelte
git commit -m "feat: add Providers link to sidebar navigation"
```

---

## Chunk 4: Frontend — Wizard Integration

### Task 8: Add "Use Saved" to ProviderList

**Files:**
- Modify: `ui/src/lib/components/ProviderList.svelte`

- [ ] **Step 1: Add saved providers state and fetch**

In the `<script>` block, first add `import { onMount } from "svelte";` at the top (after line 1, alongside the existing `import { api }`). Then add after the `LOCAL_PROVIDERS` const (line 12):

```typescript
  let savedProviders = $state<any[]>([]);
  let showSavedDropdown = $state(false);

  onMount(async () => {
    try {
      const data = await api.getSavedProviders(true);
      savedProviders = data.providers || [];
    } catch {}
  });

  function useSaved(sp: any) {
    entries = [
      ...entries,
      { provider: sp.provider, api_key: sp.api_key, model: sp.model || "" },
    ];
    showSavedDropdown = false;
    emitChange();
  }
```

- [ ] **Step 2: Add "Use Saved" button next to "Add Provider"**

Replace the add button (line 164):

```svelte
  <div class="add-row">
    <button class="add-btn" onclick={addEntry}>+ Add Provider</button>
    {#if savedProviders.length > 0}
      <div class="saved-dropdown-container">
        <button class="add-btn saved-btn" onclick={() => (showSavedDropdown = !showSavedDropdown)}>
          Use Saved
        </button>
        {#if showSavedDropdown}
          <div class="saved-dropdown">
            {#each savedProviders as sp}
              <button class="saved-item" onclick={() => useSaved(sp)}>
                <span class="saved-name">{sp.name}</span>
                <span class="saved-detail">{sp.model || "no model"}</span>
              </button>
            {/each}
          </div>
        {/if}
      </div>
    {/if}
  </div>
```

- [ ] **Step 3: Add styles for the saved dropdown**

Add to the `<style>` block (before closing `</style>`):

```css
  .add-row {
    display: flex;
    gap: 0.5rem;
  }

  .add-row .add-btn {
    flex: 1;
  }

  .saved-dropdown-container {
    position: relative;
    flex: 0 0 auto;
  }

  .saved-btn {
    border-style: solid !important;
    border-color: var(--accent-dim) !important;
    color: var(--accent) !important;
    width: auto !important;
    padding: 0.75rem 1.25rem !important;
  }

  .saved-dropdown {
    position: absolute;
    bottom: 100%;
    right: 0;
    min-width: 220px;
    background: var(--bg-surface);
    border: 1px solid var(--accent-dim);
    border-radius: 2px;
    margin-bottom: 0.25rem;
    box-shadow: 0 0 15px rgba(0, 0, 0, 0.4);
    z-index: 10;
    max-height: 200px;
    overflow-y: auto;
  }

  .saved-item {
    display: flex;
    flex-direction: column;
    width: 100%;
    padding: 0.625rem 1rem;
    background: none;
    border: none;
    border-bottom: 1px solid var(--border);
    color: var(--fg);
    cursor: pointer;
    text-align: left;
    font-family: var(--font-mono);
    transition: all 0.15s ease;
  }

  .saved-item:last-child {
    border-bottom: none;
  }

  .saved-item:hover {
    background: var(--bg-hover);
    color: var(--accent);
  }

  .saved-name {
    font-size: 0.875rem;
    font-weight: 700;
  }

  .saved-detail {
    font-size: 0.75rem;
    color: var(--fg-dim);
    margin-top: 0.125rem;
  }
```

- [ ] **Step 4: Commit**

```bash
git add ui/src/lib/components/ProviderList.svelte
git commit -m "feat: add 'Use Saved' dropdown to ProviderList in wizard"
```

### Task 9: Build and verify frontend

**Files:** None (verification only)

- [ ] **Step 1: Build frontend**

Run: `cd /Users/igorsomov/Code/null/nullhub/ui && npm run build 2>&1 | tail -10`
Expected: Build succeeds with no errors.

- [ ] **Step 2: Run backend tests one final time**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | tail -5`
Expected: All tests pass.

- [ ] **Step 3: Manual smoke test for auto-save**

If a component is installed, test the end-to-end auto-save flow:
1. Start the server: `zig build run`
2. Navigate to Install, configure a provider with valid credentials
3. Click Next (triggers validate-providers)
4. Navigate to `/providers` — the validated credential should appear as a saved provider

- [ ] **Step 4: Final commit if any build fixes needed**

Only if fixes were required during build verification.
