#!/usr/bin/env python3
"""Correlate one captured XCTest rate scenario with its actual Picker/model receipts."""
import argparse
import datetime
import json
import math
from pathlib import Path
import re

PREFIX = "[DEBUG-replay-rate-W2]"
STAGES = ["picker.proposed", "model.received", "controller.received", "model.result"]


class InvalidCapture(ValueError):
    def __init__(self, code, field):
        self.code, self.field = code, field
        super().__init__(code)


def require(condition, code, field):
    if not condition:
        raise InvalidCapture(code, field)


def read_input(path, field):
    try:
        require(path.stat().st_size <= 8 * 1024 * 1024, "input_too_large", field)
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        raise InvalidCapture("input_unavailable", field) from None


def verify(ui, trace):
    require("stage=armed scope=synthetic-export-fixture" in trace, "admission_missing", "rate_log")
    start = re.search(r't =\s*([0-9.]+)s Start Test at ([0-9-]+ [0-9:.]+)', ui)
    require(start is not None, "clock_anchor_missing", "ui_log")
    anchor = datetime.datetime.fromisoformat(start[2])
    offset = float(start[1])
    require(math.isfinite(offset), "invalid_clock_anchor", "ui_log")
    taps = [(float(m[1]), m[2]) for m in re.finditer(r't =\s*([0-9.]+)s Tap "([^"]+)"', ui)]
    requests, proposals = {}, []
    for line in trace.splitlines():
        if PREFIX not in line or " id=" not in line:
            continue
        fields = dict(re.findall(r'(id|stage|requested|effective|clock|last|accepted)=([^ ]+)', line))
        require(set(fields) == {"id", "stage", "requested", "effective", "clock", "last", "accepted"},
                "boundary_fields_missing", "rate_log")
        identity = int(fields["id"])
        require(identity > 0 and fields["stage"] in STAGES, "invalid_boundary", "rate_log")
        for key in ("requested", "effective", "clock", "last"):
            fields[key] = float(fields[key])
            require(math.isfinite(fields[key]), "nonfinite_boundary", "rate_log")
        requests.setdefault(identity, []).append(fields)
        if fields["stage"] == "picker.proposed":
            # Compare captured wall clocks relatively, without inventing a bus/receive epoch.
            elapsed = (datetime.datetime.fromisoformat(line[:23]) - anchor).total_seconds() + offset
            proposals.append((elapsed, identity, fields["requested"]))
    require(bool(requests) and all(identity == index for index, identity in enumerate(sorted(requests), 1)),
            "request_receipts_missing", "rate_log")
    receiver_errors = []
    for identity, events in requests.items():
        require([e["stage"] for e in events] == STAGES, "boundary_sequence_incomplete", "rate_log")
        wanted = events[0]["requested"]
        require(wanted in (0.5, 1.0, 2.0), "unsupported_rate", "rate_log")
        if any(e["requested"] != wanted for e in events):
            receiver_errors.append({"id": identity, "reason": "receiver_value_changed"})
        if (events[2]["clock"] < events[2]["last"] or events[-1]["accepted"] != "true"
                or events[-1]["effective"] != wanted):
            receiver_errors.append({"id": identity, "reason": "controller_not_accepted"})
    current, observations, used = 1.0, [], set()
    for index, (when, target) in enumerate(taps):
        if target in ("replay-saved-session", "stop-replay-header"):
            current = 1.0
        rate = re.fullmatch(r'([0-9.]+)\u00d7', target)
        if not rate:
            continue
        expected = float(rate[1])
        require(expected in (0.5, 1.0, 2.0) and math.isfinite(when), "invalid_rate_tap", "ui_log")
        deadline = min(taps[index + 1][0] if index + 1 < len(taps) else when + 5, when + 5)
        actual = [(identity, value) for stamp, identity, value in proposals if when - 0.1 <= stamp < deadline - 0.05]
        used.update(identity for identity, _ in actual)
        correct = actual[-1][1] == expected if actual else current == expected
        observations.append({"tapTarget": target, "expectedRate": expected, "actualPickerRequests": actual,
                             "alreadySelectedNoop": not actual and current == expected, "correct": correct})
        if actual:
            current = requests[actual[-1][0]][-1]["effective"]
    require(bool(observations), "rate_taps_missing", "ui_log")
    require(used == set(requests), "uncorrelated_rate_requests", "capture")
    good = all(o["correct"] for o in observations) and not receiver_errors
    return {"result": "PASS" if good else "FAIL", "scope": "Captured synthetic UI intent/receipt; not live CAN or physical evidence",
            "tapCount": len(observations), "correctCount": sum(o["correct"] for o in observations),
            "boundaryRequests": len(requests), "controllerAcceptedAll": not receiver_errors,
            "receiverErrors": receiver_errors, "observations": observations}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("ui_log", type=Path)
    parser.add_argument("rate_log", type=Path)
    args = parser.parse_args()
    try:
        result = verify(read_input(args.ui_log, "ui_log"), read_input(args.rate_log, "rate_log"))
    except InvalidCapture as error:
        result = {"result": "ERROR", "error": {"code": error.code, "field": error.field}}
    except (ValueError, KeyError, TypeError):
        result = {"result": "ERROR", "error": {"code": "invalid_capture_format", "field": "capture"}}
    print(json.dumps(result, ensure_ascii=False))
    return {"PASS": 0, "FAIL": 1, "ERROR": 2}[result["result"]]


if __name__ == "__main__":
    raise SystemExit(main())
