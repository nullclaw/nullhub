# NullHub

[English](./README.md) | [简体中文](./README.zh-CN.md) | [日本語](./README.ja.md)

The simplest way to install, configure, and manage
[NullClaw](https://github.com/nullclaw/nullclaw).

Management hub for the nullclaw ecosystem.

`NullHub` is a single Zig binary with an embedded Svelte web UI for installing,
configuring, monitoring, and updating ecosystem components (NullClaw, NullBoiler,
NullTickets, NullWatch).

## Features

- **Install wizard** -- manifest-driven guided setup with component-aware flows and local `NullTickets -> NullBoiler` linking
- **Process supervision** -- start, stop, restart, crash recovery with backoff
- **Health monitoring** -- periodic HTTP health checks, dashboard status cards
- **Cross-component linking** -- auto-connect `NullTickets -> NullBoiler`, generate native tracker config, and inspect queue/orchestrator status from one UI
- **Config management** -- structured editors for `NullClaw`, `NullBoiler`, `NullTickets`, and `NullWatch`, plus direct raw JSON editing when needed
- **Log viewing** -- tail and live SSE streaming per instance
- **One-click updates** -- download, migrate config, rollback on failure
- **Multi-instance** -- run multiple instances of the same component side by side
- **Web UI + CLI** -- browser dashboard for humans, CLI for automation
- **Managed instance admin API** -- instance-scoped status, config, models, cron, channels, and skills routes for managed NullClaw installs
- **NullBoiler UI** -- workflow editor, poll-based run monitoring, checkpoint forking, and encoded workflow/run links
- **NullTickets Store** -- key-value store browser proxied to NullTickets through NullHub
- **NullWatch Flight Recorder** -- local NullWatch run summaries, span timelines, eval results, token usage, cost, and error context through a NullHub proxy
- **Mission Control** -- local-first agent mission replay with workflow execution, role-based agents, failure, checkpoint recovery, durable replay storage, and live telemetry in one screen

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

- `npm` is required for `zig build` and for any build that embeds the Svelte UI.
- Backend-only tests can run without UI assets via `zig build test -Dembed-ui=false -Dbuild-ui=false`.

When these tools are missing, `nullhub` will try to install them automatically
via available system package managers (`apt`, `dnf`, `yum`, `pacman`, `zypper`,
`apk`, `brew`, `winget`, `choco`).

## CLI Usage

```
nullhub                          # Start server + open browser
nullhub serve [--host H] [--port N]
               [--allowed-origin ORIGIN] ...
                                 # Start server. Repeat --allowed-origin to
                                 # authorize extra CORS origins (e.g. a
                                 # Tailscale domain). Origins may also come
                                 # from NULLHUB_ALLOWED_ORIGINS as a
                                 # comma-separated list.
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
nullhub api GET /api/instances/nullclaw/<n>/status --pretty
nullhub api GET /api/instances/nullclaw/<n>/cron --pretty
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

**NullBoiler proxy** -- requests to `/api/nullboiler/*` are reverse-proxied
to NullBoiler's REST API via
`NULLBOILER_URL` (e.g. `http://localhost:8080`) and optional `NULLBOILER_TOKEN`.

**NullTickets store proxy** -- requests to `/api/nulltickets/store/*` are
proxied to NullTickets via `NULLTICKETS_URL` and
optional `NULLTICKETS_TOKEN`.

**NullWatch proxy** -- requests to `/api/nullwatch/*` are reverse-proxied
to the managed NullWatch instance installed in NullHub. `NULLWATCH_URL` can
still override the target for an external NullWatch instance, and
`NULLWATCH_TOKEN` overrides the managed instance token when set. The built-in
NullWatch page uses this proxy to display run summaries, spans, evals,
latency, cost, and failure context without sending data to hosted services.

Local NullWatch setup:

1. Start NullHub:

   ```bash
   zig build run -- serve --no-open
   ```

2. In the web UI, open **Install Component**, select **NullWatch**, keep or set
   the API port to `7710`, and finish the wizard. The installer starts the
   NullWatch instance and the NullWatch proxy discovers it automatically.

**Mission Control API** -- requests to `/api/mission-control/*` drive a
deterministic local replay scenario for the `/mission-control` page. It does
not require hosted infrastructure or model secrets, and it hydrates with real
NullBoiler workflow evidence and NullWatch trace detail when matching local
instances are available. Responses include a schema version, scenario id,
deterministic replay mode, controls, graph, timeline, telemetry, NullWatch-style
run/span/eval trace references, and structured conflict errors for invalid
actions. The scenario lives in a versioned embedded replay fixture at
`src/core/mission_control/code_red.v1.json`; `zig build test` validates fixture
schema, references, ordering, required phases, graph links, and telemetry phase
coverage. Mission timeline trace links deep-link to `/nullwatch?run_id=...`.
When a managed NullWatch instance is running, `/mission-control` hydrates the
failure and recovery trace panels from live run detail through the NullWatch
proxy and preserves the selected watch in trace links. When a managed
NullBoiler instance has matching workflow evidence, the Mission Control API
includes that instance name with real workflow run links and checkpoint metadata
resolved through the NullBoiler proxy.
`GET /api/mission-control/replay` exports the current snapshot, source fixture,
the side-by-side failed/recovered replay artifact comparison once the recovered
run completes, and ecosystem mapping metadata as a portable JSON artifact for
debugging and review. `POST /api/mission-control/replay/save` stores that
artifact under `~/.nullhub/mission-control/replays/`; `GET
/api/mission-control/replays` lists saved replay records and `GET
/api/mission-control/replays/{id}` reads the durable artifact back.

### Mission Control Replay

Start NullHub locally and open `/mission-control`:

```bash
zig build run -- serve --host 127.0.0.1 --port 19802 --no-open
```

The page provides `Replay Mission`, `Reset`, `Launch Mission`, and
`Fork From Checkpoint` controls. `Replay Mission` runs the deterministic reset,
launch, failure hold, checkpoint fork, and recovered replay sequence from one
click. Timeline events include trace chips that map the replay back to local
NullWatch-style run ids, span ids, operations, and eval keys. The page also
includes phase milestones and a failed-vs-recovered replay artifact comparison
panel.

Export the current replay artifact:

```bash
curl -fsS http://127.0.0.1:19802/api/mission-control/replay \
  -o mission-control-replay.json
```

The same export is available from the `Save Replay` button in Mission Control,
which also writes a durable server-side copy.
See `docs/mission-control.md` for the artifact shape and ecosystem mapping.

Run the live API smoke test against a started server:

```bash
NULLHUB_URL=http://127.0.0.1:19802 ./tests/test_mission_control_smoke.sh
```

## Development

Testing strategy and roadmap live in [TESTING.md](TESTING.md).

Backend:

```bash
zig build test -Dembed-ui=false -Dbuild-ui=false --summary all
zig build test-integration -Dembed-ui=false -Dbuild-ui=false --summary all
```

Frontend:

```bash
cd ui && npm run dev
```

End-to-end:

```bash
./tests/test_e2e.sh
NULLHUB_URL=http://127.0.0.1:19802 ./tests/test_mission_control_smoke.sh
```

`zig build test-integration` runs structured backend HTTP integration tests
against a real `nullhub` process started in a temporary home directory.

## Tech Stack

- Zig 0.16.0
- Svelte 5 + SvelteKit (static adapter)
- JSON over HTTP/1.1
- SSE for instance log streaming
- Poll-based NullBoiler run updates over the `/api/nullboiler/runs/{id}/stream` API

## Project Layout

```
src/
  main.zig              # Entry: CLI dispatch or server start
  cli.zig               # CLI command parser & handlers
  server.zig            # HTTP server (API + static UI)
  auth.zig              # Optional bearer token auth
  api/                  # REST endpoints (components, instances, wizard, ...)
    nullboiler.zig      # Reverse proxy to NullBoiler workflow/run API
    nulltickets.zig     # Reverse proxy to NullTickets store API
    nullwatch.zig       # Reverse proxy to NullWatch tracing/eval API
    mission_control.zig # HTTP adapter for local mission replay commands
  core/                 # Manifest parser, state, platform, paths
    mission_control.zig # Local deterministic agent mission domain model
    mission_control_replay.zig # Typed replay fixture parser and validator
    mission_control/    # Embedded Mission Control replay fixtures
  installer/            # Download, build, UI module fetching
  supervisor/           # Process spawn, health checks, manager
ui/src/
  routes/               # SvelteKit pages
    nullboiler/         # NullBoiler pages (dashboard, workflows, runs)
    nulltickets/        # NullTickets pages (store)
    nullwatch/          # NullWatch Flight Recorder page
    mission-control/    # Local agent mission control room
  lib/components/       # Reusable Svelte components
    nullboiler/         # GraphViewer, StateInspector, RunEventLog, InterruptPanel,
                        # CheckpointTimeline, WorkflowJsonEditor, NodeCard, SendProgressBar
    nulltickets/        # NullTickets store selectors and controls
  lib/api/              # Typed API client
  lib/missionControl/   # Mission Control feature helpers
tests/
  test_e2e.sh           # End-to-end test script
docs/
  mission-control.md    # Mission Control replay and artifact contract
```
