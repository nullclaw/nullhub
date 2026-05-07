# Agent Flight Recorder

## Problem Discovered

NullWatch already provides the observability layer for the nullclaw ecosystem:
run summaries, spans, evals, OTLP ingest, cost, token usage, and failure context.
It also exports a NullHub-compatible manifest. NullHub already provides the
operator UI and orchestration pages, but it did not register NullWatch or expose
its tracing/eval data in the UI.

## Chosen Solution

Add a local-first Observability cockpit to NullHub:

- register `nullwatch` as a known component
- proxy `/api/observability/*` to a local NullWatch instance
- add a Flight Recorder page for runs, spans, evals, cost, tokens, and errors
- document the local demo flow with `NULLWATCH_URL`

## Why This Idea Was Chosen

This is stronger than a single CLI preflight because it connects multiple parts
of the ecosystem into a visible agent platform story: execution, orchestration,
task tracking, observability, and operations. It is still hackathon-sized because
it uses existing NullWatch APIs and NullHub UI patterns instead of changing core
agent runtime behavior.

## What Was Implemented

- NullWatch component registration in the NullHub registry.
- Observability reverse proxy with optional bearer token forwarding.
- Sidebar entry and `/observability` UI page.
- API client methods for NullWatch summary, runs, spans, evals, and health.
- README documentation for the proxy and local demo setup.

## Files Changed

- `src/installer/registry.zig`
- `src/api/observability.zig`
- `src/api/proxy.zig`
- `src/api/components.zig`
- `src/api/meta.zig`
- `src/root.zig`
- `src/server.zig`
- `ui/src/lib/api/client.ts`
- `ui/src/lib/components/Sidebar.svelte`
- `ui/src/routes/observability/+page.svelte`
- `README.md`
- `HACKATHON_SUBMISSION.md`

## How To Test Or Demo

Start NullWatch with sample data from the sibling repository:

```bash
cd ../nullwatch
# Use the Zig toolchain declared by nullwatch if that checkout has not been
# migrated to your local Zig version yet. NullHub only needs the HTTP API.
DATA_DIR="$(mktemp -d)"
zig build run -- ingest-span --data-dir "$DATA_DIR" --json '{"run_id":"demo-run-1","trace_id":"trace-demo-1","span_id":"span-1","source":"nullclaw","operation":"tool.call","status":"error","started_at_ms":1710000000000,"ended_at_ms":1710000001500,"tool_name":"shell","error_message":"tool call failed: command timed out","attributes_json":"{\"exit_code\":124}"}'
zig build run -- ingest-eval --data-dir "$DATA_DIR" --json '{"run_id":"demo-run-1","eval_key":"tool_success","scorer":"deterministic","score":0.0,"verdict":"fail","dataset":"demo","notes":"The tool call timed out."}'
zig build run -- serve --data-dir "$DATA_DIR" --port 7710
```

Start NullHub with the observability proxy configured:

```bash
NULLWATCH_URL=http://127.0.0.1:7710 zig build run -- serve --no-open
```

Open `/observability` in NullHub and inspect the sample run.

## Screenshots

Flight Recorder overview:

![NullHub Observability overview](docs/screenshots/nullhub-observability-overview.png)

Failure detail with tool-call error context:

![NullHub Observability failure detail](docs/screenshots/nullhub-observability-failure.png)

## Limitations And Future Improvements

- The MVP reads from a configured `NULLWATCH_URL`; automatic discovery of managed
  NullWatch instances can be added later.
- The first UI version renders a compact timeline, not a full waterfall chart.
- Run correlation with NullBoiler orchestration pages can be added as a follow-up
  when both systems share stable run ids.
