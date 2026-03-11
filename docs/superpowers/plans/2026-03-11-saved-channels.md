# Saved Channels Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add CRUD management for saved channel configurations (Telegram, Discord, etc.) with validation, a dedicated `/channels` page, and wizard integration — mirroring the existing saved providers feature.

**Architecture:** Backend follows the exact same pattern as saved providers: `SavedChannel` struct in `state.zig`, CRUD operations, `channels.zig` API module, server routing. Frontend adds a `/channels` route page, API client methods, sidebar nav item, and "Use Saved" dropdown in `ChannelList.svelte`.

**Tech Stack:** Zig (backend), Svelte 5 with runes (frontend), `std.json` for serialization.

**Spec:** `docs/superpowers/specs/2026-03-11-saved-channels-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `src/core/state.zig` | Modify | Add `SavedChannel` struct, ArrayList storage, CRUD operations, persistence |
| `src/api/channels.zig` | Create | API handlers: list, create, update, delete, validate |
| `src/server.zig` | Modify | Import `channels_api`, add routing block for `/api/channels*` |
| `src/root.zig` | Modify | Import + test `channels_api` |
| `src/api/wizard.zig` | Modify | Add auto-save logic to `handleValidateChannels` |
| `ui/src/lib/api/client.ts` | Modify | Add saved channel API methods |
| `ui/src/lib/components/Sidebar.svelte` | Modify | Add Channels nav item |
| `ui/src/routes/channels/+page.svelte` | Create | Channels management page |
| `ui/src/lib/components/ChannelList.svelte` | Modify | Add "Use Saved" dropdown |

---

## Chunk 1: Backend State (state.zig)

### Task 1: Add SavedChannel types to state.zig

**Files:**
- Modify: `src/core/state.zig:19` (after SavedProvider types, before `providerLabel`)

- [ ] **Step 1: Add SavedChannel, SavedChannelInput, SavedChannelUpdate structs**

Add after line 34 (after `SavedProviderUpdate`), before `providerLabel`:

```zig
pub const SavedChannel = struct {
    id: u32,
    name: []const u8,
    channel_type: []const u8,
    account: []const u8,
    config: []const u8 = "", // serialized JSON string
    validated_at: []const u8 = "",
    validated_with: []const u8 = "",
};

pub const SavedChannelInput = struct {
    channel_type: []const u8,
    account: []const u8,
    config: []const u8 = "",
    validated_with: []const u8 = "",
};

pub const SavedChannelUpdate = struct {
    name: ?[]const u8 = null,
    account: ?[]const u8 = null,
    config: ?[]const u8 = null,
    validated_at: ?[]const u8 = null,
    validated_with: ?[]const u8 = null,
};
```

- [ ] **Step 2: Add channelLabel helper function**

Add after `providerLabel` (after line 59):

```zig
fn channelLabel(channel_type: []const u8) []const u8 {
    const map = .{
        .{ "telegram", "Telegram" },
        .{ "discord", "Discord" },
        .{ "slack", "Slack" },
        .{ "whatsapp", "WhatsApp" },
        .{ "matrix", "Matrix" },
        .{ "mattermost", "Mattermost" },
        .{ "irc", "IRC" },
        .{ "imessage", "iMessage" },
        .{ "email", "Email" },
        .{ "lark", "Lark/Feishu" },
        .{ "dingtalk", "DingTalk" },
        .{ "signal", "Signal" },
        .{ "line", "LINE" },
        .{ "qq", "QQ" },
        .{ "onebot", "OneBot" },
        .{ "maixcam", "MaixCam" },
        .{ "nostr", "Nostr" },
        .{ "webhook", "Webhook" },
    };
    inline for (map) |pair| {
        if (std.mem.eql(u8, channel_type, pair[0])) return pair[1];
    }
    return channel_type;
}
```

- [ ] **Step 3: Update JsonState to include saved_channels**

Modify `JsonState` (line 64-67):

```zig
const JsonState = struct {
    instances: std.json.ArrayHashMap(std.json.ArrayHashMap(InstanceEntry)),
    saved_providers: []const SavedProvider = &.{},
    saved_channels: []const SavedChannel = &.{},
};
```

- [ ] **Step 4: Add saved_channels ArrayList to State struct**

Add after `saved_providers` field (line 81):

```zig
saved_channels: std.array_list.Managed(SavedChannel),
```

- [ ] **Step 5: Update State.init to initialize saved_channels**

In `State.init` (line 85-92), add initialization:

```zig
.saved_channels = std.array_list.Managed(SavedChannel).init(allocator),
```

- [ ] **Step 6: Add freeSavedChannelStrings helper**

Add after `freeSavedProviderStrings` (after line 101):

```zig
fn freeSavedChannelStrings(self: *State, sc: SavedChannel) void {
    self.allocator.free(sc.name);
    self.allocator.free(sc.channel_type);
    self.allocator.free(sc.account);
    if (sc.config.len > 0) self.allocator.free(sc.config);
    if (sc.validated_at.len > 0) self.allocator.free(sc.validated_at);
    if (sc.validated_with.len > 0) self.allocator.free(sc.validated_with);
}
```

- [ ] **Step 7: Update deinit to free saved_channels**

In `State.deinit` (line 104-123), add before `self.saved_providers.deinit()`:

```zig
for (self.saved_channels.items) |sc| {
    self.freeSavedChannelStrings(sc);
}
self.saved_channels.deinit();
```

- [ ] **Step 8: Update State.load to load saved_channels from JSON**

In `State.load`, after the saved_providers loading loop (after line 205), add:

```zig
for (parsed.value.saved_channels) |sc| {
    const owned_name = try allocator.dupe(u8, sc.name);
    errdefer allocator.free(owned_name);
    const owned_channel_type = try allocator.dupe(u8, sc.channel_type);
    errdefer allocator.free(owned_channel_type);
    const owned_account = try allocator.dupe(u8, sc.account);
    errdefer allocator.free(owned_account);
    const owned_config = if (sc.config.len > 0) try allocator.dupe(u8, sc.config) else @as([]const u8, "");
    errdefer if (owned_config.len > 0) allocator.free(@constCast(owned_config));
    const owned_validated_at = if (sc.validated_at.len > 0) try allocator.dupe(u8, sc.validated_at) else @as([]const u8, "");
    errdefer if (owned_validated_at.len > 0) allocator.free(@constCast(owned_validated_at));
    const owned_validated_with = if (sc.validated_with.len > 0) try allocator.dupe(u8, sc.validated_with) else @as([]const u8, "");
    errdefer if (owned_validated_with.len > 0) allocator.free(@constCast(owned_validated_with));

    try state.saved_channels.append(.{
        .id = sc.id,
        .name = owned_name,
        .channel_type = owned_channel_type,
        .account = owned_account,
        .config = owned_config,
        .validated_at = owned_validated_at,
        .validated_with = owned_validated_with,
    });
}
```

- [ ] **Step 9: Update State.save to include saved_channels**

In `State.save` (line 237-240), update `json_state`:

```zig
const json_state = JsonState{
    .instances = json_outer,
    .saved_providers = self.saved_providers.items,
    .saved_channels = self.saved_channels.items,
};
```

- [ ] **Step 10: Commit**

```bash
git add src/core/state.zig
git commit -m "feat(state): add SavedChannel types and persistence"
```

### Task 2: Add SavedChannel CRUD operations to state.zig

**Files:**
- Modify: `src/core/state.zig` (after provider CRUD functions, before tests)

- [ ] **Step 1: Add savedChannels() and getSavedChannel() accessors**

Add after `hasSavedProvider` (after line 472):

```zig
pub fn savedChannels(self: *State) []const SavedChannel {
    return self.saved_channels.items;
}

