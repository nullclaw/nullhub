# NullHub Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build NullHub — a manifest-driven management hub for the nullclaw ecosystem (Zig backend + Svelte frontend).

**Architecture:** Single Zig binary serving REST API + embedded Svelte SPA. Manifest-driven component management. Process supervisor for child instances. See `docs/plans/2026-03-02-nullhub-architecture-design.md` for full design.

**Tech Stack:** Zig 0.15.2 (backend), Svelte 5 + SvelteKit 2 (frontend), no external Zig dependencies.

**Reference repos (same patterns):**
- `../nulltickets/` — HTTP server, build.zig, arg parsing, JSON handling
- `../NullBoiler/` — HTTP server + background thread, config parsing
- `../nullclaw-chat-ui/` — Svelte 5 SPA patterns

---

## Phase 1: Project Scaffolding

### Task 1: Initialize Zig project

**Files:**
- Create: `build.zig`
- Create: `build.zig.zon`
- Create: `src/main.zig`
- Create: `src/root.zig`

**Step 1: Create build.zig.zon**

```zig
.{
    .name = .nullhub,
    .version = "0.1.0",
    .fingerprint = 0xa1b2c3d4e5f60718,
    .minimum_zig_version = "0.15.2",
    .dependencies = .{},
    .paths = .{
        "build.zig",
        "build.zig.zon",
        "src",
    },
}
```

**Step 2: Create build.zig**

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "nullhub",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run nullhub");
    run_step.dependOn(&run_cmd.step);

    const exe_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(exe_unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
```

**Step 3: Create src/main.zig**

Minimal entry point with version flag:

```zig
const std = @import("std");
pub const root = @import("root.zig");

const version = "0.1.0";

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.next(); // skip program name

    const command = args.next();
    if (command) |cmd| {
        if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "version")) {
            std.debug.print("nullhub v{s}\n", .{version});
            return;
        }
    }

    std.debug.print("nullhub v{s}\n", .{version});
    std.debug.print("usage: nullhub [serve|install|start|stop|status|version]\n", .{});
}
```

**Step 4: Create src/root.zig**

```zig
// NullHub — management hub for the nullclaw ecosystem
// Module exports

pub const main = @import("main.zig");

test {
    _ = main;
}
```

**Step 5: Verify build and tests pass**

Run: `cd /Users/igorsomov/Code/null/nullhub && zig build`
Expected: builds successfully, produces `zig-out/bin/nullhub`

Run: `zig build test --summary all`
Expected: PASS

Run: `./zig-out/bin/nullhub version`
Expected: `nullhub v0.1.0`

**Step 6: Commit**

```bash
git add build.zig build.zig.zon src/
git commit -m "init: scaffold Zig project with build system and entry point"
```

---

### Task 2: Core — paths.zig (directory resolution)

**Files:**
- Create: `src/core/paths.zig`
- Modify: `src/root.zig`

**Step 1: Write tests for paths**

```zig
// src/core/paths.zig

const std = @import("std");

