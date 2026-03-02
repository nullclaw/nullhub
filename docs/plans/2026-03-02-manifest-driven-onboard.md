# Manifest-Driven Onboard Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Components own their wizard — nullhub asks the binary for its manifest and delegates config generation back to it via CLI protocol (`--export-manifest`, `--list-models`, `--from-json`).

**Architecture:** Each component implements 2-3 CLI subcommands. NullHub removes its `manifests/` directory and config_writer; instead it runs the component binary to get wizard steps and passes answers back for config generation. NullHub adds a `component_cli` helper to execute binaries and capture stdout.

**Tech Stack:** Zig 0.15.2, all four repos (nullclaw, nullboiler, nulltickets, nullhub)

**Git Strategy:**
- nullclaw: feature branch `feat/export-manifest` from main
- nullboiler: feature branch `feat/export-manifest` from main
- nulltickets: feature branch `feat/export-manifest` from main
- nullhub: direct to main

---

### Task 1: nullhub — Update manifest schema and add component_cli helper

**Context:** Before touching any component, update nullhub's manifest schema to remove fields the component now owns, add `dynamic_select` step type, and create a helper to run component binaries.

**Files:**
- Modify: `src/core/manifest.zig`
- Create: `src/core/component_cli.zig`
- Modify: `src/root.zig`

**Step 1: Update manifest.zig — remove unused fields, add dynamic_select**

Remove from `Manifest` struct:
- `config: ConfigSpec` field
- `ui_modules: []const UiModuleSpec` field
- `migrations: []const MigrationSpec` field

Remove types:
- `ConfigSpec`
- `UiModuleSpec`
- `MigrationSpec`

Add to `StepType` enum:
```zig
pub const StepType = enum {
    select,
    multi_select,
    secret,
    text,
    number,
    toggle,
    dynamic_select,
};
```

Add `DynamicSource` struct:
```zig
pub const DynamicSource = struct {
    command: []const u8,
    depends_on: []const []const u8 = &.{},
};
```

Add to `WizardStep`:
```zig
pub const WizardStep = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    @"type": StepType,
    required: bool = true,
    options: []const StepOption = &.{},
    condition: ?StepCondition = null,
    dynamic_source: ?DynamicSource = null,
};
```

Remove `writes_to` field from `WizardStep`.

Update the test JSONs to match the new schema (remove `config`, `ui_modules`, `migrations`, `writes_to`).

**Step 2: Create component_cli.zig**

Helper to run a component binary and capture stdout:

```zig
const std = @import("std");
const process = @import("../supervisor/process.zig");

pub const RunResult = struct {
    stdout: []const u8,
    success: bool,
};

/// Run a component binary with the given arguments and capture stdout.
/// Caller owns the returned stdout slice.
pub fn run(allocator: std.mem.Allocator, binary_path: []const u8, args: []const []const u8) !RunResult {
    // Build argv: binary + args
    var argv = std.array_list.Managed([]const u8).init(allocator);
    defer argv.deinit();
    try argv.append(binary_path);
    for (args) |arg| try argv.append(arg);

    var child = std.process.Child.init(argv.items, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    const stdout = try child.stdout.?.reader().readAllAlloc(allocator, 10 * 1024 * 1024);
    const term = try child.wait();

    return .{
        .stdout = stdout,
        .success = term.Exited == 0,
    };
}

/// Run --export-manifest on a component binary and return the raw JSON.
pub fn exportManifest(allocator: std.mem.Allocator, binary_path: []const u8) ![]const u8 {
    const result = try run(allocator, binary_path, &.{"--export-manifest"});
    if (!result.success) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

/// Run --list-models on a component binary and return the raw JSON array.
pub fn listModels(allocator: std.mem.Allocator, binary_path: []const u8, provider: []const u8, api_key: []const u8) ![]const u8 {
    const result = try run(allocator, binary_path, &.{ "--list-models", "--provider", provider, "--api-key", api_key });
    if (!result.success) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}

/// Run --from-json on a component binary with the given JSON answers.
pub fn fromJson(allocator: std.mem.Allocator, binary_path: []const u8, json_answers: []const u8) ![]const u8 {
    const result = try run(allocator, binary_path, &.{ "--from-json", json_answers });
    if (!result.success) {
        allocator.free(result.stdout);
        return error.CommandFailed;
    }
    return result.stdout;
}
```