pub fn getSavedChannel(self: *State, id: u32) ?SavedChannel {
    for (self.saved_channels.items) |sc| {
        if (sc.id == id) return sc;
    }
    return null;
}
```

- [ ] **Step 2: Add addSavedChannel()**

```zig
pub fn addSavedChannel(self: *State, input: SavedChannelInput) !void {
    const id = self.nextChannelId();
    const name = try self.generateChannelName(input.channel_type);
    errdefer self.allocator.free(name);
    const channel_type = try self.allocator.dupe(u8, input.channel_type);
    errdefer self.allocator.free(channel_type);
    const account = try self.allocator.dupe(u8, input.account);
    errdefer self.allocator.free(account);
    const config = if (input.config.len > 0) try self.allocator.dupe(u8, input.config) else @as([]const u8, "");
    errdefer if (config.len > 0) self.allocator.free(@constCast(config));
    const validated_with = if (input.validated_with.len > 0) try self.allocator.dupe(u8, input.validated_with) else @as([]const u8, "");
    errdefer if (validated_with.len > 0) self.allocator.free(@constCast(validated_with));

    try self.saved_channels.append(.{
        .id = id,
        .name = name,
        .channel_type = channel_type,
        .account = account,
        .config = config,
        .validated_at = "",
        .validated_with = validated_with,
    });
}
```

- [ ] **Step 3: Add updateSavedChannel()**

```zig
pub fn updateSavedChannel(self: *State, id: u32, update: SavedChannelUpdate) !bool {
    for (self.saved_channels.items) |*sc| {
        if (sc.id == id) {
            const new_name = if (update.name) |name| try self.allocator.dupe(u8, name) else null;
            errdefer if (new_name) |n| self.allocator.free(n);
            const new_account = if (update.account) |account| try self.allocator.dupe(u8, account) else null;
            errdefer if (new_account) |a| self.allocator.free(a);
            const new_config = if (update.config) |config|
                if (config.len > 0) try self.allocator.dupe(u8, config) else @as([]const u8, "")
            else
                null;
            errdefer if (new_config) |c| if (c.len > 0) self.allocator.free(@constCast(c));
            const new_validated_at = if (update.validated_at) |validated_at|
                if (validated_at.len > 0) try self.allocator.dupe(u8, validated_at) else @as([]const u8, "")
            else
                null;
            errdefer if (new_validated_at) |t| if (t.len > 0) self.allocator.free(@constCast(t));
            const new_validated_with = if (update.validated_with) |validated_with|
                if (validated_with.len > 0) try self.allocator.dupe(u8, validated_with) else @as([]const u8, "")
            else
                null;

            if (update.name != null) {
                const n = new_name.?;
                self.allocator.free(sc.name);
                sc.name = n;
            }
            if (update.account != null) {
                const a = new_account.?;
                self.allocator.free(sc.account);
                sc.account = a;
            }
            if (update.config != null) {
                const c = new_config.?;
                if (sc.config.len > 0) self.allocator.free(sc.config);
                sc.config = c;
            }
            if (update.validated_at != null) {
                const t = new_validated_at.?;
                if (sc.validated_at.len > 0) self.allocator.free(sc.validated_at);
                sc.validated_at = t;
            }
            if (update.validated_with != null) {
                const w = new_validated_with.?;
                if (sc.validated_with.len > 0) self.allocator.free(sc.validated_with);
                sc.validated_with = w;
            }

            return true;
        }
    }
    return false;
}
```

- [ ] **Step 4: Add removeSavedChannel() and hasSavedChannel()**

```zig
pub fn removeSavedChannel(self: *State, id: u32) bool {
    for (self.saved_channels.items, 0..) |sc, i| {
        if (sc.id == id) {
            self.freeSavedChannelStrings(sc);
            _ = self.saved_channels.orderedRemove(i);
            return true;
        }
    }
    return false;
}

pub fn hasSavedChannel(self: *State, channel_type: []const u8, account: []const u8, config: []const u8) bool {
    for (self.saved_channels.items) |sc| {
        if (std.mem.eql(u8, sc.channel_type, channel_type) and
            std.mem.eql(u8, sc.account, account) and
            std.mem.eql(u8, sc.config, config))
        {
            return true;
        }
    }
    return false;
}
```

- [ ] **Step 5: Add nextChannelId() and generateChannelName() helpers**

```zig
fn nextChannelId(self: *State) u32 {
    var max_id: u32 = 0;
    for (self.saved_channels.items) |sc| {
        if (sc.id > max_id) max_id = sc.id;
    }
    return max_id + 1;
}

fn generateChannelName(self: *State, channel_type: []const u8) ![]const u8 {
    const label = channelLabel(channel_type);
    var count: u32 = 0;
    for (self.saved_channels.items) |sc| {
        if (std.mem.eql(u8, sc.channel_type, channel_type)) count += 1;
    }
    return std.fmt.allocPrint(self.allocator, "{s} #{d}", .{ label, count + 1 });
}
```

- [ ] **Step 6: Add tests for SavedChannel CRUD**

Add after the last existing test (after line 987):

```zig
test "add saved channel, save, load, verify round-trip" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    {
        var s = State.init(allocator, path);
        defer s.deinit();

        try s.addSavedChannel(.{
            .channel_type = "telegram",
            .account = "main_bot",
            .config = "{\"bot_token\":\"123:ABC\"}",
            .validated_with = "nullclaw",
        });

        const channels = s.savedChannels();
        try std.testing.expectEqual(@as(usize, 1), channels.len);
        try std.testing.expectEqualStrings("telegram", channels[0].channel_type);
        try std.testing.expectEqualStrings("main_bot", channels[0].account);
        try std.testing.expectEqualStrings("{\"bot_token\":\"123:ABC\"}", channels[0].config);
        try std.testing.expectEqualStrings("Telegram #1", channels[0].name);
        try std.testing.expectEqual(@as(u32, 1), channels[0].id);

        try s.save();
    }

    {
        var s = try State.load(allocator, path);
        defer s.deinit();

        const channels = s.savedChannels();
        try std.testing.expectEqual(@as(usize, 1), channels.len);
        try std.testing.expectEqualStrings("telegram", channels[0].channel_type);
        try std.testing.expectEqualStrings("{\"bot_token\":\"123:ABC\"}", channels[0].config);
        try std.testing.expectEqualStrings("Telegram #1", channels[0].name);
        try std.testing.expectEqual(@as(u32, 1), channels[0].id);
    }
}

test "channel auto-generated name increments per type" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot1", .config = "{}" });
    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot2", .config = "{}" });
    try s.addSavedChannel(.{ .channel_type = "discord", .account = "srv1", .config = "{}" });

    const channels = s.savedChannels();
    try std.testing.expectEqual(@as(usize, 3), channels.len);
    try std.testing.expectEqualStrings("Telegram #1", channels[0].name);
    try std.testing.expectEqualStrings("Telegram #2", channels[1].name);
    try std.testing.expectEqualStrings("Discord #1", channels[2].name);
}

test "update saved channel name only" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot1", .config = "{}" });
    const updated = try s.updateSavedChannel(1, .{ .name = "My Telegram Bot" });
    try std.testing.expect(updated);

    const channels = s.savedChannels();
    try std.testing.expectEqualStrings("My Telegram Bot", channels[0].name);
}

test "remove saved channel" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot1", .config = "{}" });
    try s.addSavedChannel(.{ .channel_type = "discord", .account = "srv1", .config = "{}" });

    try std.testing.expect(s.removeSavedChannel(1));
    try std.testing.expect(!s.removeSavedChannel(99));

    const channels = s.savedChannels();
    try std.testing.expectEqual(@as(usize, 1), channels.len);
    try std.testing.expectEqualStrings("discord", channels[0].channel_type);
}

test "find saved channel by id" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot1", .config = "{}" });
    try s.addSavedChannel(.{ .channel_type = "discord", .account = "srv1", .config = "{}" });

    const found = s.getSavedChannel(2);
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("discord", found.?.channel_type);
    try std.testing.expect(s.getSavedChannel(99) == null);
}

test "hasSavedChannel detects duplicates" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot1", .config = "{\"bot_token\":\"abc\"}" });

    try std.testing.expect(s.hasSavedChannel("telegram", "bot1", "{\"bot_token\":\"abc\"}"));
    try std.testing.expect(!s.hasSavedChannel("telegram", "bot1", "{\"bot_token\":\"xyz\"}"));
    try std.testing.expect(!s.hasSavedChannel("telegram", "bot2", "{\"bot_token\":\"abc\"}"));
    try std.testing.expect(!s.hasSavedChannel("discord", "bot1", "{\"bot_token\":\"abc\"}"));
}

test "saved channels coexist with providers and instances" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    {
        var s = State.init(allocator, path);
        defer s.deinit();

        try s.addInstance("nullclaw", "bot1", .{ .version = "1.0.0" });
        try s.addSavedProvider(.{ .provider = "openrouter", .api_key = "key1" });
        try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot1", .config = "{}" });
        try s.save();
    }

    {
        var s = try State.load(allocator, path);
        defer s.deinit();

        try std.testing.expect(s.getInstance("nullclaw", "bot1") != null);
        try std.testing.expectEqual(@as(usize, 1), s.savedProviders().len);
        try std.testing.expectEqual(@as(usize, 1), s.savedChannels().len);
    }
}

test "next channel id after removals" {
    const allocator = std.testing.allocator;
    const path = try testPath(allocator, "state.json");
    defer allocator.free(path);
    defer cleanupTestDir();

    var s = State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot1", .config = "{}" }); // id=1
    try s.addSavedChannel(.{ .channel_type = "discord", .account = "srv1", .config = "{}" }); // id=2
    _ = s.removeSavedChannel(1);
    try s.addSavedChannel(.{ .channel_type = "slack", .account = "ws1", .config = "{}" }); // id=3 (not 1)

    const channels = s.savedChannels();
    try std.testing.expectEqual(@as(usize, 2), channels.len);
    try std.testing.expectEqual(@as(u32, 2), channels[0].id);
    try std.testing.expectEqual(@as(u32, 3), channels[1].id);
}
```

- [ ] **Step 7: Run tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | head -30`
Expected: All tests pass, including the new channel tests.