/// Resolves all paths under ~/.nullhub/
pub const Paths = struct {
    root: []const u8, // ~/.nullhub

    pub fn init(allocator: std.mem.Allocator, custom_root: ?[]const u8) !Paths {
        if (custom_root) |r| {
            return .{ .root = try allocator.dupe(u8, r) };
        }
        const home = std.process.getEnvVarOwned(allocator, "HOME") catch
            return error.NoHomeDir;
        defer allocator.free(home);
        const root = try std.fs.path.join(allocator, &.{ home, ".nullhub" });
        return .{ .root = root };
    }

    pub fn config(self: Paths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "config.json" });
    }

    pub fn state(self: Paths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "state.json" });
    }

    pub fn manifest(self: Paths, allocator: std.mem.Allocator, component: []const u8, ver: []const u8) ![]const u8 {
        const filename = try std.fmt.allocPrint(allocator, "{s}@{s}.json", .{ component, ver });
        defer allocator.free(filename);
        return std.fs.path.join(allocator, &.{ self.root, "manifests", filename });
    }

    pub fn binary(self: Paths, allocator: std.mem.Allocator, component: []const u8, ver: []const u8) ![]const u8 {
        const filename = try std.fmt.allocPrint(allocator, "{s}-{s}", .{ component, ver });
        defer allocator.free(filename);
        return std.fs.path.join(allocator, &.{ self.root, "bin", filename });
    }

    pub fn instanceDir(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name });
    }

    pub fn instanceConfig(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name, "config.json" });
    }

    pub fn instanceData(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name, "data" });
    }

    pub fn instanceLogs(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name, "logs" });
    }

    pub fn instanceMeta(self: Paths, allocator: std.mem.Allocator, component: []const u8, name: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "instances", component, name, "instance.json" });
    }

    pub fn uiModule(self: Paths, allocator: std.mem.Allocator, module_name: []const u8, ver: []const u8) ![]const u8 {
        const dirname = try std.fmt.allocPrint(allocator, "{s}@{s}", .{ module_name, ver });
        defer allocator.free(dirname);
        return std.fs.path.join(allocator, &.{ self.root, "ui", dirname });
    }

    pub fn cacheDownloads(self: Paths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.root, "cache", "downloads" });
    }

    /// Create all required directories under root
    pub fn ensureDirs(self: Paths) !void {
        const dirs = [_][]const u8{
            "manifests", "bin", "instances", "ui", "cache/downloads",
        };
        for (dirs) |sub| {
            var path_buf: [std.fs.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ self.root, sub }) catch continue;
            std.fs.makeDirAbsolute(full) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    pub fn deinit(self: Paths, allocator: std.mem.Allocator) void {
        allocator.free(self.root);
    }
};

test "paths resolve under custom root" {
    const allocator = std.testing.allocator;
    var paths = try Paths.init(allocator, "/tmp/test-nullhub");
    defer paths.deinit(allocator);

    const cfg = try paths.config(allocator);
    defer allocator.free(cfg);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/config.json", cfg);

    const bin = try paths.binary(allocator, "nullclaw", "2026.3.1");
    defer allocator.free(bin);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/bin/nullclaw-2026.3.1", bin);

    const inst = try paths.instanceConfig(allocator, "nullclaw", "my-agent");
    defer allocator.free(inst);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/instances/nullclaw/my-agent/config.json", inst);

    const ui = try paths.uiModule(allocator, "nullclaw-chat-ui", "1.2.0");
    defer allocator.free(ui);
    try std.testing.expectEqualStrings("/tmp/test-nullhub/ui/nullclaw-chat-ui@1.2.0", ui);
}
```

**Step 2: Update root.zig to include paths**

```zig
pub const paths = @import("core/paths.zig");

test {
    _ = @import("main.zig");
    _ = paths;
}
```

**Step 3: Run tests**

Run: `zig build test --summary all`
Expected: PASS

**Step 4: Commit**

```bash
git add src/core/paths.zig src/root.zig
git commit -m "feat: add paths module for ~/.nullhub/ directory resolution"
```

---

### Task 3: Core — platform.zig (OS/arch detection)

**Files:**
- Create: `src/core/platform.zig`
- Modify: `src/root.zig`

**Step 1: Implement platform detection**

```zig
// src/core/platform.zig
const std = @import("std");
const builtin = @import("builtin");

pub const PlatformKey = enum {
    @"x86_64-linux",
    @"aarch64-linux",
    @"riscv64-linux",
    @"aarch64-macos",
    @"x86_64-macos",
    @"x86_64-windows",
    @"aarch64-windows",
    unknown,

    pub fn toString(self: PlatformKey) []const u8 {
        return @tagName(self);
    }
};

pub fn detect() PlatformKey {
    const arch = builtin.cpu.arch;
    const os = builtin.os.tag;

    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => .@"x86_64-linux",
            .aarch64 => .@"aarch64-linux",
            .riscv64 => .@"riscv64-linux",
            else => .unknown,
        },
        .macos => switch (arch) {
            .aarch64 => .@"aarch64-macos",
            .x86_64 => .@"x86_64-macos",
            else => .unknown,
        },
        .windows => switch (arch) {
            .x86_64 => .@"x86_64-windows",
            .aarch64 => .@"aarch64-windows",
            else => .unknown,
        },
        else => .unknown,
    };
}

