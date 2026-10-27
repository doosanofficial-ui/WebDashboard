#!/usr/bin/env python3
"""Compile actual TelemetryModel methods against explicit boundary test doubles.

This is a coordinator control-flow regression harness, NOT a UIKit, Bluetooth,
SQLite, or device test. No production method body is copied into the fixtures.
The full TelemetryCore suite and native application build run separately in CI.
"""
from pathlib import Path
import argparse
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

DIAGNOSTIC_CALLBACKS = {
    "onState": ("state", "state"),
    "onResult": ("result", "result.queryID"),
    "onQueryFailure": ("failure", "state"),
    "onAcquiringChanged": None,
    "onConnection": None,
    "onObservation": None,
    "onObservationUnavailable": None,
    "onAudit": None,
    "onAuditError": None,
}


def diagnostic_bindings(source: str) -> list[str]:
    """Keep every known production closure; instrument only the legacy test seam."""
    assignments = re.findall(r"^        diagnosticAdapter\.(\w+)\s*=", source, re.M)
    matches = list(re.finditer(r"^        diagnosticAdapter\.(\w+) = \{.*?^        }", source, re.M | re.S))
    names = [match.group(1) for match in matches]
    for name in assignments:
        if name not in DIAGNOSTIC_CALLBACKS:
            raise RuntimeError("Unrecognized diagnostic callback binding: " + name)
        if assignments.count(name) != 1:
            raise RuntimeError("Duplicate diagnostic callback binding: " + name)
    if names != assignments:
        raise RuntimeError("Unsupported diagnostic callback shape; production closures must be extracted completely")
    if not {"onState", "onResult"}.issubset(names):
        raise RuntimeError("Production diagnostic callback bindings are missing")
    bindings = []
    for match in matches:
        observer = DIAGNOSTIC_CALLBACKS[match.group(1)]
        binding = match.group(0)
        if observer is not None:
            kind, value = observer
            binding = binding[:-9] + f'            self?.callbackReturned?("{kind}", {value})\n        }}'
        bindings.append(binding)
    return bindings


def recording_state_fields(source: str) -> tuple[list[str], list[Path]]:
    """Use actual App initializers and files instead of workspace/audit doubles."""
    fields, files = [], []
    for name, type_name in (("diagnosticWorkspace", "DiagnosticWorkspaceState"),
                            ("diagnosticAudit", "DiagnosticAuditRecordingState")):
        declarations = re.findall(r"^    let " + name + r"\s*=.*$", source, re.M)
        if not declarations:
            if re.search(r"\b" + name + r"\b", source):
                raise RuntimeError("Missing production state declaration: " + name)
            continue
        if len(declarations) != 1:
            raise RuntimeError("Ambiguous production state declaration: " + name)
        path = ROOT / "mobile-ios/App" / (type_name + ".swift")
        if not path.is_file():
            raise RuntimeError("Missing actual App state dependency: " + str(path))
        fields.append(declarations[0])
        files.append(path)
    return fields, files


