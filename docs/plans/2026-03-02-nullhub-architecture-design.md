# NullHub Architecture Design

**Date:** 2026-03-02
**Status:** Approved

## Overview

NullHub is a management hub for the nullclaw ecosystem. Single Zig binary that provides web UI and CLI for installing, configuring, monitoring, and updating ecosystem components (NullClaw, NullBoiler, NullTickets, and future components).

**Core principle:** Manifest-driven. Each component publishes a `nullhub-manifest.json` that describes how to install, configure, launch, and monitor it. NullHub is a generic engine that interprets manifests.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Manifest-driven plugins | Scales for growing number of components without NullHub releases |
| Binary distribution | Pre-built from GitHub Releases + build from source option | Simple for non-engineers, flexible for developers |
| UI module integration | Svelte native `mount()` | Everything is Svelte, native scoping, no iframe/Shadow DOM overhead |
| Entry point | Single binary with CLI + web UI | CLI for automation, web for humans |
| Process management | NullHub as supervisor (child processes) | Cross-platform, simple |
| Storage | `~/.nullhub/` directory | Portable, no external dependencies |
| Multi-instance | Yes, grouped by component | `instances/{component}/{name}/` |
| Access | Local by default + optional remote with bearer token | Secure by default, flexible |
| NullHub self-supervision | OS service registration (systemd/launchd) | Components survive NullHub crash via PID re-adoption |
| Manifest reuse | Component `--onboard` reads its own manifest | Single source of truth for wizard steps |

## 1. Component Manifest Format

Each component repo contains `nullhub-manifest.json` at root. Published alongside releases.

```json
{
  "schema_version": 1,
  "name": "nullclaw",
  "display_name": "NullClaw",
  "description": "Autonomous AI agent runtime",
  "icon": "agent",
  "repo": "nullclaw/nullclaw",

  "platforms": {
    "x86_64-linux": { "asset": "nullclaw-linux-x86_64", "binary": "nullclaw" },
    "aarch64-linux": { "asset": "nullclaw-linux-aarch64", "binary": "nullclaw" },
    "aarch64-macos": { "asset": "nullclaw-macos-aarch64", "binary": "nullclaw" },
    "x86_64-macos": { "asset": "nullclaw-macos-x86_64", "binary": "nullclaw" },
    "x86_64-windows": { "asset": "nullclaw-windows-x86_64.exe", "binary": "nullclaw.exe" }
  },

  "build_from_source": {
    "zig_version": "0.15.2",
    "command": "zig build -Doptimize=ReleaseSmall",
    "output": "zig-out/bin/nullclaw"
  },

  "config": {
    "path": "config.json",
    "schema": { ... }
  },

  "launch": {
    "command": "gateway",
    "args": [],
    "env": {}
  },

  "health": {
    "endpoint": "/health",
    "port_from_config": "gateway.port",
    "interval_ms": 15000
  },

  "ports": [
    { "name": "gateway", "config_key": "gateway.port", "default": 3000, "protocol": "http" }
  ],

  "wizard": {
    "steps": [
      {
        "id": "provider",
        "title": "AI Provider",
        "description": "Choose your AI model provider",
        "type": "select",
        "required": true,
        "options": [
          { "value": "openrouter", "label": "OpenRouter", "description": "Access 200+ models" },
          { "value": "anthropic", "label": "Anthropic", "description": "Claude models" },
          { "value": "ollama", "label": "Ollama", "description": "Local models, no API key needed" }
        ],
        "writes_to": "models.providers.{value}"
      },
      {
        "id": "api_key",
        "title": "API Key",
        "type": "secret",
        "required": true,
        "condition": { "step": "provider", "not_equals": "ollama" },
        "writes_to": "models.providers.{provider.value}.api_key"
      },
      {
        "id": "channels",
        "title": "Channels",
        "type": "multi_select",
        "required": true,
        "options": [
          { "value": "web", "label": "Web Chat" },
          { "value": "telegram", "label": "Telegram" },
          { "value": "discord", "label": "Discord" }
        ],
        "writes_to": "channels"
      },
      {
        "id": "telegram_token",
        "title": "Telegram Bot Token",
        "type": "secret",
        "required": true,
        "condition": { "step": "channels", "contains": "telegram" },
        "writes_to": "channels.telegram.accounts.default.bot_token"
      }
    ]
  },

  "ui_modules": [
    {
      "name": "nullclaw-chat-ui",
      "repo": "nullclaw/nullclaw-chat-ui",
      "mount_path": "/chat",
      "label": "Chat",
      "icon": "message"
    }
  ],

  "depends_on": [],

  "connects_to": [
    {
      "component": "nullboiler",
      "role": "worker",
      "auto_config": {
        "self_patch": {
          "path": "workers[+]",
          "template": {
            "id": "{{target.instance_name}}",
            "url": "http://127.0.0.1:{{target.port.gateway}}/webhook",
            "protocol": "webhook",
            "tags": ["agent"]
          }
        }
      }
    }
  ],

  "migrations": [
    {
      "from": "2026.2.*",
      "to": "2026.3.*",
      "actions": [
        { "rename": { "old": "gateway.bind", "new": "gateway.host" } },
        { "add": { "path": "gateway.require_pairing", "value": true } }
      ]
    }
  ]
}
```