**Step 3: Add to root.zig**

```zig
pub const component_cli = @import("core/component_cli.zig");
```

And in the test block: `_ = component_cli;`

**Step 4: Run tests**
```bash
cd /Users/igorsomov/Code/null/nullhub && zig build test --summary all 2>&1 | tail -10
```

**Step 5: Commit**
```bash
git add src/core/manifest.zig src/core/component_cli.zig src/root.zig
git commit -m "feat: update manifest schema, add component_cli helper"
```

---

### Task 2: nullhub — Remove manifests/ dir, config_writer, engine; rewrite wizard and orchestrator

**Context:** Now that component_cli exists, rewrite wizard.zig to use it instead of reading manifests/ files. Rewrite orchestrator to call `--from-json` instead of generating config. Remove config_writer.zig and engine.zig.

**Files:**
- Delete: `manifests/` directory (nullclaw.json, nullboiler.json, nulltickets.json)
- Delete: `src/wizard/config_writer.zig`
- Delete: `src/wizard/engine.zig`
- Modify: `src/api/wizard.zig`
- Modify: `src/installer/orchestrator.zig`
- Modify: `src/server.zig` (add models endpoint)
- Modify: `src/root.zig` (remove config_writer and wizard_engine imports)

**Step 1: Delete files**

```bash
rm -rf manifests/
rm src/wizard/config_writer.zig
rm src/wizard/engine.zig
```

**Step 2: Remove from root.zig**

Remove lines:
```zig
pub const config_writer = @import("wizard/config_writer.zig");
pub const wizard_engine = @import("wizard/engine.zig");
```

And remove `_ = config_writer;` and `_ = wizard_engine;` from the test block.

**Step 3: Rewrite wizard.zig handleGetWizard**

Replace the current implementation that reads from `manifests/` with one that runs the component binary:

```zig
const component_cli = @import("../core/component_cli.zig");
const paths_mod = @import("../core/paths.zig");

/// Handle GET /api/wizard/{component} — runs component --export-manifest.
/// Returns the manifest JSON directly.
/// Accepts paths to locate the downloaded binary.
pub fn handleGetWizard(allocator: std.mem.Allocator, component_name: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    // Find the component binary
    const bin_path = findComponentBinary(allocator, component_name, paths) orelse return null;
    defer allocator.free(bin_path);

    // Run --export-manifest
    const manifest_json = component_cli.exportManifest(allocator, bin_path) catch return null;
    return manifest_json;
}
```

Add helper to find binary (check installed versions in state, or look for latest):

```zig
fn findComponentBinary(allocator: std.mem.Allocator, component: []const u8, paths: paths_mod.Paths) ?[]const u8 {
    // Look for binary in bins/{component}/ directory
    const bins_dir = std.fmt.allocPrint(allocator, "{s}/bins/{s}", .{ paths.root, component }) catch return null;
    defer allocator.free(bins_dir);

    const dir = std.fs.openDirAbsolute(bins_dir, .{ .iterate = true }) catch return null;
    defer dir.close();

    // Find any version directory with the binary
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind == .directory) {
            // Check if binary exists in this version dir
            const bin = paths.binary(allocator, component, entry.name) catch continue;
            if (std.fs.openFileAbsolute(bin, .{}) != null) |f| {
                f.close();
                return bin;
            } else |_| {
                allocator.free(bin);
            }
        }
    }
    return null;
}
```

**Step 4: Rewrite wizard.zig handlePostWizard**

Replace config_writer call with `--from-json`:

