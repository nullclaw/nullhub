# Multi-Step Install Wizard Design

## Overview

Transform the single-page install wizard into a 3-page stepper with validation gates between pages. Provider and channel credentials are validated live before proceeding.

## Page Flow

### Page 1: Setup
- Instance Name (hint: "Name doesn't matter, just needs to be unique")
- Version selector
- Provider list (existing ProviderList component)
- **Next** triggers `POST /api/wizard/{component}/validate-providers`
  - Per-provider green/red indicator
  - Blocks until all providers validated

### Page 2: Channels
- WEB and CLI shown as default-on toggles (no config needed)
- "+ Add Channel" button with type selector
- Expanding config form per channel (fields from `configSchemas.ts`)
- Multiple accounts supported for channels with `hasAccounts: true`
- **Next** triggers `POST /api/wizard/{component}/validate-channels`
  - Per-channel green/red indicator
  - Blocks until all channels validated

### Page 3: Settings
- Non-advanced manifest steps grouped by `group` field
- Collapsible "Advanced" section for steps with `"advanced": true`
- **Install** button at bottom

## Backend Changes

### New Endpoints

#### `POST /api/wizard/{component}/validate-providers`

Request:
```json
{
  "providers": [
    { "provider": "openai", "api_key": "sk-...", "model": "gpt-4" }
  ]
}
```

Implementation:
1. Find component binary (same as `handleGetWizard`)
2. Create temp directory with minimal config per provider
3. Run `--probe-provider-health --provider {name} --model {model} --timeout-secs 10` per provider
4. Clean up temp directory

Response:
```json
{
  "results": [
    { "provider": "openai", "live_ok": true, "reason": "ok" },
    { "provider": "anthropic", "live_ok": false, "reason": "invalid_api_key" }
  ]
}
```

#### `POST /api/wizard/{component}/validate-channels`

Request:
```json
{
  "channels": {
    "telegram": { "default": { "bot_token": "123:ABC" } }
  }
}
```

Implementation:
1. Find component binary
2. Create temp directory with channel config
3. Run `--probe-channel-health --channel {type} --account {name} --timeout-secs 10` per channel/account
4. Clean up temp directory

Response:
```json
{
  "results": [
    { "channel": "telegram", "account": "default", "live_ok": true, "reason": "ok" }
  ]
}
```

### Path Parsing

Extend `extractComponentName` in `wizard.zig` to match `/validate-providers` and `/validate-channels` suffixes. Add `isValidateProvidersPath` and `isValidateChannelsPath` helpers.

## Frontend Changes

### WizardRenderer.svelte (major refactor)
- `currentPage` state (0, 1, 2)
- Derive pages from manifest step groups
- Step indicator at top showing progress
- Back / Next / Install navigation
- Next triggers validation for pages 0 and 1
- Track validation state per provider/channel

### New: ChannelList.svelte
- WEB/CLI as default-on toggles
- "+ Add Channel" with channel type picker
- Config form per channel using fields from `configSchemas.ts`
- Account support for multi-account channels
- Green/red validation indicators per channel

### ProviderList.svelte (extend)
- Per-provider status indicator (gray -> spinning -> green/red)
- Error reason display on red

### API Client (client.ts)
- `validateProviders(component, providers)` -> POST validate-providers
- `validateChannels(component, channels)` -> POST validate-channels

## Manifest Step Schema Extension

Steps gain two optional fields:
- `"group"`: string — determines which wizard page (e.g. `"providers"`, `"channels"`, `"settings"`)
- `"advanced"`: boolean — rendered inside collapsible "Advanced" section

## Install Payload

On page 3 "Install" click, the full payload sent to `POST /api/wizard/{component}`:
```json
{
  "instance_name": "instance-1",
  "version": "v2026.3.2",
  "providers": [...],
  "channels": { "web": {...}, "cli": {...}, "telegram": {...} },
  "memory_backend": "sqlite",
  "tunnel": "none",
  "autonomy_level": "supervised"
}
```
