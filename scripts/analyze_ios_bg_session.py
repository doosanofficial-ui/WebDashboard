#!/usr/bin/env python3
"""Analyze an iOS 30-minute background GPS session CSV.

Usage:
    python3 scripts/analyze_ios_bg_session.py --gps-csv path/to/gps.csv
    python3 scripts/analyze_ios_bg_session.py --gps-csv gps.csv --events-csv events.csv --gap-threshold-sec 60
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def _load_csv(path: str, label: str) -> list[dict[str, str]]:
    """Return rows as list-of-dicts; exit with a clear message on failure."""
    p = Path(path)
    if not p.exists():
        print(f"[error] {label} file not found: {path}", file=sys.stderr)
        sys.exit(1)
    if p.stat().st_size == 0:
        print(f"[error] {label} file is empty: {path}", file=sys.stderr)
        sys.exit(1)

    import csv

    with p.open(newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh))


def _require_column(rows: list[dict[str, str]], col: str, path: str) -> None:
    if rows and col not in rows[0]:
        print(
            f"[error] required column '{col}' not found in {path}. "
            f"Available columns: {list(rows[0].keys())}",
            file=sys.stderr,
        )
        sys.exit(1)


def analyze_gps(rows: list[dict[str, str]], gap_threshold_sec: float, csv_path: str) -> None:
    _require_column(rows, "client_t", csv_path)

    if not rows:
        print(f"\n=== GPS CSV Analysis: {csv_path} ===")
        print("Record count : 0")
        print("bg_state distribution: no rows")
        print(f"\nGaps > {gap_threshold_sec}s: 0")
        print("\nFreshness: no records")
        return

    try:
        timestamps = sorted(float(r["client_t"]) for r in rows)
    except ValueError as exc:
        print(f"[error] could not parse 'client_t' as numbers in {csv_path}: {exc}", file=sys.stderr)
        sys.exit(1)

    n = len(timestamps)
    print(f"\n=== GPS CSV Analysis: {csv_path} ===")
    print(f"Record count : {n}")

    if "bg_state" in rows[0]:
        from collections import Counter

        dist = Counter(r.get("bg_state", "") for r in rows)
        print("bg_state distribution:")
        for state, count in sorted(dist.items(), key=lambda kv: -kv[1]):
            pct = count / n * 100 if n else 0
            print(f"  {state or '(empty)'}: {count} ({pct:.1f}%)")
    else:
        print("bg_state distribution: column not present (skipped)")

    gaps: list[tuple[float, float, float]] = []
    for i in range(1, len(timestamps)):
        delta = timestamps[i] - timestamps[i - 1]
        if delta > gap_threshold_sec:
            gaps.append((timestamps[i - 1], timestamps[i], delta))

    print(f"\nGaps > {gap_threshold_sec}s: {len(gaps)}")
    for start, end, delta in gaps:
        print(f"  {start:.0f} -> {end:.0f}  ({delta:.1f}s)")

    import time

    now = time.time()
    last_t = timestamps[-1]
    freshness = now - last_t
    print(f"\nFreshness (now - last client_t): {freshness:.1f}s")


def analyze_events(rows: list[dict[str, str]], csv_path: str) -> None:
    print(f"\n=== Events CSV Analysis: {csv_path} ===")
    print(f"Event record count: {len(rows)}")
    if not rows:
        return

    from collections import Counter

    event_key = "type" if "type" in rows[0] else "event_type" if "event_type" in rows[0] else None
    if not event_key:
        print("event distribution: 'type' column not present (skipped)")
        return

    dist = Counter(r.get(event_key, "") for r in rows)
    print(f"{event_key} distribution:")
    for event_type, count in sorted(dist.items(), key=lambda kv: -kv[1]):
        print(f"  {event_type or '(empty)'}: {count}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Analyze an iOS 30-minute background GPS session CSV.")
    parser.add_argument(
        "--gps-csv",
        required=True,
        metavar="PATH",
        help="Path to GPS CSV file. Required column: client_t (epoch seconds).",
    )
    parser.add_argument("--events-csv", metavar="PATH", help="(Optional) Path to events CSV file.")
    parser.add_argument(
        "--gap-threshold-sec",
        type=float,
        default=30.0,
        metavar="N",
        help="Report gaps larger than N seconds (default: 30).",
    )
    args = parser.parse_args()

    gps_rows = _load_csv(args.gps_csv, "GPS CSV")
    analyze_gps(gps_rows, args.gap_threshold_sec, args.gps_csv)

    if args.events_csv:
        event_rows = _load_csv(args.events_csv, "Events CSV")
        analyze_events(event_rows, args.events_csv)

    return 0


if __name__ == "__main__":
    sys.exit(main())
