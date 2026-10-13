"""Run exact app methods/label expressions on macOS, without app/device launch.

This tests model logic and localization only. SwiftUI rendering, CoreBluetooth
callbacks and persistence I/O remain outside this probe's verification scope.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess


def declaration(source, marker):
    start = source.index(marker)
    opening = source.index("{", start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    return source[start:end]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("root", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root, output = args.root, args.output
    output.mkdir(parents=True, exist_ok=False)
    app = root / "mobile-ios/App"
    model = (app / "TelemetryModel.swift").read_text()
    view = (app / "DashboardView.swift").read_text()
    ble = (app / "BLEDiscoveryController.swift").read_text()
    steps = []
    for number in ("1", "2"):
        block = view[view.index('number: "' + number + '"'):]
        title = re.search(r"title: (.+),\n", block).group(1)
        detail = re.search(r"detail: (.+),\n", block).group(1)
        steps.append((title, detail))
    accessibility = re.search(r"\.accessibilityLabel\((.+)\)\n", view[view.index("private func setupStep"):]).group(1)
    snap = "\n".join(declaration(model, marker) for marker in (
        "func snapDashboard(", "func undoDashboardLayout()", "func redoDashboardLayout()"))
    labels = "\n".join(
        'func step' + str(index) + '(model: Model) -> (String, String) {\n'
        + 'let title = ' + title + '\nlet detail = ' + detail
        + '\nreturn (AppLocalization.text(title), ' + accessibility + ')\n}'
        for index, (title, detail) in enumerate(steps)
    )
    swift = r'''
import Foundation

class Model {
    var dashboardProfile: DashboardProfile?
    var dashboardLayoutHistory = DashboardLayoutHistory()
    var saves = 0
    var localRecordingEnabled = false
    var collecting = false
    var localRecordingStatus = "Recording"
    var locationStatus = "Location ready"
    func persistDashboardProfile() { saves += 1 }
    MODEL_METHODS
}
enum PeripheralState { case connected, connecting, disconnecting, disconnected }
class Peripheral {
    let identifier = UUID()
    var state: PeripheralState
    init(_ state: PeripheralState) { self.state = state }
}
class Central {
    var cancelled: Set<UUID> = []
    func stopScan() {}
    func cancelPeripheralConnection(_ peripheral: Peripheral) { cancelled.insert(peripheral.identifier) }
}
class Inspector {
    struct Activity { var scanning = false }
    var scanning = false
    var activity = Activity()
    var central: Central? = Central()
    var peripherals: [UUID: Peripheral] = [:]
    var inspectionPeripherals: [UUID: Peripheral] = [:]
    func publish(_ status: String) {}
    STOP_METHOD
}

@main struct Probe {
    @MainActor static func main() throws {
        var results: [[String: Any]] = []
        func check(_ condition: Bool, _ name: String) {
            results.append(["name": name, "passed": condition])
        }
        func fixture(_ rects: [DashboardRect]) throws -> DashboardProfile {
            try .init(id: "test-profile", name: "Synthetic", pages: [
                .init(id: "page", name: "Main", orientation: .portrait, widgets:
                    rects.enumerated().map { index, rect in
                        .init(id: "w\(index)", type: .numericGauge, signalID: nil,
                              rect: rect, zIndex: index,
                              configuration: .init(label: "Test", unit: "", decimals: 0,
                                minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil))
                    })])
        }
        let model = Model()
        let cells = try fixture([.init(x: 0, y: 0, width: 2, height: 1),
                                 .init(x: 2, y: 0, width: 2, height: 1),
                                 .init(x: 0, y: 2, width: 6, height: 3)])
        model.dashboardProfile = cells
        model.snapDashboard(pageID: "page")
        check(model.dashboardProfile == cells, "default_snap_preserves_cell_rects")
        check(model.saves == 0, "no_op_snap_does_not_persist")
        let odd = try fixture([.init(x: 1, y: 3, width: 3, height: 3),
                               .init(x: 5, y: 1, width: 3, height: 3)])
        model.dashboardProfile = odd
        model.snapDashboard(pageID: "page", grid: 2)
        let snapped = model.dashboardProfile
        check(snapped?.pages[0].widgets.map(\.rect) == [
            .init(x: 2, y: 4, width: 4, height: 4),
            .init(x: 6, y: 2, width: 4, height: 4)], "explicit_grid_snaps_all_widgets")
        model.undoDashboardLayout()
        check(model.dashboardProfile == odd, "one_undo_restores_entire_snap")
        model.snapDashboard(pageID: "page")
        model.redoDashboardLayout()
        check(model.dashboardProfile == snapped, "no_op_preserves_redo")

        LABEL_METHODS
        let korean = AppLanguageStore.shared.language == .korean
        for enabled in [false, true] {
            model.localRecordingEnabled = enabled
            model.collecting = enabled
            let recording = step0(model: model)
            let gps = step1(model: model)
            let wantRecording = korean ? (enabled ? "기록 중지" : "기록 시작")
                                       : (enabled ? "Stop recording" : "Start recording")
            let wantGPS = korean ? (enabled ? "GPS 중지" : "GPS 시작")
                                 : (enabled ? "Stop GPS" : "Start GPS")
            check(recording.0 == wantRecording, "recording_title_\(enabled)")
            check(recording.1.hasPrefix(wantRecording + ", "), "recording_accessibility_\(enabled)")
            check(gps.0 == wantGPS, "gps_title_\(enabled)")
            check(gps.1.hasPrefix(wantGPS + ", "), "gps_accessibility_\(enabled)")
        }
        let inspector = Inspector()
        let old = Peripheral(.connected)
        inspector.inspectionPeripherals[old.identifier] = old
        inspector.stop()
        check(inspector.central?.cancelled == [old.identifier], "rescan_stop_cancels_retained_inspection")
        let pending = Peripheral(.connecting)
        inspector.peripherals[pending.identifier] = pending
        inspector.inspectionPeripherals[pending.identifier] = pending
        inspector.stop()
        check(inspector.central?.cancelled == [old.identifier, pending.identifier], "stop_cancels_pending_connection")
        print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]), encoding: .utf8)!)
        if results.contains(where: { $0["passed"] as? Bool == false }) { exit(1) }
    }
}
'''.replace("MODEL_METHODS", snap).replace("STOP_METHOD", declaration(ble, "func stop()"))
    swift = swift.replace("LABEL_METHODS", labels)
    (output / "Probe.swift").write_text(swift)
    bundle = output / "LogicProbe.app"
    executable = bundle / "Contents/MacOS/LogicProbe"
    executable.parent.mkdir(parents=True)
    resources = bundle / "Contents/Resources"
    resources.mkdir()
    for name in ["en.lproj", "ko.lproj", "AppStringTemplates.json"]:
        source = app / "Resources" / name
        if source.is_dir(): shutil.copytree(source, resources / name)
        else: shutil.copy2(source, resources / name)
    import plistlib
    (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "local.webdashboard.SyntheticLogicProbe", "CFBundleExecutable": "LogicProbe",
        "CFBundlePackageType": "APPL", "CFBundleDevelopmentRegion": "en"}))
    sources = [root / "mobile-ios/TelemetryCore/Sources/TelemetryCore" / name
               for name in ["DashboardModel.swift", "DashboardLayoutHistory.swift"]]
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
               CLANG_MODULE_CACHE_PATH=str(output / "clang-cache"))
    command = ["/usr/bin/swiftc", "-parse-as-library", *map(str, sources),
               str(app / "AppLocalization.swift"), str(output / "Probe.swift"), "-o", str(executable)]
    compile_result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=120)
    (output / "compile.log").write_text(compile_result.stdout + compile_result.stderr)
    if compile_result.returncode:
        print(compile_result.stderr); raise SystemExit(compile_result.returncode)
    failed = False
    for language in ["en", "ko"]:
        run = subprocess.run([str(executable), "--app-language", language], env=env,
                             capture_output=True, text=True, timeout=15)
        (output / (language + ".json")).write_text(run.stdout)
        (output / (language + ".stderr")).write_text(run.stderr)
        print(language, "exit", run.returncode, run.stdout)
        failed |= run.returncode != 0
    raise SystemExit(1 if failed else 0)


if __name__ == "__main__":
    main()