- [ ] **Step 8: Commit**

```bash
git add src/core/state.zig
git commit -m "feat(state): add SavedChannel CRUD operations and tests"
```

---

## Chunk 2: Backend API (channels.zig + server.zig + root.zig)

### Task 3: Create channels.zig API module

**Files:**
- Create: `src/api/channels.zig`

This file mirrors `src/api/providers.zig` exactly. The key differences:
- `/api/channels` instead of `/api/providers`
- `sc_` prefix instead of `sp_`
- Config is a raw JSON string, output as raw JSON (not double-encoded)
- Secret masking uses the config JSON to find password-type field values

- [ ] **Step 1: Create channels.zig with path parsing helpers**

Create `src/api/channels.zig`:

```zig
const std = @import("std");
const state_mod = @import("../core/state.zig");
const paths_mod = @import("../core/paths.zig");
const helpers = @import("helpers.zig");
const wizard_api = @import("wizard.zig");
const providers_api = @import("providers.zig");

const appendEscaped = helpers.appendEscaped;

// ─── Path Parsing ────────────────────────────────────────────────────────────

/// Check if path matches /api/channels or /api/channels/...
pub fn isChannelsPath(target: []const u8) bool {
    return std.mem.eql(u8, target, "/api/channels") or
        std.mem.startsWith(u8, target, "/api/channels?") or
        std.mem.startsWith(u8, target, "/api/channels/");
}

/// Extract channel ID from /api/channels/{id} or /api/channels/{id}/validate
pub fn extractChannelId(target: []const u8) ?u32 {
    const prefix = "/api/channels/";
    if (!std.mem.startsWith(u8, target, prefix)) return null;
    const rest = target[prefix.len..];
    const segment = if (std.mem.indexOfScalar(u8, rest, '/')) |slash_pos|
        rest[0..slash_pos]
    else
        rest;
    return std.fmt.parseInt(u32, segment, 10) catch null;
}

/// Check if path matches /api/channels/{id}/validate
pub fn isValidatePath(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "/api/channels/") and
        std.mem.endsWith(u8, target, "/validate");
}

/// Check if ?reveal=true is in the query string
pub fn hasRevealParam(target: []const u8) bool {
    const query_start = std.mem.indexOfScalar(u8, target, '?') orelse return false;
    return std.mem.indexOf(u8, target[query_start..], "reveal=true") != null;
}
```

- [ ] **Step 2: Add handleList handler**

Append to `channels.zig`:

```zig
// ─── Handlers ────────────────────────────────────────────────────────────────

// List of config keys that contain secrets and should be masked.
// NOTE: This is a runtime array, so we use a regular `for` loop (not `inline for`).
const secret_keys = [_][]const u8{
    "bot_token", "token", "access_token", "app_token", "signing_secret",
    "verify_token", "app_secret", "server_password", "nickserv_password",
    "sasl_password", "password", "encrypt_key", "verification_token",
    "client_secret", "channel_secret", "secret", "private_key", "auth_token",
    "relay_token",
};

fn isSecretKey(key: []const u8) bool {
    for (&secret_keys) |sk| {
        if (std.mem.eql(u8, key, sk)) return true;
    }
    return false;
}

/// GET /api/channels — list all saved channels
pub fn handleList(allocator: std.mem.Allocator, state: *state_mod.State, reveal: bool) ![]const u8 {
    const channels = state.savedChannels();

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try buf.appendSlice("{\"channels\":[");

    for (channels, 0..) |sc, idx| {
        if (idx > 0) try buf.append(',');
        try appendChannelJson(&buf, sc, reveal);
    }

    try buf.appendSlice("]}");
    return buf.toOwnedSlice();
}
```

- [ ] **Step 3: Add handleCreate handler**

```zig
/// POST /api/channels — validate and save a new channel
pub fn handleCreate(
    allocator: std.mem.Allocator,
    body: []const u8,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    // Parse the body as generic JSON to extract fields
    var tree = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch
        return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}");
    defer tree.deinit();

    const root = switch (tree.value) {
        .object => |obj| obj,
        else => return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}"),
    };

    const channel_type = switch (root.get("channel_type") orelse return try allocator.dupe(u8, "{\"error\":\"missing channel_type\"}")) {
        .string => |s| s,
        else => return try allocator.dupe(u8, "{\"error\":\"channel_type must be a string\"}"),
    };

    const account = switch (root.get("account") orelse return try allocator.dupe(u8, "{\"error\":\"missing account\"}")) {
        .string => |s| s,
        else => return try allocator.dupe(u8, "{\"error\":\"account must be a string\"}"),
    };

    const config_val = root.get("config") orelse return try allocator.dupe(u8, "{\"error\":\"missing config\"}");

    // Serialize config to a canonical JSON string
    const config_str = try std.json.Stringify.valueAlloc(allocator, config_val, .{});
    defer allocator.free(config_str);

    // Find an installed component binary
    const component_name = findProbeComponent(allocator, state) orelse
        return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate channels\"}");
    defer allocator.free(component_name);

    const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
        return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
    defer allocator.free(bin_path);

    // Validate via probe
    const probe_result = probeChannel(allocator, component_name, bin_path, channel_type, account, config_str);
    if (!probe_result.live_ok) {
        var buf = std.array_list.Managed(u8).init(allocator);
        errdefer buf.deinit();
        try buf.appendSlice("{\"error\":\"Channel validation failed: ");
        try appendEscaped(&buf, probe_result.reason);
        try buf.appendSlice("\"}");
        return buf.toOwnedSlice();
    }

    // Save to state
    try state.addSavedChannel(.{
        .channel_type = channel_type,
        .account = account,
        .config = config_str,
        .validated_with = component_name,
    });

    // Update validated_at on the just-added channel
    const channels = state.savedChannels();
    const new_id = channels[channels.len - 1].id;
    const now = try providers_api.nowIso8601(allocator);
    defer allocator.free(now);
    _ = try state.updateSavedChannel(new_id, .{ .validated_at = now });

    try state.save();

    const sc = state.getSavedChannel(new_id).?;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try appendChannelJson(&buf, sc, true);
    return buf.toOwnedSlice();
}
```

- [ ] **Step 4: Add handleUpdate handler**

```zig
/// PUT /api/channels/{id} — update a saved channel
pub fn handleUpdate(
    allocator: std.mem.Allocator,
    id: u32,
    body: []const u8,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    const existing = state.getSavedChannel(id) orelse return try allocator.dupe(u8, "{\"error\":\"channel not found\"}");

    var tree = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch
        return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}");
    defer tree.deinit();

    const root = switch (tree.value) {
        .object => |obj| obj,
        else => return try allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}"),
    };

    const new_name: ?[]const u8 = if (root.get("name")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    const new_account: ?[]const u8 = if (root.get("account")) |v| switch (v) {
        .string => |s| s,
        else => null,
    } else null;

    const new_config_val = root.get("config");
    const new_config_str: ?[]const u8 = if (new_config_val) |cv| blk: {
        const s = std.json.Stringify.valueAlloc(allocator, cv, .{}) catch break :blk null;
        break :blk s;
    } else null;
    defer if (new_config_str) |s| allocator.free(s);

    const credentials_changed = (new_account != null and
        !std.mem.eql(u8, new_account.?, existing.account)) or
        (new_config_str != null and
            !std.mem.eql(u8, new_config_str.?, existing.config));

    if (credentials_changed) {
        const component_name = findProbeComponent(allocator, state) orelse
            return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate channels\"}");
        defer allocator.free(component_name);

        const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
            return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
        defer allocator.free(bin_path);

        const effective_account = new_account orelse existing.account;
        const effective_config = new_config_str orelse existing.config;

        const probe_result = probeChannel(allocator, component_name, bin_path, existing.channel_type, effective_account, effective_config);
        if (!probe_result.live_ok) {
            var buf = std.array_list.Managed(u8).init(allocator);
            errdefer buf.deinit();
            try buf.appendSlice("{\"error\":\"Channel validation failed: ");
            try appendEscaped(&buf, probe_result.reason);
            try buf.appendSlice("\"}");
            return buf.toOwnedSlice();
        }

        const now = providers_api.nowIso8601(allocator) catch "";
        defer if (now.len > 0) allocator.free(now);

        _ = try state.updateSavedChannel(id, .{
            .name = new_name,
            .account = new_account,
            .config = new_config_str,
            .validated_at = now,
            .validated_with = component_name,
        });
    } else {
        _ = try state.updateSavedChannel(id, .{ .name = new_name });
    }

    try state.save();

    const sc = state.getSavedChannel(id).?;
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    try appendChannelJson(&buf, sc, true);
    return buf.toOwnedSlice();
}
```