AUDIT_CHECKS = r'''
    // Legacy assertions retain their exact scope. Only valid typed audit rows
    // are separate additions. Loss markers remain visible to legacy assertions.
    static func legacyMeasurements(_ rows: [PersistedMeasurement]) throws -> [PersistedMeasurement] {
        struct Name: Decodable { let name: String }
        return try rows.filter { row in
            guard row.kind == "SYSTEM" else { return true }
            let data = Data(row.payloadJSON.utf8)
            let name = try JSONDecoder().decode(Name.self, from: data).name
            if name == DiagnosticAuditSystemPayload.name {
                _ = try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: data)
                return false
            }
            return true
        }
    }

    @MainActor static func verifyNoAuditLossMarker(_ rows: [PersistedMeasurement], scenario: String) throws {
        struct Name: Decodable { let name: String }
        let names = try rows.filter { $0.kind == "SYSTEM" }.map {
            try JSONDecoder().decode(Name.self, from: Data($0.payloadJSON.utf8)).name
        }
        expect(!names.contains("diagnostic_audit_incomplete"),
               "\(scenario) healthy fixture persists zero audit loss markers")
    }

    @MainActor static func verifyAuditRows(_ rows: [PersistedMeasurement]) throws {
        struct Name: Decodable { let name: String }
        var events: [DiagnosticAuditEvent] = []
        let system = rows.filter { $0.kind == "SYSTEM" }
        for row in system {
            let data = Data(row.payloadJSON.utf8)
            if try JSONDecoder().decode(Name.self, from: data).name == DiagnosticAuditSystemPayload.name {
                events.append(try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: data).diagnosticAudit)
            }
        }
        let projection = DiagnosticAuditReplayProjection.project(systemPayloadJSON: system.map(\.payloadJSON))
        expect(!events.isEmpty, "actual App callbacks persist recording-window audit rows")
        expect(projection.status == .available, "healthy audit fixture has no malformed, incomplete or truncated attempt")
        expect(events.allSatisfy { $0.scope.isRecordingWindow }, "persisted audit scope is the explicit recording window")
        let groups = Dictionary(grouping: events, by: \.attemptID)
        expect(groups.values.allSatisfy { group in
            group.filter { $0.stage == .queued }.count == 1
                && group.filter { $0.stage == .started }.count <= 1
                && group.filter { $0.stage == .transportWriteStarted }.count <= 1
                && group.filter { $0.stage == .transportWriteCompleted }.count <= 1
                && group.filter { $0.stage == .terminal }.count == 1
                && Set(group.map(\.ordinal)).count == group.count
        }, "each admitted audit attempt has one queue, unique stages and exactly one terminal")
        expect(groups.values.contains { group in
            group.filter { $0.stage == .queued }.count == 1
                && group.filter { $0.stage == .started }.count == 1
                && group.filter { $0.stage == .transportWriteStarted }.count == 1
                && group.filter { $0.stage == .transportWriteCompleted }.count == 1
                && group.filter { $0.stage == .terminal }.count == 1
        }, "queued started transport-write-start completed and terminal all cross the actual App recording path")
        expect(projection.attempts.count == groups.count && projection.attempts.allSatisfy(\.isTerminal),
               "every persisted audit group reconstructs completely after Stop")
    }

    @MainActor static func recordAuditScenario(root: URL) async throws {
        let path = root.appendingPathComponent("audit-stages.sqlite")
        let original = try SantaFeMX5HybridQueryCatalog.initialQueries()[2]
        let profile = try AdapterProfile(id: "synthetic-audit", name: "Synthetic audit fixture", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil, notifyCharacteristicUUID: nil,
            host: "127.0.0.1", port: 35000, signals: [], diagnosticQueries: [query(original, id: queryID)])
        let transport = DiagnosticTransport()
        LiveAdapterController.transport = transport
        let model = RecordingModel(path: path)
        let finished = AsyncStream<Void>.makeStream()
        var stopped = false
        model.projectionReturned = {
            if stopped && !model.recordingClosing && model.completedRecorder != nil {
                finished.continuation.yield(()); finished.continuation.finish()
            }
        }
        model.callbackReturned = { kind, _ in
            guard kind == "failure", !stopped else { return }
            stopped = true
            // Keep the real callback -> queue admission -> Stop path synchronous.
            model.stopRecording()
            model.diagnosticAdapter.stop()
        }
        // Open the window before acquisition. A query queued before recording
        // starts is intentionally excluded by the production capture contract.
        model.startRecording()
        model.diagnosticAdapter.start(profile: profile)
        try await waitFor(finished.stream)
        try await waitFor(await transport.closeEvents())
        guard let recorder = model.completedRecorder else { throw ProbeError.deadline }
        let rows = try await recorder.export()
        try verifyNoAuditLossMarker(rows, scenario: "audit-stages")
        try verifyAuditRows(rows)
        for row in rows where row.kind == "SYSTEM" {
            struct Name: Decodable { let name: String }
            let data = Data(row.payloadJSON.utf8)
            if try JSONDecoder().decode(Name.self, from: data).name == DiagnosticAuditSystemPayload.name {
                let event = try JSONDecoder().decode(DiagnosticAuditSystemPayload.self, from: data).diagnosticAudit
                model.diagnosticAdapter.onAudit?(event)
                break
            }
        }
        model.diagnosticAdapter.onAuditError?(.init(connectionID: UUID(), error: .scopeMismatch,
            emittedAtEpoch: Date().timeIntervalSince1970,
            emittedAtMonotonicNanos: DispatchTime.now().uptimeNanoseconds))
        let afterLate = try await recorder.export()
        expect(afterLate == rows, "late actual audit and audit-error callbacks after Stop cannot append a row")
        try await recorder.exportSessionJSON().write(to: root.appendingPathComponent("audit-stages.json"))
        model.callbackReturned = nil; model.projectionReturned = nil
        model.completedRecorder = nil
        LiveAdapterController.transport = nil
    }

    @MainActor static func closeAuditWindow(_ model: RecordingModel) async throws -> MeasurementRecorder {
        let finished = AsyncStream<Void>.makeStream()
        model.projectionReturned = {
            if !model.recordingClosing && model.completedRecorder != nil {
                finished.continuation.yield(()); finished.continuation.finish()
            }
        }
        model.stopRecording()
        try await waitFor(finished.stream)
        model.projectionReturned = nil
        guard let recorder = model.completedRecorder else { throw ProbeError.deadline }
        return recorder
    }

    @MainActor static func verifyAuditErrorWindowRows(_ rows: [PersistedMeasurement], scenario: String) throws {
        let names = try namedEvents(rows)
        if scenario == "audit-current-error-window" {
            expect(names.filter { $0 == "diagnostic_audit_incomplete" }.count == 1,
                   "a current-window error is persisted exactly once even when delivered twice")
            expect(names == ["recording_started", "diagnostic_audit_incomplete", "recording_stopped"],
                   "current-window capture loss remains an explicit ordered SYSTEM measurement")
            let projection = DiagnosticAuditReplayProjection.project(
                systemPayloadJSON: rows.filter { $0.kind == "SYSTEM" }.map(\.payloadJSON))
            expect(projection.captureWasIncomplete && projection.status == .unavailable,
                   "persisted current-window capture loss remains unavailable after Replay projection")
        } else {
            try verifyNoAuditLossMarker(rows, scenario: scenario)
            expect(names == ["recording_started", "recording_stopped"],
                   "a frozen error from the previous window creates no row in the new database")
        }
    }

    @MainActor static func recordAuditErrorWindows(root: URL) async throws {
        let model = RecordingModel(path: root.appendingPathComponent("audit-error-source.sqlite"))
        let connection = UUID()
        model.startRecording()
        // Freeze source emission time before Stop. Delivery below occurs only
        // after a later Begin and must never be relabeled with arrival time.
        let stale = DiagnosticAuditFailureReceipt(connectionID: connection, error: .scopeMismatch,
            emittedAtEpoch: Date().timeIntervalSince1970,
            emittedAtMonotonicNanos: DispatchTime.now().uptimeNanoseconds)
        let sourceRecorder = try await closeAuditWindow(model)
        let sourceRows = try await sourceRecorder.export()
        expect(try namedEvents(sourceRows) == ["recording_started", "recording_stopped"],
               "an empty audit window closes without invalidating the measurement queue")

        model.measurementDBURL = root.appendingPathComponent("audit-old-error-window.sqlite")
        model.startRecording()
        model.diagnosticAdapter.onAuditError?(stale)
        expect(model.localRecordingEnabled && !model.recordingClosing && !model.diagnosticAudit.captureIsIncomplete,
               "an old frozen error cannot poison the new recording window")
        let oldRecorder = try await closeAuditWindow(model)
        let oldRows = try await oldRecorder.export()
        try verifyAuditErrorWindowRows(oldRows, scenario: "audit-old-error-window")
        try await oldRecorder.exportSessionJSON().write(to: root.appendingPathComponent("audit-old-error-window.json"))

        model.measurementDBURL = root.appendingPathComponent("audit-current-error-window.sqlite")
        model.startRecording()
        let current = DiagnosticAuditFailureReceipt(connectionID: connection, error: .scopeMismatch,
            emittedAtEpoch: Date().timeIntervalSince1970,
            emittedAtMonotonicNanos: DispatchTime.now().uptimeNanoseconds)
        model.diagnosticAdapter.onAuditError?(current)
        model.diagnosticAdapter.onAuditError?(current)
        expect(model.localRecordingEnabled && model.diagnosticAudit.captureIsIncomplete,
               "a new-window source error marks loss while recording continues")
        let currentRecorder = try await closeAuditWindow(model)
        let currentRows = try await currentRecorder.export()
        try verifyAuditErrorWindowRows(currentRows, scenario: "audit-current-error-window")
        try await currentRecorder.exportSessionJSON().write(to: root.appendingPathComponent("audit-current-error-window.json"))
        model.completedRecorder = nil
    }
'''


