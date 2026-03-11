# Saved Channels Design

**Date:** 2026-03-11
**Status:** Approved

## Overview

Add the ability to save validated channel configurations (Telegram, Discord, Slack, etc.) in NullHub for reuse across bot/instance creation. One saved entry = one channel type + one account with all config fields. Channels are validated with a real probe request before saving. A new Channels page lets users manage saved configurations. Full analogy with saved Providers.

## Data Model

New `saved_channels` array in `~/.nullhub/state.json` (alongside existing `instances` and `saved_providers`), using the established `State` struct and its atomic read/write/parse infrastructure:

```json
{
  "instances": { ... },
  "saved_providers": [ ... ],
  "saved_channels": [
    {
      "id": "sc_1",
      "name": "Telegram #1",
      "channel_type": "telegram",
      "account": "main_bot",
      "config": {
        "bot_token": "123456:ABC-DEF...",
        "allow_from": ["user1", "user2"]
      },
      "validated_at": "2026-03-11T12:00:00Z",
      "validated_with": "nullclaw"
    }
  ]
}
```

- `id` — internally `u32`, monotonically incrementing. The `sc_` prefix (e.g., `sc_1`, `sc_2`) is a serialization concern only — added during JSON output, stripped by the frontend before API calls. Next ID derived from max existing ID + 1.
- `name` — auto-generated as `"{ChannelLabel} #{n}"`, editable on channels page
- `channel_type` — channel type key. All types from channelSchemas except `cli` and `web` (those are defaults): telegram, discord, slack, whatsapp, matrix, mattermost, irc, imessage, email, lark, dingtalk, signal, line, qq, onebot, maixcam, nostr, webhook.
- `account` — account name within the channel type. For channels with `hasAccounts: true`, this is user-provided. For channels without accounts (e.g., nostr, webhook), defaults to the channel type name (e.g., `"nostr"`), matching the existing behavior in `ChannelList.svelte`.
- `config` — stored in Zig as `[]const u8` containing a serialized JSON string. This avoids the complexity of dynamic JSON tree types (`std.json.Value`) in the state struct while keeping the same memory management pattern as other `[]const u8` fields (dupe on load, free on deinit). Serialized to JSON as a raw JSON object (not a double-encoded string) using `std.json.Value` during output.
- `validated_at` — ISO 8601 timestamp of last successful validation
- `validated_with` — which component binary was used for validation (currently always `"nullclaw"`, future-proofed for other components)

### Secret Masking

Fields with type `password` in channelSchemas (bot_token, token, access_token, app_token, etc.) are masked in GET responses. Full values available via `?reveal=true`.

### Duplicate Detection

Duplicates are determined by the triple `(channel_type, account, config)`. Config comparison uses byte-level equality of the serialized JSON string (not deep semantic equality). This means field ordering matters — the frontend must produce a canonical JSON serialization (sorted keys) before sending. This keeps the Zig side simple (just `std.mem.eql`).

## Backend API

New endpoints under `/api/channels`:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/channels` | List saved channels (secrets masked) |
| `POST` | `/api/channels` | Validate & save a new channel |
| `PUT` | `/api/channels/{id}` | Update name, account, config |
| `DELETE` | `/api/channels/{id}` | Delete a saved channel |
| `POST` | `/api/channels/{id}/validate` | Re-validate an existing channel |

### Validation Flow (POST)

1. Receive channel_type + account + config (object with fields)
2. Find an installed component binary via `findProviderProbeComponent` (reuses the same function as providers — currently hardcoded to look for nullclaw instances)
3. If none installed → return 400 with message "Install a component first"
4. Write a full config file to a temp directory in the format the component binary expects: `{"channels": {"{type}": {"{account}": {<config fields>}}}}`. Run `--probe-channel-health --channel {type} --account {account} --timeout-secs 10` (matching the existing wizard validation in `wizard.zig`)
5. If validation passes → save to state.json, return saved entry
6. If validation fails → return 422 with failure reason, don't save

### PUT Behavior

- If only `name` changed: update name, preserve existing `validated_at` and `validated_with`, return full entry with 200
- If `account` or any `config` field changed: re-validate via `--probe-channel-health`, update all fields including `validated_at`, return full entry with 200; if validation fails return 422, entry unchanged

### Re-validate Endpoint

`POST /api/channels/{id}/validate` re-runs validation using the channel's current config without changing any fields. Used by the "Re-validate" button on channel cards. On success: updates `validated_at` and `validated_with`. On failure: returns 422 with reason, `validated_at` unchanged.

### Secret Masking

GET responses mask fields that have `password` type in channelSchemas (e.g., `"123...DEF"`). The frontend fetches full values for wizard pre-fill via `GET /api/channels?reveal=true`. This endpoint requires the existing auth token check (enforced by `src/auth.zig`) — same as all other API endpoints.

## Frontend: Channels Page

### Route

New route at `/channels`.

### Navigation

Added to left sidebar in its own `nav-section` div (separate from Providers), placed between the Providers section and the bottom-pinned Settings bar (`.nav-bottom`):

```
Dashboard
Install Component
Instances
  nullclaw
    default
    instance-1
Providers
Channels        ← new nav-section
─── bottom ───
Settings
```

### Layout

- Header: "Channels" with "Add Channel" button
- If no components installed: info message "Install a component first to add channels" with link to `/install`
- List of saved channels as cards showing:
  - Name (editable)
  - Channel type label (from channelSchemas)
  - Account name
  - Masked secret fields (bot_token, etc.)
  - Validation status: green dot + "Validated on {date}" or yellow dot + "Not validated"
  - Actions: Re-validate, Edit, Delete

### Add Channel Flow

- Channel type dropdown (from channelSchemas, excluding cli and web — those are defaults)
- Account name input (for channels with `hasAccounts: true`)
- Dynamic form fields from channelSchemas for the selected type
- "Validate & Save" button calls `POST /api/channels`
- Success: card appears in list
- Failure: error shown inline

### Edit Flow

- Inline editing of name, account, config fields
- Name-only changes: save immediately, no re-validation
- account or config changes: save triggers re-validation via `PUT /api/channels/{id}`

## Wizard Integration

### "Use Saved" in ChannelList

- "Use Saved" button/dropdown next to "Add Channel" button in wizard
- Shows dropdown listing saved channels by name (fetched via `GET /api/channels?reveal=true` to get full secrets)
- Selecting one fills in channel_type, account, and all config fields into a new channel entry
- User can edit pre-filled values before validation

### Auto-save After Wizard Validation

When `validate-channels` passes in the wizard (in `handleValidateChannels` in `wizard.zig`):
- Pass `state` to the handler (same pattern as was done for providers auto-save)
- For each validated channel, check if identical configuration exists (same channel_type + account + config triple via `hasSavedChannel`)
- If not found, auto-save with auto-generated name via `addSavedChannel`
- Silent — no extra UI prompt

## Out of Scope

- Secret encryption (consistent with existing plain-text storage in instance configs and saved providers)
- Channel type catalog/info page
- Channel usage analytics