- [ ] **Step 5: Add handleDelete and handleValidate handlers**

```zig
/// DELETE /api/channels/{id}
pub fn handleDelete(allocator: std.mem.Allocator, id: u32, state: *state_mod.State) ![]const u8 {
    if (!state.removeSavedChannel(id)) {
        return try allocator.dupe(u8, "{\"error\":\"channel not found\"}");
    }
    try state.save();
    return allocator.dupe(u8, "{\"status\":\"ok\"}");
}

/// POST /api/channels/{id}/validate — re-validate existing channel
pub fn handleValidate(
    allocator: std.mem.Allocator,
    id: u32,
    state: *state_mod.State,
    paths: paths_mod.Paths,
) ![]const u8 {
    const existing = state.getSavedChannel(id) orelse return try allocator.dupe(u8, "{\"error\":\"channel not found\"}");

    const component_name = findProbeComponent(allocator, state) orelse
        return try allocator.dupe(u8, "{\"error\":\"Install a nullclaw instance first to validate channels\"}");
    defer allocator.free(component_name);

    const bin_path = wizard_api.findOrFetchComponentBinaryPub(allocator, component_name, paths) orelse
        return try allocator.dupe(u8, "{\"error\":\"component binary not found\"}");
    defer allocator.free(bin_path);

    const probe_result = probeChannel(allocator, component_name, bin_path, existing.channel_type, existing.account, existing.config);

    if (probe_result.live_ok) {
        const now = try providers_api.nowIso8601(allocator);
        defer allocator.free(now);
        _ = try state.updateSavedChannel(id, .{ .validated_at = now, .validated_with = component_name });
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
```

- [ ] **Step 6: Add helper functions**

```zig
// ─── Helpers ─────────────────────────────────────────────────────────────────

fn findProbeComponent(allocator: std.mem.Allocator, state: *state_mod.State) ?[]const u8 {
    const names = state.instanceNames("nullclaw") catch return null;
    defer if (names) |list| allocator.free(list);
    if (names) |list| {
        if (list.len > 0) {
            return allocator.dupe(u8, "nullclaw") catch null;
        }
    }
    return null;
}

const ChannelProbeResult = struct {
    live_ok: bool,
    reason: []const u8,
};

fn probeChannel(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    binary_path: []const u8,
    channel_type: []const u8,
    account: []const u8,
    config_json: []const u8,
) ChannelProbeResult {
    const component_cli = @import("../core/component_cli.zig");
    const timestamp = @abs(std.time.milliTimestamp());
    const tmp_dir = std.fmt.allocPrint(allocator, "/tmp/nullhub-channel-validate-{d}", .{timestamp}) catch
        return .{ .live_ok = false, .reason = "tmp_dir_failed" };
    defer {
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        allocator.free(tmp_dir);
    }
    std.fs.makeDirAbsolute(tmp_dir) catch return .{ .live_ok = false, .reason = "tmp_dir_failed" };

    // Write config in the format: {"channels": {channel_type: {account: config}}}
    const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{tmp_dir}) catch
        return .{ .live_ok = false, .reason = "config_write_failed" };
    defer allocator.free(config_path);
    {
        const wrapper = std.fmt.allocPrint(allocator, "{{\"channels\":{{\"{s}\":{{\"{s}\":{s}}}}}}}", .{ channel_type, account, config_json }) catch
            return .{ .live_ok = false, .reason = "config_write_failed" };
        defer allocator.free(wrapper);
        const file = std.fs.createFileAbsolute(config_path, .{}) catch
            return .{ .live_ok = false, .reason = "config_write_failed" };
        defer file.close();
        file.writeAll(wrapper) catch return .{ .live_ok = false, .reason = "config_write_failed" };
    }

    const result = component_cli.runWithComponentHome(
        allocator,
        component_name,
        binary_path,
        &.{ "--probe-channel-health", "--channel", channel_type, "--account", account, "--timeout-secs", "10" },
        null,
        tmp_dir,
    ) catch return .{ .live_ok = false, .reason = "probe_exec_failed" };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const parsed = std.json.parseFromSlice(struct {
        live_ok: bool = false,
        reason: ?[]const u8 = null,
    }, allocator, result.stdout, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return .{ .live_ok = false, .reason = "invalid_probe_response" };
    defer parsed.deinit();

    const reason = parsed.value.reason orelse (if (parsed.value.live_ok) "ok" else "probe_failed");
    return .{ .live_ok = parsed.value.live_ok, .reason = reason };
}

fn maskSecret(buf: *std.array_list.Managed(u8), value: []const u8) !void {
    if (value.len <= 8) {
        try buf.appendSlice("***");
    } else {
        try buf.appendSlice(value[0..4]);
        try buf.appendSlice("...");
        try buf.appendSlice(value[value.len - 4 ..]);
    }
}

fn appendChannelJson(buf: *std.array_list.Managed(u8), sc: state_mod.SavedChannel, reveal: bool) !void {
    try buf.appendSlice("{\"id\":\"sc_");
    var id_buf: [16]u8 = undefined;
    const id_str = std.fmt.bufPrint(&id_buf, "{d}", .{sc.id}) catch "0";
    try buf.appendSlice(id_str);
    try buf.appendSlice("\"");
    try buf.appendSlice(",\"name\":\"");
    try appendEscaped(buf, sc.name);
    try buf.appendSlice("\",\"channel_type\":\"");
    try appendEscaped(buf, sc.channel_type);
    try buf.appendSlice("\",\"account\":\"");
    try appendEscaped(buf, sc.account);
    try buf.appendSlice("\",\"config\":");
    // config is stored as JSON string - output as raw JSON, masking secrets if needed
    if (sc.config.len > 0) {
        if (reveal) {
            try buf.appendSlice(sc.config);
        } else {
            try appendMaskedConfig(buf, sc.config);
        }
    } else {
        try buf.appendSlice("{}");
    }
    try buf.appendSlice(",\"validated_at\":\"");
    try appendEscaped(buf, sc.validated_at);
    try buf.appendSlice("\",\"validated_with\":\"");
    try appendEscaped(buf, sc.validated_with);
    try buf.appendSlice("\"}");
}

fn appendMaskedConfig(buf: *std.array_list.Managed(u8), config_json: []const u8) !void {
    // Parse the config JSON, mask secret keys, re-serialize
    const allocator = buf.allocator;
    var tree = std.json.parseFromSlice(std.json.Value, allocator, config_json, .{ .allocate = .alloc_always }) catch {
        try buf.appendSlice("{}");
        return;
    };
    defer tree.deinit();

    switch (tree.value) {
        .object => |obj| {
            try buf.append('{');
            var first = true;
            var it = obj.iterator();
            while (it.next()) |entry| {
                if (!first) try buf.append(',');
                first = false;
                try buf.append('"');
                try appendEscaped(buf, entry.key_ptr.*);
                try buf.appendSlice("\":");
                if (isSecretKey(entry.key_ptr.*)) {
                    // Mask string values
                    switch (entry.value_ptr.*) {
                        .string => |s| {
                            try buf.append('"');
                            try maskSecret(buf, s);
                            try buf.append('"');
                        },
                        else => {
                            const val_str = std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{}) catch {
                                try buf.appendSlice("null");
                                continue;
                            };
                            defer allocator.free(val_str);
                            try buf.appendSlice(val_str);
                        },
                    }
                } else {
                    const val_str = std.json.Stringify.valueAlloc(allocator, entry.value_ptr.*, .{}) catch {
                        try buf.appendSlice("null");
                        continue;
                    };
                    defer allocator.free(val_str);
                    try buf.appendSlice(val_str);
                }
            }
            try buf.append('}');
        },
        else => try buf.appendSlice("{}"),
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "isChannelsPath matches correct paths" {
    try std.testing.expect(isChannelsPath("/api/channels"));
    try std.testing.expect(isChannelsPath("/api/channels?reveal=true"));
    try std.testing.expect(isChannelsPath("/api/channels/1"));
    try std.testing.expect(isChannelsPath("/api/channels/1/validate"));
    try std.testing.expect(!isChannelsPath("/api/wizard"));
    try std.testing.expect(!isChannelsPath("/api/channel"));
}

test "extractChannelId parses correctly" {
    try std.testing.expectEqual(@as(?u32, 1), extractChannelId("/api/channels/1"));
    try std.testing.expectEqual(@as(?u32, 42), extractChannelId("/api/channels/42"));
    try std.testing.expectEqual(@as(?u32, 5), extractChannelId("/api/channels/5/validate"));
    try std.testing.expectEqual(@as(?u32, null), extractChannelId("/api/channels"));
    try std.testing.expectEqual(@as(?u32, null), extractChannelId("/api/channels/abc"));
}

test "isValidatePath matches only validate suffix" {
    try std.testing.expect(isValidatePath("/api/channels/1/validate"));
    try std.testing.expect(!isValidatePath("/api/channels/1"));
    try std.testing.expect(!isValidatePath("/api/channels"));
}

test "hasRevealParam detects reveal query param" {
    try std.testing.expect(hasRevealParam("/api/channels?reveal=true"));
    try std.testing.expect(!hasRevealParam("/api/channels"));
    try std.testing.expect(!hasRevealParam("/api/channels?reveal=false"));
}

test "handleList returns empty array for no channels" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-channel-test-list.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    const json = try handleList(allocator, &s, false);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"channels\":[]}", json);
}

test "handleList masks secrets by default" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-channel-test-mask.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{
        .channel_type = "telegram",
        .account = "bot1",
        .config = "{\"bot_token\":\"1234567890:ABCDEF\"}",
    });

    const json = try handleList(allocator, &s, false);
    defer allocator.free(json);
    // Should contain masked token, not full token
    try std.testing.expect(std.mem.indexOf(u8, json, "1234567890:ABCDEF") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "1234...CDEF") != null);
}

test "handleList reveals secrets when requested" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-channel-test-reveal.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{
        .channel_type = "telegram",
        .account = "bot1",
        .config = "{\"bot_token\":\"1234567890:ABCDEF\"}",
    });

    const json = try handleList(allocator, &s, true);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "1234567890:ABCDEF") != null);
}

test "handleDelete removes channel" {
    const allocator = std.testing.allocator;
    const tmp = "/tmp/nullhub-channel-test-delete";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    std.fs.makeDirAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const path = try std.fmt.allocPrint(allocator, "{s}/state.json", .{tmp});
    defer allocator.free(path);

    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    try s.addSavedChannel(.{ .channel_type = "telegram", .account = "bot1", .config = "{}" });

    const json = try handleDelete(allocator, 1, &s);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", json);
    try std.testing.expectEqual(@as(usize, 0), s.savedChannels().len);
}

test "handleDelete returns error for unknown id" {
    const allocator = std.testing.allocator;
    const path = "/tmp/nullhub-channel-test-del-unknown.json";
    var s = state_mod.State.init(allocator, path);
    defer s.deinit();

    const json = try handleDelete(allocator, 99, &s);
    defer allocator.free(json);
    try std.testing.expectEqualStrings("{\"error\":\"channel not found\"}", json);
}
```

