# WebDashboard Agent Operating Guide

This file defines always-on, repository-level instructions for AI agents in this workspace.

## 1) Scope and priority
- Applies to all tasks in this repository.
- Keep changes minimal, reversible, and aligned with existing file structure.
- Prefer fixing root cause over surface patching.

## 1.1) Canonical branch policy
- `main` is the repository's single working and integration branch.
- Start every implementation, review, verification, commit, and push from the local `main` checkout.
- Keep code changes, tests, and release evidence on `main`; do not create or switch to feature branches, PR branches, or worktrees for repository work.
- Parallel workers may perform independent read-only research, review, or verification only. The primary agent reconciles their reports and applies code changes sequentially on `main`.
- Before committing or pushing, verify `git branch --show-current` is `main` and preserve unrelated user changes; stage only files in the active task.
- If a hosting rule mandates a pull request, treat the temporary transport ref as a platform constraint, return the canonical checkout to `main`, and remove the temporary ref after integration when safe.

## 1.2) Active platform scope
- The active mobile product scope is native iOS telemetry and CarPlay.
- Android implementation, integration, build, device validation, UI, and background execution are deferred and out of scope until the user explicitly reactivates Android.
- Existing Android source, generated folders, and Android-related documentation may remain for reference, but they are not acceptance criteria or release evidence and must not be modified, deleted, or promoted as completed work while Android is deferred.
- Prioritize iPhone physical-device validation, Core Location, BLE/ELM327 transport, durable recording, and entitlement-gated CarPlay behavior. Report CarPlay entitlement or simulator limitations explicitly.

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
- The `mobile` matrix job is legacy/shared scaffold validation only; it is not Android acceptance evidence while Android is deferred.

## 3) Session continuity rules (official behavior aligned)
- New session is independent by default (no automatic carry-over).
- To continue context across sessions, use handoff/delegation flows.
- Prefer explicit checkpoints in prompts:
  - objective
  - scope/in-scope/out-of-scope
  - acceptance criteria
  - target files

## 4) Local execution policy: subagents + parallelism
- Use subagents only when they provide an independent read-only research, review, or verification result.
- For multi-track tasks, split only read-only work into parallel sub-tasks when safe:
  - research/analysis
  - verification
- Keep each sub-task output concise and reconcile results in the primary `main` checkout.
- Apply implementation changes sequentially on `main`; do not give workers a writable branch or worktree.
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

## 9.5) Standing Execution Authorization
- Treat routine, in-scope execution as pre-approved until the active user goal is achieved; do not ask for repeated confirmation before inspection, scoped edits, dependency installation, bounded builds/tests, simulator/browser validation, commits, or pushes to the verified project remote.
- Continue automatically to the next in-scope step after each verified result and report the evidence instead of requesting an approval checkpoint.
- Keep human handoff for passwords, MFA/OTP, passkeys, recovery codes, secret/token entry, paid actions, ambiguous destructive targets, irreversible production changes, and platform-mandated confirmations.
- This authorization does not permit guessing credentials, widening scope, deleting user data, or claiming completion without the required test and runtime evidence.

## 10) Standard execution workflow (always use this unless explicitly overridden)
1. Intake lock:
   - Restate objective, in-scope/out-of-scope, acceptance criteria.
   - Confirm target files and risk boundaries.
2. Plan:
   - Define 2~4 concrete steps and dependency order.
   - Split into parallel tracks only when tasks are independent.
3. Serial implementation on `main`:
   - Confirm `git branch --show-current` returns `main` before editing.
   - Apply the smallest viable patch directly in the canonical checkout.
   - Use parallel workers only for read-only reports; the primary agent owns all writes and integration.
4. Review and verification gate (per track):
   - Changed-file sanity check.
   - Repository parity checks:
     - `python3 scripts/validate_platform_docs.py`
     - `mobile` tests when touched: `npm test -- --runInBand --silent`
     - `server` Python sanity when touched: compile/import smoke.
     - iOS changes: run the applicable Swift/Xcode build or test and record physical-device or simulator evidence separately.
     - CarPlay changes: verify the applicable simulator/template/entitlement boundary; do not substitute Android checks.
     - Contract/schema consistency check against existing runtime/log formats.
5. Integration:
   - Commit verified changes directly on `main` in explicit dependency order (lowest-risk/foundation first).
   - After each commit: verify local `main` and `origin/main` are synchronized and re-check the next change for drift.
6. Finalization:
   - Verify `main` clean and synced with remote.
   - Clean temporary worktrees/branches.
   - Close or update related issues with actual merge references.

## 11) Copilot CLI orchestration policy
- Copilot CLI is an allowed read-only worker for this repository.
- Default non-interactive execution pattern:
  - `copilot -p "<task>" --allow-all-tools --allow-all-paths --allow-all-urls --no-ask-user --silent`
- Do not give Copilot CLI a writable worktree or branch. It may inspect, research, review, or verify and return a report; the primary agent applies any accepted change directly on `main`.
- If GitHub assignee mapping for `Copilot` is unavailable, do not block:
  - create/update issue + comment mention, then proceed with local Copilot CLI execution.
- Human/primary agent remains responsible for final code review, fixes, and merge decisions.

## 12) PR merge gate checklist (must pass before merge)
- This gate applies only when a hosting rule mandates a pull request; normal work is committed directly on `main`.
- PR is not draft.
- Required `smoke` checks are green (`server`, `client`, `mobile`).
- No unresolved conflicts with current `main`.
- Any discovered functional/schema mismatch is fixed in-PR before merge.
- Post-merge local sync and quick regression check completed.