```zig
pub fn handlePostWizard(
    allocator: std.mem.Allocator,
    component_name: []const u8,
    body: []const u8,
    paths: paths_mod.Paths,
    state: *state_mod.State,
    manager: *manager_mod.Manager,
) ?[]const u8 {
    if (registry.findKnownComponent(component_name) == null) return null;

    // Parse the body to get instance_name and version
    const parsed = std.json.parseFromSlice(
        struct {
            instance_name: []const u8,
            version: []const u8 = "latest",
            answers: std.json.Value = .null,
        },
        allocator,
        body,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return allocator.dupe(u8, "{\"error\":\"invalid JSON body\"}") catch null;
    defer parsed.deinit();

    // Call orchestrator.install (which now uses --from-json internally)
    const orchestrator = @import("../installer/orchestrator.zig");
    const result = orchestrator.install(allocator, .{
        .component = component_name,
        .instance_name = parsed.value.instance_name,
        .version = parsed.value.version,
        .answers_json = body, // pass the whole body, component will parse it
    }, paths, state, manager) catch |err| {
        return buildErrorResponse(allocator, err);
    };
    defer allocator.free(result.version);

    var buf = std.array_list.Managed(u8).init(allocator);
    errdefer buf.deinit();
    buildPostResponse(&buf, component_name, parsed.value.instance_name, result.version) catch return null;
    return buf.toOwnedSlice() catch null;
}
```

**Step 5: Rewrite orchestrator.install**

Update `InstallOptions` to carry raw JSON instead of parsed answers:

```zig
pub const InstallOptions = struct {
    component: []const u8,
    instance_name: []const u8,
    version: []const u8,
    answers_json: []const u8, // raw JSON body from wizard POST
};
```

In `install()`, replace steps 7 (generate config) with:

```zig
// 7. Run component --from-json to generate config
const component_cli = @import("../core/component_cli.zig");
const from_json_result = component_cli.fromJson(allocator, bin_path, opts.answers_json) catch
    return error.ConfigGenerationFailed;
defer allocator.free(from_json_result);
```

Remove all config_writer imports and usage.

**Step 6: Add models endpoint to server.zig**

Add new route in server.zig `route()` function, under the wizard section:

```zig
// Models API — GET /api/wizard/{component}/models?provider=X&api_key=Y
if (std.mem.endsWith(u8, target, "/models")) {
    // Extract component name from /api/wizard/{component}/models
    // Parse query params for provider and api_key
    // Run component_cli.listModels()
    // Return JSON array
}
```

**Step 7: Update server.zig handleGetWizard call**

Pass `self.paths` to the GET handler:

```zig
if (wizard_api.handleGetWizard(allocator, comp_name, self.paths)) |json| {
```

**Step 8: Update tests**

- Remove tests that depend on `manifests/` directory
- Update wizard tests to not expect file-based manifest reads
- Keep path extraction tests

**Step 9: Run tests**
```bash
cd /Users/igorsomov/Code/null/nullhub && zig build test --summary all 2>&1 | tail -10
zig build 2>&1 | tail -10
```

**Step 10: Commit**
```bash
git add -A
git commit -m "feat: rewrite wizard/orchestrator to use component CLI protocol

Remove manifests/ directory, config_writer, engine.
Wizard GET calls component --export-manifest.
Wizard POST calls component --from-json via orchestrator.
Add models API endpoint."
```

---

### Task 3: nullclaw — Add --export-manifest subcommand

**Context:** nullclaw already has full onboard in `src/onboard.zig`. Add a new function that serializes the wizard knowledge (providers, memory backends, tunnels, channels, autonomy levels) into Manifest JSON format. Work in branch `feat/export-manifest`.

**Files:**
- Modify: `src/main.zig` (add command routing)
- Create: `src/export_manifest.zig` (manifest generation)

**Step 1: Create branch**
```bash
cd /Users/igorsomov/Code/null/nullclaw && git checkout -b feat/export-manifest main
```

**Step 2: Create src/export_manifest.zig**

This file generates the Manifest JSON by reading the same data structures that `onboard.zig` uses:

```zig
const std = @import("std");
const onboard = @import("onboard.zig");

pub fn run(allocator: std.mem.Allocator) !void {
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buildManifest(&buf);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(buf.items);
}

fn buildManifest(buf: *std.array_list.Managed(u8)) !void {
    try buf.appendSlice("{\n");
    try buf.appendSlice("  \"schema_version\": 1,\n");
    try buf.appendSlice("  \"name\": \"nullclaw\",\n");
    try buf.appendSlice("  \"display_name\": \"NullClaw\",\n");
    try buf.appendSlice("  \"description\": \"Autonomous AI agent runtime\",\n");
    try buf.appendSlice("  \"icon\": \"agent\",\n");
    try buf.appendSlice("  \"repo\": \"nullclaw/nullclaw\",\n");

    // Platforms
    try buf.appendSlice("  \"platforms\": {\n");
    try buf.appendSlice("    \"aarch64-macos\": { \"asset\": \"nullclaw-macos-aarch64\", \"binary\": \"nullclaw\" },\n");
    try buf.appendSlice("    \"x86_64-macos\": { \"asset\": \"nullclaw-macos-x86_64\", \"binary\": \"nullclaw\" },\n");
    try buf.appendSlice("    \"x86_64-linux\": { \"asset\": \"nullclaw-linux-x86_64\", \"binary\": \"nullclaw\" },\n");
    try buf.appendSlice("    \"aarch64-linux\": { \"asset\": \"nullclaw-linux-aarch64\", \"binary\": \"nullclaw\" }\n");
    try buf.appendSlice("  },\n");

    // Build from source
    try buf.appendSlice("  \"build_from_source\": {\n");
    try buf.appendSlice("    \"zig_version\": \"0.15.2\",\n");
    try buf.appendSlice("    \"command\": \"zig build -Doptimize=ReleaseSmall\",\n");
    try buf.appendSlice("    \"output\": \"zig-out/bin/nullclaw\"\n");
    try buf.appendSlice("  },\n");

    // Launch
    try buf.appendSlice("  \"launch\": { \"command\": \"gateway\", \"args\": [] },\n");

    // Health
    try buf.appendSlice("  \"health\": { \"endpoint\": \"/health\", \"port_from_config\": \"gateway.port\" },\n");

    // Ports
    try buf.appendSlice("  \"ports\": [{ \"name\": \"gateway\", \"config_key\": \"gateway.port\", \"default\": 3000, \"protocol\": \"http\" }],\n");

    // Wizard steps — generated from onboard.zig data
    try buf.appendSlice("  \"wizard\": { \"steps\": [\n");
    try appendProviderStep(buf);
    try buf.appendSlice(",\n");
    try appendApiKeyStep(buf);
    try buf.appendSlice(",\n");
    try appendModelStep(buf);
    try buf.appendSlice(",\n");
    try appendMemoryStep(buf);
    try buf.appendSlice(",\n");
    try appendTunnelStep(buf);
    try buf.appendSlice(",\n");
    try appendAutonomyStep(buf);
    try buf.appendSlice(",\n");
    try appendChannelsStep(buf);
    try buf.appendSlice(",\n");
    try appendGatewayPortStep(buf);
    try buf.appendSlice("\n  ] },\n");

    // Dependencies
    try buf.appendSlice("  \"depends_on\": [],\n");
    try buf.appendSlice("  \"connects_to\": [{ \"component\": \"nullboiler\", \"role\": \"worker\", \"description\": \"Registers as a worker\" }]\n");
    try buf.appendSlice("}\n");
}
```

The `appendProviderStep` function iterates `onboard.known_providers` to build the options array dynamically. Same pattern for memory, tunnels, etc. — reading from the existing arrays in onboard.zig.

**Step 3: Add routing in main.zig**

In the arg parsing loop (before `parseCommand`), add early return for `--export-manifest`:

```zig
// Check for top-level flags before command dispatch
if (args.len >= 2) {
    if (std.mem.eql(u8, args[1], "--export-manifest")) {
        try @import("export_manifest.zig").run(allocator);
        return;
    }
    if (std.mem.eql(u8, args[1], "--list-models")) {
        try @import("list_models.zig").run(allocator, args[2..]);
        return;
    }
    if (std.mem.eql(u8, args[1], "--from-json")) {
        try @import("from_json.zig").run(allocator, args[2..]);
        return;
    }
}
```

**Step 4: Run and verify output**
```bash
zig build && ./zig-out/bin/nullclaw --export-manifest | python3 -m json.tool
```

Should output valid JSON with all wizard steps.

**Step 5: Run tests**
```bash
zig build test --summary all 2>&1 | tail -10
```

**Step 6: Commit**
```bash
git add src/export_manifest.zig src/main.zig
git commit -m "feat: add --export-manifest subcommand"
```

---

### Task 4: nullclaw — Add --list-models subcommand

**Context:** nullclaw already has `fetchModels()` in `onboard.zig`. Create a thin wrapper that outputs the result as JSON to stdout.

