# Report Command Design

Create GitHub issues with pre-filled system data from CLI and Web UI.

## Target repositories

| # | Component | GitHub repo |
|---|-----------|-------------|
| 1 | nullhub | nullclaw/nullhub |
| 2 | nullclaw | nullclaw/nullclaw |
| 3 | nullboiler | nullclaw/NullBoiler |
| 4 | nulltickets | nullclaw/nulltickets |
| 5 | nullwatch | nullclaw/nullwatch |

Order is fixed (as listed above) in both CLI and Web UI selectors.

The target list is hardcoded in `report.zig`, independent of `known_components` in `registry.zig`. nullwatch exists as a repo but is not yet in the component registry.

## Report types and labels

| Report type | CLI value | Label(s) |
|---|---|---|
| Bug: crash (process exits or hangs) | `bug:crash` | `bug`, `bug:crash` |
| Bug: behavior (incorrect output/state) | `bug:behavior` | `bug`, `bug:behavior` |
| Bug: regression (worked before, now fails) | `regression` | `bug`, `regression` |
| Feature request | `feature` | `enhancement` |

Labels `regression`, `bug:behavior`, `bug:crash` must be created in all 5 repos before launch (one-time script, not committed).

## System data collected automatically

| Field | Source | Notes |
|---|---|---|
| nullhub version | `version.zig` (CalVer, e.g. `2026.3.13`) | Always available (compile-time) |
| Platform | `platform.zig` (e.g. `aarch64-macos`) | Always available (compile-time) |
| OS version | `uname -s -r` at runtime | Child process call |
| Installed components + versions | `state.json` via `state.zig` | Versions only, no runtime status — CLI runs without the server |

Feature requests include only nullhub version and platform (intentionally lightweight — system details are less relevant for feature requests).

## Issue body format

### Bug report

```markdown
### Bug type

<bug type text>

### Description

<user description>

### System information

| Field | Value |
|---|---|
| nullhub version | 2026.3.13 |
| Platform | aarch64-macos |
| OS version | Darwin 25.1.0 |

### Installed components

| Component | Version |
|---|---|
| nullclaw | 2026.3.14 |
| nullboiler | 2026.3.10 |
```

Title: `[Bug]: <description>`

### Feature request

```markdown
### Summary

<user description>

### System information

| Field | Value |
|---|---|
| nullhub version | 2026.3.13 |
| Platform | aarch64-macos |
```

Title: `[Feature]: <description>`

## CLI flow

### Interactive mode

```
$ nullhub report

Where is the problem?
  1. nullhub
  2. nullclaw
  3. nullboiler
  4. nulltickets
  5. nullwatch
> 1

Report type?
  1. Bug: crash (process exits or hangs)
  2. Bug: behavior (incorrect output/state)
  3. Bug: regression (worked before, now fails)
  4. Feature request
> 2

Description: Dashboard shows stale status after restart

Preview:
──────────────────────────
Title: [Bug]: Dashboard shows stale status after restart

### Bug type
...
──────────────────────────
Submit? [Y/n/e]
```

- `Y` / Enter — submit
- `n` — cancel
- `e` — open `$EDITOR` to edit the full markdown before submitting. If `$EDITOR` is unset, falls back to `vi`. Writes markdown to a temp file, invokes editor, reads back on exit, deletes temp file.

### Non-interactive mode

```
$ nullhub report --repo nullhub --type bug:behavior --message "Dashboard shows stale status"
```

Flags:
- `--repo <name>` — one of: nullhub, nullclaw, nullboiler, nulltickets, nullwatch
- `--type <type>` — one of: bug:crash, bug:behavior, regression, feature
- `--message <text>` — one-line description
- `--yes` — skip confirmation (for scripting)
- `--dry-run` — show preview and exit without submitting

Non-interactive mode still shows preview and asks for confirmation unless `--yes` is passed.

### TTY detection

If stdin is not a TTY (piped input), all three flags (`--repo`, `--type`, `--message`) are required. If any is missing, print error and exit. No interactive prompts in non-TTY mode.

## Web UI flow

Page at `/report`:

1. Select: repository (dropdown, same order as CLI)
2. Select: report type (dropdown)
3. Input: description (single-line text input)
4. Click "Next" → calls `POST /api/report/preview` → shows preview step with full markdown in an editable textarea
5. Click "Submit" (calls `POST /api/report` with final markdown) or "Back" to edit inputs