test "detect returns a known platform on test host" {
    const key = detect();
    try std.testing.expect(key != .unknown);
}
```

**Step 2: Add to root.zig, run tests, commit**

Run: `zig build test --summary all`

```bash
git add src/core/platform.zig src/root.zig
git commit -m "feat: add platform detection for binary selection"
```

---

### Task 4: Core — manifest.zig (JSON manifest parser)

**Files:**
- Create: `src/core/manifest.zig`
- Create: `tests/fixtures/nullclaw-manifest.json` (test fixture)
- Modify: `src/root.zig`

**Step 1: Create test fixture**

Create `tests/fixtures/nullclaw-manifest.json` with a minimal but complete manifest (copied from design doc, trimmed for testing).

**Step 2: Implement manifest parser**

Parse `nullhub-manifest.json` using `std.json`. Define Zig types matching the manifest schema:

```zig
// src/core/manifest.zig
const std = @import("std");

pub const Manifest = struct {
    schema_version: u32,
    name: []const u8,
    display_name: []const u8,
    description: []const u8,
    icon: []const u8,
    repo: []const u8,
    platforms: std.json.ArrayHashMap(PlatformEntry),
    build_from_source: ?BuildFromSource = null,
    config: ConfigSpec,
    launch: LaunchSpec,
    health: HealthSpec,
    ports: []const PortSpec,
    wizard: WizardSpec,
    ui_modules: []const UiModuleSpec,
    depends_on: []const []const u8,
    connects_to: []const ConnectionSpec,
    migrations: []const MigrationSpec,
};

pub const PlatformEntry = struct {
    asset: []const u8,
    binary: []const u8,
};

pub const BuildFromSource = struct {
    zig_version: []const u8,
    command: []const u8,
    output: []const u8,
};

pub const ConfigSpec = struct {
    path: []const u8,
    // schema stored as raw JSON value — interpreted by wizard engine
};

pub const LaunchSpec = struct {
    command: []const u8,
    args: []const []const u8,
};

pub const HealthSpec = struct {
    endpoint: []const u8,
    port_from_config: []const u8,
    interval_ms: u32,
};

pub const PortSpec = struct {
    name: []const u8,
    config_key: []const u8,
    default: u16,
    protocol: []const u8,
};

pub const WizardSpec = struct {
    steps: []const WizardStep,
};

pub const WizardStep = struct {
    id: []const u8,
    title: []const u8,
    description: []const u8 = "",
    type: StepType,
    required: bool = true,
    options: []const StepOption = &.{},
    writes_to: []const u8,
    condition: ?StepCondition = null,
};

pub const StepType = enum { select, multi_select, secret, text, number, toggle };

pub const StepOption = struct {
    value: []const u8,
    label: []const u8,
    description: []const u8 = "",
};

pub const StepCondition = struct {
    step: []const u8,
    equals: ?[]const u8 = null,
    not_equals: ?[]const u8 = null,
    contains: ?[]const u8 = null,
};

pub const UiModuleSpec = struct {
    name: []const u8,
    repo: []const u8,
    mount_path: []const u8,
    label: []const u8,
    icon: []const u8,
};

pub const ConnectionSpec = struct {
    component: []const u8,
    role: []const u8 = "",
    description: []const u8 = "",
    auto_config: ?AutoConfig = null,
};

pub const AutoConfig = struct {
    // stored as raw JSON — template resolution at runtime
};

pub const MigrationSpec = struct {
    from: []const u8,
    to: []const u8,
    // actions stored as raw JSON
};

pub fn parseManifest(allocator: std.mem.Allocator, json_bytes: []const u8) !std.json.Parsed(Manifest) {
    return std.json.parseFromSlice(
        Manifest,
        allocator,
        json_bytes,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    );
}

pub fn parseManifestFile(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(Manifest) {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const bytes = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(bytes);
    return parseManifest(allocator, bytes);
}
```

**Step 3: Write tests**

```zig
test "parse minimal manifest" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "schema_version": 1,
        \\  "name": "nullclaw",
        \\  "display_name": "NullClaw",
        \\  "description": "AI agent",
        \\  "icon": "agent",
        \\  "repo": "nullclaw/nullclaw",
        \\  "platforms": {
        \\    "aarch64-macos": { "asset": "nullclaw-macos-aarch64", "binary": "nullclaw" }
        \\  },
        \\  "config": { "path": "config.json" },
        \\  "launch": { "command": "gateway", "args": [] },
        \\  "health": { "endpoint": "/health", "port_from_config": "gateway.port", "interval_ms": 15000 },
        \\  "ports": [{ "name": "gateway", "config_key": "gateway.port", "default": 3000, "protocol": "http" }],
        \\  "wizard": { "steps": [] },
        \\  "ui_modules": [],
        \\  "depends_on": [],
        \\  "connects_to": [],
        \\  "migrations": []
        \\}
    ;
    var parsed = try parseManifest(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("nullclaw", parsed.value.name);
    try std.testing.expectEqual(@as(u32, 1), parsed.value.schema_version);
    try std.testing.expectEqualStrings("gateway", parsed.value.launch.command);
    try std.testing.expectEqual(@as(u16, 3000), parsed.value.ports[0].default);
}

