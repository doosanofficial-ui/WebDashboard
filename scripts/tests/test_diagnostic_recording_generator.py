"""Generator contracts only: no Swift process, device, network or App execution."""
import importlib.util
from pathlib import Path
import re
import shutil
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location("diagnostic_recording_generator",
                                            ROOT / "scripts/verify_telemetry_model.py")
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)

LEGACY = {
    "onState": "self?.handleAdapterState(state)",
    "onResult": "self?.handleDiagnosticResult(result)",
    "onQueryFailure": "self?.handleDiagnosticFailure(failure, state: state)",
}
EXTRA = {
    "onAcquiringChanged": "self?.diagnosticWorkspace.setAcquiring(acquiring)",
    "onConnection": "self?.diagnosticWorkspace.beganConnection(id, profile: profile)",
    "onObservation": "self?.diagnosticWorkspace.observe(receipt)",
    "onObservationUnavailable": "self?.diagnosticWorkspace.invalidateObservations(connectionID: id)",
    "onAudit": "self?.diagnosticAudit.receive(event)",
    "onAuditError": "self?.diagnosticAudit.failed(receipt)",
}
PARAMETERS = {
    "onState": "state", "onResult": "result", "onQueryFailure": "failure, state",
    "onAcquiringChanged": "acquiring", "onConnection": "id, profile", "onObservation": "id, receipt",
    "onObservationUnavailable": "id", "onAudit": "event", "onAuditError": "receipt",
}


def binding(name, body):
    return f"        diagnosticAdapter.{name} = {{ [weak self] {PARAMETERS[name]} in\n            {body}\n        }}"


def source(current=True):
    fields = ("    let diagnosticWorkspace = DiagnosticWorkspaceState()\n"
              "    let diagnosticAudit = DiagnosticAuditRecordingState()\n") if current else ""
    callbacks = dict(LEGACY, **EXTRA) if current else LEGACY
    methods = "\n".join(f"    func {name}() {{\n    }}" for name in
                        ("handleAdapterState", "handleDiagnosticResult", "startRecording",
                         "stopRecording", "handleRecordingFailure"))
    return ("final class InputFixture {\n" + fields + "    init() {\n"
            + "\n".join(binding(name, body) for name, body in callbacks.items()) + "\n    }\n"
            + methods + "\n    private func record(_ event: Int) {\n    }\n"
            "    private func record(contentsOf events: [Int]) {\n    }\n}\n")


class CompilerBoundary(Exception):
    pass


