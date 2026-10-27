#!/usr/bin/env python3
"""Compile actual TelemetryModel methods against explicit boundary test doubles.

This is a coordinator control-flow regression harness, NOT a UIKit, Bluetooth,
SQLite, or device test. No production method body is copied into the fixtures.
The full TelemetryCore suite and native application build run separately in CI.
"""
from pathlib import Path
import datetime
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "mobile-ios/App/TelemetryModel.swift"
METHODS = ["endpoint", "startLocation", "stopLocation", "store", "refreshQueueDepth",
           "handleLocations", "mark", "handleDiagnosticResult", "applyLocalDiagnosticSignals",
           "handleLiveFrame", "ingestLocal", "applyLocalSignals", "stopDemoAdapter", "stopLiveAdapter", "configureOptionalUpload"]


def extract(source: str, name: str) -> str:
    # Require the current four-space method boundary; fail closed after a
    # refactor rather than accidentally testing a stale hand-written copy.
    matches = list(re.finditer(r"^    (?:private )?func " + re.escape(name) + r"\b.*?^    }", source, re.M | re.S))
    if len(matches) != 1:
        raise RuntimeError(f"Expected one complete method: {name}; got {len(matches)}")
    return matches[0].group(0).replace("    private func ", "    func ", 1)


def main() -> None:
    source = SOURCE.read_text(encoding="utf-8")
    methods = [extract(source, name) for name in METHODS]
    # New shared helpers are extracted too, never reimplemented by the harness.
    for name in ("resetLocalSignalSnapshot", "mergeLocalSignals"):
        if re.search(r"^    (?:private )?func " + name + r"\b", source, re.M):
            methods.append(extract(source, name))
    template_dir = ROOT / "scripts/tests/telemetry-model-harness"
    shell = (template_dir / "Support.swift").read_text(encoding="utf-8")
    helper = ROOT / "mobile-ios/TelemetryCore/Sources/TelemetryCore/LocalSignalSnapshot.swift"
    if helper.exists():
        shell = shell.replace("// CACHE_FIELD", "var localSignalSnapshot = LocalSignalSnapshot()")
    shell = shell.replace("// PRODUCTION_METHODS", "\n\n".join(methods))
    swift = shutil.which("swiftc")
    if swift is None:
        raise SystemExit("Swift compiler is required")
    print(f"TelemetryModel source SHA256: {hashlib.sha256(source.encode()).hexdigest()}", flush=True)
    print("Running actual coordinator methods; OS/upload/store boundaries are test doubles.", flush=True)
    with tempfile.TemporaryDirectory(prefix="telemetry-model-harness-") as tmp:
        tmp = Path(tmp)
        generated = tmp / "Coordinator.swift"
        generated.write_text(shell, encoding="utf-8")
        binary = tmp / "tests"
        inputs = [str(generated), str(template_dir / "Checks.swift"),
                  str(ROOT / "mobile-ios/App/TelemetryProductScope.swift")]
        if helper.exists():
            inputs.append(str(helper))
        subprocess.run([swift, "-swift-version", "5", "-parse-as-library", *inputs, "-o", str(binary)], check=True, timeout=90)
        subprocess.run([str(binary)], check=True, timeout=30)


