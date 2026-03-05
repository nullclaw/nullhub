# Multi-Step Install Wizard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform the single-page install wizard into a 3-page stepper with live provider/channel validation gates between pages.

**Architecture:** The wizard gains `currentPage` state (0=Setup, 1=Channels, 2=Settings). Pages are derived from manifest step groups. Two new backend POST endpoints validate providers and channels by running the component binary with probe flags against a temp config directory. The frontend adds a ChannelList component and validation indicator UI.

**Tech Stack:** Zig backend (wizard.zig, server.zig), Svelte 5 frontend (runes syntax), TypeScript

---

### Task 1: Backend — Add validate-providers endpoint to wizard.zig

**Files:**
- Modify: `src/api/wizard.zig:22-64` (path parsing section)
- Modify: `src/api/wizard.zig` (add handler function at end, before tests)

**Step 1: Add path detection helpers**

Add these functions after `isVersionsPath` (line 64) in `src/api/wizard.zig`:

```zig
/// Check if this is a validate-providers request path.
pub fn isValidateProvidersPath(target: []const u8) bool {
    return std.mem.endsWith(u8, stripQuery(target), "/validate-providers");
}

/// Check if this is a validate-channels request path.
pub fn isValidateChannelsPath(target: []const u8) bool {
    return std.mem.endsWith(u8, stripQuery(target), "/validate-channels");
}
```

**Step 2: Update extractComponentName to handle new suffixes**

Add two new suffix blocks inside `extractComponentName`, after the `models_suffix` block (after line 43):

```zig
    const validate_providers_suffix = "/validate-providers";
    if (std.mem.endsWith(u8, rest, validate_providers_suffix)) {
        const component = rest[0 .. rest.len - validate_providers_suffix.len];
        if (component.len == 0) return null;
        if (std.mem.indexOfScalar(u8, component, '/') != null) return null;
        return component;
    }

    const validate_channels_suffix = "/validate-channels";
    if (std.mem.endsWith(u8, rest, validate_channels_suffix)) {
        const component = rest[0 .. rest.len - validate_channels_suffix.len];
        if (component.len == 0) return null;
        if (std.mem.indexOfScalar(u8, component, '/') != null) return null;
        return component;
    }
```

**Step 3: Add handleValidateProviders function**

Add before the tests section in `src/api/wizard.zig`. This creates a temp dir, writes a minimal config per provider, runs `--probe-provider-health`, and returns results:

```zig
const instances_api = @import("instances.zig");
const ProviderProbeResult = instances_api.ProviderProbeResult;

/// Handle POST /api/wizard/{component}/validate-providers
/// Accepts JSON: { "providers": [{ "provider": "openai", "api_key": "sk-...", "model": "gpt-4" }] }
/// Probes each provider using component binary --probe-provider-health.
/// Returns JSON: { "results": [{ "provider": "openai", "live_ok": true, "reason": "ok" }, ...] }
pub fn handleValidateProviders(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    const bin_path = findOrFetchComponentBinary(allocator, component_name, paths) orelse
        return allocator.dupe(u8, "{\"error\":\"component binary not found\"}") catch null;
    defer allocator.free(bin_path);

    // Parse the provider list from the request body
    const parsed = std.json.parseFromSlice(struct {
        providers: []const struct {
            provider: []const u8,
            api_key: []const u8 = "",
            model: []const u8 = "",
            base_url: []const u8 = "",
        },
    }, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;
    defer parsed.deinit();

    // Create temp directory for probes
    const tmp_dir = std.fmt.allocPrint(allocator, "/tmp/nullhub-wizard-validate-{d}", .{std.time.milliTimestamp()}) catch return null;
    defer {
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        allocator.free(tmp_dir);
    }
    std.fs.makeDirAbsolute(tmp_dir) catch return null;

    // Build results JSON
    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice("{\"results\":[") catch return null;

    for (parsed.value.providers, 0..) |prov, idx| {
        if (idx > 0) buf.append(',') catch return null;

        // Write a minimal config for this provider
        writeMinimalProviderConfig(allocator, tmp_dir, prov.provider, prov.api_key, prov.base_url) catch {
            appendProviderResult(&buf, prov.provider, false, "config_write_failed") catch return null;
            continue;
        };

        // Run probe
        const result = probeProviderViaComponentBinary(allocator, bin_path, tmp_dir, prov.provider, prov.model);
        appendProviderResult(&buf, prov.provider, result.live_ok, result.reason) catch return null;
    }

    buf.appendSlice("]}") catch return null;
    return buf.toOwnedSlice() catch null;
}

fn writeMinimalProviderConfig(
    allocator: std.mem.Allocator,
    dir: []const u8,
    provider: []const u8,
    api_key: []const u8,
    base_url: []const u8,
) !void {
    const config_path = try std.fmt.allocPrint(allocator, "{s}/config.json", .{dir});
    defer allocator.free(config_path);

    var cfg_buf = std.array_list.Managed(u8).init(allocator);
    defer cfg_buf.deinit();

    try cfg_buf.appendSlice("{\"models\":{\"providers\":{\"");
    try appendEscaped(&cfg_buf, provider);
    try cfg_buf.appendSlice("\":{\"api_key\":\"");
    try appendEscaped(&cfg_buf, api_key);
    try cfg_buf.appendSlice("\"");
    if (base_url.len > 0) {
        try cfg_buf.appendSlice(",\"base_url\":\"");
        try appendEscaped(&cfg_buf, base_url);
        try cfg_buf.appendSlice("\"");
    }
    try cfg_buf.appendSlice("}}}}");

    const file = try std.fs.createFileAbsolute(config_path, .{});
    defer file.close();
    try file.writeAll(cfg_buf.items);
}

fn probeProviderViaComponentBinary(
    allocator: std.mem.Allocator,
    binary_path: []const u8,
    instance_home: []const u8,
    provider: []const u8,
    model: []const u8,
) struct { live_ok: bool, reason: []const u8 } {
    const args: []const []const u8 = if (model.len > 0)
        &.{ "--probe-provider-health", "--provider", provider, "--model", model, "--timeout-secs", "10" }
    else
        &.{ "--probe-provider-health", "--provider", provider, "--timeout-secs", "10" };

    const result = component_cli.runWithNullclawHome(
        allocator,
        binary_path,
        args,
        null,
        instance_home,
    ) catch return .{ .live_ok = false, .reason = "probe_exec_failed" };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    const probe_parsed = std.json.parseFromSlice(struct {
        live_ok: bool = false,
        reason: ?[]const u8 = null,
    }, allocator, result.stdout, .{
        .allocate = .alloc_if_needed,
        .ignore_unknown_fields = true,
    }) catch return .{
        .live_ok = false,
        .reason = if (result.success) "invalid_probe_response" else "probe_exec_failed",
    };
    defer probe_parsed.deinit();

    const reason = probe_parsed.value.reason orelse (if (probe_parsed.value.live_ok) "ok" else "auth_check_failed");
    return .{ .live_ok = probe_parsed.value.live_ok, .reason = reason };
}

fn appendProviderResult(buf: *std.array_list.Managed(u8), provider: []const u8, live_ok: bool, reason: []const u8) !void {
    try buf.appendSlice("{\"provider\":\"");
    try appendEscaped(buf, provider);
    try buf.appendSlice("\",\"live_ok\":");
    try buf.appendSlice(if (live_ok) "true" else "false");
    try buf.appendSlice(",\"reason\":\"");
    try appendEscaped(buf, reason);
    try buf.appendSlice("\"}");
}
```

