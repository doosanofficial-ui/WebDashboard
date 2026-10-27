"""Exercise actual replay energy bindings, projection and session reset on the host.

SwiftUI @State is replaced with explicit test storage so child values can be
recreated without a window. This verifies the App's ownership/binding boundary,
not SwiftUI's real lazy/disclosure lifetime. Native UI evidence is separate.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def balanced(source, start, opening, closing):
    begin = source.index(opening, start)
    depth, end = 1, begin + 1
    while depth:
        depth += (source[end] == opening) - (source[end] == closing)
        end += 1
    return source[start:end]


def generate(sessions, energy, summary, fixture):
    # Execute the production initializer call and declarations, rather than
    # recreating the selection plumbing in the fixture.
    call = balanced(sessions, sessions.index("ReplayEnergyView("), "(", ")")
    fields = re.findall(r"^    @State private var selected(?:VoltageSignalID|CurrentSignalID|CurrentSignConventionRawValue): String\?.*$",
                        sessions, re.MULTILINE)
    callback_marker = ".onChange(of: model.replayController.sessionID)"
    reset = ""
    owner_body = sessions[:sessions.index("    private func energySignalIDs(")]
    if callback_marker in owner_body:
        callback = balanced(owner_body, owner_body.index(callback_marker), "{", "}")
        reset = callback.split(" in", 1)[1].rsplit("}", 1)[0]
    candidates = balanced(sessions, sessions.index("private func energySignalIDs("), "{", "}")
    # Keep the actual properties, initializer and projection; rendering stays
    # with the native UI test. Access control is lifted only in this test copy.
    projection = energy[:energy.index("    var body: some View {")] + "}\n"
    projection = projection.replace("struct ReplayEnergyView: View", "@MainActor struct ReplayEnergyView")
    projection = projection.replace("private ", "").replace("@State ", "@HeadlessState ")
    labels = balanced(summary, summary.index("struct Labels {"), "{", "}")
    owner = "\n".join(fields).replace("@State ", "@HeadlessState ").replace("private ", "")
    return (fixture.replace("// ACTUAL_ENERGY_PROJECTION", projection)
            .replace("// ACTUAL_SUMMARY_LABELS", labels)
            .replace("// ACTUAL_OWNER_FIELDS", owner)
            .replace("// ACTUAL_ENERGY_CALL", "return " + call)
            .replace("// ACTUAL_ENERGY_CANDIDATES", candidates)
            .replace("// ACTUAL_SESSION_RESET", reset))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = args.root.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    app = root / "mobile-ios/App"
    inputs = [app / name for name in ("SessionsView.swift", "ReplayEnergyView.swift",
              "ReplayController.swift", "SessionEnergySummaryView.swift")]
    checks = root / "scripts/tests/replay-energy-selection/Checks.swift"
    work = Path(tempfile.mkdtemp(prefix="telemetry-replay-energy-selection-"))
    package = work / "Probe"
    sources = package / "Sources/Probe"
    sources.mkdir(parents=True)
    (sources / "Checks.swift").write_text(generate(inputs[0].read_text(), inputs[1].read_text(),
                                                 inputs[3].read_text(), checks.read_text()))
    shutil.copyfile(inputs[2], sources / inputs[2].name)
    core = root / "mobile-ios/TelemetryCore"
    core_inputs = [core / "Package.swift"] + sorted(path for path in (core / "Sources").rglob("*") if path.is_file())
    for path in core_inputs:
        target = work / "TelemetryCore" / path.relative_to(core)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    (package / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "ReplayEnergySelectionProbe", platforms: [.macOS(.v14)], '
        'dependencies: [.package(path: "../TelemetryCore")], '
        'targets: [.executableTarget(name: "Probe", dependencies: '
        '[.product(name: "TelemetryCore", package: "TelemetryCore")])])\n')
    receipt = {"startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
               "sourceRoot": str(root), "workspace": str(work),
               "sourceHashes": {str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in [*inputs, checks, Path(__file__)]},
               "coreInputHashes": {str(path.relative_to(core)): hashlib.sha256(path.read_bytes()).hexdigest()
                                   for path in core_inputs},
               "scope": "Actual App parent fields/call/session-reset, child bindings/projection and ReplayController/Core; headless state storage; no native UI lifetime, device or Simulator evidence"}
    command = ["/usr/bin/nice", "-n", "10", "swift", "run", "--build-system", "native", "--disable-sandbox",
               "--jobs", "1", "--package-path", str(package), "--scratch-path", str(work / "build"),
               "--cache-path", str(work / "swiftpm-cache"), "--config-path", str(work / "swiftpm-config"),
               "--security-path", str(work / "swiftpm-security"), "Probe"]
    receipt["command"] = command
    environment = dict(os.environ, CLANG_MODULE_CACHE_PATH=str(work / "clang-module-cache"),
                       SWIFTPM_MODULECACHE_OVERRIDE=str(work / "swift-module-cache"))
    with (args.output / "checks.log").open("w") as log:
        try:
            receipt["exitCode"] = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                                  env=environment, timeout=180).returncode
        except subprocess.TimeoutExpired:
            receipt["exitCode"] = None
    content = (args.output / "checks.log").read_text()
    match = re.search(r"REPLAY ENERGY SELECTION SOURCE HARNESS: (\d+) assertions, (\d+) failures", content)
    if match:
        receipt["assertions"], receipt["failures"] = map(int, match.groups())
    receipt["behaviorFailures"] = [line for line in content.splitlines() if line.startswith("FAIL:")]
    receipt["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (args.output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(content[-7000:])
    print(json.dumps({key: value for key, value in receipt.items() if key != "coreInputHashes"}))
    raise SystemExit(0 if receipt["exitCode"] == 0 and match else 1)


if __name__ == "__main__":
    main()