On success: show link to created issue.
On fallback: show copyable markdown block + hint to install gh.

System data collected on server side — user does not fill system fields manually.

## Submission fallback chain

Each step falls through to the next on failure (non-zero exit, network error, missing tool, etc.):

```
1. `gh` in PATH + `gh auth status` succeeds?
   → gh issue create --repo <repo> --title <title> --body <body> --label <labels>
   → Success: return issue URL

2. Token from `gh auth token`?
   → curl POST https://api.github.com/repos/<repo>/issues
     -H "Authorization: Bearer <token>"
   → Success: return issue URL

3. $GITHUB_TOKEN env var set?
   → curl POST (same as above with env token)
   → Success: return issue URL

4. No auth available:
   → Output formatted markdown + hint:
     "Install and authenticate gh CLI to submit automatically:
      https://cli.github.com/"
```

Web UI uses the same chain server-side. If all fail, API returns the fallback response and UI renders a copyable block.

## Architecture

### New files

| File | Purpose |
|---|---|
| `src/report.zig` | Core module: repo/type enums, system data collection, issue body formatting, submission via fallback chain |
| `src/report_cli.zig` | Interactive CLI flow: stdin prompts, flag parsing, preview, editor support |
| `src/api/report.zig` | API endpoint handlers for `POST /api/report` and `POST /api/report/preview` |
| `ui/src/routes/report/+page.svelte` | Report form page |

### Modified files

| File | Change |
|---|---|
| `src/cli.zig` | Add `ReportOptions` struct, `ReportRepo` enum, `ReportType` enum, `report: ReportOptions` to `Command` union, `parseReport()` sub-parser, update `printUsage()` |
| `src/main.zig` | Add `.report` case to command dispatch switch |
| `src/server.zig` | Add `POST /api/report` and `POST /api/report/preview` routes |

### Enums and options

```zig
pub const ReportRepo = enum {
    nullhub,
    nullclaw,
    nullboiler,
    nulltickets,
    nullwatch,

    pub fn fromStr(s: []const u8) ?ReportRepo { ... }
    pub fn toGithubRepo(self: ReportRepo) []const u8 { ... }
    pub fn displayName(self: ReportRepo) []const u8 { ... }
};

pub const ReportType = enum {
    bug_crash,
    bug_behavior,
    regression,
    feature,

    pub fn fromStr(s: []const u8) ?ReportType { ... }
    pub fn toLabels(self: ReportType) []const []const u8 { ... }
    pub fn displayName(self: ReportType) []const u8 { ... }
};

pub const ReportOptions = struct {
    repo: ?ReportRepo = null,
    report_type: ?ReportType = null,
    message: ?[]const u8 = null,
    yes: bool = false,
    dry_run: bool = false,
};
```

### API endpoints

#### `POST /api/report/preview`

Generates preview without submitting.

Request:
```json
{
  "repo": "nullhub",
  "type": "bug:behavior",
  "message": "Dashboard shows stale status"
}
```

Response:
```json
{
  "title": "[Bug]: Dashboard shows stale status",
  "markdown": "### Bug type\n...",
  "labels": ["bug", "bug:behavior"],
  "repo": "nullclaw/nullhub"
}
```

#### `POST /api/report`

Submits issue (with optional edited markdown from preview).

Request:
```json
{
  "repo": "nullhub",
  "type": "bug:behavior",
  "message": "Dashboard shows stale status",
  "markdown": "### Bug type\n..."
}
```

The `markdown` field is optional. If provided (edited by user in preview), it replaces the auto-generated body. If omitted, the server generates it.

Success response:
```json
{
  "status": "created",
  "url": "https://github.com/nullclaw/nullhub/issues/42"
}
```

Fallback response (no auth):
```json
{
  "status": "no_auth",
  "title": "[Bug]: Dashboard shows stale status",
  "markdown": "### Bug type\n...",
  "labels": ["bug", "bug:behavior"],
  "repo": "nullclaw/nullhub",
  "hint": "Install and authenticate gh CLI to submit automatically: https://cli.github.com/"
}
```

Error response (invalid input):
```json
{
  "status": "error",
  "error": "invalid repo: foo"
}
```

Returns HTTP 400 for invalid/missing fields (repo, type, message).

### Auth on report endpoint

`POST /api/report` and `POST /api/report/preview` follow the existing auth pattern in `server.zig` — if a bearer token is configured, these endpoints require it. Same as all other `/api/` routes.