test "parse manifest with wizard steps" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "schema_version": 1, "name": "test", "display_name": "Test",
        \\  "description": "", "icon": "", "repo": "t/t",
        \\  "platforms": {},
        \\  "config": { "path": "config.json" },
        \\  "launch": { "command": "run", "args": [] },
        \\  "health": { "endpoint": "/health", "port_from_config": "port", "interval_ms": 5000 },
        \\  "ports": [], "ui_modules": [], "depends_on": [], "connects_to": [], "migrations": [],
        \\  "wizard": {
        \\    "steps": [{
        \\      "id": "name", "title": "Name", "type": "text",
        \\      "required": true, "writes_to": "name"
        \\    }, {
        \\      "id": "mode", "title": "Mode", "type": "select",
        \\      "options": [{"value": "a", "label": "A"}, {"value": "b", "label": "B"}],
        \\      "writes_to": "mode",
        \\      "condition": {"step": "name", "not_equals": "skip"}
        \\    }]
        \\  }
        \\}
    ;
    var parsed = try parseManifest(allocator, json);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.value.wizard.steps.len);
    try std.testing.expectEqual(StepType.text, parsed.value.wizard.steps[0].type);
    try std.testing.expectEqual(StepType.select, parsed.value.wizard.steps[1].type);
    try std.testing.expect(parsed.value.wizard.steps[1].condition != null);
}
```

**Step 4: Run tests, commit**

Run: `zig build test --summary all`
Expected: PASS

```bash
git add src/core/manifest.zig tests/ src/root.zig
git commit -m "feat: add manifest JSON parser with full schema types"
```

---

### Task 5: Core — state.zig (instance registry)

**Files:**
- Create: `src/core/state.zig`
- Modify: `src/root.zig`

Atomic read/write of `state.json`. Add/remove/update instances. Uses write-to-temp + rename for crash safety.

Key functions:
- `State.load(allocator, path) → State`
- `State.save(path) → void` (atomic write)
- `State.addInstance(component, name, version, auto_start)`
- `State.removeInstance(component, name)`
- `State.getInstance(component, name) → ?InstanceEntry`
- `State.listInstances() → iterator`

Test with temp directory. Verify atomic save (write + rename). Verify add/remove/get round-trip.

**Commit:** `feat: add state manager for instance registry (atomic JSON persistence)`

---

## Phase 2: HTTP Server + CLI Skeleton

### Task 6: HTTP server with routing

**Files:**
- Create: `src/server.zig`
- Modify: `src/main.zig`

Implement HTTP server following nulltickets pattern:
- Single-threaded accept loop
- Per-request arena allocator
- Route dispatch based on method + path
- Content-Type: application/json for /api/*
- Static file serving for /* (hub UI, placeholder for now)
- CORS headers for local dev

Initial routes:
- `GET /api/status` → `{"hub": {"version": "0.1.0", "platform": "..."}}`
- `GET /health` → `{"status": "ok"}`

`nullhub serve --port 9000 --host 127.0.0.1` starts the server.
`nullhub` (no args) starts server + opens browser.

**Commit:** `feat: add HTTP server with basic routing and status endpoint`

---

### Task 7: CLI argument parser

**Files:**
- Create: `src/cli.zig`
- Modify: `src/main.zig`

Parse CLI commands and dispatch:

```
nullhub                    → serve + open browser
nullhub serve              → serve
nullhub version            → print version
nullhub status             → print instance table (placeholder)
nullhub install <comp>     → placeholder
nullhub start <c>/<n>      → placeholder
nullhub stop <c>/<n>       → placeholder
```

Pattern: `cli.parseArgs(allocator) → Command` union type. Each command variant holds its parsed args. `main.zig` matches on command and dispatches.

Test arg parsing for each command variant.

**Commit:** `feat: add CLI command parser with serve/status/install/start/stop`

---

## Phase 3: Supervisor

### Task 8: Process spawning

**Files:**
- Create: `src/supervisor/process.zig`
- Modify: `src/root.zig`

Spawn a child process with:
- argv from manifest.launch
- cwd = instance data dir
- stdout/stderr redirected to log files
- Returns PID

Functions:
- `spawn(allocator, binary_path, argv, cwd, stdout_path, stderr_path) → Child`
- `isAlive(pid) → bool` (platform-specific: kill(0) on unix, OpenProcess on windows)
- `terminate(pid) → void` (SIGTERM on unix, TerminateProcess on windows)
- `kill(pid) → void` (SIGKILL on unix)
- `getMemoryRss(pid) → ?u64` (platform-specific)

Test with a simple child process (e.g., `sleep 60`), verify alive, terminate, verify dead.

**Commit:** `feat: add process spawning with log redirect and platform-specific PID ops`

---

### Task 9: Health checker

**Files:**
- Create: `src/supervisor/health.zig`

HTTP GET to `http://127.0.0.1:{port}{endpoint}`. Returns true if status 200, false otherwise. Timeout after 5 seconds.