def diagnostic_recording(output: Path) -> None:
    """Real App callback/admission methods and Core SQLite, without OS adapters."""
    output.mkdir(parents=True, exist_ok=False)
    source = SOURCE.read_text(encoding="utf-8")
    names = ["handleAdapterState", "handleDiagnosticResult", "startRecording", "stopRecording", "handleRecordingFailure"]
    methods = [extract(source, name) for name in names]
    records = re.findall(r"^    private func record\b.*?^    }", source, re.M | re.S)
    if len(records) != 2:
        raise RuntimeError("Expected both production record admission methods")
    methods += [method.replace("    private func ", "    func ", 1) for method in records]
    if re.search(r"^    private func handleDiagnosticFailure\b", source, re.M):
        methods.append(extract(source, "handleDiagnosticFailure"))
    bindings = []
    for match in re.finditer(r"^        diagnosticAdapter\.(\w+) = \{.*?^        }", source, re.M | re.S):
        name = match.group(1)
        if name not in ("onState", "onResult", "onQueryFailure"):
            raise RuntimeError("Unrecognized diagnostic callback binding: " + name)
        # Observe only after the complete, unchanged production callback body.
        kind, value = ("result", "result.queryID") if name == "onResult" else ("failure" if name == "onQueryFailure" else "state", "state")
        bindings.append(match.group(0)[:-9] + f'            self?.callbackReturned?("{kind}", {value})\n        }}')
    if len(bindings) < 2:
        raise RuntimeError("Production diagnostic callback bindings are missing")
    templates = ROOT / "scripts/tests/diagnostic-recording-harness"
    shell = (templates / "Support.swift").read_text().replace("// PRODUCTION_BINDINGS", "\n".join(bindings))
    shell = shell.replace("// PRODUCTION_METHODS", "\n\n".join(methods))
    checks = (templates / "Checks.swift").read_text()
    csv_source = (ROOT / "mobile-ios/TelemetryCore/Tests/TelemetryCoreTests/MeasurementReplayIntegrityTests.swift").read_text()
    checks = checks.replace("// CSV_PARSER", extract(csv_source, "parseCSV"))
    work = Path(tempfile.mkdtemp(prefix="telemetry-diagnostic-recording-"))
    package = work / "Probe"
    sources = package / "Sources/Probe"
    sources.mkdir(parents=True)
    (sources / "RecordingModel.swift").write_text(shell)
    (sources / "Checks.swift").write_text(checks)
    controller = ROOT / "mobile-ios/App/DiagnosticAdapterController.swift"
    shutil.copyfile(controller, sources / controller.name)
    core = ROOT / "mobile-ios/TelemetryCore"
    core_inputs = [core / "Package.swift"] + [p for folder in ("Sources", "Tests") for p in (core / folder).rglob("*") if p.is_file()]
    for path in core_inputs:
        target = work / "TelemetryCore" / path.relative_to(core)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    (package / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "DiagnosticRecordingProbe", platforms: [.macOS(.v13)], '
        'dependencies: [.package(path: "../TelemetryCore")], '
        'targets: [.executableTarget(name: "Probe", dependencies: '
        '[.product(name: "TelemetryCore", package: "TelemetryCore")])])\n')
    fixture = work / "fixture"
    receipt = {"startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "workspace": str(work), "sourceRoot": str(ROOT),
        "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [SOURCE, controller, *templates.glob("*.swift")]},
        "coreInputHashes": {str(p.relative_to(core)): hashlib.sha256(p.read_bytes()).hexdigest() for p in core_inputs},
        "scope": "Actual App controller/callback/record/Stop source plus Core; adapter/UI projection doubles; no device/network"}
    command = ["swift", "run", "--package-path", str(package), "--scratch-path", str(work / "build"), "Probe", "record", str(fixture)]
    receipt["recordCommand"] = command
    with (output / "record.log").open("w") as log:
        try:
            receipt["recordExitCode"] = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=180).returncode
        except subprocess.TimeoutExpired:
            receipt["recordExitCode"] = None
    binaries = {p.resolve() for p in (work / "build").rglob("Probe") if p.is_file() and os.access(p, os.X_OK)}
    receipt["compiled"] = len(binaries) == 1
    receipt["reopenExitCode"] = None
    if receipt["compiled"]:
        command = [str(binaries.pop()), "reopen", str(fixture)]
        receipt["reopenCommand"] = command
        with (output / "reopen.log").open("w") as log:
            try:
                receipt["reopenExitCode"] = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=30).returncode
            except subprocess.TimeoutExpired:
                pass
    for phase in ("record", "reopen"):
        path = output / (phase + ".log")
        if path.exists():
            content = path.read_text()
            match = re.search(r"SOURCE HARNESS: (\d+) assertions, (\d+) failures", content)
            if match:
                receipt[phase + "Assertions"] = int(match.group(1))
                receipt[phase + "Failures"] = int(match.group(2))
            print(content[-10000:])
    receipt["closedBeforeReopenByProcessExit"] = receipt["compiled"]
    receipt["finishedUTC"] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    raise SystemExit(0 if receipt["compiled"] and receipt["recordExitCode"] == receipt["reopenExitCode"] == 0 else 1)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--diagnostic-recording":
        diagnostic_recording(Path(sys.argv[2]))
    else:
        main()