**Step 4: Add handleValidateChannels function**

Add after `handleValidateProviders` in `src/api/wizard.zig`:

```zig
/// Handle POST /api/wizard/{component}/validate-channels
/// Accepts JSON: { "channels": { "telegram": { "default": { "bot_token": "..." } } } }
/// Probes each channel using component binary --probe-channel-health.
/// Returns JSON: { "results": [{ "channel": "telegram", "account": "default", "live_ok": true, "reason": "ok" }, ...] }
pub fn handleValidateChannels(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    const bin_path = findOrFetchComponentBinary(allocator, component_name, paths) orelse
        return allocator.dupe(u8, "{\"error\":\"component binary not found\"}") catch null;
    defer allocator.free(bin_path);

    // Create temp directory for probes
    const tmp_dir = std.fmt.allocPrint(allocator, "/tmp/nullhub-wizard-validate-ch-{d}", .{std.time.milliTimestamp()}) catch return null;
    defer {
        std.fs.deleteTreeAbsolute(tmp_dir) catch {};
        allocator.free(tmp_dir);
    }
    std.fs.makeDirAbsolute(tmp_dir) catch return null;

    // Write the channels config to temp dir
    const config_path = std.fmt.allocPrint(allocator, "{s}/config.json", .{tmp_dir}) catch return null;
    defer allocator.free(config_path);
    {
        // Wrap body channels into a config structure: {"channels": ...}
        var cfg_buf = std.array_list.Managed(u8).init(allocator);
        defer cfg_buf.deinit();

        // Extract the "channels" value from the body and wrap it
        cfg_buf.appendSlice(body) catch return null;

        const file = std.fs.createFileAbsolute(config_path, .{}) catch return null;
        defer file.close();
        file.writeAll(cfg_buf.items) catch return null;
    }

    // Parse body to iterate channels and accounts
    var tree = std.json.parseFromSlice(std.json.Value, allocator, body, .{ .allocate = .alloc_always }) catch
        return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;
    defer tree.deinit();

    const channels_obj = switch (tree.value) {
        .object => |obj| obj.get("channels") orelse return allocator.dupe(u8, "{\"error\":\"missing channels field\"}") catch null,
        else => return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null,
    };
    const channels_map = switch (channels_obj) {
        .object => |obj| obj,
        else => return allocator.dupe(u8, "{\"error\":\"channels must be an object\"}") catch null,
    };

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buf.appendSlice("{\"results\":[") catch return null;

    var first = true;
    var ch_it = channels_map.iterator();
    while (ch_it.next()) |ch_entry| {
        const channel_type = ch_entry.key_ptr.*;
        const accounts = switch (ch_entry.value_ptr.*) {
            .object => |obj| obj,
            else => continue,
        };

        var acc_it = accounts.iterator();
        while (acc_it.next()) |acc_entry| {
            const account_name = acc_entry.key_ptr.*;
            if (!first) buf.append(',') catch return null;
            first = false;

            // Run --probe-channel-health
            const result = component_cli.runWithNullclawHome(
                allocator,
                bin_path,
                &.{ "--probe-channel-health", "--channel", channel_type, "--account", account_name, "--timeout-secs", "10" },
                null,
                tmp_dir,
            ) catch {
                appendChannelResult(&buf, channel_type, account_name, false, "probe_exec_failed") catch return null;
                continue;
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            const probe_parsed = std.json.parseFromSlice(struct {
                live_ok: bool = false,
                reason: ?[]const u8 = null,
            }, allocator, result.stdout, .{
                .allocate = .alloc_if_needed,
                .ignore_unknown_fields = true,
            }) catch {
                appendChannelResult(&buf, channel_type, account_name, false, "invalid_probe_response") catch return null;
                continue;
            };
            defer probe_parsed.deinit();

            const reason = probe_parsed.value.reason orelse (if (probe_parsed.value.live_ok) "ok" else "probe_failed");
            appendChannelResult(&buf, channel_type, account_name, probe_parsed.value.live_ok, reason) catch return null;
        }
    }

    buf.appendSlice("]}") catch return null;
    return buf.toOwnedSlice() catch null;
}

fn appendChannelResult(buf: *std.array_list.Managed(u8), channel: []const u8, account: []const u8, live_ok: bool, reason: []const u8) !void {
    try buf.appendSlice("{\"channel\":\"");
    try appendEscaped(buf, channel);
    try buf.appendSlice("\",\"account\":\"");
    try appendEscaped(buf, account);
    try buf.appendSlice("\",\"live_ok\":");
    try buf.appendSlice(if (live_ok) "true" else "false");
    try buf.appendSlice(",\"reason\":\"");
    try appendEscaped(buf, reason);
    try buf.appendSlice("\"}");
}
```

**Step 5: Add tests for new path helpers**

Add in the test section of `src/api/wizard.zig`:

```zig
test "isValidateProvidersPath detects validate-providers suffix" {
    try std.testing.expect(isValidateProvidersPath("/api/wizard/nullclaw/validate-providers"));
    try std.testing.expect(!isValidateProvidersPath("/api/wizard/nullclaw"));
    try std.testing.expect(!isValidateProvidersPath("/api/wizard/nullclaw/models"));
}

test "isValidateChannelsPath detects validate-channels suffix" {
    try std.testing.expect(isValidateChannelsPath("/api/wizard/nullclaw/validate-channels"));
    try std.testing.expect(!isValidateChannelsPath("/api/wizard/nullclaw"));
    try std.testing.expect(!isValidateChannelsPath("/api/wizard/nullclaw/models"));
}

test "extractComponentName parses validate-providers path" {
    const name = extractComponentName("/api/wizard/nullclaw/validate-providers");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("nullclaw", name.?);
}

test "extractComponentName parses validate-channels path" {
    const name = extractComponentName("/api/wizard/nullclaw/validate-channels");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("nullclaw", name.?);
}
```

Update the existing `isWizardPath` test to include the new paths:

```zig
    try std.testing.expect(isWizardPath("/api/wizard/nullclaw/validate-providers"));
    try std.testing.expect(isWizardPath("/api/wizard/nullclaw/validate-channels"));
```

**Step 6: Run tests**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | head -30`
Expected: All wizard.zig tests PASS

**Step 7: Commit**

```bash
git add src/api/wizard.zig
git commit -m "feat: add validate-providers and validate-channels wizard endpoints"
```

---

### Task 2: Backend — Wire new endpoints in server.zig

**Files:**
- Modify: `src/server.zig:480-567` (wizard routing section)

**Step 1: Add routing for validate-providers and validate-channels**

Insert before the versions API block (before line 485 in `src/server.zig`):

```zig
        // Validate Providers API — POST /api/wizard/{component}/validate-providers
        if (std.mem.eql(u8, method, "POST") and wizard_api.isValidateProvidersPath(target)) {
            if (wizard_api.extractComponentName(target)) |comp_name| {
                if (wizard_api.handleValidateProviders(allocator, comp_name, body, self.paths)) |json| {
                    const status = if (std.mem.indexOf(u8, json, "\"error\"") != null)
                        "400 Bad Request"
                    else
                        "200 OK";
                    return .{
                        .status = status,
                        .content_type = "application/json",
                        .body = json,
                    };
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"component not found\"}",
                };
            }
        }

        // Validate Channels API — POST /api/wizard/{component}/validate-channels
        if (std.mem.eql(u8, method, "POST") and wizard_api.isValidateChannelsPath(target)) {
            if (wizard_api.extractComponentName(target)) |comp_name| {
                if (wizard_api.handleValidateChannels(allocator, comp_name, body, self.paths)) |json| {
                    const status = if (std.mem.indexOf(u8, json, "\"error\"") != null)
                        "400 Bad Request"
                    else
                        "200 OK";
                    return .{
                        .status = status,
                        .content_type = "application/json",
                        .body = json,
                    };
                }
                return .{
                    .status = "404 Not Found",
                    .content_type = "application/json",
                    .body = "{\"error\":\"component not found\"}",
                };
            }
        }
```

**Step 2: Build to verify compilation**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build 2>&1 | head -20`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add src/server.zig
git commit -m "feat: wire validate-providers and validate-channels routes in server"
```

---

### Task 3: Frontend — Add API client methods

**Files:**
- Modify: `ui/src/lib/api/client.ts:67-77`

**Step 1: Add validateProviders and validateChannels methods**

Add before the closing `};` in `ui/src/lib/api/client.ts`:

```typescript
  validateProviders: (component: string, providers: any[]) =>
    request<any>(`/wizard/${component}/validate-providers`, {
      method: 'POST',
      body: JSON.stringify({ providers }),
    }),

  validateChannels: (component: string, channels: Record<string, any>) =>
    request<any>(`/wizard/${component}/validate-channels`, {
      method: 'POST',
      body: JSON.stringify({ channels }),
    }),
```

**Step 2: Commit**

```bash
git add ui/src/lib/api/client.ts
git commit -m "feat: add validateProviders and validateChannels API client methods"
```

---

### Task 4: Frontend — Add validation indicators to ProviderList.svelte

**Files:**
- Modify: `ui/src/lib/components/ProviderList.svelte`

**Step 1: Add validation state props and indicator UI**

Add `validationResults` prop and status indicator rendering. The parent (WizardRenderer) will manage the validation state and pass results down.

Update the script section to accept validation results:

```typescript
let {
    providers = [],
    value = "[]",
    onchange = (v: string) => {},
    component = "",
    validationResults = [] as Array<{ provider: string; live_ok: boolean; reason: string }>,
  } = $props();
