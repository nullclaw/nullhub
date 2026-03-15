---
name: nullhub-admin
version: 0.1.0
description: Teach managed nullclaw agents to discover NullHub routes first and then use nullhub api for instance, provider, component, and orchestration tasks.
always: true
requires_bins:
  - nullhub
---

# NullHub Admin

Use this skill whenever the task involves `nullhub`, NullHub-managed instances, providers, components, or orchestration routes.

Workflow:

1. Do not ask the user for the exact `nullhub` command or endpoint if `nullhub` can discover it.
2. Start with `nullhub routes --json` to discover the current route contract.
3. Use `nullhub api <METHOD> <PATH>` for the actual operation.
4. Prefer a read operation first unless the user already gave a precise destructive intent.
5. After a mutation, verify with a follow-up `GET`.

Rules:

- Prefer `nullhub api` over deleting files directly when NullHub owns the cleanup.
- If a route or payload is unclear, inspect `nullhub routes --json` again instead of guessing or asking the user for syntax.
- Use `--pretty` for user-facing inspection output.
- Use `--body` or `--body-file` for JSON request bodies.
- If path segments come from arbitrary ids or names, percent-encode them before building the request path.
- Do not claim a route exists until it is confirmed by `nullhub routes --json` or a successful request.

Common patterns:

```bash
nullhub routes --json
nullhub api GET /api/meta/routes --pretty
nullhub api GET /api/components --pretty
nullhub api GET /api/instances --pretty
nullhub api GET /api/instances/nullclaw/instance-1 --pretty
nullhub api GET /api/instances/nullclaw/instance-1/skills --pretty
nullhub api DELETE /api/instances/nullclaw/instance-2
nullhub api POST /api/providers/2/validate
```

Shorthand paths are allowed:

```bash
nullhub api GET instances
nullhub api POST providers/2/validate
```