- [ ] **Step 7: Run tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | head -30`
Expected: All tests pass.

- [ ] **Step 8: Commit**

```bash
git add src/api/channels.zig
git commit -m "feat(api): add channels API module with CRUD handlers"
```

### Task 4: Wire channels API into server.zig and root.zig

**Files:**
- Modify: `src/server.zig:17` (imports) and `src/server.zig:706` (after providers routing block)
- Modify: `src/root.zig:32` (imports) and `src/root.zig:66` (test block)

- [ ] **Step 1: Add channels_api import to server.zig**

Add after line 17 (`const providers_api = ...`):

```zig
const channels_api = @import("api/channels.zig");
```

- [ ] **Step 2: Add channels routing block to server.zig**

Add after the providers routing block ends (after line 706, before the Config API comment):

```zig
        // Channels API — /api/channels[/{id}[/validate]]
        if (channels_api.isChannelsPath(target)) {
            if (std.mem.eql(u8, target, "/api/channels") or std.mem.startsWith(u8, target, "/api/channels?")) {
                if (std.mem.eql(u8, method, "GET")) {
                    const reveal = channels_api.hasRevealParam(target);
                    if (channels_api.handleList(allocator, self.state, reveal)) |json| {
                        return jsonResponse(json);
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "POST")) {
                    if (channels_api.handleCreate(allocator, body, self.state, self.paths)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "422 Unprocessable Entity" else "201 Created";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
            }
            if (channels_api.extractChannelId(target)) |id| {
                if (channels_api.isValidatePath(target)) {
                    if (std.mem.eql(u8, method, "POST")) {
                        if (channels_api.handleValidate(allocator, id, self.state, self.paths)) |json| {
                            const status = if (std.mem.indexOf(u8, json, "\"error\"") != null or
                                std.mem.indexOf(u8, json, "\"live_ok\":false") != null)
                                "422 Unprocessable Entity"
                            else
                                "200 OK";
                            return .{ .status = status, .content_type = "application/json", .body = json };
                        } else |_| {
                            return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                        }
                    }
                    return .{ .status = "405 Method Not Allowed", .content_type = "application/json", .body = "{\"error\":\"method not allowed\"}" };
                }
                if (std.mem.eql(u8, method, "PUT")) {
                    if (channels_api.handleUpdate(allocator, id, body, self.state, self.paths)) |json| {
                        const status = if (std.mem.indexOf(u8, json, "\"error\"") != null) "422 Unprocessable Entity" else "200 OK";
                        return .{ .status = status, .content_type = "application/json", .body = json };
                    } else |_| {
                        return .{ .status = "500 Internal Server Error", .content_type = "application/json", .body = "{\"error\":\"internal error\"}" };
                    }
                }
                if (std.mem.eql(u8, method, "DELETE")) {
                    if (channels_api.handleDelete(allocator, id, self.state)) |json| {
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

- [ ] **Step 3: Add channels_api to root.zig**

After line 32 (`pub const providers_api = ...`), add:

```zig
pub const channels_api = @import("api/channels.zig");
```

In the test block, after `_ = providers_api;` (line 66), add:

```zig
    _ = channels_api;
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | head -30`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/server.zig src/root.zig
git commit -m "feat(server): wire channels API routes"
```

### Task 5: Add auto-save to wizard validate-channels

**Files:**
- Modify: `src/api/wizard.zig:701-797` (`handleValidateChannels`)

- [ ] **Step 1: Update handleValidateChannels signature to accept state**

Change the function signature (line 702) to include `state`:

```zig
pub fn handleValidateChannels(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
    state: *state_mod.State,
) ?[]const u8 {
```

- [ ] **Step 2: Add auto-save logic after validation results**

First, add a structure to track validated channels. Before the validation loop (before `var first = true;`), add:

```zig
    // Track which (channel_type, account) pairs pass validation
    const ValidatedPair = struct { channel_type: []const u8, account: []const u8 };
    var validated_pairs = std.array_list.Managed(ValidatedPair).init(allocator);
    defer validated_pairs.deinit();
```

Inside the inner validation loop, after parsing the probe result (after line 790, `const reason = ...`), add tracking:

```zig
            if (probe_parsed.value.live_ok) {
                validated_pairs.append(.{ .channel_type = channel_type, .account = account_name }) catch {};
            }
```

After the validation loop (after line 792, before `buf.appendSlice("]}") catch return null;`), add auto-save for only validated channels:

```zig
    // Auto-save validated channels (only those that passed validation)
    var did_save = false;
    for (validated_pairs.items) |pair| {
        const accs = switch (channels_map.get(pair.channel_type) orelse continue) {
            .object => |obj| obj,
            else => continue,
        };
        const acc_val = accs.get(pair.account) orelse continue;
        const config_str = std.json.Stringify.valueAlloc(allocator, acc_val, .{}) catch continue;
        defer allocator.free(config_str);

        if (!state.hasSavedChannel(pair.channel_type, pair.account, config_str)) {
            state.addSavedChannel(.{
                .channel_type = pair.channel_type,
                .account = pair.account,
                .config = config_str,
                .validated_with = component_name,
            }) catch continue;
            did_save = true;
        }
    }
    if (did_save) state.save() catch {};
```

- [ ] **Step 3: Update the caller in server.zig**

In `src/server.zig`, find the call to `handleValidateChannels` (search for `wizard_api.handleValidateChannels`). Change:

```zig
if (wizard_api.handleValidateChannels(allocator, comp_name, body, self.paths)) |json| {
```

to:

```zig
if (wizard_api.handleValidateChannels(allocator, comp_name, body, self.paths, self.state)) |json| {
```

- [ ] **Step 4: Run tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | head -30`
Expected: All tests pass.

- [ ] **Step 5: Commit**

```bash
git add src/api/wizard.zig src/server.zig
git commit -m "feat(wizard): auto-save validated channels"
```

---

## Chunk 3: Frontend

### Task 6: Add saved channels API methods to client.ts

**Files:**
- Modify: `ui/src/lib/api/client.ts:107-108` (end of api object)

- [ ] **Step 1: Add saved channel API methods**

Add before the closing `};` of the `api` object (after line 107):

```typescript
  // Saved channels
  getSavedChannels: (reveal = false) =>
    request<any>(`/channels${reveal ? '?reveal=true' : ''}`),
  createSavedChannel: (data: { channel_type: string; account: string; config: Record<string, any> }) =>
    request<any>('/channels', { method: 'POST', body: JSON.stringify(data) }),
  updateSavedChannel: (id: string, data: { name?: string; account?: string; config?: Record<string, any> }) =>
    request<any>(`/channels/${id.replace('sc_', '')}`, { method: 'PUT', body: JSON.stringify(data) }),
  deleteSavedChannel: (id: string) =>
    request<any>(`/channels/${id.replace('sc_', '')}`, { method: 'DELETE' }),
  revalidateSavedChannel: (id: string) =>
    request<any>(`/channels/${id.replace('sc_', '')}/validate`, { method: 'POST' }),
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/lib/api/client.ts
git commit -m "feat(ui): add saved channels API client methods"
```

### Task 7: Add Channels nav item to Sidebar

**Files:**
- Modify: `ui/src/lib/components/Sidebar.svelte:54-56`

- [ ] **Step 1: Add Channels link after Providers**

After the Providers nav-section (after line 56), add:

```svelte
  <div class="nav-section">
    <a href="/channels" class:active={currentPath === "/channels"}>Channels</a>
  </div>
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/lib/components/Sidebar.svelte
git commit -m "feat(ui): add Channels nav item to sidebar"
```

### Task 8: Create Channels management page

**Files:**
- Create: `ui/src/routes/channels/+page.svelte`

This page mirrors `ui/src/routes/providers/+page.svelte` but adapts for channel-specific fields:
- Channel type dropdown instead of provider dropdown
- Account name input
- Dynamic config fields from channelSchemas
- Secret fields masked in card view

- [ ] **Step 1: Create the channels page**

Create `ui/src/routes/channels/+page.svelte` — full code mirrors providers page with channel adaptations:

```svelte
<script lang="ts">
  import { onMount } from "svelte";
  import { api } from "$lib/api/client";
  import { channelSchemas } from "$lib/components/configSchemas";

  const DEFAULT_CHANNELS = ['web', 'cli'];
  const CHANNEL_OPTIONS = Object.entries(channelSchemas)
    .filter(([key]) => !DEFAULT_CHANNELS.includes(key))
    .map(([key, schema]) => ({ value: key, label: schema.label }));

  let channels = $state<any[]>([]);
  let loading = $state(true);
  let error = $state("");
  let message = $state("");

  // Add form state
  let showAddForm = $state(false);
  let addForm = $state<{ channel_type: string; account: string; config: Record<string, any> }>({
    channel_type: "telegram",
    account: "default",
    config: {},
  });
  let addValidating = $state(false);
  let addError = $state("");

  // Edit state
  let editingId = $state<string | null>(null);
  let editForm = $state<{ name: string; account: string; config: Record<string, any> }>({
    name: "", account: "", config: {},
  });
  let editValidating = $state(false);
  let editError = $state("");

  // Re-validate state
  let revalidatingId = $state<string | null>(null);

  let hasComponents = $state(false);

  let addSchema = $derived(channelSchemas[addForm.channel_type]);
  let editChannelType = $state("");
  let editSchema = $derived(channelSchemas[editChannelType]);

  onMount(async () => {
    await loadChannels();
    try {
      const status = await api.getStatus();
      hasComponents = Object.keys(status.instances || {}).length > 0;
    } catch {}
  });

  async function loadChannels() {
    loading = true;
    error = "";
    try {
      const data = await api.getSavedChannels();
      channels = data.channels || [];
    } catch (e) {
      error = (e as Error).message;
    } finally {
      loading = false;
    }
  }

  function resetAddConfig(type: string) {
    const schema = channelSchemas[type];
    const defaults: Record<string, any> = {};
    for (const field of schema?.fields || []) {
      if (field.default !== undefined) defaults[field.key] = field.default;
    }
    addForm = {
      channel_type: type,
      account: schema?.hasAccounts ? "default" : type,
      config: defaults,
    };
  }

  async function handleAdd() {
    addValidating = true;
    addError = "";
    try {
      await api.createSavedChannel({
        channel_type: addForm.channel_type,
        account: addForm.account,
        config: addForm.config,
      });
      showAddForm = false;
      resetAddConfig("telegram");
      message = "Channel saved";
      setTimeout(() => (message = ""), 3000);
      await loadChannels();
    } catch (e) {
      addError = (e as Error).message;
    } finally {
      addValidating = false;
    }
  }

  async function startEdit(c: any) {
    editChannelType = c.channel_type;
    // Fetch revealed secrets so edit form has real values, not masked ones
    try {
      const data = await api.getSavedChannels(true);
      const revealed = data.channels?.find((ch: any) => ch.id === c.id);
      if (revealed) {
        editForm = { name: revealed.name, account: revealed.account, config: { ...revealed.config } };
      } else {
        editForm = { name: c.name, account: c.account, config: { ...c.config } };
      }
    } catch {
      editForm = { name: c.name, account: c.account, config: { ...c.config } };
    }
    editingId = c.id;
  }

  function cancelEdit() {
    editingId = null;
  }

  async function saveEdit(id: string) {
    editValidating = true;
    editError = "";
    try {
      await api.updateSavedChannel(id, {
        name: editForm.name,
        account: editForm.account,
        config: editForm.config,
      });
      editingId = null;
      message = "Channel updated";
      setTimeout(() => (message = ""), 3000);
      await loadChannels();
    } catch (e) {
      editError = (e as Error).message;
    } finally {
      editValidating = false;
    }
  }

  async function handleDelete(id: string) {
    try {
      await api.deleteSavedChannel(id);
      message = "Channel deleted";
      setTimeout(() => (message = ""), 3000);
      await loadChannels();
    } catch (e) {
      error = (e as Error).message;
    }
  }

  async function handleRevalidate(id: string) {
    revalidatingId = id;
    try {
      const result = await api.revalidateSavedChannel(id);
      if (result.live_ok) {
        message = "Validation passed";
      } else {
        message = `Validation failed: ${result.reason || "unknown error"}`;
      }
      setTimeout(() => (message = ""), 5000);
      await loadChannels();
    } catch (e) {
      message = `Validation failed: ${(e as Error).message}`;
      setTimeout(() => (message = ""), 5000);
    } finally {
      revalidatingId = null;
    }
  }

  function getChannelLabel(type: string) {
    return channelSchemas[type]?.label || type;
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

  function isSecretField(key: string) {
    const secretKeys = [
      'bot_token', 'token', 'access_token', 'app_token', 'signing_secret',
      'verify_token', 'app_secret', 'server_password', 'nickserv_password',
      'sasl_password', 'password', 'encrypt_key', 'verification_token',
      'client_secret', 'channel_secret', 'secret', 'private_key', 'auth_token',
      'relay_token',
    ];
    return secretKeys.includes(key);
  }

  function displayConfigValue(key: string, val: any): string {
    if (val === undefined || val === null || val === '') return '—';
    if (Array.isArray(val)) return val.length > 0 ? val.join(', ') : '—';
    if (typeof val === 'boolean') return val ? 'Yes' : 'No';
    return String(val);
  }
</script>

<div class="channels-page">
  <div class="page-header">
    <h1>Channels</h1>
    {#if hasComponents}
      <button class="primary-btn" onclick={() => { if (!showAddForm) resetAddConfig(addForm.channel_type); showAddForm = !showAddForm; }}>
        {showAddForm ? "Cancel" : "+ Add Channel"}
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
      <p>Install a component first to add channels.</p>
      <a href="/install" class="link-btn">Install Component</a>
    </div>
  {:else if showAddForm}
    <div class="add-form">
      <h2>Add Channel</h2>
      <div class="field">
        <label for="add-channel-type">Channel Type</label>
        <select id="add-channel-type" value={addForm.channel_type}
          onchange={(e) => resetAddConfig(e.currentTarget.value)}>
          {#each CHANNEL_OPTIONS as opt}
            <option value={opt.value}>{opt.label}</option>
          {/each}
        </select>
      </div>
      {#if addSchema?.hasAccounts}
        <div class="field">
          <label for="add-account">Account Name</label>
          <input id="add-account" type="text" bind:value={addForm.account} placeholder="e.g. main_bot" />
        </div>
      {/if}
      {#each addSchema?.fields || [] as field}
        <div class="field">
          <label for={`add-${field.key}`}>
            {field.label}
            {#if field.hint}
              <span class="field-hint">{field.hint}</span>
            {/if}
          </label>
          {#if field.type === 'password'}
            <input id={`add-${field.key}`} type="password"
              value={addForm.config[field.key] ?? field.default ?? ''}
              oninput={(e) => addForm.config = { ...addForm.config, [field.key]: e.currentTarget.value }}
              placeholder="Enter value..." />
          {:else if field.type === 'number'}
            <input id={`add-${field.key}`} type="number"
              value={addForm.config[field.key] ?? field.default ?? ''}
              oninput={(e) => addForm.config = { ...addForm.config, [field.key]: Number(e.currentTarget.value) }} />
          {:else if field.type === 'toggle'}
            <label class="toggle">
              <input type="checkbox"
                checked={(addForm.config[field.key] ?? field.default) === true}
                onchange={(e) => addForm.config = { ...addForm.config, [field.key]: e.currentTarget.checked }} />
              <span class="toggle-slider"></span>
            </label>
          {:else if field.type === 'select'}
            <select id={`add-${field.key}`}
              value={addForm.config[field.key] ?? field.default ?? ''}
              onchange={(e) => addForm.config = { ...addForm.config, [field.key]: e.currentTarget.value }}>
              {#each field.options || [] as opt}
                <option value={opt}>{opt}</option>
              {/each}
            </select>
          {:else if field.type === 'list'}
            <input id={`add-${field.key}`} type="text"
              value={(addForm.config[field.key] ?? field.default ?? []).join(', ')}
              oninput={(e) => addForm.config = { ...addForm.config, [field.key]: e.currentTarget.value.split(',').map((s: string) => s.trim()).filter(Boolean) }}
              placeholder={field.hint || "Comma-separated values..."} />
          {:else}
            <input id={`add-${field.key}`} type="text"
              value={addForm.config[field.key] ?? field.default ?? ''}
              oninput={(e) => addForm.config = { ...addForm.config, [field.key]: e.currentTarget.value }}
              placeholder={field.hint || "Enter value..."} />
          {/if}
        </div>
      {/each}
      {#if addError}
        <div class="error-message">{addError}</div>
      {/if}
      <button class="primary-btn" onclick={handleAdd} disabled={addValidating}>
        {addValidating ? "Validating..." : "Validate & Save"}
      </button>
    </div>
  {/if}

  {#if loading}
    <p class="loading">Loading channels...</p>
  {:else if channels.length === 0 && hasComponents}
    <div class="empty-state">
      <p>No saved channels yet. Add one above or install a component — channels are saved automatically during setup.</p>
    </div>
  {:else}
    <div class="channel-grid">
      {#each channels as c}
        <div class="channel-card">
          {#if editingId === c.id}
            <div class="edit-form">
              <div class="field">
                <label for="edit-name-{c.id}">Name</label>
                <input id="edit-name-{c.id}" type="text" bind:value={editForm.name} />
              </div>
              {#if editSchema?.hasAccounts}
                <div class="field">
                  <label for="edit-account-{c.id}">Account</label>
                  <input id="edit-account-{c.id}" type="text" bind:value={editForm.account} />
                </div>
              {/if}
              {#each editSchema?.fields || [] as field}
                <div class="field">
                  <label for={`edit-${c.id}-${field.key}`}>
                    {field.label}
                    {#if field.hint}
                      <span class="field-hint">{field.hint}</span>
                    {/if}
                  </label>
                  {#if field.type === 'password'}
                    <input id={`edit-${c.id}-${field.key}`} type="password"
                      value={editForm.config[field.key] ?? ''}
                      oninput={(e) => editForm.config = { ...editForm.config, [field.key]: e.currentTarget.value }}
                      placeholder="Leave empty to keep current" />
                  {:else if field.type === 'number'}
                    <input id={`edit-${c.id}-${field.key}`} type="number"
                      value={editForm.config[field.key] ?? ''}
                      oninput={(e) => editForm.config = { ...editForm.config, [field.key]: Number(e.currentTarget.value) }} />
                  {:else if field.type === 'toggle'}
                    <label class="toggle">
                      <input type="checkbox"
                        checked={(editForm.config[field.key] ?? false) === true}
                        onchange={(e) => editForm.config = { ...editForm.config, [field.key]: e.currentTarget.checked }} />
                      <span class="toggle-slider"></span>
                    </label>
                  {:else if field.type === 'select'}
                    <select id={`edit-${c.id}-${field.key}`}
                      value={editForm.config[field.key] ?? ''}
                      onchange={(e) => editForm.config = { ...editForm.config, [field.key]: e.currentTarget.value }}>
                      {#each field.options || [] as opt}
                        <option value={opt}>{opt}</option>
                      {/each}
                    </select>
                  {:else if field.type === 'list'}
                    <input id={`edit-${c.id}-${field.key}`} type="text"
                      value={(editForm.config[field.key] ?? []).join(', ')}
                      oninput={(e) => editForm.config = { ...editForm.config, [field.key]: e.currentTarget.value.split(',').map((s: string) => s.trim()).filter(Boolean) }}
                      placeholder="Comma-separated values..." />
                  {:else}
                    <input id={`edit-${c.id}-${field.key}`} type="text"
                      value={editForm.config[field.key] ?? ''}
                      oninput={(e) => editForm.config = { ...editForm.config, [field.key]: e.currentTarget.value }}
                      placeholder="Enter value..." />
                  {/if}
                </div>
              {/each}
              {#if editError}
                <div class="error-message">{editError}</div>
              {/if}
              <div class="edit-actions">
                <button class="primary-btn" onclick={() => saveEdit(c.id)} disabled={editValidating}>
                  {editValidating ? "Saving..." : "Save"}
                </button>
                <button class="btn" onclick={cancelEdit}>Cancel</button>
              </div>
            </div>
          {:else}
            <div class="card-header">
              <div class="card-title">
                <span class="status-dot" class:validated={!!c.validated_at} class:not-validated={!c.validated_at}></span>
                <h3>{c.name}</h3>
              </div>
              <span class="channel-type">{getChannelLabel(c.channel_type)}</span>
            </div>
            <div class="card-body">
              <div class="card-field">
                <span class="label">Account</span>
                <code>{c.account}</code>
              </div>
              {#each Object.entries(c.config || {}) as [key, val]}
                <div class="card-field">
                  <span class="label">{key}</span>
                  <code>{isSecretField(key) ? (typeof val === 'string' ? val : '***') : displayConfigValue(key, val)}</code>
                </div>
              {/each}
              {#if c.validated_at}
                <div class="card-field">
                  <span class="label">Validated</span>
                  <span>{formatDate(c.validated_at)}</span>
                </div>
              {/if}
            </div>
            <div class="card-actions">
              <button class="btn" onclick={() => handleRevalidate(c.id)} disabled={revalidatingId === c.id}>
                {revalidatingId === c.id ? "Validating..." : "Re-validate"}
              </button>
              <button class="btn" onclick={() => startEdit(c)}>Edit</button>
              <button class="btn danger" onclick={() => handleDelete(c.id)}>Delete</button>
            </div>
          {/if}
        </div>
      {/each}
    </div>
  {/if}
</div>

<style>
  /* Reuse exact same styles as providers page */
  .channels-page { max-width: 800px; margin: 0 auto; padding: 2rem; }
  .page-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 2rem; }
  h1 { font-size: 1.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 2px; color: var(--accent); text-shadow: var(--text-glow); }
  h2 { font-size: 1.125rem; font-weight: 700; margin-bottom: 1rem; color: var(--accent-dim); text-transform: uppercase; letter-spacing: 1px; }
  .add-form, .channel-card { background: var(--bg-surface); border: 1px solid var(--border); border-radius: 2px; padding: 1.25rem; margin-bottom: 1rem; box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2); }
  .add-form { margin-bottom: 2rem; }
  .field { margin-bottom: 1rem; }
  .field label { display: block; font-size: 0.75rem; color: var(--fg-dim); margin-bottom: 0.35rem; text-transform: uppercase; letter-spacing: 1px; font-weight: 700; }
  .field-hint { font-weight: 400; font-size: 0.65rem; color: color-mix(in srgb, var(--fg-dim) 70%, transparent); letter-spacing: 0; text-transform: none; margin-left: 0.5rem; }
  .field input, .field select { width: 100%; background: var(--bg-surface); border: 1px solid var(--border); border-radius: 2px; padding: 0.5rem 0.75rem; color: var(--fg); font-size: 0.875rem; font-family: var(--font-mono); outline: none; transition: all 0.2s ease; box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2); }
  .field input:focus, .field select:focus { border-color: var(--accent); box-shadow: 0 0 8px var(--border-glow); }
  .card-header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; }
  .card-title { display: flex; align-items: center; gap: 0.5rem; }
  .card-title h3 { font-size: 1rem; font-weight: 700; color: var(--fg); }
  .channel-type { font-size: 0.75rem; color: var(--fg-dim); text-transform: uppercase; letter-spacing: 1px; }
  .status-dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
  .status-dot.validated { background: var(--success, #4a4); box-shadow: 0 0 6px var(--success, #4a4); }
  .status-dot.not-validated { background: var(--warning, #ca0); box-shadow: 0 0 6px var(--warning, #ca0); }
  .card-body { margin-bottom: 1rem; }
  .card-field { display: flex; justify-content: space-between; align-items: center; padding: 0.375rem 0; border-bottom: 1px dashed color-mix(in srgb, var(--border) 40%, transparent); }
  .card-field:last-child { border-bottom: none; }
  .card-field .label { font-size: 0.75rem; color: var(--fg-dim); text-transform: uppercase; letter-spacing: 1px; font-weight: 700; }
  .card-field code { font-family: var(--font-mono); font-size: 0.8125rem; color: var(--fg); }
  .card-actions, .edit-actions { display: flex; gap: 0.5rem; }
  .btn { padding: 0.375rem 0.875rem; background: var(--bg-surface); color: var(--accent); border: 1px solid var(--accent-dim); border-radius: 2px; font-size: 0.75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 1px; cursor: pointer; transition: all 0.2s ease; text-shadow: var(--text-glow); }
  .btn:hover:not(:disabled) { background: var(--bg-hover); border-color: var(--accent); box-shadow: 0 0 10px var(--border-glow); }
  .btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .btn.danger { color: var(--error, #e55); border-color: color-mix(in srgb, var(--error, #e55) 50%, transparent); }
  .btn.danger:hover:not(:disabled) { border-color: var(--error, #e55); box-shadow: 0 0 10px color-mix(in srgb, var(--error, #e55) 30%, transparent); }
  .primary-btn { padding: 0.5rem 1.25rem; background: color-mix(in srgb, var(--accent) 20%, transparent); color: var(--accent); border: 1px solid var(--accent); border-radius: 2px; font-size: 0.875rem; font-weight: 700; text-transform: uppercase; letter-spacing: 1px; cursor: pointer; transition: all 0.2s ease; text-shadow: var(--text-glow); }
  .primary-btn:hover:not(:disabled) { background: var(--bg-hover); box-shadow: 0 0 15px var(--border-glow); }
  .primary-btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .message { padding: 0.875rem 1.25rem; background: color-mix(in srgb, var(--success) 10%, transparent); border: 1px solid var(--success); border-radius: 2px; font-size: 0.875rem; font-weight: bold; color: var(--success); margin-bottom: 1.5rem; box-shadow: 0 0 10px color-mix(in srgb, var(--success) 30%, transparent); }
  .error-message { padding: 0.875rem 1.25rem; background: color-mix(in srgb, var(--error, #e55) 10%, transparent); border: 1px solid var(--error, #e55); border-radius: 2px; font-size: 0.875rem; color: var(--error, #e55); margin-bottom: 1rem; }
  .empty-state { text-align: center; padding: 3rem; color: var(--fg-dim); }
  .empty-state p { margin-bottom: 1rem; font-family: var(--font-mono); }
  .link-btn { color: var(--accent); text-decoration: none; border: 1px solid var(--accent); padding: 0.5rem 1.25rem; border-radius: 2px; text-transform: uppercase; letter-spacing: 1px; font-size: 0.875rem; transition: all 0.2s ease; }
  .link-btn:hover { background: color-mix(in srgb, var(--accent) 15%, transparent); box-shadow: 0 0 10px var(--border-glow); }
  .loading { color: var(--fg-dim); font-family: var(--font-mono); text-align: center; padding: 2rem; }
  .channel-grid { display: flex; flex-direction: column; gap: 0.75rem; }
  .edit-form { padding: 0.5rem 0; }
  .toggle { position: relative; display: inline-block; width: 44px; height: 24px; cursor: pointer; }
  .toggle input { opacity: 0; width: 0; height: 0; }
  .toggle-slider { position: absolute; inset: 0; background: var(--bg-surface); border: 1px solid var(--border); border-radius: 2px; transition: all 0.2s ease; box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.5); }
  .toggle-slider::before { content: ""; position: absolute; width: 16px; height: 16px; left: 4px; top: 3px; background: var(--fg-dim); border-radius: 2px; transition: all 0.2s ease; }
  .toggle input:checked + .toggle-slider { background: color-mix(in srgb, var(--accent) 20%, transparent); border-color: var(--accent); box-shadow: inset 0 0 10px color-mix(in srgb, var(--accent) 30%, transparent); }
  .toggle input:checked + .toggle-slider::before { transform: translateX(18px); background: var(--accent); box-shadow: 0 0 5px var(--border-glow); }
</style>
```

- [ ] **Step 2: Commit**

```bash
git add ui/src/routes/channels/+page.svelte
git commit -m "feat(ui): add Channels management page"
```

### Task 9: Add "Use Saved" dropdown to ChannelList wizard component

**Files:**
- Modify: `ui/src/lib/components/ChannelList.svelte`

- [ ] **Step 1: Add saved channels state and API import**

At the top of the `<script>` block (after line 2), add:

```typescript
  import { onMount } from "svelte";
  import { api } from "$lib/api/client";
```

After the `showAddPicker` state (after line 13), add:

```typescript
  let savedChannels = $state<any[]>([]);
  let showSavedDropdown = $state(false);
  let savedChannelsRevealed = $state(false);
  let loadingSavedChannels = $state(false);

  onMount(async () => {
    try {
      const data = await api.getSavedChannels();
      savedChannels = data.channels || [];
    } catch {}
  });

  async function toggleSavedDropdown() {
    if (showSavedDropdown) {
      showSavedDropdown = false;
      return;
    }
    if (!savedChannelsRevealed && savedChannels.length > 0) {
      loadingSavedChannels = true;
      try {
        const data = await api.getSavedChannels(true);
        savedChannels = data.channels || [];
        savedChannelsRevealed = true;
      } catch {
        loadingSavedChannels = false;
        return;
      }
      loadingSavedChannels = false;
    }
    showSavedDropdown = true;
  }

  function useSaved(sc: any) {
    const type = sc.channel_type;
    const account = sc.account;
    addedChannels = [...addedChannels, { type, account }];
    const newValue = { ...value };
    if (!newValue[type]) newValue[type] = {};
    newValue[type][account] = { ...sc.config };
    onchange(newValue);
    showSavedDropdown = false;
  }
```

- [ ] **Step 2: Add "Use Saved" button in the template**

After the add-btn / add-picker section (after line 191, before the closing `</div>`), add:

```svelte
  {#if savedChannels.length > 0}
    <div class="saved-section">
      <button class="saved-btn" onclick={toggleSavedDropdown} disabled={loadingSavedChannels}>
        {loadingSavedChannels ? "Loading..." : showSavedDropdown ? "Close" : "Use Saved"}
      </button>
      {#if showSavedDropdown}
        <div class="saved-dropdown">
          {#each savedChannels as sc}
            <button class="saved-item" onclick={() => useSaved(sc)}>
              <span class="saved-name">{sc.name}</span>
              <span class="saved-type">{channelSchemas[sc.channel_type]?.label || sc.channel_type} / {sc.account}</span>
            </button>
          {/each}
        </div>
      {/if}
    </div>
  {/if}
```

- [ ] **Step 3: Add styles for the saved section**

Add to the `<style>` block:

```css
  .saved-section { position: relative; margin-top: 0.5rem; }
  .saved-btn {
    width: 100%;
    padding: 0.75rem;
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
    border: 1px dashed color-mix(in srgb, var(--accent) 40%, transparent);
    border-radius: 2px;
    color: var(--accent);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .saved-btn:hover:not(:disabled) {
    border-color: var(--accent);
    border-style: solid;
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    box-shadow: 0 0 8px var(--border-glow);
    text-shadow: var(--text-glow);
  }
  .saved-btn:disabled { opacity: 0.5; cursor: not-allowed; }
  .saved-dropdown {
    position: absolute;
    bottom: 100%;
    left: 0;
    right: 0;
    background: var(--bg-surface);
    border: 1px solid var(--accent);
    border-radius: 2px;
    max-height: 300px;
    overflow-y: auto;
    z-index: 10;
    box-shadow: 0 -4px 16px rgba(0, 0, 0, 0.3);
    margin-bottom: 4px;
  }
  .saved-item {
    display: flex;
    justify-content: space-between;
    align-items: center;
    width: 100%;
    padding: 0.75rem 1rem;
    background: none;
    border: none;
    border-bottom: 1px solid var(--border);
    color: var(--fg);
    cursor: pointer;
    transition: all 0.15s ease;
    font-family: var(--font-mono);
    font-size: 0.8rem;
  }
  .saved-item:last-child { border-bottom: none; }
  .saved-item:hover {
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    color: var(--accent);
  }
  .saved-name { font-weight: 700; }
  .saved-type { font-size: 0.7rem; color: var(--fg-dim); text-transform: uppercase; letter-spacing: 1px; }
```

- [ ] **Step 4: Commit**

```bash
git add ui/src/lib/components/ChannelList.svelte
git commit -m "feat(ui): add 'Use Saved' dropdown to ChannelList wizard"
```

---

## Chunk 4: Build & Verify

### Task 10: Build and verify everything compiles

- [ ] **Step 1: Run Zig tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | tail -20`
Expected: All tests pass.

- [ ] **Step 2: Run Zig build**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build 2>&1 | tail -10`
Expected: Clean build.

- [ ] **Step 3: Build frontend**

Run: `cd /Users/igorsomov/Code/null/nullhub/ui && npm run build 2>&1 | tail -20`
Expected: Clean build.

- [ ] **Step 4: Final commit if any fixups needed**

```bash
git add -A && git commit -m "fix: address build issues"
```
