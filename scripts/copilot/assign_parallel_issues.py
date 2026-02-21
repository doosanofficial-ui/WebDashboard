#!/usr/bin/env python3
"""Create and assign parallel implementation issues to GitHub Copilot coding agent."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
from dataclasses import dataclass


DEFAULT_GH_BIN = os.path.expanduser("~/.local/bin/gh")


def run_gh(gh_bin: str, args: list[str], input_json: dict | None = None) -> str:
    cmd_args = list(args)
    if input_json is not None and cmd_args and cmd_args[0] == "api" and "--input" not in cmd_args:
        cmd_args.extend(["--input", "-"])

    cmd = [gh_bin, *cmd_args]
    proc = subprocess.run(
        cmd,
        input=json.dumps(input_json) if input_json is not None else None,
        text=True,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"gh command failed: {' '.join(cmd)}\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}"
        )
    return proc.stdout


def issue_exists(gh_bin: str, repo: str, title: str) -> int | None:
    out = run_gh(
        gh_bin,
        [
            "issue",
            "list",
            "-R",
            repo,
            "--state",
            "open",
            "--search",
            f'"{title}" in:title',
            "--json",
            "number,title",
        ],
    )
    items = json.loads(out)
    for item in items:
        if item.get("title") == title:
            return int(item["number"])
    return None


def ensure_label(gh_bin: str, repo: str, name: str, color: str, description: str) -> None:
    try:
        run_gh(gh_bin, ["label", "create", name, "-R", repo, "--color", color, "--description", description])
    except RuntimeError:
        run_gh(
            gh_bin,
            ["label", "edit", name, "-R", repo, "--color", color, "--description", description],
        )


def create_issue_with_copilot(
    gh_bin: str,
    repo: str,
    base_branch: str,
    title: str,
    body: str,
    labels: list[str],
    custom_instructions: str,
    dry_run: bool,
) -> int | None:
    assign_payload = {
        "assignees": ["copilot-swe-agent[bot]"],
        "agent_assignment": {
            "target_repo": repo,
            "base_branch": base_branch,
            "custom_instructions": custom_instructions,
            "custom_agent": "",
            "model": "",
        },
    }

    if dry_run:
        print(f"[dry-run] would create issue: {title}")
        print({"title": title, "labels": labels})
        print(json.dumps(assign_payload, ensure_ascii=False, indent=2))
        return None

    create_args = ["issue", "create", "-R", repo, "--title", title, "--body", body]
    for label in labels:
        create_args.extend(["--label", label])

    out = run_gh(
        gh_bin,
        create_args,
    )
    issue_url = out.strip().splitlines()[-1].strip()
    issue_number = int(issue_url.rsplit("/", 1)[-1])

    try:
        assign_issue(
            gh_bin=gh_bin,
            repo=repo,
            issue_number=issue_number,
            base_branch=base_branch,
            custom_instructions=custom_instructions,
            dry_run=dry_run,
        )
    except RuntimeError as exc:
        print(f"[warn] issue #{issue_number} created but Copilot assignment failed: {exc}")

    return issue_number


def assign_issue(
    gh_bin: str,
    repo: str,
    issue_number: int,
    base_branch: str,
    custom_instructions: str,
    dry_run: bool,
) -> None:
    assign_payload = {
        "assignees": ["copilot-swe-agent[bot]"],
        "agent_assignment": {
            "target_repo": repo,
            "base_branch": base_branch,
            "custom_instructions": custom_instructions,
            "custom_agent": "",
            "model": "",
        },
    }

    if dry_run:
        print(f"[dry-run] would assign Copilot to #{issue_number}")
        return

    run_gh(
        gh_bin,
        [
            "api",
            "--method",
            "POST",
            "-H",
            "Accept: application/vnd.github+json",
            "-H",
            "X-GitHub-Api-Version: 2022-11-28",
            f"/repos/{repo}/issues/{issue_number}/assignees",
        ],
        input_json=assign_payload,
    )


@dataclass
class ParallelTask:
    title: str
    body: str
    labels: list[str]
    custom_instructions: str


def build_tasks() -> list[ParallelTask]:
    common_guard = (
        "Follow repository-root AGENTS.md strictly. "
        "Keep scope narrow to listed files only. "
        "Do not reformat unrelated files. "
        "Do not introduce unrelated dependencies."
    )

    return [
        ParallelTask(
            title="P3-3/Track-A: iOS native background location lifecycle bridge",
            labels=["enhancement", "copilot-agent", "parallel-track", "ios-first", "p3-3"],
            body=(
                "## Objective\n"
                "Implement iOS-first native bridge path for stable background location lifecycle.\n\n"
                "## Scope\n"
                "- Add iOS native integration points required for continuous/significant-change updates\n"
                "- Ensure JS layer can start/stop background mode explicitly\n"
                "- Keep Android untouched in this track\n\n"
                "## Target files\n"
                "- `mobile/ios/**`\n"
                "- `mobile/src/telemetry/gps-client.js`\n"
                "- `mobile/src/config.js`\n"
                "- `mobile/README.md`\n\n"
                "## Acceptance Criteria\n"
                "- iOS app can request Always permission and keep location updates in background mode\n"
                "- Background mode flag is visible in JS and sent as `meta.bg_state=background`\n"
                "- No regression in foreground GPS uplink\n"
            ),
            custom_instructions=(
                f"{common_guard} "
                "Do not edit queue logic files; Track-B owns queue semantics."
            ),
        ),
        ParallelTask(
            title="P3-3/Track-B: GPS store-and-forward reliability and replay controls",
            labels=["enhancement", "copilot-agent", "parallel-track", "p3-3", "reliability"],
            body=(
                "## Objective\n"
                "Harden store-and-forward queue behavior under disconnect/reconnect.\n\n"
                "## Scope\n"
                "- Improve bounded queue policy and replay controls\n"
                "- Add guard against duplicate flush loops\n"
                "- Add lightweight tests for queue behavior\n\n"
                "## Target files\n"
                "- `mobile/src/telemetry/store-forward-queue.js`\n"
                "- `mobile/src/App.js` (queue integration only)\n"
                "- `mobile/src/telemetry/protocol.js`\n"
                "- `mobile/tests/**` (new)\n\n"
                "## Acceptance Criteria\n"
                "- Offline payloads are persisted and replayed in order after reconnect\n"
                "- Queue has explicit max size policy and overflow behavior\n"
                "- Basic automated tests pass for enqueue/flush/order semantics\n"
            ),
            custom_instructions=(
                f"{common_guard} "
                "Do not edit iOS native files; Track-A owns native lifecycle."
            ),
        ),
        ParallelTask(
            title="P3-3/Track-C: iOS 30-minute background validation harness and report template",
            labels=["enhancement", "copilot-agent", "parallel-track", "ios-first", "validation"],
            body=(
                "## Objective\n"
                "Build repeatable validation assets for iOS-first background telemetry.\n\n"
                "## Scope\n"
                "- Add test runbook for 30-minute background scenario\n"
                "- Add log extraction checklist and pass/fail report template\n"
                "- Integrate checklist references into docs\n\n"
                "## Target files\n"
                "- `docs/e2e-platform-checklist.md`\n"
                "- `docs/platform-matrix.md`\n"
                "- `mobile/README.md`\n"
                "- `docs/reports/` (new templates)\n\n"
                "## Acceptance Criteria\n"
                "- Team can execute same scenario and produce comparable report\n"
                "- Report template includes drop rate, reconnect count, queue depth, GPS freshness\n"
            ),
            custom_instructions=(
                f"{common_guard} "
                "Documentation only; do not modify runtime code or CI workflows."
            ),
        ),
        ParallelTask(
            title="P3-3/Track-D: mobile CI smoke expansion and conflict-safe integration guide",
            labels=["enhancement", "copilot-agent", "parallel-track", "ci", "p3-3"],
            body=(
                "## Objective\n"
                "Expand mobile CI smoke coverage and define conflict-safe merge protocol.\n\n"
                "## Scope\n"
                "- Add mobile-focused smoke checks for new telemetry modules\n"
                "- Add integration guide for parallel Copilot tracks\n"
                "- Keep checks lightweight (no simulator dependency)\n\n"
                "## Target files\n"
                "- `.github/workflows/reusable-smoke.yml`\n"
                "- `scripts/validate_platform_docs.py`\n"
                "- `docs/copilot-parallel-runbook.md`\n\n"
                "## Acceptance Criteria\n"
                "- CI detects missing mobile telemetry core files\n"
                "- Runbook includes merge order and conflict resolution rules\n"
            ),
            custom_instructions=(
                f"{common_guard} "
                "Avoid touching mobile runtime implementation files used by Tracks A/B."
            ),
        ),
    ]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="doosanofficial-ui/WebDashboard")
    parser.add_argument("--base-branch", default="main")
    parser.add_argument("--gh-bin", default=DEFAULT_GH_BIN)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    labels = [
        ("parallel-track", "1d76db", "Parallel execution track"),
        ("ios-first", "0e8a16", "iOS-first implementation"),
        ("p3-3", "fbca04", "P3-3 background telemetry stream"),
        ("reliability", "5319e7", "Reliability-focused task"),
        ("validation", "c2e0c6", "Validation and test report task"),
        ("ci", "0366d6", "CI and automation task"),
    ]
    for name, color, desc in labels:
        ensure_label(args.gh_bin, args.repo, name, color, desc)

    tasks = build_tasks()
    created: list[tuple[str, int | None]] = []
    for task in tasks:
        existing = issue_exists(args.gh_bin, args.repo, task.title)
        if existing is not None:
            print(f"[skip] already open: #{existing} {task.title}")
            try:
                assign_issue(
                    gh_bin=args.gh_bin,
                    repo=args.repo,
                    issue_number=existing,
                    base_branch=args.base_branch,
                    custom_instructions=task.custom_instructions,
                    dry_run=args.dry_run,
                )
                if not args.dry_run:
                    print(f"[assigned] Copilot -> #{existing}")
            except RuntimeError as exc:
                print(f"[warn] failed to assign Copilot on existing issue #{existing}: {exc}")
            created.append((task.title, existing))
            continue

        number = create_issue_with_copilot(
            gh_bin=args.gh_bin,
            repo=args.repo,
            base_branch=args.base_branch,
            title=task.title,
            body=task.body,
            labels=task.labels,
            custom_instructions=task.custom_instructions,
            dry_run=args.dry_run,
        )
        created.append((task.title, number))
        if number is not None:
            print(f"[created] #{number} {task.title}")

    print("\nSummary:")
    for title, number in created:
        if number is None:
            print(f"- (dry-run) {title}")
        else:
            print(f"- #{number}: {title}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