**Files:**
- Create: `src/list_models.zig`
- Modify: `src/main.zig` (already done in Task 3 routing)

**Step 1: Create src/list_models.zig**

```zig
const std = @import("std");
const onboard = @import("onboard.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    var provider: ?[]const u8 = null;
    var api_key: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--provider") and i + 1 < args.len) {
            provider = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, args[i], "--api-key") and i + 1 < args.len) {
            api_key = args[i + 1];
            i += 1;
        }
    }

    if (provider == null) {
        std.debug.print("error: --provider is required\n", .{});
        std.process.exit(1);
    }

    // Use onboard's fetchModels
    const models = onboard.fetchModels(allocator, provider.?, api_key) catch |err| {
        std.debug.print("error fetching models: {}\n", .{err});
        std.process.exit(1);
    };

    // Output as JSON array
    const stdout = std.io.getStdOut().writer();
    try stdout.writeByte('[');
    for (models, 0..) |model, idx| {
        if (idx > 0) try stdout.writeByte(',');
        try stdout.writeByte('"');
        try stdout.writeAll(model);
        try stdout.writeByte('"');
    }
    try stdout.writeByte(']');
    try stdout.writeByte('\n');
}
```

Note: The exact `fetchModels` signature may need adjustment — check if it's public and what it returns. If not public, make it public.

**Step 2: Verify fetchModels is accessible**

Check `onboard.zig` for `fetchModels` — if it's `fn` (private), change to `pub fn`.

**Step 3: Test**
```bash
zig build && ./zig-out/bin/nullclaw --list-models --provider openrouter --api-key sk-test
```

**Step 4: Commit**
```bash
git add src/list_models.zig src/onboard.zig
git commit -m "feat: add --list-models subcommand"
```

---

### Task 5: nullclaw — Add --from-json subcommand

**Context:** This is the counterpart to `runQuickSetup()` — accepts all wizard answers as JSON and generates config. Must handle channels, which quick setup currently skips.

**Files:**
- Create: `src/from_json.zig`
- Modify: `src/main.zig` (already done in Task 3 routing)

**Step 1: Create src/from_json.zig**

```zig
const std = @import("std");
const onboard = @import("onboard.zig");
const config_mod = @import("config.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("error: --from-json requires a JSON argument\n", .{});
        std.process.exit(1);
    }

    const json_str = args[0];

    // Parse the input JSON
    const parsed = std.json.parseFromSlice(
        WizardAnswers,
        allocator,
        json_str,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();
    const answers = parsed.value;

    // Load existing or create fresh config
    var cfg = config_mod.Config.load(allocator) catch
        try onboard.initFreshConfig(allocator);
    defer cfg.deinit();

    // Apply answers to config
    if (answers.provider) |p| {
        cfg.default_provider = p;
        // Set provider entry with API key
        if (answers.api_key) |key| {
            cfg.setProviderApiKey(p, key);
        }
    }
    if (answers.model) |m| cfg.default_model = m;
    if (answers.memory) |m| cfg.setMemoryBackend(m);
    if (answers.tunnel) |t| cfg.setTunnelProvider(t);
    if (answers.autonomy) |a| cfg.setAutonomyLevel(a);
    if (answers.gateway_port) |p| cfg.gateway.port = p;
    // Apply channel configs...

    // Save config
    try cfg.save();

    // Scaffold workspace
    try onboard.scaffoldWorkspace(allocator, cfg.workspace_dir, .{});

    // Output success
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("{\"status\":\"ok\"}\n");
}

const WizardAnswers = struct {
    provider: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    model: ?[]const u8 = null,
    memory: ?[]const u8 = null,
    tunnel: ?[]const u8 = null,
    autonomy: ?[]const u8 = null,
    gateway_port: ?u16 = null,
    channels: ?[]const []const u8 = null,
    // Per-channel config as nested JSON
    channel_config: ?std.json.Value = null,
};
```

Note: The exact Config methods (`setProviderApiKey`, `setMemoryBackend`, etc.) may need to be added or the existing code may use different patterns. Check config.zig for the actual API and adapt.

**Step 2: Make necessary onboard.zig functions public**

Functions like `initFreshConfig` and `scaffoldWorkspace` need to be `pub` if they aren't already.