Uses `std.http.Client` for the check.

Test: start a simple HTTP server in test, verify health check returns true. Verify timeout on non-listening port returns false.

**Commit:** `feat: add HTTP health checker for instance monitoring`

---

### Task 10: Supervisor manager

**Files:**
- Create: `src/supervisor/manager.zig`
- Create: `src/supervisor/autostart.zig`
- Modify: `src/root.zig`

Central coordinator. Holds `StringHashMap(ManagedInstance)` keyed by `"{component}/{name}"`.

Functions:
- `Manager.init(allocator, paths, state) → Manager`
- `Manager.startInstance(component, name, manifest) → !void`
- `Manager.stopInstance(component, name) → !void`
- `Manager.restartInstance(component, name) → !void`
- `Manager.tick() → void` (called every 1s from supervisor thread)
- `Manager.getStatus(component, name) → ?InstanceStatus`
- `Manager.getAllStatuses(allocator) → []InstanceStatus`
- `Manager.reAdopt(allocator, state) → void` (on NullHub restart, check PIDs)

`tick()` implements the state machine: starting→running→restarting→failed.

Autostart: on NullHub start, iterate state.json, start all `auto_start: true`.

Supervisor runs in a separate thread, spawned from `main.zig` alongside the HTTP server.

**Commit:** `feat: add supervisor manager with health checks, restart backoff, re-adoption`

---

## Phase 4: Installer

### Task 11: GitHub Releases registry

**Files:**
- Create: `src/installer/registry.zig`

Query GitHub API for available versions:
- `fetchLatestVersion(allocator, repo) → []const u8`
- `fetchReleaseAssetUrl(allocator, repo, tag, asset_name) → []const u8`
- `fetchManifestFromRelease(allocator, repo, tag) → Manifest`

Uses `std.http.Client` to `GET https://api.github.com/repos/{repo}/releases/latest`.

Parses response JSON to extract tag_name and asset download URLs.

Known components hardcoded:
```zig
const known_components = [_]KnownComponent{
    .{ .name = "nullclaw", .repo = "nullclaw/nullclaw" },
    .{ .name = "nullboiler", .repo = "nullclaw/nullboiler" },
    .{ .name = "nulltickets", .repo = "nullclaw/nulltickets" },
};
```

Test: mock not practical for HTTP. Write test that validates URL construction and JSON response parsing with sample data.

**Commit:** `feat: add GitHub Releases registry for version and asset discovery`

---

### Task 12: Binary downloader

**Files:**
- Create: `src/installer/downloader.zig`

Download file from URL to disk with:
- Progress callback (bytes downloaded / total)
- SHA256 checksum verification
- Atomic: download to temp, verify, rename to final path
- chmod +x on unix

Functions:
- `download(allocator, url, dest_path, expected_sha256) → !void`
- `downloadWithProgress(allocator, url, dest_path, sha256, progress_fn) → !void`

Test: download a small known file, verify checksum.

**Commit:** `feat: add binary downloader with checksum verification`

---

### Task 13: UI module downloader

**Files:**
- Create: `src/installer/ui_modules.zig`