class DiagnosticRecordingGeneratorTests(unittest.TestCase):
    def generated(self, current=True):
        """Execute generation with synthetic inputs; stop before the Swift boundary."""
        captured = {}
        with tempfile.TemporaryDirectory(prefix="diagnostic-generator-contract-") as directory:
            root = Path(directory) / "source"
            app = root / "mobile-ios/App"
            app.mkdir(parents=True)
            model = app / "TelemetryModel.swift"
            model.write_text(source(current))
            (app / "DiagnosticAdapterController.swift").write_text("// synthetic source identity\n")
            for name in ("DiagnosticWorkspaceState", "DiagnosticAuditRecordingState"):
                (app / (name + ".swift")).write_text("final class " + name + " {}\n")
            templates = root / "scripts/tests/diagnostic-recording-harness"
            shutil.copytree(ROOT / "scripts/tests/diagnostic-recording-harness", templates)
            core = root / "mobile-ios/TelemetryCore"
            (core / "Sources/Fixture").mkdir(parents=True)
            (core / "Sources/Fixture/Fixture.swift").write_text("// generator-only dependency\n")
            (core / "Package.swift").write_text("// generator-only package identity\n")
            parser = core / "Tests/TelemetryCoreTests/MeasurementReplayIntegrityTests.swift"
            parser.parent.mkdir(parents=True)
            parser.write_text("struct CSVFixture {\n    private func parseCSV(_ value: String) -> [[String]] {\n"
                              "        []\n    }\n}\n")

            def compiler(command, **kwargs):
                package = Path(command[command.index("--package-path") + 1])
                captured["work"] = package.parent
                probe = package / "Sources/Probe"
                captured["model"] = (probe / "RecordingModel.swift").read_text()
                captured["checks"] = (probe / "Checks.swift").read_text()
                captured["appFiles"] = {p.name: p.read_bytes() for p in probe.glob("*.swift")}
                captured["command"] = command
                raise CompilerBoundary()

            try:
                with patch.object(GENERATOR, "ROOT", root), patch.object(GENERATOR, "SOURCE", model), \
                        patch.object(GENERATOR.subprocess, "run", compiler):
                    with self.assertRaises(CompilerBoundary):
                        GENERATOR.diagnostic_recording(Path(directory) / "output")
            finally:
                if "work" in captured:
                    shutil.rmtree(captured["work"])
        return captured

    def test_known_callbacks_keep_bodies_and_only_legacy_observer_seams_are_added(self):
        result = GENERATOR.diagnostic_bindings(source())
        self.assertEqual(len(result), 9)
        for name, body in EXTRA.items():
            self.assertIn(binding(name, body), result)
        for name, body in LEGACY.items():
            emitted = next(value for value in result if f"diagnosticAdapter.{name} =" in value)
            self.assertLess(emitted.index(body), emitted.index("callbackReturned?"))
        self.assertEqual(len(GENERATOR.diagnostic_bindings(source(False))), 3)

    def test_missing_duplicate_unknown_and_unextractable_callbacks_fail_closed(self):
        base = source(False)
        cases = [
            (base + "\n        diagnosticAdapter.onUnexpected={ value in\n        }\n", "Unrecognized"),
            (base + "\n" + binding("onState", "print(state)"), "Duplicate"),
            (binding("onState", "print(state)"), "missing"),
            (base.replace(binding("onResult", LEGACY["onResult"]),
                          "        diagnosticAdapter.onResult = { result in print(result) }"), "shape"),
        ]
        for value, reason in cases:
            with self.subTest(reason=reason), self.assertRaisesRegex(RuntimeError, reason):
                GENERATOR.diagnostic_bindings(value)

    def test_state_dependencies_are_required_and_actual_initializers_are_preserved(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "mobile-ios/App"
            app.mkdir(parents=True)
            with patch.object(GENERATOR, "ROOT", root):
                with self.assertRaisesRegex(RuntimeError, "Missing actual App state"):
                    GENERATOR.recording_state_fields(source())
                for name in ("DiagnosticWorkspaceState", "DiagnosticAuditRecordingState"):
                    (app / (name + ".swift")).write_text("// source fixture\n")
                fields, files = GENERATOR.recording_state_fields(source())
                self.assertEqual(fields, ["    let diagnosticWorkspace = DiagnosticWorkspaceState()",
                                          "    let diagnosticAudit = DiagnosticAuditRecordingState()"])
                self.assertEqual([p.name for p in files],
                                 ["DiagnosticWorkspaceState.swift", "DiagnosticAuditRecordingState.swift"])
                with self.assertRaisesRegex(RuntimeError, "Missing production state declaration"):
                    GENERATOR.recording_state_fields("diagnosticWorkspace.setAcquiring(false)")

    def test_generation_keeps_legacy_checks_and_copies_real_app_files(self):
        legacy = self.generated(False)
        current = self.generated(True)
        for emitted in (legacy, current):
            self.assertIn("one accepted failure is detailed and drained exactly once", emitted["checks"])
            self.assertIn("normal diagnostic row ordering is unchanged", emitted["checks"])
            self.assertIn("CSV seven columns preserve quotes/newlines/Unicode payload", emitted["checks"])
            self.assertIn("rows == beforeLate", emitted["checks"])
            self.assertIn("columns[6] == row.payloadJSON", emitted["checks"])
        self.assertNotIn("DiagnosticWorkspaceState.swift", legacy["appFiles"])
        for name in ("DiagnosticWorkspaceState", "DiagnosticAuditRecordingState"):
            self.assertEqual(current["appFiles"][name + ".swift"],
                             ("final class " + name + " {}\n").encode())
        self.assertIn("let diagnosticWorkspace = DiagnosticWorkspaceState()", current["model"])
        self.assertIn("let diagnosticAudit = DiagnosticAuditRecordingState()", current["model"])
        self.assertEqual(current["command"][current["command"].index("--jobs") + 1], "1")

    def test_generated_checks_preserve_loss_markers_and_check_both_healthy_phases(self):
        checks = self.generated(True)["checks"]
        legacy = re.search(r"(?ms)^    static func legacyMeasurements\b.*?^    }", checks).group(0)
        self.assertNotIn("diagnostic_audit_incomplete", legacy)
        self.assertIn("decode(DiagnosticAuditSystemPayload.self", legacy)
        self.assertIn('!names.contains("diagnostic_audit_incomplete")', checks)
        record = re.search(r"(?ms)^    @MainActor static func recordScenario\b.*?^    }", checks).group(0)
        reopen = re.search(r"(?ms)^    @MainActor static func reopenScenario\b.*?^    }", checks).group(0)
        self.assertIn("verifyNoAuditLossMarker(rows, scenario: scenario)", record)
        self.assertIn("verifyNoAuditLossMarker(loaded.measurements, scenario: scenario)", reopen)
        self.assertNotIn("livePayloads", checks)


if __name__ == "__main__":
    unittest.main()
