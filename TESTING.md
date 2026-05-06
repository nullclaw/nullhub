# Testing Strategy

This document defines the path to bring NullHub's test discipline closer to NullClaw's while keeping each improvement shippable in small, isolated pull requests.

The aim is not a single large testing rewrite. The aim is to improve confidence incrementally, with each PR standing on its own wherever possible.

## Goals

- make the existing backend test suite a reliable daily gate
- expand coverage into the highest-risk backend areas
- add the missing frontend unit-test layer
- replace shell-only smoke reliance with structured integration coverage
- keep browser E2E small and focused
- adopt NullClaw-style expectations: every behavior change gets tests, every bug fix gets a regression test

## Current Repository State

As of the current `main` branch:

- NullHub already has substantial Zig unit-test coverage in parts of the backend.
- Coverage is concentrated heavily in API and routing code.
- The project has a shell smoke script at `tests/test_e2e.sh`.
- The project does not yet have a committed frontend unit-test harness.
- CI currently runs backend tests, the shell smoke test on Linux, and ReleaseSmall binary builds.

This means the main gap is not "no tests". The gap is uneven coverage and missing layers.

## Testing Principles

NullHub should follow the same core discipline used by NullClaw.

- Every code change must be accompanied by tests.
- Every bug fix must include a regression test.
- If a path is impractical to unit test, document why.
- Keep tests as close as possible to the behavior they validate.
- Prefer the smallest test that proves the contract.
- Add test helpers only when they unlock repeated future coverage.
- Keep fast tests fast; separate unit, integration, smoke, and browser E2E concerns.

## Current Coverage Map

The snapshot below is based on the current `src/` tree and the committed test distribution.

| Area | Current assessment | Evidence in tree | Highest-value next work |
|---|---|---|---|
| API routing and instance endpoints | Strong | `src/api/instances.zig`, `src/server.zig`, `src/api/*` contain the densest test coverage | expand cross-module integration coverage instead of adding more narrow route parsing tests |
| Installer | Medium | `src/installer/orchestrator.zig`, `registry.zig`, `downloader.zig`, `ui_modules.zig`, `builder.zig` | add rollback, partial-failure cleanup, and fixture-driven install/update scenarios |
| Supervisor and process lifecycle | Medium | `src/supervisor/manager.zig`, `process.zig`, `health.zig`, `runtime_state.zig` | add restart/backoff, boot reconciliation, and deterministic lifecycle integration tests |
| Config, state, and paths | Medium | `src/core/state.zig`, `src/api/config.zig`, `src/core/paths.zig` | add tests around persisted-state restoration and migration-sensitive behavior |
| Auth and access control | Light | `src/auth.zig`, `src/access.zig` | add unauthorized origin, token failure, and sensitive-route boundary tests |
| Service install/uninstall/status | Light | `src/service.zig` | add stronger platform-specific generation and failure-path tests |
| Orchestration proxy | Light | `src/api/orchestration.zig` | add upstream error mapping, token/header forwarding, and store-vs-boiler routing tests |
| Discovery, mDNS, and compat layers | Light | `src/discovery.zig`, `src/mdns.zig`, `src/compat/*` | add degraded-mode and missing-tool fallback coverage |
| Frontend UI logic | Missing | no committed UI test harness in `ui/` | add Vitest and Testing Library first |
| Structured backend integration tests | Light | shell smoke only in `tests/test_e2e.sh` | add a real HTTP/integration harness with fixtures |
| Browser end-to-end | Missing | no Playwright or equivalent suite | add a very small critical-flow suite after UI unit tests land |

## Current Test Distribution Snapshot

The current backend suite is broad in file count but uneven in depth.

Files that sit near the high end of the current distribution include:

- `src/api/instances.zig`
- `src/server.zig`
- `src/api/providers.zig`
- `src/core/state.zig`
- `src/cli.zig`
- `src/api/wizard.zig`
- `src/api/logs.zig`
- `src/installer/orchestrator.zig`
- `src/supervisor/manager.zig`
- `src/api/config.zig`

Refresh this snapshot with:

```bash
rg -n --glob '*.zig' '^test\s+"' src | awk -F: '{count[$1]++} END {for (f in count) print count[f], f}' | sort -nr
```

## Test Layers To Build Toward

NullHub should converge on four layers.

### 1. Backend Unit Tests

Use for:

- parsing and normalization
- route matching
- config and state transforms
- installer decision logic
- supervisor state transitions
- auth and access rules

Primary local command:

```bash
zig build test -Dembed-ui=false -Dbuild-ui=false --summary all
```

This backend-only test entrypoint does not require prebuilt UI assets.

### 2. Backend Integration Tests

Use for:

- HTTP route behavior across modules
- boot and runtime lifecycle flows
- managed-instance interactions
- orchestration proxy behavior with fake upstreams
- installer and update scenarios using fixtures

These should not require a browser.

### 3. Frontend Unit and Component Tests

Use for:

- API client helpers
- stores and route transforms
- form validation and state behavior
- orchestration helpers and key UI components

Recommended tooling:

- `vitest`
- `@testing-library/svelte`

### 4. Browser End-to-End Tests

Use for:

- route loading and hydration sanity
- critical user flows
- embedded asset/runtime integration

