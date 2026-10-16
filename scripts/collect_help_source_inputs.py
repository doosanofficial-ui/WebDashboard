"""Collect the canonical recursive Help source inventory without certifying PNGs.

Use this producer before an authorized capture and verify it again afterward.
An inventory collected now must never relabel older captures. Historical
amendments may fill omissions from the original snapshot, never refresh hashes.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re

from verify_help_assets import source_input_hashes, staged_source_input_hashes


def collect(root):
    return source_input_hashes(Path(root))


def complete_historical_inputs(manifest, capture_snapshot, expected_paths):
    """Return an append-only correction backed by the original source snapshot."""
    base = manifest.get("sourceBaseCommit")
    if not isinstance(base, str) or re.fullmatch(r"[0-9a-f]{40}", base) is None \
            or capture_snapshot.get("baseHead") != base:
        raise ValueError("Historical capture base differs")
    recorded = manifest["screenInputs"]
    historical = capture_snapshot["files"]
    if not isinstance(recorded, dict) or not isinstance(historical, dict):
        raise ValueError("Source inventories must be dictionaries")
    expected = set(expected_paths)
    if set(recorded) - expected:
        raise ValueError("Historical correction cannot remove extra recorded inputs")
    result = dict(recorded)
    for path in set(recorded) & set(historical):
        if recorded[path] != historical[path]:
            raise ValueError("Recorded hash conflicts with capture snapshot: " + path)
    for path in sorted(expected - set(recorded)):
        if path not in historical:
            raise ValueError("Original capture snapshot lacks omitted input: " + path)
        result[path] = historical[path]
    if any(not isinstance(value, str) or re.fullmatch(r"[0-9a-f]{64}", value) is None
           for value in result.values()):
        raise ValueError("Malformed historical source hash")
    return result


def _test_hash(mobile_ios_root):
    path = Path(mobile_ios_root) / "UITests/LocalizationHelpUITests.swift"
    return hashlib.sha256(path.read_bytes().replace(b"\r\n", b"\n")).hexdigest()


def begin_capture(root, staged_mobile_ios, commit):
    if not isinstance(commit, str) or re.fullmatch(r"[0-9a-f]{40}", commit) is None:
        raise ValueError("Capture source requires an exact commit")
    source = collect(root)
    if source != staged_source_input_hashes(staged_mobile_ios):
        raise ValueError("Staged Help source differs from the source inventory")
    tests = _test_hash(Path(root) / "mobile-ios")
    if tests != _test_hash(staged_mobile_ios):
        raise ValueError("Staged Help capture test differs")
    return {"schemaVersion": 1, "scope": "help-capture-source-inventory", "sourceBaseCommit": commit,
            "sourceInputs": source, "captureTestSHA256": tests, "captureCertified": False}


def finish_capture(root, staged_mobile_ios, before, commit):
    after = begin_capture(root, staged_mobile_ios, commit)
    if after != before:
        raise ValueError("Help source or commit changed during capture")
    return {**after, "sourceStableDuringRun": True}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args(argv)
    print(json.dumps({"schemaVersion": 1, "scope": "capture-source-inventory-only",
                      "captureCertified": False, "sourceInputs": collect(args.root)},
                     indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