Download and extract UI module bundles from GitHub Releases:
- Download tarball/zip asset
- Extract to `~/.nullhub/ui/{module}@{version}/`

Reuses downloader.zig for the HTTP download.

**Commit:** `feat: add UI module bundle downloader and extractor`

---

## Phase 5: Wizard Engine

### Task 14: Wizard engine (step interpretation)

**Files:**
- Create: `src/wizard/engine.zig`

Interpret manifest wizard steps. For API mode (web UI), this just validates answers against steps. For CLI mode, prompts user interactively.

Functions:
- `validateAnswers(steps, answers) → !void` — check required fields, conditions
- `evaluateCondition(condition, answers) → bool` — evaluate step visibility
- `getVisibleSteps(steps, answers) → []WizardStep` — filter by conditions

Test: given steps with conditions, verify condition evaluation, visible step filtering, required field validation.

**Commit:** `feat: add wizard engine for manifest step interpretation and validation`

---

### Task 15: Config writer (writes_to resolution)

**Files:**
- Create: `src/wizard/config_writer.zig`

Take wizard answers and produce config.json by resolving `writes_to` paths:
- `"gateway.port"` → `{"gateway": {"port": value}}`
- `"models.providers.{value}"` → substitute `{value}` from answer
- `"channels.telegram.accounts.default.bot_token"` → deep nesting

Functions:
- `generateConfig(allocator, steps, answers, defaults) → []const u8` (JSON string)
- `resolveWritesTo(template, answers) → []const u8` (resolve `{step_id}` refs)
- `setNestedValue(root, dot_path, value) → void`

Test extensively: simple paths, templated paths, nested objects, merging with defaults.

**Commit:** `feat: add config writer with writes_to path resolution and template substitution`

---

## Phase 6: API Endpoints

### Task 16: Components API

**Files:**
- Create: `src/api/components.zig`
- Modify: `src/server.zig` (add routes)

`GET /api/components` — list available components with installed versions and instance counts.
`GET /api/components/{name}/manifest` — return cached manifest.
`POST /api/components/refresh` — re-fetch manifests from GitHub.

**Commit:** `feat: add components catalog API endpoints`

---

### Task 17: Wizard API

**Files:**
- Create: `src/api/wizard.zig`
- Modify: `src/server.zig`

`GET /api/wizard/{component}` — return wizard steps + available versions.
`POST /api/wizard/{component}` — execute full install flow, SSE progress stream.

SSE format:
```
event: step\ndata: {"phase": "downloading", "message": "..."}\n\n
event: step\ndata: {"phase": "config", "message": "..."}\n\n
event: done\ndata: {"instance": "name", "component": "comp"}\n\n
```

Install orchestration: download binary → generate config → create dirs → download UI modules → start instance.

**Commit:** `feat: add wizard API with SSE install progress streaming`

---

### Task 18: Instances API

**Files:**
- Create: `src/api/instances.zig`
- Modify: `src/server.zig`

`GET /api/instances` — all instances grouped by component.
`GET /api/instances/{c}/{n}` — instance detail with live metrics.
`POST /api/instances/{c}/{n}/start`
`POST /api/instances/{c}/{n}/stop`
`POST /api/instances/{c}/{n}/restart`
`DELETE /api/instances/{c}/{n}`
`PATCH /api/instances/{c}/{n}` — update settings (auto_start, etc.)

**Commit:** `feat: add instances CRUD and lifecycle API endpoints`

---

### Task 19: Status, Config, Logs API

**Files:**
- Create: `src/api/status.zig`
- Create: `src/api/config.zig`
- Create: `src/api/logs.zig`
- Modify: `src/server.zig`

`GET /api/status` — aggregated dashboard data.
`GET /api/instances/{c}/{n}/config` — instance config.
`PUT /api/instances/{c}/{n}/config` — replace config.
`PATCH /api/instances/{c}/{n}/config` — partial update (dot-notation).
`GET /api/instances/{c}/{n}/logs?lines=100` — tail logs.
`GET /api/instances/{c}/{n}/logs/stream` — SSE live tail.

**Commit:** `feat: add status dashboard, config editor, and log streaming APIs`

---

### Task 20: Updates API

**Files:**
- Create: `src/api/updates.zig`
- Modify: `src/server.zig`