def extend_audit_checks(checks: str) -> str:
    replacements = {
        'return try rows.filter { $0.kind == "SYSTEM" }.map {':
            'return try legacyMeasurements(rows).filter { $0.kind == "SYSTEM" }.map {',
        'expect(rows.map(\\.kind) == [':
            'expect(try legacyMeasurements(rows).map(\\.kind) == [',
        'let names = try namedEvents(rows)':
            'let names = try namedEvents(rows)\n'
            '        try verifyNoAuditLossMarker(rows, scenario: scenario)',
        'for scenario in ["failure-immediate", "recording-off", "replay", "skip-and-success"] {':
            'for scenario in ["failure-immediate", "recording-off", "replay", "skip-and-success", '
            '"audit-stages", "audit-old-error-window", "audit-current-error-window"] {',
        'else { try await recordScenario(scenario, root: root) }':
            'else if scenario == "audit-stages" { try await recordAuditScenario(root: root) }\n'
            '                else if scenario == "audit-old-error-window" { try await recordAuditErrorWindows(root: root) }\n'
            '                else if scenario == "audit-current-error-window" { continue }\n'
            '                else { try await recordScenario(scenario, root: root) }',
        'let loaded = try await archive.load(sessionID: expected.session.sessionID)':
            'let loaded = try await archive.load(sessionID: expected.session.sessionID)\n'
            '        if scenario == "audit-old-error-window" || scenario == "audit-current-error-window" {\n'
            '            try verifyAuditErrorWindowRows(loaded.measurements, scenario: scenario)\n'
            '        } else {\n'
            '            try verifyNoAuditLossMarker(loaded.measurements, scenario: scenario)\n'
            '        }\n'
            '        if scenario == "audit-stages" { try verifyAuditRows(loaded.measurements) }',
        '    @MainActor static func main() async {':
            AUDIT_CHECKS + '\n    @MainActor static func main() async {',
    }
    for before, after in replacements.items():
        if checks.count(before) != 1:
            raise RuntimeError("Diagnostic recording check seam changed: " + before)
        checks = checks.replace(before, after, 1)
    return checks


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
        subprocess.run([swift, "-swift-version", "5", "-parse-as-library",
                        "-module-cache-path", str(tmp / "module-cache"), *inputs, "-o", str(binary)],
                       check=True, timeout=90)
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
    bindings = diagnostic_bindings(source)
    fields, app_dependencies = recording_state_fields(source)
    templates = ROOT / "scripts/tests/diagnostic-recording-harness"
    shell = (templates / "Support.swift").read_text().replace("// PRODUCTION_BINDINGS", "\n".join(bindings))
    shell = shell.replace("// PRODUCTION_METHODS", "\n\n".join(methods))
    if fields:
        anchor = "    let diagnosticAdapter = DiagnosticAdapterController()"
        if shell.count(anchor) != 1:
            raise RuntimeError("Diagnostic RecordingModel field seam changed")
        shell = shell.replace(anchor, anchor + "\n" + "\n".join(fields), 1)
    checks = (templates / "Checks.swift").read_text()
    if any(path.name == "DiagnosticAuditRecordingState.swift" for path in app_dependencies):
        checks = extend_audit_checks(checks)
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
    for dependency in app_dependencies:
        shutil.copyfile(dependency, sources / dependency.name)
    core = ROOT / "mobile-ios/TelemetryCore"
    core_inputs = [core / "Package.swift"] + [p for folder in ("Sources", "Tests") for p in (core / folder).rglob("*") if p.is_file()]
    for path in core_inputs:
        target = work / "TelemetryCore" / path.relative_to(core)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
    (package / "Package.swift").write_text(
        '// swift-tools-version: 5.9\nimport PackageDescription\n'
        'let package = Package(name: "DiagnosticRecordingProbe", platforms: [.macOS(.v14)], '
        'dependencies: [.package(path: "../TelemetryCore")], '
        'targets: [.executableTarget(name: "Probe", dependencies: '
        '[.product(name: "TelemetryCore", package: "TelemetryCore")])])\n')
    fixture = work / "fixture"
    receipt = {"startedUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "workspace": str(work), "sourceRoot": str(ROOT),
        "sourceHashes": {str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                         for p in [SOURCE, controller, *app_dependencies, *templates.glob("*.swift")]},
        "generatorSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "diagnosticCallbackNames": re.findall(r"^        diagnosticAdapter\.(\w+)\s*=", source, re.M),
        "appDependencies": [str(path.relative_to(ROOT)) for path in app_dependencies],
        "coreInputHashes": {str(p.relative_to(core)): hashlib.sha256(p.read_bytes()).hexdigest() for p in core_inputs},
        "scope": "Actual App controller/callback/record/Stop source plus Core; adapter/UI projection doubles; no device/network"}
    command = ["swift", "run", "--build-system", "native", "--disable-sandbox", "--jobs", "1",
               "--package-path", str(package), "--scratch-path", str(work / "build"),
               "--cache-path", str(work / "swiftpm-cache"), "--config-path", str(work / "swiftpm-config"),
               "--security-path", str(work / "swiftpm-security"), "Probe", "record", str(fixture)]
    environment = os.environ.copy()
    environment["CLANG_MODULE_CACHE_PATH"] = str(work / "clang-module-cache")
    environment["SWIFTPM_MODULECACHE_OVERRIDE"] = str(work / "swift-module-cache")
    receipt["recordCommand"] = command
    with (output / "record.log").open("w") as log:
        try:
            receipt["recordExitCode"] = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT,
                                                      env=environment, timeout=180).returncode
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", type=Path, default=ROOT,
                        help="Read actual App/Core/template files from this root; never modify them")
    parser.add_argument("--diagnostic-recording", type=Path, metavar="OUTPUT",
                        help="Run actual recording/controller callbacks and separate-process SQLite reopen")
    arguments = parser.parse_args()
    ROOT = arguments.source_root.resolve()
    SOURCE = ROOT / "mobile-ios/App/TelemetryModel.swift"
    if arguments.diagnostic_recording is not None:
        diagnostic_recording(arguments.diagnostic_recording)
    else:
        main()
