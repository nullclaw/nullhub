# NullHub

The simplest way to install, configure, and manage
[NullClaw](https://github.com/nullclaw/nullclaw).

Management hub for the nullclaw ecosystem.

`NullHub` is a single Zig binary with an embedded Svelte web UI for installing,
configuring, monitoring, and updating ecosystem components (NullClaw, NullBoiler,
NullTickets).

## Features

- **Install wizard** -- manifest-driven guided setup with component-aware flows and local `NullTickets -> NullBoiler` linking
- **Process supervision** -- start, stop, restart, crash recovery with backoff
- **Health monitoring** -- periodic HTTP health checks, dashboard status cards
- **Cross-component linking** -- auto-connect `NullTickets -> NullBoiler`, generate native tracker config, and inspect queue/orchestrator status from one UI
- **Config management** -- structured editors for `NullClaw`, `NullBoiler`, and `NullTickets`, with raw JSON fallback when needed
- **Log viewing** -- tail and live SSE streaming per instance
- **One-click updates** -- download, migrate config, rollback on failure
- **Multi-instance** -- run multiple instances of the same component side by side
- **Web UI + CLI** -- browser dashboard for humans, CLI for automation
- **Orchestration UI** -- workflow editor, poll-based run monitoring, checkpoint forking, encoded workflow/run/store links, and key-value store browser (proxied to NullTickets through NullHub)

## Quick Start

```bash
zig build
./zig-out/bin/nullhub
```

Opens browser to [http://nullhub.localhost:19800](http://nullhub.localhost:19800).
The resulting binary includes the built web UI; it no longer depends on a
runtime `ui/build` directory.

Local access chain:

- `http://nullhub.local:19800`
- `http://nullhub.localhost:19800`
- `http://127.0.0.1:19800`

`nullhub` tries to publish `nullhub.local` through `dns-sd`/Bonjour or
`avahi-publish` when those tools are available, and otherwise falls back to
`nullhub.localhost` and finally `127.0.0.1`.

### Runtime Prerequisites

- `curl` is required to fetch releases and binaries.
- `tar` is required to extract UI module bundles.

### Build Prerequisites

- `npm` is required for `zig build` and `zig build test` because the Svelte UI is
  built and embedded into the binary during the Zig build.

When these tools are missing, `nullhub` will try to install them automatically
via available system package managers (`apt`, `dnf`, `yum`, `pacman`, `zypper`,
`apk`, `brew`, `winget`, `choco`).

## CLI Usage

```
nullhub                          # Start server + open browser
nullhub serve [--port N]         # Start server without browser
nullhub version | -v | --version # Print version

nullhub install <component>      # Terminal wizard
nullhub uninstall <c>/<n>        # Remove instance

nullhub start <c>/<n>            # Start instance
nullhub stop <c>/<n>             # Stop instance
nullhub restart <c>/<n>          # Restart instance
nullhub start-all / stop-all     # Bulk start/stop

nullhub status                   # Table of all instances
nullhub status <c>/<n>           # Single instance detail
nullhub logs <c>/<n> [-f]        # Tail logs (-f for follow)

nullhub check-updates            # Check for new versions
nullhub update <c>/<n>           # Update single instance
nullhub update-all               # Update everything

nullhub config <c>/<n> [--edit]  # View/edit config
nullhub service install          # Register/start OS service (systemd/launchd)
nullhub service uninstall        # Remove OS service
nullhub service status           # Show OS service status
```

Instance addressing uses `{component}/{instance-name}` everywhere.

## Architecture

**Zig backend** -- HTTP server, process supervisor, installer, manifest engine.
Two modes: server (HTTP + supervisor threads) or CLI (direct calls, stdout, exit).

**Svelte frontend** -- SvelteKit with static adapter, `@embedFile`'d into the
binary. Component UI modules (chat, monitor) loaded dynamically via Svelte 5
`mount()`.

**Manifest-driven** -- each component publishes `nullhub-manifest.json` that
describes installation, configuration, launch, health checks, wizard steps, and
UI modules. NullHub is a generic engine that interprets manifests.

**Storage** -- all state lives under `~/.nullhub/` (config, instances, binaries,
logs, cached manifests).

**Orchestration proxy** -- requests to `/api/orchestration/*` are reverse-proxied
to the local orchestration stack. Most routes go to NullBoiler's REST API via
`NULLBOILER_URL` (e.g. `http://localhost:8080`) and optional `NULLBOILER_TOKEN`.
`/api/orchestration/store/*` is proxied to NullTickets via `NULLTICKETS_URL` and
optional `NULLTICKETS_TOKEN`.

## Development

Backend:

```bash
zig build test
```

Frontend:

```bash
cd ui && npm run dev
```

End-to-end:

```bash
./tests/test_e2e.sh
```

## Tech Stack

- Zig 0.15.2
- Svelte 5 + SvelteKit (static adapter)
- JSON over HTTP/1.1
- SSE for instance log streaming
- Poll-based orchestration run updates over the `/orchestration/runs/{id}/stream` API

## Project Layout

```
src/
  main.zig              # Entry: CLI dispatch or server start
  cli.zig               # CLI command parser & handlers
  server.zig            # HTTP server (API + static UI)
  auth.zig              # Optional bearer token auth
  api/                  # REST endpoints (components, instances, wizard, ...)
    orchestration.zig   # Reverse proxy to NullBoiler orchestration API
  core/                 # Manifest parser, state, platform, paths
  installer/            # Download, build, UI module fetching
  supervisor/           # Process spawn, health checks, manager
ui/src/
  routes/               # SvelteKit pages
    orchestration/      # Orchestration pages (dashboard, workflows, runs, store)
  lib/components/       # Reusable Svelte components
    orchestration/      # GraphViewer, StateInspector, RunEventLog, InterruptPanel,
                        # CheckpointTimeline, WorkflowJsonEditor, NodeCard, SendProgressBar
  lib/api/              # Typed API client
tests/
  test_e2e.sh           # End-to-end test script
```
