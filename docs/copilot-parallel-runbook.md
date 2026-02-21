# Copilot Parallel Tracks: Integration Runbook

## Overview

This runbook defines the conflict-safe merge protocol for parallel Copilot
engineering tracks (Track-A through Track-D) working concurrently in the
WebDashboard repository.

## Merge Order

Merge tracks in the following order to minimize dependency conflicts:

1. **Track-A** – Core server infrastructure (server-side telemetry ingestion,
   WebSocket handler). Merge first because all other tracks depend on the
   server API contract.
2. **Track-B** – Client web dashboard (HTML/JS/CSS). Depends only on the
   server API shape stabilised in Track-A.
3. **Track-C** – Mobile scaffold baseline (React Native project structure,
   package.json, app.json). Must be merged before Track-D extends it.
4. **Track-D** – Mobile telemetry modules (`protocol.js`,
   `store-forward-queue.js`, CI smoke expansion). Extends Track-C scaffold;
   merge last among mobile tracks.

## Conflict Resolution Rules

### General Rules

- **Fetch main before resolving**: Always run `git fetch origin main` and
  rebase/merge from `origin/main` before raising a PR.
- **One logical change per PR**: Keep each track's PR scoped to the files
  listed in the corresponding issue's *Target files* section.
- **Never reformat unrelated files**: Whitespace/style changes outside your
  scope will manufacture merge conflicts for concurrent tracks.

### File-Ownership Matrix

| Path prefix | Primary owner track | Secondary (read-only OK) |
|---|---|---|
| `server/` | Track-A | any |
| `client/` | Track-B | any |
| `mobile/src/` | Track-C (scaffold) / Track-D (telemetry modules) | any |
| `mobile/scripts/` | Track-C | Track-D (additive only) |
| `.github/workflows/` | Track-D | any |
| `scripts/validate_platform_docs.py` | Track-D | any |
| `docs/` | Track-D | any |

### CI Workflow Files (`.github/workflows/`)

- Only Track-D adds or modifies workflow steps.
- Other tracks must **not** edit `reusable-smoke.yml` or `smoke.yml`.
- If a conflict arises, Track-D's version wins for the `Mobile smoke` step;
  keep all other steps exactly as they appear on `main`.

### `mobile/` Conflicts

- Track-C owns `mobile/package.json`, `mobile/app.json`, `mobile/index.js`,
  and `mobile/src/App.js`.
- Track-D owns `mobile/src/telemetry/protocol.js`,
  `mobile/src/telemetry/store-forward-queue.js`, and
  `mobile/scripts/validate-mobile-scaffold.js`.
- If both tracks touch `mobile/src/config.js`, resolve by keeping both sets
  of exported constants and removing duplicate lines.

### `docs/` Conflicts

- Each track appends to its own files; do not edit another track's docs.
- `docs/copilot-parallel-runbook.md` (this file) is owned by Track-D; other
  tracks must not modify it.

## Smoke CI: Mobile Telemetry Core Files

The following files are verified by the `Mobile smoke` CI step and must exist
before any mobile-related PR is merged:

- `mobile/src/telemetry/ws-client.js`
- `mobile/src/telemetry/gps-client.js`
- `mobile/src/telemetry/protocol.js`
- `mobile/src/telemetry/store-forward-queue.js`

CI will fail on any PR that deletes or renames these files without a
corresponding workflow update.

## Escalation

If a conflict cannot be resolved using the rules above, open a discussion
thread on the originating issue and request a synchronous review from both
track owners before merging either PR.
