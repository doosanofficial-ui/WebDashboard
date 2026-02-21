#!/usr/bin/env python3
"""Validate required platform planning/checklist docs for smoke CI."""

from __future__ import annotations

from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]

REQUIRED_FILES = {
    "docs/platform-matrix.md": [
        "# Platform Implementation Matrix & Checklist",
        "## 기능별 매트릭스",
        "### B. Background Telemetry 전환 (중기)",
        "### C. CarPlay / Android Auto 전환 (중장기)",
    ],
    "docs/e2e-platform-checklist.md": [
        "# E2E Platform Validation Checklist",
        "## 공통 기능 점검",
        "## GPS Foreground 점검",
        "## HTTPS/보안 점검",
    ],
    "docs/adr/0001-mobile-runtime-selection.md": [
        "# ADR-0001: Mobile Runtime Selection for Background Telemetry and Projection",
        "- Status: Proposed",
        "## Options",
        "## Recommendation",
    ],
}


def validate_file(rel_path: str, required_markers: list[str]) -> list[str]:
    errors: list[str] = []
    path = ROOT / rel_path
    if not path.exists():
        return [f"[missing] {rel_path}"]

    content = path.read_text(encoding="utf-8")
    for marker in required_markers:
        if marker not in content:
            errors.append(f"[missing-marker] {rel_path}: {marker}")
    return errors


def main() -> int:
    failures: list[str] = []
    for rel_path, markers in REQUIRED_FILES.items():
        failures.extend(validate_file(rel_path, markers))

    if failures:
        print("Platform docs validation failed:")
        for item in failures:
            print(f"- {item}")
        return 1

    print("Platform docs validation passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