Recommended tooling:

- Playwright

Keep this layer intentionally small.

## Default TDD Workflow

Every testing PR should follow this pattern unless it is documentation-only.

1. Pick one behavior, contract, or regression.
2. Add a failing test that expresses the expected behavior.
3. Make the smallest code change that makes the test pass.
4. Run the smallest relevant validation first.
5. Run the broader project gate before opening the PR.
6. Document anything skipped.

For bug fixes, prefer explicit regression naming or a short regression comment.

## Incremental PR Roadmap

The sequence below is designed for clean, isolated PRs.

### Phase 0: Policy and Documentation

Purpose:

- document the test contract
- align contributor expectations with NullClaw's model

Status:

- covered by this document

Dependencies:

- none

### Phase 1: Smoke Harness Hardening

Purpose:

- make the shell smoke test fail on real server crashes
- keep smoke runs isolated from developer-local state

Landed scope:

- `test(smoke): harden e2e server diagnostics`

Status:

- already landed on `main` in `tests/test_e2e.sh`; do not open a duplicate smoke-hardening PR unless new smoke gaps are identified

Dependencies:

- none

### Phase 2: Coverage Map and Gap Inventory

Purpose:

- make current strengths and weaknesses explicit
- give later test PRs a scoped target list

Status:

- covered by this document

Dependencies:

- none

### Phase 3: Backend Test Entry Stabilization

Purpose:

- make backend tests the undisputed daily gate
- reduce confusion around UI asset coupling during test runs

Suggested PR:

- `build(test): make backend test entrypoint deterministic and documented`

Dependencies:

- none

### Phase 4: Shared Backend Fixtures

Purpose:

- make installer, supervisor, and orchestration tests cheaper to write

Suggested PR:

- `test(fixtures): add reusable backend test helpers for state and upstream fakes`

Dependencies:

- Phase 3 preferred

### Phase 5: High-Risk Backend Coverage

Target order:

1. supervisor and process lifecycle
2. installer and updates
3. auth and access control
4. orchestration proxy behavior
5. service generation and status behavior
6. discovery and degraded-mode fallbacks

Example PRs:

- `test(supervisor): cover restart threshold and crash recovery transitions`
- `test(installer): cover rollback and duplicate-instance failure paths`
- `test(auth): cover unauthorized origin and bearer-token failure paths`
- `test(orchestration): cover upstream error mapping and token forwarding`
- `test(service): cover launchd/systemd generation and failure paths`

Dependencies:

- Phase 4 recommended for several of these areas

### Phase 6: Structured Backend Integration Harness

Purpose:

- stop relying on a shell script as the only assembled-behavior check

Suggested PRs:

- `test(integration): add structured HTTP smoke harness`
- `test(integration): cover instance lifecycle and config mutation flows`
- `test(integration): cover orchestration proxy scenarios`

Dependencies:

- Phase 4 strongly recommended

### Phase 7: Frontend Unit-Test Harness

Purpose:

- add the missing UI logic test layer

Suggested PRs:

- `test(ui): add Vitest and Testing Library harness`
- `test(ui): cover API client and config-form helpers`
- `test(ui): cover orchestration helpers and key components`

Dependencies:

- none

### Phase 8: Minimal Browser E2E

Purpose:

- catch browser-only regressions without growing a large flaky suite

Suggested PRs:

- `test(e2e): add Playwright harness and dashboard smoke flow`
- `test(e2e): cover instances and settings journeys`
- `test(e2e): cover wizard happy path`

Dependencies:

- Phase 7 recommended

### Phase 9: CI and Hook Enforcement

Purpose:

- make testing discipline the default workflow rather than tribal knowledge

Suggested PRs:

- `ci(test): split backend, smoke, and release jobs`
- `hooks(test): add pre-push backend test enforcement`
- `ci(ui): add frontend unit and browser E2E jobs`

Dependencies:

- depends on the corresponding earlier phases for any enforced suites

### Phase 10: Coverage Visibility

Purpose:

- make gaps visible without optimizing for vanity percentages too early

Suggested PR:

- `ci(coverage): publish test suite summary and UI coverage artifacts`

Dependencies:

- frontend harness in place first

## Recommended Validation By Change Type

Docs-only changes:

```bash
git diff --check
```

Backend code changes:

```bash
zig build test -Dembed-ui=false -Dbuild-ui=false --summary all
```

Smoke or lifecycle changes:

```bash
zig build test -Dembed-ui=false -Dbuild-ui=false --summary all
bash tests/test_e2e.sh
```

Future UI test changes after the harness exists:

```bash
npm --prefix ui test -- --run
zig build test -Dembed-ui=false -Dbuild-ui=false --summary all
```

If any validation is skipped, the PR description should say exactly what was skipped and why.

## Definition of Done

NullHub should be considered aligned with NullClaw's testing model when all of the following are true:

- contributor docs require tests for every code change
- backend tests are reliable and treated as the primary local gate
- high-risk backend subsystems have direct failure-mode coverage
- structured backend integration tests exist beyond shell-only smoke
- frontend unit tests run locally and in CI
- a minimal browser E2E suite covers critical user journeys
- CI and hooks reinforce the workflow