**Step 3: Test**
```bash
zig build && ./zig-out/bin/nullclaw --from-json '{"provider":"openrouter","api_key":"test","model":"anthropic/claude-sonnet-4.6","memory":"sqlite","gateway_port":3000}'
cat ~/.nullclaw/config.json | python3 -m json.tool
```

**Step 4: Run tests**
```bash
zig build test --summary all 2>&1 | tail -10
```

**Step 5: Commit**
```bash
git add src/from_json.zig src/onboard.zig src/config.zig
git commit -m "feat: add --from-json subcommand for non-interactive config generation"
```

---

### Task 6: nullboiler — Add --export-manifest and --from-json

**Context:** NullBoiler has simple config: host, port, db, api_token, workers, engine settings. For nullhub wizard, only port, api_token, and db_path need user input. Work in branch `feat/export-manifest`.

**Files:**
- Modify: `src/main.zig` (add arg handling)
- Create: `src/export_manifest.zig`
- Create: `src/from_json.zig`

**Step 1: Create branch**
```bash
cd /Users/igorsomov/Code/null/NullBoiler && git checkout -b feat/export-manifest main
```

**Step 2: Create src/export_manifest.zig**

Static manifest — nullboiler's wizard is simple:

```zig
const std = @import("std");

pub fn run() !void {
    const manifest =
        \\{
        \\  "schema_version": 1,
        \\  "name": "nullboiler",
        \\  "display_name": "NullBoiler",
        \\  "description": "DAG-based workflow orchestrator",
        \\  "icon": "orchestrator",
        \\  "repo": "nullclaw/NullBoiler",
        \\  "platforms": {
        \\    "aarch64-macos": { "asset": "nullboiler-macos-aarch64", "binary": "nullboiler" },
        \\    "x86_64-macos": { "asset": "nullboiler-macos-x86_64", "binary": "nullboiler" },
        \\    "x86_64-linux": { "asset": "nullboiler-linux-x86_64", "binary": "nullboiler" },
        \\    "aarch64-linux": { "asset": "nullboiler-linux-aarch64", "binary": "nullboiler" }
        \\  },
        \\  "build_from_source": {
        \\    "zig_version": "0.15.2",
        \\    "command": "zig build -Doptimize=ReleaseSmall",
        \\    "output": "zig-out/bin/nullboiler"
        \\  },
        \\  "launch": { "command": "nullboiler", "args": [] },
        \\  "health": { "endpoint": "/health", "port_from_config": "port" },
        \\  "ports": [{ "name": "api", "config_key": "port", "default": 8080, "protocol": "http" }],
        \\  "wizard": { "steps": [
        \\    { "id": "port", "title": "API Port", "type": "number", "required": true, "options": [] },
        \\    { "id": "api_token", "title": "API Token", "description": "Optional bearer token for API auth", "type": "secret", "required": false, "options": [] },
        \\    { "id": "db_path", "title": "Database Path", "type": "text", "required": true, "options": [] }
        \\  ] },
        \\  "depends_on": [],
        \\  "connects_to": []
        \\}
    ;
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(manifest);
    try stdout.writeByte('\n');
}
```

**Step 3: Create src/from_json.zig**

```zig
const std = @import("std");
const config = @import("config.zig");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("error: --from-json requires a JSON argument\n", .{});
        std.process.exit(1);
    }

    const parsed = std.json.parseFromSlice(
        struct {
            port: u16 = 8080,
            api_token: ?[]const u8 = null,
            db_path: []const u8 = "nullboiler.db",
        },
        allocator,
        args[0],
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    // Build config JSON and write to config.json
    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("{\n");
    try std.fmt.format(buf.writer(), "  \"port\": {d},\n", .{parsed.value.port});
    try std.fmt.format(buf.writer(), "  \"db\": \"{s}\"", .{parsed.value.db_path});
    if (parsed.value.api_token) |token| {
        try buf.appendSlice(",\n");
        try std.fmt.format(buf.writer(), "  \"api_token\": \"{s}\"", .{token});
    }
    try buf.appendSlice("\n}\n");

    // Write config.json
    const file = try std.fs.cwd().createFile("config.json", .{});
    defer file.close();
    try file.writeAll(buf.items);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("{\"status\":\"ok\"}\n");
}
```

