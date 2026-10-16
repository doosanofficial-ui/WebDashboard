"""Separate capture preparation from the still-required complete contract gate.

Seed/SE preparation defers exactly the bundled-current-Help integration test.
All its rejection/unit tests, every other test and import failure remain. The
independent native-contracts CI job runs the complete suite, including that gate.
No result here authorizes a local Simulator operation or certifies a capture.
"""
import argparse
import json
import os
from pathlib import Path
import sys
import unittest

FINAL_HELP_GATE = "test_help_assets.HelpAssetGateTests.test_bundled_captures_and_provenance_are_complete"


def cases(suite):
    for test in suite:
        if isinstance(test, unittest.TestSuite):
            yield from cases(test)
        else:
            yield test


def select_suite(suite, stage):
    if stage not in ("all", "seed", "se"):
        raise ValueError("Unknown native contract stage")
    tests = list(cases(suite))
    if sum(test.id() == FINAL_HELP_GATE for test in tests) != 1:
        raise ValueError("Exactly one complete bundled Help gate must be present")
    deferred = [FINAL_HELP_GATE] if stage != "all" else []
    selected = [test for test in tests if test.id() not in deferred]
    return unittest.TestSuite(selected), {"stage": stage, "discoveredCount": len(tests),
                                         "selectedCount": len(selected), "deferred": deferred,
                                         "fullValidationPerformed": stage == "all"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--suite", choices=("all", "seed", "se"), required=True)
    args = parser.parse_args(argv)
    os.environ["PYTHONDONTWRITEBYTECODE"] = "1"
    suite = unittest.defaultTestLoader.discover(str(args.root / "scripts/tests"), pattern="test_*.py")
    selected, report = select_suite(suite, args.suite)
    result = unittest.TextTestRunner(verbosity=2, stream=sys.stderr).run(selected)
    report.update(testsRun=result.testsRun, failures=len(result.failures), errors=len(result.errors),
                  skipped=len(result.skipped), fullValidationPassed=args.suite == "all" and result.wasSuccessful())
    print(json.dumps(report, sort_keys=True))
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
