#!/usr/bin/env python3
"""Compile actual TelemetryModel methods against explicit boundary test doubles.

This is a coordinator control-flow regression harness, NOT a UIKit, Bluetooth,
SQLite, or device test. No production method body is copied into the fixtures.
The full TelemetryCore suite and native application build run separately in CI.
"""
from pathlib import Path
import hashlib
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "mobile-ios/App/TelemetryModel.swift"
METHODS = ["endpoint", "startLocation", "stopLocation", "store", "refreshQueueDepth",
           "handleLocations", "mark", "handleDiagnosticResult", "applyLocalDiagnosticSignals",
           "handleLiveFrame", "ingestLocal", "applyLocalSignals", "stopDemoAdapter", "configureOptionalUpload"]


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


if __name__ == "__main__":
    main()