**Step 4: Add routing in main.zig**

Before the existing arg parsing loop, add:

```zig
// Check for manifest protocol flags first
var check_args = try std.process.argsWithAllocator(allocator);
defer check_args.deinit();
_ = check_args.next(); // skip program name
if (check_args.next()) |first_arg| {
    if (std.mem.eql(u8, first_arg, "--export-manifest")) {
        try @import("export_manifest.zig").run();
        return;
    }
    if (std.mem.eql(u8, first_arg, "--from-json")) {
        const rest = try collectRemainingArgs(allocator, &check_args);
        defer allocator.free(rest);
        try @import("from_json.zig").run(allocator, rest);
        return;
    }
}
```

Note: NullBoiler doesn't use a `Command` enum — it just has a flat arg parser. The `--export-manifest` / `--from-json` flags should be checked first before the existing loop.

**Step 5: Test**
```bash
zig build && ./zig-out/bin/nullboiler --export-manifest | python3 -m json.tool
./zig-out/bin/nullboiler --from-json '{"port":9090,"api_token":"secret123","db_path":"test.db"}'
cat config.json
```

**Step 6: Run tests**
```bash
zig build test --summary all 2>&1 | tail -10
```

**Step 7: Commit**
```bash
git add src/export_manifest.zig src/from_json.zig src/main.zig
git commit -m "feat: add --export-manifest and --from-json for nullhub integration"
```

---

### Task 7: nulltickets — Add --export-manifest and --from-json

**Context:** nulltickets is the simplest — just port and db path. Currently has no config file at all. Add config.json support via --from-json. Work in branch `feat/export-manifest`.

**Files:**
- Modify: `src/main.zig` (add arg handling + config file loading)
- Create: `src/export_manifest.zig`
- Create: `src/from_json.zig`

**Step 1: Create branch**
```bash
cd /Users/igorsomov/Code/null/nulltickets && git checkout -b feat/export-manifest main
```

**Step 2: Create src/export_manifest.zig**

```zig
const std = @import("std");

pub fn run() !void {
    const manifest =
        \\{
        \\  "schema_version": 1,
        \\  "name": "nulltickets",
        \\  "display_name": "NullTickets",
        \\  "description": "Headless task and issue tracker for AI agents",
        \\  "icon": "tickets",
        \\  "repo": "nullclaw/nulltickets",
        \\  "platforms": {
        \\    "aarch64-macos": { "asset": "nulltickets-macos-aarch64", "binary": "nulltickets" },
        \\    "x86_64-macos": { "asset": "nulltickets-macos-x86_64", "binary": "nulltickets" },
        \\    "x86_64-linux": { "asset": "nulltickets-linux-x86_64", "binary": "nulltickets" },
        \\    "aarch64-linux": { "asset": "nulltickets-linux-aarch64", "binary": "nulltickets" }
        \\  },
        \\  "build_from_source": {
        \\    "zig_version": "0.15.2",
        \\    "command": "zig build -Doptimize=ReleaseSmall",
        \\    "output": "zig-out/bin/nulltickets"
        \\  },
        \\  "launch": { "command": "nulltickets", "args": [] },
        \\  "health": { "endpoint": "/health", "port_from_config": "port" },
        \\  "ports": [{ "name": "api", "config_key": "port", "default": 7700, "protocol": "http" }],
        \\  "wizard": { "steps": [
        \\    { "id": "port", "title": "API Port", "type": "number", "required": true, "options": [] },
        \\    { "id": "db_path", "title": "Database Path", "type": "text", "required": true, "options": [] }
        \\  ] },
        \\  "depends_on": [],
        \\  "connects_to": []
        \\}
    ;
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(manifest);
    try stdout.writeByte('\n');
}
```

**Step 3: Create src/from_json.zig**