Wizard step types: `select`, `multi_select`, `secret`, `text`, `number`, `toggle`.
Conditions: `equals`, `not_equals`, `contains` referencing previous step values.

## 2. Directory Layout

```
~/.nullhub/
├── config.json                        # NullHub own config (port, auth, theme)
├── state.json                         # Registry of all instances
├── manifests/                         # Cached component manifests
│   └── {component}@{version}.json
├── bin/                               # Versioned binaries (shared across instances)
│   └── {component}-{version}
├── instances/                         # Grouped by component
│   └── {component}/
│       └── {instance-name}/
│           ├── instance.json          # Metadata (version, ports, auto_start, pid)
│           ├── config.json            # Generated component config
│           ├── data/                  # Working directory
│           └── logs/
│               ├── stdout.log
│               └── stderr.log
├── ui/                                # Downloaded UI module bundles
│   ├── hub/                           # Embedded hub UI
│   └── {module-name}@{version}/
└── cache/
    └── downloads/
```

`state.json` groups instances by component:

```json
{
  "instances": {
    "nullclaw": {
      "my-agent": { "version": "2026.3.1", "auto_start": true },
      "staging": { "version": "2026.3.1", "auto_start": false }
    },
    "nulltickets": {
      "tracker": { "version": "0.1.0", "auto_start": true }
    }
  }
}
```

## 3. Backend Architecture (Zig)

```
src/
├── main.zig              # Entry: CLI dispatch or server start
├── root.zig              # Module exports
├── cli.zig               # CLI command parser & handlers
├── server.zig            # HTTP server (API + static UI)
├── auth.zig              # Optional bearer token auth
├── api/
│   ├── components.zig    # Component catalog endpoints
│   ├── instances.zig     # Instance CRUD + start/stop/restart
│   ├── wizard.zig        # Wizard steps & execution (SSE progress)
│   ├── status.zig        # Aggregated status for dashboard
│   ├── updates.zig       # Check & apply updates (SSE progress)
│   ├── logs.zig          # Log tail & SSE streaming
│   └── config.zig        # Instance config get/put/patch
├── core/
│   ├── manifest.zig      # Manifest parser & validator
│   ├── state.zig         # state.json atomic read/write
│   ├── platform.zig      # OS/arch detection
│   └── paths.zig         # ~/.nullhub/ path resolution
├── installer/
│   ├── registry.zig      # GitHub Releases API queries
│   ├── downloader.zig    # Download + SHA256 verify
│   ├── builder.zig       # Build from source (zig detection)
│   └── ui_modules.zig    # Download & extract UI bundles
├── supervisor/
│   ├── process.zig       # Spawn child, redirect stdout/stderr
│   ├── manager.zig       # Central coordinator (start/stop/tick)
│   ├── health.zig        # Periodic HTTP health checks
│   └── autostart.zig     # Launch auto_start instances on hub start
└── wizard/
    ├── engine.zig        # Interpret manifest wizard steps
    ├── config_writer.zig # writes_to resolution → config.json
    └── validator.zig     # Input validation against schema
```

Two modes:
- **Server mode** (`nullhub` / `nullhub serve`): HTTP thread + supervisor thread + opens browser
- **CLI mode** (`nullhub install/start/stop/...`): direct module calls, stdout output, exit

Hub UI is `@embedFile`'d into binary. Module UIs served from `~/.nullhub/ui/`.

## 4. Hub UI Architecture (Svelte)

Svelte 5 + SvelteKit, static adapter, embedded in Zig binary.

```
ui/src/
├── routes/
│   ├── +layout.svelte           # Shell: sidebar + topbar + content
│   ├── +page.svelte             # Dashboard: instance cards grid
│   ├── install/
│   │   ├── +page.svelte         # Component catalog
│   │   └── [component]/+page.svelte  # Wizard
│   ├── instances/[component]/[name]/
│   │   ├── +page.svelte         # Instance detail (tabs: overview/config/logs)
│   │   └── config/+page.svelte  # Config editor
│   └── settings/+page.svelte    # Hub settings
└── lib/
    ├── components/
    │   ├── Sidebar.svelte        # Nav grouped by component + UI modules
    │   ├── TopBar.svelte
    │   ├── InstanceCard.svelte   # Dashboard card with status/metrics
    │   ├── ComponentCard.svelte  # Install catalog card
    │   ├── WizardRenderer.svelte # Generic wizard from manifest steps
    │   ├── WizardStep.svelte     # Individual step types
    │   ├── StatusBadge.svelte
    │   ├── LogViewer.svelte      # SSE log streaming
    │   ├── ConfigEditor.svelte
    │   └── ModuleFrame.svelte    # Svelte mount() for external UI modules
    ├── api/client.ts             # Typed API client
    └── stores/
        ├── instances.svelte.ts   # Polling /api/status
        └── hub.svelte.ts         # Hub config, theme
```

