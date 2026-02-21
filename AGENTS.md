# WebDashboard Agent Operating Guide

This file defines always-on, repository-level instructions for AI agents in this workspace.

## 1) Scope and priority
- Applies to all tasks in this repository.
- Keep changes minimal, reversible, and aligned with existing file structure.
- Prefer fixing root cause over surface patching.

## 2) Current project workflow (observed)
- Main CI entry: `.github/workflows/smoke.yml`
  - Runs on `pull_request` and `push` to `main`.
  - Uses concurrency guard: `${{ github.workflow }}-${{ github.ref }}` with cancel-in-progress.
  - Uses matrix (`server`, `client`, `mobile`) and delegates to reusable workflow.
- Reusable CI: `.github/workflows/reusable-smoke.yml`
  - Validates runtime input (`server|client|mobile`).
  - `server`: Python setup, dependencies, `py_compile` smoke check.
  - `client`: verifies key runtime files exist.
  - `mobile`: verifies RN scaffold files + `validate-mobile-scaffold.js`.

## 3) Session continuity rules (official behavior aligned)
- New session is independent by default (no automatic carry-over).
- To continue context across sessions, use handoff/delegation flows.
- Prefer explicit checkpoints in prompts:
  - objective
  - scope/in-scope/out-of-scope
  - acceptance criteria
  - target files

## 4) Local execution policy: subagents + parallelism
- If local execution can use subagents, default to using them.
- For multi-track tasks, split into parallel sub-tasks when safe:
  - research/analysis
  - implementation
  - verification
- Keep each sub-task output concise and merge results in main thread.
- Do not run destructive commands in parallel.
- Parallel execution in this repository does **not** require extra project config.
  - Local agent parallelism is runtime/orchestrator capability.
  - CI parallelism is already configured via matrix in `.github/workflows/smoke.yml`.

## 5) Pro plan-safe operating mode
- If third-party *agent type* is unavailable, continue with built-in types (Local/Background/Cloud).
- Model selection may still use available Codex/Claude models from model picker.
- Do not block workflow waiting for third-party agent visibility.

## 6) Practical runbook for this repository
- Planning: create 2~4 concrete steps before edits for non-trivial work.
- Implementation: smallest viable patch first.
- Validation order:
  1. changed-file sanity check
  2. smoke workflow parity checks (server/client/mobile expectations)
  3. status summary with risks and next action

## 7) Editing conventions
- Do not reformat unrelated files.
- Do not rename files or symbols unless required.
- Keep public behavior stable unless request explicitly changes behavior.
- Avoid adding dependencies unless justified.

## 8) Reporting format
- Report with: what changed / why / verification / remaining risk.
- If blocked by plan/policy/permission, provide exact unblock step.

## 9) Canonical AGENTS.md (single source of truth)
- Canonical instruction file is repository-root `AGENTS.md` only.
- Do not create additional `AGENTS.md` files in subfolders.
- VSCode workspace and Codex extension sessions must point to the same repository root so both read this single file.
- If using multi-root workspace, include this same folder path (not a copied folder) to avoid instruction drift.

## 10) Standard execution workflow (always use this unless explicitly overridden)
1. Intake lock:
   - Restate objective, in-scope/out-of-scope, acceptance criteria.
   - Confirm target files and risk boundaries.
2. Plan:
   - Define 2~4 concrete steps and dependency order.
   - Split into parallel tracks only when tasks are independent.
3. Parallel implementation:
   - Use dedicated branch/worktree per track (`copilot/issue-<id>-<slug>` preferred).
   - Run workers in parallel (local agent and/or Copilot CLI).
   - Keep each track minimal and focused; avoid cross-track file overlap where possible.
4. Review and verification gate (per track):
   - Changed-file sanity check.
   - Repository parity checks:
     - `python3 scripts/validate_platform_docs.py`
     - `mobile` tests when touched: `npm test -- --runInBand --silent`
     - `server` Python sanity when touched: compile/import smoke.
   - Contract/schema consistency check against existing runtime/log formats.
5. Integration:
   - Merge in explicit dependency order (lowest-risk/foundation first).
   - After each merge: fast-forward local `main` and re-check next PR for drift/conflicts.
6. Finalization:
   - Verify `main` clean and synced with remote.
   - Clean temporary worktrees/branches.
   - Close or update related issues with actual merge references.

## 11) Copilot CLI orchestration policy
- Copilot CLI is an allowed parallel worker for this repository.
- Default non-interactive execution pattern:
  - `copilot -p "<task>" --allow-all-tools --allow-all-paths --allow-all-urls --no-ask-user --silent`
- One worker per isolated worktree; do not share a worktree across parallel workers.
- If GitHub assignee mapping for `Copilot` is unavailable, do not block:
  - create/update issue + comment mention, then proceed with local Copilot CLI execution.
- Human/primary agent remains responsible for final code review, fixes, and merge decisions.

## 12) PR merge gate checklist (must pass before merge)
- PR is not draft.
- Required `smoke` checks are green (`server`, `client`, `mobile`).
- No unresolved conflicts with current `main`.
- Any discovered functional/schema mismatch is fixed in-PR before merge.
- Post-merge local sync and quick regression check completed.