```

Add a status indicator in each provider row header, after the provider number span:

```svelte
{@const result = validationResults.find((r: any) => r.provider === entry.provider)}
{#if result}
  <span class="status-dot" class:ok={result.live_ok} class:error={!result.live_ok}
    title={result.reason}></span>
{/if}
```

Add styles:

```css
.status-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    flex-shrink: 0;
}
.status-dot.ok {
    background: var(--success, #4a4);
    box-shadow: 0 0 6px var(--success, #4a4);
}
.status-dot.error {
    background: var(--error, #e55);
    box-shadow: 0 0 6px var(--error, #e55);
}
```

**Step 2: Commit**

```bash
git add ui/src/lib/components/ProviderList.svelte
git commit -m "feat: add validation status indicators to ProviderList"
```

---

### Task 5: Frontend — Create ChannelList.svelte

**Files:**
- Create: `ui/src/lib/components/ChannelList.svelte`

**Step 1: Create the component**

This component shows WEB and CLI as default-on toggles, provides "+ Add Channel" for adding other channels (Telegram, Discord, etc.), renders config fields from `configSchemas.ts`, and displays validation indicators.

```svelte
<script lang="ts">
  import { channelSchemas, type ChannelSchema, type FieldDef } from './configSchemas';

  let {
    value = {} as Record<string, Record<string, Record<string, any>>>,
    onchange = (v: Record<string, Record<string, Record<string, any>>>) => {},
    validationResults = [] as Array<{ channel: string; account: string; live_ok: boolean; reason: string }>,
  } = $props();

  // Default channels that are always shown as toggles
  const DEFAULT_CHANNELS = ['web', 'cli'];

  // Channels the user has added
  let addedChannels = $state<Array<{ type: string; account: string }>>([]);
  let showAddPicker = $state(false);

  // Initialize from value prop
  $effect(() => {
    const entries: Array<{ type: string; account: string }> = [];
    for (const [type, accounts] of Object.entries(value)) {
      if (DEFAULT_CHANNELS.includes(type)) continue;
      for (const account of Object.keys(accounts)) {
        entries.push({ type, account });
      }
    }
    if (entries.length > 0 && addedChannels.length === 0) {
      addedChannels = entries;
    }
  });

  // Available channel types for adding (exclude defaults and already-added single-account channels)
  let availableChannelTypes = $derived(
    Object.entries(channelSchemas)
      .filter(([key]) => !DEFAULT_CHANNELS.includes(key))
      .map(([key, schema]) => ({ key, label: schema.label }))
  );

  function addChannel(type: string) {
    const schema = channelSchemas[type];
    const account = schema?.hasAccounts ? 'default' : type;
    addedChannels = [...addedChannels, { type, account }];
    // Init empty config for this channel
    const newValue = { ...value };
    if (!newValue[type]) newValue[type] = {};
    if (!newValue[type][account]) {
      const defaults: Record<string, any> = {};
      for (const field of schema?.fields || []) {
        if (field.default !== undefined) defaults[field.key] = field.default;
      }
      newValue[type][account] = defaults;
    }
    onchange(newValue);
    showAddPicker = false;
  }

  function removeChannel(index: number) {
    const entry = addedChannels[index];
    addedChannels = addedChannels.filter((_, i) => i !== index);
    const newValue = { ...value };
    if (newValue[entry.type]?.[entry.account]) {
      delete newValue[entry.type][entry.account];
      if (Object.keys(newValue[entry.type]).length === 0) {
        delete newValue[entry.type];
      }
    }
    onchange(newValue);
  }

  function updateField(type: string, account: string, key: string, val: any) {
    const newValue = { ...value };
    if (!newValue[type]) newValue[type] = {};
    if (!newValue[type][account]) newValue[type][account] = {};
    newValue[type][account] = { ...newValue[type][account], [key]: val };
    onchange(newValue);
  }

  function getFieldValue(type: string, account: string, key: string, def: any): any {
    return value[type]?.[account]?.[key] ?? def ?? '';
  }

  function getValidationResult(type: string, account: string) {
    return validationResults.find((r: any) => r.channel === type && r.account === account);
  }
</script>

<div class="channel-list">
  <div class="step-title">Channels</div>
  <p class="step-description">
    Configure communication channels. WEB and CLI are enabled by default.
  </p>

  <!-- Default channels as toggles -->
  {#each DEFAULT_CHANNELS as ch}
    <div class="channel-default">
      <label class="toggle-row">
        <input type="checkbox" checked disabled />
        <span class="channel-label">{channelSchemas[ch]?.label || ch.toUpperCase()}</span>
        <span class="default-badge">default</span>
      </label>
    </div>
  {/each}

  <!-- Added channels with config forms -->
  {#each addedChannels as entry, i}
    {@const schema = channelSchemas[entry.type]}
    {@const result = getValidationResult(entry.type, entry.account)}
    <div class="channel-row">
      <div class="channel-row-header">
        {#if result}
          <span class="status-dot" class:ok={result.live_ok} class:error={!result.live_ok}
            title={result.reason}></span>
        {/if}
        <span class="channel-name">{schema?.label || entry.type}</span>
        {#if schema?.hasAccounts}
          <span class="account-name">{entry.account}</span>
        {/if}
        <button class="icon-btn remove-btn" onclick={() => removeChannel(i)} title="Remove">&#215;</button>
      </div>

      <div class="channel-fields">
        {#each schema?.fields || [] as field}
          <div class="channel-field">
            <label for={`ch-${entry.type}-${entry.account}-${field.key}`}>
              {field.label}
              {#if field.hint}
                <span class="field-hint">{field.hint}</span>
              {/if}
            </label>

            {#if field.type === 'password'}
              <input
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                type="password"
                value={getFieldValue(entry.type, entry.account, field.key, field.default)}
                oninput={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.value)}
                placeholder="Enter value..."
              />
            {:else if field.type === 'number'}
              <input
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                type="number"
                value={getFieldValue(entry.type, entry.account, field.key, field.default)}
                oninput={(e) => updateField(entry.type, entry.account, field.key, Number(e.currentTarget.value))}
                min={field.min}
                max={field.max}
                step={field.step}
              />
            {:else if field.type === 'toggle'}
              <label class="toggle">
                <input
                  type="checkbox"
                  checked={getFieldValue(entry.type, entry.account, field.key, field.default) === true}
                  onchange={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.checked)}
                />
                <span class="toggle-slider"></span>
              </label>
            {:else if field.type === 'select'}
              <select
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                value={getFieldValue(entry.type, entry.account, field.key, field.default)}
                onchange={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.value)}
              >
                {#each field.options || [] as opt}
                  <option value={opt}>{opt}</option>
                {/each}
              </select>
            {:else if field.type === 'list'}
              <input
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                type="text"
                value={(getFieldValue(entry.type, entry.account, field.key, field.default) || []).join(', ')}
                oninput={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.value.split(',').map((s: string) => s.trim()).filter(Boolean))}
                placeholder={field.hint || "Comma-separated values..."}
              />
            {:else}
              <input
                id={`ch-${entry.type}-${entry.account}-${field.key}`}
                type="text"
                value={getFieldValue(entry.type, entry.account, field.key, field.default)}
                oninput={(e) => updateField(entry.type, entry.account, field.key, e.currentTarget.value)}
                placeholder={field.hint || "Enter value..."}
              />
            {/if}
          </div>
        {/each}
      </div>
    </div>
  {/each}

  <!-- Add channel picker -->
  {#if showAddPicker}
    <div class="add-picker">
      {#each availableChannelTypes as ct}
        <button class="picker-option" onclick={() => addChannel(ct.key)}>
          {ct.label}
        </button>
      {/each}
      <button class="picker-cancel" onclick={() => (showAddPicker = false)}>Cancel</button>
    </div>
  {:else}
    <button class="add-btn" onclick={() => (showAddPicker = true)}>+ Add Channel</button>
  {/if}
</div>

<style>
  .channel-list { margin-bottom: 2rem; }

  .step-title {
    display: block;
    font-size: 0.9rem;
    font-weight: 700;
    color: var(--accent);
    margin-bottom: 0.25rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    text-shadow: var(--text-glow);
  }

  .step-description {
    font-size: 0.8rem;
    color: var(--fg-dim);
    margin-bottom: 1rem;
    font-family: var(--font-mono);
  }

  .channel-default {
    padding: 0.75rem 1rem;
    margin-bottom: 0.5rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    display: flex;
    align-items: center;
    opacity: 0.7;
  }

  .toggle-row {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    cursor: default;
  }

  .toggle-row input[type="checkbox"] { accent-color: var(--accent); }

  .channel-label {
    font-size: 0.875rem;
    font-weight: 700;
    color: var(--fg);
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .default-badge {
    font-size: 0.65rem;
    font-weight: 700;
    background: color-mix(in srgb, var(--fg-dim) 20%, transparent);
    color: var(--fg-dim);
    border: 1px solid var(--border);
    padding: 0.1rem 0.35rem;
    border-radius: 2px;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .channel-row {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 1rem;
    margin-bottom: 0.75rem;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
    transition: all 0.2s ease;
  }

  .channel-row:hover {
    border-color: color-mix(in srgb, var(--accent) 50%, transparent);
    box-shadow: 0 0 10px rgba(0, 0, 0, 0.2);
  }

  .channel-row-header {
    display: flex;
    align-items: center;
    gap: 0.75rem;
    margin-bottom: 0.75rem;
  }

  .channel-name {
    font-weight: 700;
    font-size: 0.875rem;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 1px;
    text-shadow: var(--text-glow);
    flex: 1;
  }

  .account-name {
    font-size: 0.75rem;
    color: var(--fg-dim);
    font-family: var(--font-mono);
  }

  .channel-fields { display: flex; flex-direction: column; gap: 0.75rem; }

  .channel-field label {
    display: block;
    font-size: 0.75rem;
    color: var(--fg-dim);
    margin-bottom: 0.35rem;
    text-transform: uppercase;
    letter-spacing: 1px;
    font-weight: 700;
  }

  .field-hint {
    font-weight: 400;
    font-size: 0.65rem;
    color: color-mix(in srgb, var(--fg-dim) 70%, transparent);
    letter-spacing: 0;
    text-transform: none;
    margin-left: 0.5rem;
  }

  .channel-field input,
  .channel-field select {
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

  .channel-field input:focus,
  .channel-field select:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .status-dot {
    width: 10px;
    height: 10px;
    border-radius: 50%;
    flex-shrink: 0;
  }
  .status-dot.ok {
    background: var(--success, #4a4);
    box-shadow: 0 0 6px var(--success, #4a4);
  }
  .status-dot.error {
    background: var(--error, #e55);
    box-shadow: 0 0 6px var(--error, #e55);
  }

  .icon-btn {
    width: 32px;
    height: 32px;
    display: flex;
    align-items: center;
    justify-content: center;
    background: color-mix(in srgb, var(--bg-surface) 80%, transparent);
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--fg-dim);
    font-size: 1rem;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .remove-btn:hover {
    background: color-mix(in srgb, var(--error, #e55) 15%, transparent);
    border-color: var(--error, #e55);
    color: var(--error, #e55);
    box-shadow: 0 0 5px color-mix(in srgb, var(--error, #e55) 50%, transparent);
  }

  .add-picker {
    display: flex;
    flex-wrap: wrap;
    gap: 0.5rem;
    padding: 1rem;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
  }

  .picker-option {
    padding: 0.5rem 0.75rem;
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
    border: 1px solid var(--border);
    border-radius: 2px;
    color: var(--fg);
    font-size: 0.8rem;
    font-family: var(--font-mono);
    cursor: pointer;
    transition: all 0.2s ease;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .picker-option:hover {
    border-color: var(--accent);
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    box-shadow: 0 0 8px var(--border-glow);
    text-shadow: var(--text-glow);
  }

  .picker-cancel {
    padding: 0.5rem 0.75rem;
    background: none;
    border: 1px dashed var(--border);
    border-radius: 2px;
    color: var(--fg-dim);
    font-size: 0.8rem;
    cursor: pointer;
    text-transform: uppercase;
    letter-spacing: 1px;
  }
  .picker-cancel:hover { border-color: var(--fg-dim); color: var(--fg); }

  .add-btn {
    width: 100%;
    padding: 0.75rem;
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
    border: 1px dashed color-mix(in srgb, var(--border) 60%, transparent);
    border-radius: 2px;
    color: var(--fg-dim);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    transition: all 0.2s ease;
  }
  .add-btn:hover {
    border-color: var(--accent);
    border-style: solid;
    color: var(--accent);
    background: color-mix(in srgb, var(--accent) 10%, transparent);
    box-shadow: 0 0 8px var(--border-glow);
    text-shadow: var(--text-glow);
  }

  /* Toggle (reused from WizardStep) */
  .toggle {
    position: relative;
    display: inline-block;
    width: 44px;
    height: 24px;
    cursor: pointer;
  }
  .toggle input { opacity: 0; width: 0; height: 0; }
  .toggle-slider {
    position: absolute;
    inset: 0;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.5);
  }
  .toggle-slider::before {
    content: "";
    position: absolute;
    width: 16px;
    height: 16px;
    left: 4px;
    top: 3px;
    background: var(--fg-dim);
    border-radius: 2px;
    transition: all 0.2s ease;
  }
  .toggle input:checked + .toggle-slider {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    border-color: var(--accent);
    box-shadow: inset 0 0 10px color-mix(in srgb, var(--accent) 30%, transparent);
  }
  .toggle input:checked + .toggle-slider::before {
    transform: translateX(18px);
    background: var(--accent);
    box-shadow: 0 0 5px var(--border-glow);
  }
</style>
```

**Step 2: Commit**

```bash
git add ui/src/lib/components/ChannelList.svelte
git commit -m "feat: create ChannelList component with schema-driven config forms"
```

---

### Task 6: Frontend — Refactor WizardRenderer into multi-step wizard

**Files:**
- Modify: `ui/src/lib/components/WizardRenderer.svelte` (full rewrite)

**Step 1: Rewrite WizardRenderer.svelte**

Replace the entire file with a multi-step wizard that has:
- Step indicator at the top (3 steps: Setup, Channels, Settings)
- Page 0: Instance name + version + ProviderList
- Page 1: ChannelList
- Page 2: Remaining manifest steps with collapsible Advanced section
- Back/Next/Install navigation
- Validation on Next for pages 0 and 1

```svelte
<script lang="ts">
  import WizardStep from "./WizardStep.svelte";
  import ProviderList from "./ProviderList.svelte";
  import ChannelList from "./ChannelList.svelte";
  import { api } from "$lib/api/client";

  let {
    component = "",
    steps = [],
    onComplete,
  } = $props<{
    component: string;
    steps: any[];
    onComplete?: () => void;
  }>();

  let answers = $state<Record<string, string>>({});
  let instanceName = $state("");
  let currentPage = $state(0);
  let installing = $state(false);
  let installMessage = $state("");
  let versions = $state<any[]>([]);
  let selectedVersion = $state("latest");
  let channels = $state<Record<string, Record<string, Record<string, any>>>>({});
  const instanceNameId = "wizard-instance-name";

  // Validation state
  let validating = $state(false);
  let providerValidationResults = $state<any[]>([]);
  let channelValidationResults = $state<any[]>([]);
  let validationError = $state("");

  const PAGE_LABELS = ["Setup", "Channels", "Settings"];

  // Auto-generate instance name on mount
  $effect(() => {
    if (component && !instanceName) {
      api
        .getInstances()
        .then((data: any) => {
          const existing = data?.instances?.[component] || {};
          const names = Object.keys(existing);
          let id = 1;
          while (names.includes(`instance-${id}`)) id++;
          instanceName = `instance-${id}`;
        })
        .catch(() => {
          instanceName = "instance-1";
        });
    }
  });

  // Fetch available versions
  $effect(() => {
    if (component) {
      api
        .getVersions(component)
        .then((data: any) => {
          versions = Array.isArray(data) ? data : [];
          if (versions.length > 0) {
            const rec = versions.find((v: any) => v.recommended);
            selectedVersion = rec?.value || versions[0].value;
          }
        })
        .catch(() => {
          versions = [{ value: "latest", label: "latest", recommended: true }];
          selectedVersion = "latest";
        });
    }
  });

  // Apply default values from steps
  $effect(() => {
    for (const step of steps) {
      if (step.default_value && !(step.id in answers)) {
        answers[step.id] = step.default_value;
      } else if (step.options?.length && !(step.id in answers)) {
        const rec = step.options.find((o: any) => o.recommended);
        if (rec) answers[step.id] = rec.value;
      }
    }
  });

  // Initialize default provider entry when provider step exists
  $effect(() => {
    if (!("_providers" in answers)) {
      const providerStep = steps.find((s) => s.id === "provider");
      if (providerStep) {
        const rec = providerStep.options?.find((o: any) => o.recommended);
        const defaultProvider =
          rec?.value || providerStep.options?.[0]?.value || "";
        answers["_providers"] = JSON.stringify([
          { provider: defaultProvider, api_key: "", model: "" },
        ]);
      }
    }
  });

  function isStepVisible(step: any): boolean {
    if (!step.condition) return true;
    const ref = answers[step.condition.step] || "";
    if (step.condition.equals) return ref === step.condition.equals;
    if (step.condition.not_equals) return ref !== step.condition.not_equals;
    if (step.condition.contains)
      return ref.split(",").includes(step.condition.contains);
    if (step.condition.not_in) {
      const excluded = step.condition.not_in.split(",");
      return !excluded.includes(ref);
    }
    return true;
  }

  // Steps for page 2 (settings): non-provider, non-channel steps
  let settingsSteps = $derived(
    steps.filter(
      (s) =>
        s.id !== "provider" &&
        s.id !== "api_key" &&
        s.id !== "model" &&
        s.group !== "providers" &&
        s.group !== "channels" &&
        !s.advanced &&
        isStepVisible(s),
    ),
  );

  let advancedSteps = $derived(
    steps.filter(
      (s) =>
        s.advanced &&
        s.id !== "provider" &&
        s.id !== "api_key" &&
        s.id !== "model" &&
        isStepVisible(s),
    ),
  );

  let showAdvanced = $state(false);

  // Provider step for getting provider options
  let providerStep = $derived(steps.find((s) => s.id === "provider"));

  // Check if all providers validated successfully
  let allProvidersValid = $derived(
    providerValidationResults.length > 0 &&
      providerValidationResults.every((r: any) => r.live_ok),
  );

  // Check if all channels validated successfully
  let allChannelsValid = $derived(
    channelValidationResults.length > 0 &&
      channelValidationResults.every((r: any) => r.live_ok),
  );

  // Whether we can proceed from current page
  let canProceed = $derived(
    currentPage === 0
      ? !!instanceName
      : currentPage === 1
        ? true
        : true,
  );

  async function validateProviders(): Promise<boolean> {
    validating = true;
    validationError = "";
    providerValidationResults = [];

    try {
      const providers = JSON.parse(answers["_providers"] || "[]");
      if (providers.length === 0) {
        validationError = "Add at least one provider";
        return false;
      }
      const result = await api.validateProviders(component, providers);
      providerValidationResults = result.results || [];
      return providerValidationResults.every((r: any) => r.live_ok);
    } catch (e) {
      validationError = `Validation failed: ${(e as Error).message}`;
      return false;
    } finally {
      validating = false;
    }
  }

  async function validateChannels(): Promise<boolean> {
    validating = true;
    validationError = "";
    channelValidationResults = [];

    // Check if there are any non-default channels to validate
    const hasNonDefaultChannels = Object.keys(channels).some(
      (k) => k !== "web" && k !== "cli",
    );
    if (!hasNonDefaultChannels) {
      // No custom channels to validate, skip
      validating = false;
      return true;
    }

    try {
      const result = await api.validateChannels(component, channels);
      channelValidationResults = result.results || [];
      return channelValidationResults.every((r: any) => r.live_ok);
    } catch (e) {
      validationError = `Validation failed: ${(e as Error).message}`;
      return false;
    } finally {
      validating = false;
    }
  }

  async function handleNext() {
    if (currentPage === 0) {
      const valid = await validateProviders();
      if (valid) {
        currentPage = 1;
        validationError = "";
      }
    } else if (currentPage === 1) {
      const valid = await validateChannels();
      if (valid) {
        currentPage = 2;
        validationError = "";
      }
    }
  }

  function handleBack() {
    if (currentPage > 0) {
      currentPage -= 1;
      validationError = "";
    }
  }

  async function submit() {
    installing = true;
    installMessage = "Installing...";
    try {
      const { _providers, ...rest } = answers;
      const payload: any = {
        instance_name: instanceName,
        version: selectedVersion,
        ...rest,
      };
      if (_providers) {
        try {
          const parsed = JSON.parse(_providers);
          payload.providers = parsed;
          if (parsed.length > 0) {
            if (!payload.api_key && parsed[0].api_key)
              payload.api_key = parsed[0].api_key;
            if (!payload.model && parsed[0].model)
              payload.model = parsed[0].model;
          }
        } catch {}
      }
      // Include channels
      if (Object.keys(channels).length > 0) {
        payload.channels = channels;
      }
      const result = await api.postWizard(component, payload);
      installMessage = result.message || "Installation complete!";
      setTimeout(() => onComplete?.(), 1500);
    } catch (e) {
      installMessage = `Error: ${(e as Error).message}`;
    } finally {
      installing = false;
    }
  }
</script>

<div class="wizard">
  <div class="wizard-header">
    <h2>Install {component}</h2>
    <div class="step-indicator">
      {#each PAGE_LABELS as label, i}
        <button
          class="step-dot"
          class:active={currentPage === i}
          class:completed={currentPage > i}
          disabled={i > currentPage}
          onclick={() => { if (i < currentPage) currentPage = i; }}
        >
          <span class="step-num">{i + 1}</span>
          <span class="step-label">{label}</span>
        </button>
        {#if i < PAGE_LABELS.length - 1}
          <div class="step-line" class:completed={currentPage > i}></div>
        {/if}
      {/each}
    </div>
  </div>

  <div class="wizard-body">
    {#if currentPage === 0}
      <!-- Page 0: Setup -->
      <div class="name-step">
        <label for={instanceNameId}>Instance Name</label>
        <p class="name-hint">Name doesn't matter, just needs to be unique</p>
        <input
          id={instanceNameId}
          type="text"
          bind:value={instanceName}
          placeholder="instance-1"
        />
      </div>

      {#if versions.length > 1}
        <WizardStep
          step={{
            id: "_version",
            title: "Version",
            description: "Select the version to install",
            type: "select",
            options: versions,
          }}
          value={selectedVersion}
          onchange={(v) => (selectedVersion = v)}
        />
      {/if}

      {#if providerStep}
        <ProviderList
          providers={providerStep.options || []}
          value={answers["_providers"] || "[]"}
          onchange={(v) => (answers["_providers"] = v)}
          {component}
          validationResults={providerValidationResults}
        />
      {/if}
    {:else if currentPage === 1}
      <!-- Page 1: Channels -->
      <ChannelList
        value={channels}
        onchange={(v) => (channels = v)}
        validationResults={channelValidationResults}
      />
    {:else}
      <!-- Page 2: Settings -->
      {#each settingsSteps as step}
        <WizardStep
          {step}
          value={answers[step.id] || ""}
          onchange={(v) => (answers[step.id] = v)}
        />
      {/each}

      {#if advancedSteps.length > 0}
        <button class="advanced-toggle" onclick={() => (showAdvanced = !showAdvanced)}>
          <span class="advanced-arrow">{showAdvanced ? "&#9660;" : "&#9654;"}</span>
          Advanced
        </button>

        {#if showAdvanced}
          <div class="advanced-section">
            {#each advancedSteps as step}
              <WizardStep
                {step}
                value={answers[step.id] || ""}
                onchange={(v) => (answers[step.id] = v)}
              />
            {/each}
          </div>
        {/if}
      {/if}
    {/if}
  </div>

  {#if validationError}
    <div class="validation-error">{validationError}</div>
  {/if}

  {#if installMessage}
    <div class="install-message">{installMessage}</div>
  {/if}

  <div class="wizard-footer">
    {#if currentPage > 0}
      <button class="secondary-btn" onclick={handleBack} disabled={validating || installing}>
        Back
      </button>
    {/if}
    <div class="footer-spacer"></div>
    {#if currentPage < 2}
      <button
        class="primary-btn"
        onclick={handleNext}
        disabled={validating || !canProceed}
      >
        {validating ? "Validating..." : "Next"}
      </button>
    {:else}
      <button
        class="primary-btn"
        onclick={submit}
        disabled={installing || !instanceName}
      >
        {installing ? "Installing..." : "Install"}
      </button>
    {/if}
  </div>
</div>

<style>
  .wizard {
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 4px;
    overflow: hidden;
    backdrop-filter: blur(4px);
    box-shadow: 0 0 10px rgba(0, 0, 0, 0.5);
  }

  .wizard-header {
    padding: 1.5rem;
    border-bottom: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
  }

  .wizard-header h2 {
    font-size: 1.25rem;
    font-weight: 700;
    color: var(--accent);
    text-transform: uppercase;
    letter-spacing: 2px;
    text-shadow: var(--text-glow);
    margin-bottom: 1rem;
  }

  .step-indicator {
    display: flex;
    align-items: center;
    gap: 0;
  }

  .step-dot {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    background: none;
    border: none;
    color: var(--fg-dim);
    cursor: pointer;
    padding: 0.25rem 0;
    transition: all 0.2s ease;
  }

  .step-dot:disabled { cursor: default; }

  .step-dot.active .step-num,
  .step-dot.completed .step-num {
    background: color-mix(in srgb, var(--accent) 30%, transparent);
    border-color: var(--accent);
    color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
    text-shadow: var(--text-glow);
  }

  .step-dot.active .step-label { color: var(--accent); text-shadow: var(--text-glow); }
  .step-dot.completed .step-label { color: var(--fg); }

  .step-num {
    width: 28px;
    height: 28px;
    border-radius: 50%;
    border: 1px solid var(--border);
    display: flex;
    align-items: center;
    justify-content: center;
    font-size: 0.75rem;
    font-weight: 700;
    font-family: var(--font-mono);
    transition: all 0.2s ease;
  }

  .step-label {
    font-size: 0.75rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    transition: all 0.2s ease;
  }

  .step-line {
    flex: 1;
    height: 1px;
    background: var(--border);
    margin: 0 0.75rem;
    transition: all 0.2s ease;
  }
  .step-line.completed { background: var(--accent); box-shadow: 0 0 4px var(--border-glow); }

  .wizard-body { padding: 1.75rem 1.5rem; }

  .name-step { margin-bottom: 2rem; }

  .name-step label {
    display: block;
    font-size: 0.8125rem;
    font-weight: 700;
    color: var(--fg-dim);
    margin-bottom: 0.25rem;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .name-hint {
    font-size: 0.75rem;
    color: color-mix(in srgb, var(--fg-dim) 70%, transparent);
    margin-bottom: 0.5rem;
    font-family: var(--font-mono);
  }

  .name-step input {
    width: 100%;
    background: var(--bg-surface);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 0.625rem 0.875rem;
    color: var(--fg);
    font-size: 0.875rem;
    font-family: var(--font-mono);
    outline: none;
    transition: all 0.2s ease;
    box-shadow: inset 0 2px 4px rgba(0, 0, 0, 0.2);
  }

  .name-step input:focus {
    border-color: var(--accent);
    box-shadow: 0 0 8px var(--border-glow);
  }

  .advanced-toggle {
    display: flex;
    align-items: center;
    gap: 0.5rem;
    background: none;
    border: 1px dashed color-mix(in srgb, var(--border) 60%, transparent);
    border-radius: 2px;
    padding: 0.625rem 1rem;
    color: var(--fg-dim);
    font-size: 0.8125rem;
    font-weight: 700;
    text-transform: uppercase;
    letter-spacing: 1px;
    cursor: pointer;
    width: 100%;
    transition: all 0.2s ease;
    margin-top: 1rem;
  }
  .advanced-toggle:hover {
    border-color: var(--accent);
    color: var(--accent);
    text-shadow: var(--text-glow);
  }
  .advanced-arrow { font-size: 0.65rem; }

  .advanced-section {
    margin-top: 1rem;
    padding: 1rem;
    border: 1px solid color-mix(in srgb, var(--border) 40%, transparent);
    border-radius: 2px;
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
  }

  .validation-error {
    padding: 0.75rem 1.5rem;
    font-size: 0.8125rem;
    color: var(--error, #e55);
    border-top: 1px dashed color-mix(in srgb, var(--error, #e55) 30%, transparent);
    background: color-mix(in srgb, var(--error, #e55) 5%, transparent);
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 1px;
  }

  .install-message {
    padding: 1rem 1.5rem;
    font-size: 0.875rem;
    color: var(--accent);
    border-top: 1px dashed color-mix(in srgb, var(--border) 50%, transparent);
    background: color-mix(in srgb, var(--accent) 5%, transparent);
    font-weight: bold;
    text-transform: uppercase;
    letter-spacing: 1px;
    text-shadow: var(--text-glow);
  }

  .wizard-footer {
    padding: 1.25rem 1.5rem;
    border-top: 1px solid color-mix(in srgb, var(--border) 50%, transparent);
    display: flex;
    align-items: center;
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
  }

  .footer-spacer { flex: 1; }

  .primary-btn {
    background: color-mix(in srgb, var(--accent) 20%, transparent);
    color: var(--accent);
    border: 1px solid var(--accent);
    border-radius: 2px;
    padding: 0.75rem 2rem;
    font-size: 0.875rem;
    font-weight: 700;
    cursor: pointer;
    transition: all 0.2s ease;
    text-transform: uppercase;
    letter-spacing: 2px;
    text-shadow: var(--text-glow);
    box-shadow: inset 0 0 10px color-mix(in srgb, var(--accent) 30%, transparent);
  }

  .primary-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    border-color: var(--accent);
    box-shadow:
      0 0 15px var(--border-glow),
      inset 0 0 15px color-mix(in srgb, var(--accent) 40%, transparent);
    text-shadow: 0 0 10px var(--accent);
  }

  .primary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
    box-shadow: none;
    text-shadow: none;
  }

  .secondary-btn {
    background: color-mix(in srgb, var(--bg-surface) 50%, transparent);
    color: var(--fg-dim);
    border: 1px solid var(--border);
    border-radius: 2px;
    padding: 0.75rem 1.5rem;
    font-size: 0.875rem;
    font-weight: 700;
    cursor: pointer;
    transition: all 0.2s ease;
    text-transform: uppercase;
    letter-spacing: 2px;
  }

  .secondary-btn:hover:not(:disabled) {
    background: var(--bg-hover);
    border-color: var(--accent);
    color: var(--fg);
  }

  .secondary-btn:disabled {
    opacity: 0.5;
    cursor: not-allowed;
  }
</style>
```

**Step 2: Verify build**

Run: `cd /Users/igorsomov/Code/null/nullhub/ui && npm run build 2>&1 | tail -5`
Expected: Build succeeds

**Step 3: Commit**

```bash
git add ui/src/lib/components/WizardRenderer.svelte
git commit -m "feat: refactor wizard into multi-step flow with validation gates"
```

---

### Task 7: Backend — Build and test everything together

**Step 1: Run full Zig test suite**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build test 2>&1 | tail -20`
Expected: All tests pass

**Step 2: Run full UI build**

Run: `cd /Users/igorsomov/Code/null/nullhub/ui && npm run build 2>&1 | tail -10`
Expected: Build succeeds with no errors

**Step 3: Run full build**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build 2>&1 | tail -10`
Expected: Build succeeds

**Step 4: Commit any fixes**

If any compilation issues were found, fix and commit.

---

### Task 8: Final integration commit

**Step 1: Verify all changes**

Run: `cd /Users/igorsomov/Code/null/nullhub && git diff --stat`
Expected: Changes in wizard.zig, server.zig, client.ts, WizardRenderer.svelte, ProviderList.svelte, ChannelList.svelte (new)

**Step 2: Test manually if server is running**

Start the server and navigate to the install wizard page. Verify:
- 3-step indicator shows at top
- Page 0 shows instance name, version, providers
- Instance name has hint text
- Clicking Next triggers provider validation
- Page 1 shows WEB/CLI defaults and + Add Channel
- Page 2 shows remaining settings with Advanced toggle
- Install button on page 2

**Step 3: Final commit if needed**

```bash
git add -A
git commit -m "feat: multi-step install wizard with provider and channel validation"
```
