#!/usr/bin/env python3
"""Host regression for the actual Demo producer, Core decoder and SQLite replay.

No Simulator, app container, install, network dependency or permission is used.
Build in an owned system-temp directory to avoid file-provider signing metadata.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--checks", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    checks = args.checks or args.root / "scripts/tests/demo-adapter/Checks.swift"
    demo = args.root / "mobile-ios/App/DemoAdapterController.swift"
    core = args.root / "mobile-ios/TelemetryCore"
    work = Path(tempfile.mkdtemp(prefix="telemetry-demo-regression-"))
    package = work / "Probe"
    sources = package / "Sources/Probe"
    sources.mkdir(parents=True)
    inputs = {"DemoAdapterController.swift": demo, "Checks.swift": checks}
    for name, path in inputs.items():
        shutil.copyfile(path, sources / name)
    core_inputs = [core / "Package.swift"]
    core_inputs += [path for folder in ("Sources", "Tests") for path in (core / folder).rglob("*") if path.is_file()]
    for path in core_inputs:
        relative = path.relative_to(core)
        if path.is_file() and (relative.parts[0] in ("Sources", "Tests") or str(relative) == "Package.swift"):
            target = work / "TelemetryCore" / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, target)
    (package / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "DemoProbe", platforms: [.macOS(.v13)], '
        'dependencies: [.package(path: "../TelemetryCore")], '
        'targets: [.executableTarget(name: "Probe", dependencies: '
        '[.product(name: "TelemetryCore", package: "TelemetryCore")])])\n')
    receipt = {"startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "workspace": str(work), "sourceRoot": str(args.root),
               "sourceHashes": {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in inputs.items()},
               "coreInputHashes": {str(path.relative_to(core)): hashlib.sha256(path.read_bytes()).hexdigest() for path in core_inputs},
               "scope": "Actual unmodified Demo source and Core on macOS host; no Simulator/UI/app data",
               "fixtureRetained": True}
    command = ["swift", "run", "--package-path", str(package), "--scratch-path", str(work / "build"),
               "Probe", str(work / "fixture")]
    receipt["command"] = command
    env = os.environ.copy()
    with (args.output / "checks.log").open("w") as log:
        try:
            result = subprocess.run(command, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=150)
            receipt["exitCode"] = result.returncode
            receipt["timedOut"] = False
        except subprocess.TimeoutExpired:
            receipt["exitCode"] = None
            receipt["timedOut"] = True
    receipt["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (args.output / "receipt.json").write_text(json.dumps(receipt, ensure_ascii=False, indent=2) + "\n")
    print((args.output / "checks.log").read_text()[-5000:])
    print(json.dumps(receipt, ensure_ascii=False))
    raise SystemExit(0 if receipt["exitCode"] == 0 else 1)


if __name__ == "__main__":
    main()
