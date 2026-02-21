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
  - Uses matrix (`server`, `client`) and delegates to reusable workflow.
- Reusable CI: `.github/workflows/reusable-smoke.yml`
  - Validates runtime input (`server|client`).
  - `server`: Python setup, dependencies, `py_compile` smoke check.
  - `client`: verifies key runtime files exist.

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

## 5) Pro plan-safe operating mode
- If third-party *agent type* is unavailable, continue with built-in types (Local/Background/Cloud).
- Model selection may still use available Codex/Claude models from model picker.
- Do not block workflow waiting for third-party agent visibility.

## 6) Practical runbook for this repository
- Planning: create 2~4 concrete steps before edits for non-trivial work.
- Implementation: smallest viable patch first.
- Validation order:
  1. changed-file sanity check
  2. smoke workflow parity checks (server/client expectations)
  3. status summary with risks and next action

## 7) Editing conventions
- Do not reformat unrelated files.
- Do not rename files or symbols unless required.
- Keep public behavior stable unless request explicitly changes behavior.
- Avoid adding dependencies unless justified.

## 8) Reporting format
- Report with: what changed / why / verification / remaining risk.
- If blocked by plan/policy/permission, provide exact unblock step.