`GET /api/updates` — check for updates across all components.
`POST /api/instances/{c}/{n}/update` — apply update with SSE progress + rollback on failure.

**Commit:** `feat: add update checking and apply API with rollback support`

---

### Task 21: Settings & Service API

**Files:**
- Modify: `src/server.zig`

`GET/PUT /api/settings` — hub config (port, host, auth_token).
`POST /api/service/install` — register as OS service.
`POST /api/service/uninstall` — unregister.
`GET /api/service/status` — service status.

OS service: generate systemd unit / launchd plist / Windows scheduled task.

**Commit:** `feat: add hub settings and OS service registration APIs`

---

### Task 22: Auth middleware

**Files:**
- Create: `src/auth.zig`
- Modify: `src/server.zig`

If `config.json` has `auth_token` set, all `/api/*` requests require `Authorization: Bearer {token}`. Skip auth for `GET /health`.

**Commit:** `feat: add optional bearer token auth for remote access`

---

## Phase 7: Hub UI (Svelte)

### Task 23: Scaffold Svelte project

**Files:**
- Create: `ui/package.json`
- Create: `ui/svelte.config.js`
- Create: `ui/vite.config.ts`
- Create: `ui/tsconfig.json`
- Create: `ui/src/app.css`
- Create: `ui/src/app.d.ts`
- Create: `ui/src/routes/+layout.svelte`
- Create: `ui/src/routes/+page.svelte`

Init SvelteKit with adapter-static, fallback index.html. Reuse theme system from nullclaw-chat-ui (CSS variables, JetBrains Mono font). Set up API client stub.

Run: `cd ui && npm install && npm run build`
Expected: `ui/build/` contains index.html + assets.

**Commit:** `feat: scaffold Hub UI with SvelteKit, static adapter, and theme system`

---

### Task 24: Layout shell (Sidebar + TopBar)

**Files:**
- Create: `ui/src/lib/components/Sidebar.svelte`
- Create: `ui/src/lib/components/TopBar.svelte`
- Modify: `ui/src/routes/+layout.svelte`

Sidebar: dynamic nav from `/api/instances`. Groups by component. Status indicators. "Install" button. UI module links at bottom.

TopBar: "NullHub" title, theme toggle, settings gear.

**Commit:** `feat: add layout shell with sidebar navigation and top bar`

---

### Task 25: Dashboard page

**Files:**
- Create: `ui/src/lib/components/InstanceCard.svelte`
- Create: `ui/src/lib/components/StatusBadge.svelte`
- Create: `ui/src/lib/stores/instances.svelte.ts`
- Create: `ui/src/lib/api/client.ts`
- Modify: `ui/src/routes/+page.svelte`

Dashboard: grid of InstanceCards. Each card shows: name, component, status badge, uptime, RSS memory, port. Quick actions: start/stop. "Install Component" button.

Store: polls `GET /api/status` every 5 seconds.

**Commit:** `feat: add dashboard with instance cards and status polling`

---

### Task 26: Install wizard page

**Files:**
- Create: `ui/src/lib/components/ComponentCard.svelte`
- Create: `ui/src/lib/components/WizardRenderer.svelte`
- Create: `ui/src/lib/components/WizardStep.svelte`
- Create: `ui/src/routes/install/+page.svelte`
- Create: `ui/src/routes/install/[component]/+page.svelte`

Install page: component catalog (cards from `/api/components`).
Wizard page: renders steps from manifest. Supports select, multi_select, text, secret, number, toggle. Conditional step visibility. SSE progress on submit.

**Commit:** `feat: add component catalog and wizard renderer for guided installation`

---

### Task 27: Instance detail page

**Files:**
- Create: `ui/src/lib/components/LogViewer.svelte`
- Create: `ui/src/lib/components/ConfigEditor.svelte`
- Create: `ui/src/routes/instances/[component]/[name]/+page.svelte`
- Create: `ui/src/routes/instances/[component]/[name]/config/+page.svelte`

Instance detail: tabs (Overview, Config, Logs). Overview: status, uptime, memory, ports, connections. Actions: start/stop/restart/update/delete. Config tab: JSON editor. Logs tab: SSE streaming log viewer.

**Commit:** `feat: add instance detail page with config editor and log viewer`

---

### Task 28: Settings page

**Files:**
- Create: `ui/src/routes/settings/+page.svelte`

