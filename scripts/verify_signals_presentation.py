"""Actual Signals caller expression + methods, with a frozen render-clock boundary."""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
from pathlib import Path


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end].replace("private ", "", 1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    signals = args.root / "mobile-ios/App/SignalsView.swift"
    display = args.root / "mobile-ios/App/TelemetryDisplayState.swift"
    source = signals.read_text()
    line = re.search(r"^\s*let displayDate = .+$", source, re.MULTILINE).group(0).strip()
    methods = "\n".join(declaration(source, m) for m in [
        "private func isFresh(", "private func frameAge(", "private func filteredRows("])
    fixture = (Path(__file__).parent / "tests/signals-presentation/Checks.swift").read_text()
    swift = fixture.replace("DISPLAY_DATE_EXPRESSION", line).replace("ACTUAL_SIGNALS_METHODS", methods)
    swift = swift.replace("ACTUAL_DISPLAY_STATE", display.read_text().replace("import TelemetryCore\n", ""))
    path = args.output / "Probe.swift"
    path.write_text(swift)
    receipt = {"startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "sourceRoot": str(args.root), "signalsSHA256": hashlib.sha256(signals.read_bytes()).hexdigest(),
               "displaySHA256": hashlib.sha256(display.read_bytes()).hexdigest(),
               "fixtureSHA256": hashlib.sha256(fixture.encode()).hexdigest(),
               "actualCallerExpression": line,
               "scope": "Actual presentation expression/methods, frozen Date clock and plain model boundary; no SwiftUI rendering, native services or app/device actions"}
    env = dict(os.environ, DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer")
    binary = args.output / "SignalsProbe"
    compile_command = ["/usr/bin/xcrun", "swiftc", "-parse-as-library", "-module-cache-path",
                       str(args.output / "module-cache"), str(path), "-o", str(binary)]
    build = subprocess.run(compile_command, capture_output=True, text=True, env=env, timeout=90)
    (args.output / "compile.log").write_text(build.stdout + build.stderr)
    receipt["compileExitCode"] = build.returncode
    if build.returncode == 0:
        result = subprocess.run([str(binary)], capture_output=True, text=True, env=env, timeout=15)
        (args.output / "checks.log").write_text(result.stdout + result.stderr)
        receipt["exitCode"] = result.returncode
        receipt["behaviorFailures"] = [line for line in result.stdout.splitlines() if line.startswith("FAIL:")]
        print(result.stdout)
    else:
        print(build.stderr[-5000:])
    receipt["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (args.output / "result.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    if receipt.get("compileExitCode") != 0 or receipt.get("exitCode") != 0:
        raise SystemExit(1)


if __name__ == "__main__":
    main()