UI modules (chat, monitor) export `create(target, props)` function. NullHub dynamically imports `module.js` and calls `mount()` from Svelte 5.

## 5. Supervisor

**Instance lifecycle:** `stopped → starting → running → restarting → failed`

Supervisor thread runs `tick()` every 1 second:
- **starting**: check process alive + health endpoint → running (or timeout → failed)
- **running**: check process alive + periodic health → restarting on crash
- **restarting**: backoff (0s, 2s, 4s, 8s, 16s), max 5 attempts → failed
- **stopping**: SIGTERM → 10s wait → SIGKILL

PID written to `instance.json`. On NullHub restart, re-adopts alive processes by PID check.

Memory RSS read via platform-specific APIs (`/proc/{pid}/status`, `task_info`, `GetProcessMemoryInfo`).

Log rotation at 10MB. Graceful shutdown via SIGTERM on all platforms, SIGKILL as fallback.

NullHub self-supervision: `nullhub service install` registers as systemd/launchd/Windows service.

## 6. Installer & Updates

**Install flow:** Resolve binary (download or build) → generate config from wizard answers → create instance dir → download UI modules → auto-connect to existing instances → start.

**Update flow:** Download new binary → stop instance → update version → migrate config → start → health check → rollback on failure (old binary preserved).

**Config migration:** Declarative actions in manifest `migrations` field: `rename`, `add`, `remove`.

**Component registry:** Known components hardcoded in binary. Custom sources addable via `nullhub add-source <repo>`.

Checksums verified via SHA256 from release assets.

## 7. REST API

All endpoints under `/api`. Auth via `Authorization: Bearer {token}` when remote access enabled.

| Method | Path | Purpose |
|--------|------|---------|
| GET | /api/components | Available components catalog |
| GET | /api/components/{name}/manifest | Full manifest |
| POST | /api/components/refresh | Re-fetch manifests |
| POST | /api/components/add-source | Add custom component |
| GET | /api/wizard/{component} | Wizard steps + versions |
| POST | /api/wizard/{component} | Execute install (SSE) |
| GET | /api/instances | All instances grouped |
| GET | /api/instances/{c}/{n} | Instance detail |
| POST | /api/instances/{c}/{n}/start | Start |
| POST | /api/instances/{c}/{n}/stop | Stop |
| POST | /api/instances/{c}/{n}/restart | Restart |
| DELETE | /api/instances/{c}/{n} | Remove |
| PATCH | /api/instances/{c}/{n} | Update settings |
| GET | /api/instances/{c}/{n}/config | Get config |
| PUT | /api/instances/{c}/{n}/config | Replace config |
| PATCH | /api/instances/{c}/{n}/config | Partial update |
| GET | /api/instances/{c}/{n}/logs | Tail logs |
| GET | /api/instances/{c}/{n}/logs/stream | SSE live tail |
| GET | /api/updates | Check all updates |
| POST | /api/instances/{c}/{n}/update | Apply update (SSE) |
| GET | /api/status | Dashboard aggregate |
| GET/PUT | /api/settings | Hub settings |
| POST | /api/service/install | Register OS service |
| POST | /api/service/uninstall | Unregister OS service |
| GET | /api/service/status | Service status |

SSE used for long-running operations (install, update, log streaming).

## 8. Inter-component Discovery

`connects_to` in manifest describes optional links. When installing a new component, NullHub scans existing instances for matches and offers to auto-configure:

- User confirms which instances to link
- `auto_config.self_patch` template resolves `{{target.*}}` variables
- NullHub patches config of the new instance

Template variables: `{{target.instance_name}}`, `{{target.port.<name>}}`, `{{target.host}}`.

## 9. CLI

```
nullhub                          # Start server + open browser
nullhub serve [--port N --host H]

nullhub install <component>      # Terminal wizard
nullhub uninstall <c>/<n>
nullhub start <c>/<n>
nullhub stop <c>/<n>
nullhub restart <c>/<n>
nullhub start-all / stop-all

nullhub status                   # Table of all instances
nullhub status <c>/<n>
nullhub logs <c>/<n> [-f]

nullhub check-updates
nullhub update <c>/<n>
nullhub update-all

nullhub config <c>/<n> [--edit]
nullhub wizard <component>

nullhub service install/uninstall/status
nullhub add-source <repo-url>
nullhub version
```

Instance addressing: `{component}/{instance-name}` everywhere.
