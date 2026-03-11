# Saved Providers Design

**Date:** 2026-03-11
**Status:** Approved

## Overview

Add the ability to save validated AI provider credentials in NullHub for reuse across bot/instance creation. Credentials are validated with a real API request before saving. A new Providers page lets users manage saved credentials.

## Data Model

New `saved_providers` array in `~/.nullhub/state.json` (alongside existing `instances`), using the established `State` struct and its atomic read/write/parse infrastructure:

```json
{
  "instances": { ... },
  "saved_providers": [
    {
      "id": "sp_1",
      "name": "OpenRouter #1",
      "provider": "openrouter",
      "api_key": "sk-or-xxx",
      "model": "anthropic/claude-sonnet-4",
      "validated_at": "2026-03-11T12:00:00Z",
      "validated_with": "nullclaw"
    }
  ]
}
```

- `id` — monotonically incrementing integer with `sp_` prefix (e.g., `sp_1`, `sp_2`). Next ID derived from max existing ID + 1.
- `name` — auto-generated as `"{ProviderLabel} #{n}"`, editable on providers page
- `model` — optional, saved if user had one filled in
- `validated_at` — ISO 8601 timestamp of last successful validation
- `validated_with` — which component binary was used for validation

## Backend API

New endpoints under `/api/providers`:

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/api/providers` | List saved providers (api_key masked) |
| `POST` | `/api/providers` | Validate & save a new credential |
| `PUT` | `/api/providers/{id}` | Update name, api_key, model |
| `DELETE` | `/api/providers/{id}` | Delete a saved credential |
| `POST` | `/api/providers/{id}/validate` | Re-validate an existing credential |

### Validation Flow (POST)

1. Receive provider + api_key + model (optional)
2. Find an installed component binary: collect `state.instances` keys, sort alphabetically, pick the first component that has at least one registered instance, resolve its binary via existing `findOrFetchComponentBinary`
3. If none installed → return 400 with message "Install a component first"
4. Run `--probe-provider-health` via that component binary
5. If validation passes → save to state.json, return saved entry
6. If validation fails → return 422 with failure reason, don't save

### PUT Behavior

- If only `name` changed: update name, preserve existing `validated_at` and `validated_with`, return full entry with 200
- If `api_key` or `model` changed: re-validate via `--probe-provider-health`, update all fields including `validated_at`, return full entry with 200; if validation fails return 422, entry unchanged

### Re-validate Endpoint

`POST /api/providers/{id}/validate` re-runs validation using the credential's current api_key and model without changing any fields. Used by the "Re-validate" button on provider cards. On success: updates `validated_at` and `validated_with`. On failure: returns 422 with reason, `validated_at` unchanged.

### API Key Masking

GET responses mask api_key (e.g., `"sk-or-...xxx"`). The frontend fetches full keys for wizard pre-fill via an internal fetch to `GET /api/providers?reveal=true`. This endpoint requires the existing auth token check (enforced by `src/auth.zig`) — same as all other API endpoints.

## Frontend: Providers Page

### Route

New route at `/providers`.

### Navigation

Added to left sidebar in a new `nav-section` div placed between the Instances section and the bottom-pinned Settings bar (`.nav-bottom`), matching the existing two-section sidebar layout in `Sidebar.svelte`:

```
Dashboard
Install Component
Instances
  nullclaw
    default
    instance-1
Providers        ← new nav-section
─── bottom ───
Settings
```

### Layout

- Header: "Providers" with "Add Provider" button
- If no components installed: info message "Install a component first to add providers" with link to `/install`
- List of saved credentials as cards showing:
  - Name (editable)
  - Provider type label
  - Masked API key
  - Model (if saved), or "No default model"
  - Validation status: green dot + "Validated on {date}" or yellow dot + "Not validated"
  - Actions: Re-validate, Edit, Delete

### Add Provider Flow

- Same provider/api_key/model fields as wizard ProviderList
- "Validate & Save" button calls `POST /api/providers`
- Success: card appears in list
- Failure: error shown inline

### Edit Flow

- Inline editing of name, api_key, model
- Name-only changes: save immediately, no re-validation
- api_key or model changes: save triggers re-validation via `PUT /api/providers/{id}`

## Wizard Integration

### "Use Saved" in ProviderList

- "Use Saved" button/dropdown above or next to "Add Provider" button
- Shows dropdown listing saved credentials by name (fetched via `GET /api/providers?reveal=true` to get full api_keys)
- Selecting one fills in provider type, api_key, and model into a new provider entry
- User can edit pre-filled values before validation

### Auto-save After Wizard Validation

When `validate-providers` passes in the wizard:
- For each validated provider, check if identical credential exists (same provider + api_key + model triple)
- If not found, auto-save with auto-generated name
- Silent — no extra UI prompt

## Out of Scope

- API key encryption (consistent with existing plain-text storage in instance configs)
- Provider type catalog/info page
- Provider usage analytics