```zig
const std = @import("std");

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len == 0) {
        std.debug.print("error: --from-json requires a JSON argument\n", .{});
        std.process.exit(1);
    }

    const parsed = std.json.parseFromSlice(
        struct { port: u16 = 7700, db_path: []const u8 = "nulltickets.db" },
        allocator,
        args[0],
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch {
        std.debug.print("error: invalid JSON\n", .{});
        std.process.exit(1);
    };
    defer parsed.deinit();

    var buf = std.array_list.Managed(u8).init(allocator);
    defer buf.deinit();
    try std.fmt.format(buf.writer(), "{{\n  \"port\": {d},\n  \"db\": \"{s}\"\n}}\n", .{ parsed.value.port, parsed.value.db_path });

    const file = try std.fs.cwd().createFile("config.json", .{});
    defer file.close();
    try file.writeAll(buf.items);

    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll("{\"status\":\"ok\"}\n");
}
```

**Step 4: Update main.zig — add flag handling and config.json loading**

Add before the existing arg loop:

```zig
// Check for manifest protocol flags
if (args.len >= 2) {
    if (std.mem.eql(u8, args[1], "--export-manifest")) {
        try @import("export_manifest.zig").run();
        return;
    }
    if (std.mem.eql(u8, args[1], "--from-json") and args.len >= 3) {
        try @import("from_json.zig").run(allocator, args[2..]);
        return;
    }
}
```

Also add config.json loading after the arg loop — if config.json exists, use its values as defaults (CLI args still override):

```zig
// Load config.json defaults (if exists), CLI args override
if (port == 7700 and db_path_is_default) {
    if (loadConfigJson(allocator)) |cfg| {
        if (port == 7700) port = cfg.port;
        // db_path override...
    }
}
```

**Step 5: Test**
```bash
zig build && ./zig-out/bin/nulltickets --export-manifest | python3 -m json.tool
./zig-out/bin/nulltickets --from-json '{"port":8800,"db_path":"test.db"}'
cat config.json
```

**Step 6: Run tests**
```bash
zig build test --summary all 2>&1 | tail -10
```

**Step 7: Commit**
```bash
git add src/export_manifest.zig src/from_json.zig src/main.zig
git commit -m "feat: add --export-manifest and --from-json for nullhub integration"
```

---

### Task 8: Integration test — verify end-to-end flow

**Context:** Build all components, verify the CLI protocol works as expected.

**Step 1: Test nullclaw protocol**
```bash
cd /Users/igorsomov/Code/null/nullclaw
zig build
./zig-out/bin/nullclaw --export-manifest | python3 -c "import sys,json; m=json.load(sys.stdin); print(f'Steps: {len(m[\"wizard\"][\"steps\"])}')"
./zig-out/bin/nullclaw --export-manifest | python3 -c "import sys,json; m=json.load(sys.stdin); [print(f'  {s[\"id\"]}: {s[\"type\"]}') for s in m['wizard']['steps']]"
```

**Step 2: Test nullboiler protocol**
```bash
cd /Users/igorsomov/Code/null/NullBoiler
zig build
./zig-out/bin/nullboiler --export-manifest | python3 -m json.tool
```

**Step 3: Test nulltickets protocol**
```bash
cd /Users/igorsomov/Code/null/nulltickets
zig build
./zig-out/bin/nulltickets --export-manifest | python3 -m json.tool
```

**Step 4: Test nullhub build**
```bash
cd /Users/igorsomov/Code/null/nullhub
zig build test --summary all 2>&1 | tail -10
zig build 2>&1 | tail -10
```

---

## Verification

After all tasks:

1. **nullclaw** (on branch `feat/export-manifest`):
   - `--export-manifest` outputs valid Manifest JSON with 8+ wizard steps
   - `--list-models --provider openrouter --api-key X` outputs JSON model array
   - `--from-json '{...}'` generates `~/.nullclaw/config.json` and scaffolds workspace
   - All existing tests pass

2. **nullboiler** (on branch `feat/export-manifest`):
   - `--export-manifest` outputs valid Manifest JSON with 3 wizard steps
   - `--from-json '{...}'` generates `config.json`
   - All existing tests pass

3. **nulltickets** (on branch `feat/export-manifest`):
   - `--export-manifest` outputs valid Manifest JSON with 2 wizard steps
   - `--from-json '{...}'` generates `config.json`
   - All existing tests pass

4. **nullhub** (on main):
   - No `manifests/` directory
   - No config_writer.zig or engine.zig
   - `zig build` and `zig build test` pass
   - Wizard GET calls `--export-manifest` on binary
   - Wizard POST calls `--from-json` via orchestrator