Hub settings: port, host, auth token, auto-update check interval. Service registration button ("Enable Autostart").

**Commit:** `feat: add hub settings page with service registration`

---

### Task 29: Module frame for external UI modules

**Files:**
- Create: `ui/src/lib/components/ModuleFrame.svelte`

Dynamic import of `module.js` from `/ui/{module}/module.js`. Calls `create(container, props)` from Svelte 5. Props: instanceUrl, token, theme.

**Commit:** `feat: add ModuleFrame for Svelte-native UI module mounting`

---

## Phase 8: Embed UI in Binary

### Task 30: Embed built UI in Zig binary

**Files:**
- Modify: `build.zig` (add UI build step + @embedFile)
- Modify: `src/server.zig` (serve embedded files)

Build process:
1. `build.zig` runs `npm run build` in `ui/` as a build step
2. Embed `ui/build/` contents via `@embedFile` (or serve from disk during dev)
3. `server.zig` serves embedded files for non-`/api/*` routes
4. Content-Type detection based on file extension

For dev mode: serve from `ui/build/` directory on disk (no embedding).
For release: `@embedFile` the build output.

**Commit:** `feat: embed Svelte UI build into Zig binary for zero-dependency distribution`

---

## Phase 9: Integration & Polish

### Task 31: End-to-end test script

**Files:**
- Create: `tests/test_e2e.sh`

Script that:
1. Builds nullhub
2. Starts it on a test port
3. Curls API endpoints
4. Creates a mock manifest
5. Tests install flow (with a mock binary)
6. Tests start/stop/status
7. Cleans up

Follow pattern from `../nulltickets/tests/test_e2e.sh`.

**Commit:** `feat: add end-to-end test script`

---

### Task 32: Create nullhub-manifest.json for each component

**Files:**
- Create: `/Users/igorsomov/Code/null/nullclaw/nullhub-manifest.json`
- Create: `/Users/igorsomov/Code/null/NullBoiler/nullhub-manifest.json`
- Create: `/Users/igorsomov/Code/null/nulltickets/nullhub-manifest.json`

Real manifests for each component based on their actual config schemas, wizard steps, ports, and health endpoints.

**Commit (per repo):** `feat: add nullhub-manifest.json for hub integration`

---

### Task 33: Discovery / connects_to implementation

**Files:**
- Modify: `src/api/wizard.zig`
- Modify: `src/wizard/engine.zig`

After wizard completes, scan existing instances for `connects_to` matches. Present connection options. Apply `auto_config.self_patch` templates.

**Commit:** `feat: add inter-component discovery and auto-configuration`

---

### Task 34: Build-from-source support

**Files:**
- Create: `src/installer/builder.zig`

Detect zig on PATH, verify version matches manifest. Clone repo to cache, run build command, copy output to bin/.

**Commit:** `feat: add build-from-source installer option`

---

### Task 35: README and CLAUDE.md

**Files:**
- Create: `README.md`
- Create: `CLAUDE.md`

README: overview, quick start, features, architecture.
CLAUDE.md: build commands, architecture guide, testing info.

**Commit:** `docs: add README and CLAUDE.md`

---

## Dependency Graph

```
Task 1 (scaffold)
├── Task 2 (paths)
├── Task 3 (platform)
├── Task 4 (manifest)
└── Task 5 (state)
    ├── Task 6 (HTTP server)
    │   ├── Task 16 (components API)
    │   ├── Task 17 (wizard API) ← depends on Tasks 14, 15
    │   ├── Task 18 (instances API)
    │   ├── Task 19 (status/config/logs API)
    │   ├── Task 20 (updates API)
    │   ├── Task 21 (settings/service API)
    │   └── Task 22 (auth)
    ├── Task 7 (CLI)
    ├── Task 8 (process spawn)
    │   ├── Task 9 (health check)
    │   └── Task 10 (manager) ← depends on Tasks 8, 9
    ├── Task 11 (registry)
    │   ├── Task 12 (downloader)
    │   └── Task 13 (UI module downloader)
    └── Tasks 14-15 (wizard engine)

Tasks 23-29 (UI) — can be developed in parallel with Phase 3-6
Task 30 (embed) ← depends on Tasks 6, 23-29
Task 31 (e2e) ← depends on all backend tasks
Tasks 32-35 — final integration
```
