"""Run exact app methods/label expressions on macOS, without app/device launch.

This tests model logic, LocationService control flow and Help localization.
Location/Bluetooth managers are explicit test doubles; no native service runs.
SwiftUI rendering, OS callback delivery and persistence I/O remain unverified.
"""
import argparse
import hashlib
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
    location = (app / "LocationService.swift").read_text()
    help_view = (app / "AppHelpView.swift").read_text()
    # Compile the complete service against an explicit fake CoreLocation boundary.
    # Only the framework import is removed; production method bodies stay intact.
    (output / "LocationService.swift").write_text(location.replace("import CoreLocation\n", "import Foundation\n", 1))
    help_types = "\n".join(declaration(help_view, marker) for marker in (
        "@MainActor struct HelpCopy", "struct HelpStep", "@MainActor struct HelpGuide"))
    help_image_name = declaration(help_view, "private var imageName:")
    image_label = re.search(r"\.accessibilityLabel\((guide\.title\.text.+)\)\n", help_view).group(1)
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
    var cancelled: [UUID] = []
    func stopScan() {}
    func cancelPeripheralConnection(_ peripheral: Peripheral) { cancelled.append(peripheral.identifier) }
}
typealias CBCentralManager = Central
typealias CBPeripheral = Peripheral
class Inspector {
    struct Activity { var scanning = false }
    var scanning = false
    var activity = Activity()
    var central: Central? = Central()
    var peripherals: [UUID: Peripheral] = [:]
    var inspectionPeripherals: [UUID: Peripheral] = [:]
    struct Device { var state = "observed" }
    var devices: [UUID: Device] = [:]
    func update(_ id: UUID, _ change: (inout Device) -> Void) {
        guard var device = devices[id] else { return }
        change(&device); devices[id] = device
    }
    func publish(_ status: String) {}
    STOP_METHOD
    BLE_TERMINAL_CALLBACKS
}

// CoreLocation boundary doubles: no CoreLocation framework is linked or called.
enum CLAuthorizationStatus { case notDetermined, authorizedWhenInUse, authorizedAlways, denied, restricted }
struct CLLocation {}
protocol CLLocationManagerDelegate: AnyObject {}
let kCLLocationAccuracyBestForNavigation = 1.0
let kCLDistanceFilterNone = 0.0
@MainActor final class CLLocationManager: NSObject {
    static var lastCreated: CLLocationManager?
    weak var delegate: CLLocationManagerDelegate?
    var authorizationStatus = CLAuthorizationStatus.notDetermined
    enum Activity { case automotiveNavigation }
    var activityType = Activity.automotiveNavigation
    var desiredAccuracy = 0.0; var distanceFilter = 0.0
    var pausesLocationUpdatesAutomatically = true
    var allowsBackgroundLocationUpdates = false; var showsBackgroundLocationIndicator = false
    var whenInUseRequests = 0; var alwaysRequests = 0; var starts = 0; var stops = 0
    override init() { super.init(); Self.lastCreated = self }
    func requestWhenInUseAuthorization() { whenInUseRequests += 1 }
    func requestAlwaysAuthorization() { alwaysRequests += 1 }
    func startUpdatingLocation() { starts += 1 }
    func stopUpdatingLocation() { stops += 1 }
}
HELP_TYPES
@MainActor struct HelpPresentation {
    let guide: HelpGuide
    let stepIndex: Int
    HELP_IMAGE_NAME
    var name: String { imageName }
    func imageLabel() -> String {
        let name = imageName
        return HELP_IMAGE_LABEL
    }
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
        inspector.central?.cancelled = []
        inspector.stop()
        let cancellations = inspector.central?.cancelled ?? []
        check(Set(cancellations) == [old.identifier, pending.identifier], "stop_cancels_pending_connection")
        check(cancellations.count == 2, "stop_cancels_duplicate_reference_only_once")
        check(inspector.inspectionPeripherals.count == 2, "stop_retains_inspections_until_terminal_callback")
        inspector.devices[old.identifier] = .init()
        inspector.devices[pending.identifier] = .init()
        inspector.centralManager(inspector.central!, didFailToConnect: pending, error: nil)
        check(inspector.inspectionPeripherals[pending.identifier] == nil &&
              inspector.inspectionPeripherals[old.identifier] != nil,
              "failed_connection_releases_only_its_inspection")
        inspector.centralManager(inspector.central!, didDisconnectPeripheral: old, error: nil)
        check(inspector.inspectionPeripherals.isEmpty && inspector.devices[old.identifier]?.state == "disconnected",
              "disconnect_callback_releases_retained_inspection")
        let inactive = Inspector()
        let disconnected = Peripheral(.disconnected), disconnecting = Peripheral(.disconnecting)
        inactive.peripherals[disconnected.identifier] = disconnected
        inactive.inspectionPeripherals[disconnecting.identifier] = disconnecting
        inactive.stop()
        check(inactive.central?.cancelled.isEmpty == true, "stop_does_not_recancel_inactive_connections")

        let service = LocationService()
        let manager = CLLocationManager.lastCreated!
        var collectingChanges: [Bool] = [], statuses: [String] = []
        service.onCollectingChanged = { collectingChanges.append($0) }
        service.onStatus = { statuses.append($0) }
        check(manager.starts == 0 && manager.whenInUseRequests == 0, "gps_init_does_not_acquire_or_request_permission")
        service.start()
        check(manager.whenInUseRequests == 1 && !service.isCollecting && manager.starts == 0,
              "gps_pending_permission_does_not_claim_collection")
        service.stop()
        manager.authorizationStatus = .authorizedWhenInUse
        service.locationManagerDidChangeAuthorization(manager)
        check(manager.starts == 0 && !service.isCollecting, "gps_stop_cancels_pending_authorization_intent")
        service.start()
        check(service.isCollecting && manager.starts == 1 && manager.alwaysRequests == 1,
              "gps_when_in_use_collects_before_always_choice")
        service.locationManagerDidChangeAuthorization(manager)
        check(manager.alwaysRequests == 1, "gps_always_upgrade_requested_once")
        service.stop()
        manager.authorizationStatus = .authorizedAlways
        let startsAtStop = manager.starts
        service.locationManagerDidChangeAuthorization(manager)
        check(manager.starts == startsAtStop && !service.isCollecting && statuses.last == "Stopped",
              "gps_late_always_callback_does_not_restart_after_stop")
        service.start()
        check(service.isCollecting && manager.starts == startsAtStop + 1,
              "gps_explicit_restart_after_stop_is_allowed")
        manager.authorizationStatus = .denied
        service.locationManagerDidChangeAuthorization(manager)
        check(!service.isCollecting && collectingChanges.last == false && statuses.last == "Location permission denied",
              "gps_revoked_permission_clears_collection_state")
        manager.authorizationStatus = .authorizedAlways
        let startsAtDenial = manager.starts
        service.locationManagerDidChangeAuthorization(manager)
        check(manager.starts == startsAtDenial && !service.isCollecting,
              "gps_later_authorization_does_not_restart_denied_intent")
        for denied in [CLAuthorizationStatus.denied, .restricted] {
            let blocked = LocationService(), blockedManager = CLLocationManager.lastCreated!
            blockedManager.authorizationStatus = denied
            blocked.start()
            check(!blocked.isCollecting && blockedManager.starts == 0 && blockedManager.whenInUseRequests == 0,
                  "gps_blocked_authorization_\(denied)")
        }
        let guides = HelpGuide.all
        check(guides.map(\.id) == ["setup", "live", "signals", "sessions", "replay", "editor"], "help_guide_identity_order")
        check(guides.map { $0.steps.count } == [2, 3, 2, 3, 2, 2], "help_fourteen_steps_define_twenty_eight_language_images")
        check(Set(guides.flatMap { $0.steps.map(\.id) }).count == 14, "help_steps_have_unique_control_identifiers")
        for guide in guides {
            check(guide.steps.map(\.number) == Array(1...guide.steps.count), "help_numbering_\(guide.id)")
            let copies = [guide.title, guide.overview] + guide.steps.flatMap { [$0.action, $0.result, $0.recovery] }
            check(copies.allSatisfy { !$0.en.isEmpty && !$0.ko.isEmpty && $0.en != $0.ko &&
                $0.text == (korean ? $0.ko : $0.en) }, "help_effective_language_copy_\(guide.id)")
            for (index, step) in guide.steps.enumerated() {
                let presentation = HelpPresentation(guide: guide, stepIndex: index)
                check(presentation.name == "Help-\(guide.id)-\(korean ? "ko" : "en")-\(index + 1)",
                      "help_asset_name_\(guide.id)_\(index + 1)")
                check(presentation.imageLabel() == guide.title.text + ". \(step.number). " + step.action.text,
                      "help_image_accessibility_copy_\(guide.id)_\(index + 1)")
            }
        }
        print(String(data: try JSONSerialization.data(withJSONObject: results, options: [.prettyPrinted]), encoding: .utf8)!)
        if results.contains(where: { $0["passed"] as? Bool == false }) { exit(1) }
    }
}
'''.replace("MODEL_METHODS", snap).replace("STOP_METHOD", declaration(ble, "func stop()"))
    swift = swift.replace("LABEL_METHODS", labels)
    swift = swift.replace("BLE_TERMINAL_CALLBACKS", "\n".join(declaration(ble, marker) for marker in (
        "func centralManager(_ central: CBCentralManager,\n                        didFailToConnect",
        "func centralManager(_ central: CBCentralManager,\n                        didDisconnectPeripheral")))
    swift = swift.replace("HELP_TYPES", help_types).replace("HELP_IMAGE_NAME", help_image_name).replace("HELP_IMAGE_LABEL", image_label)
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
    tracked = sources + [app / name for name in ["AppLocalization.swift", "TelemetryModel.swift",
                         "DashboardView.swift", "BLEDiscoveryController.swift", "LocationService.swift", "AppHelpView.swift"]]
    tracked += sorted((app / "Resources").rglob("Localizable.strings")) + [app / "Resources/AppStringTemplates.json"]
    (output / "source.json").write_text(json.dumps({str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                                                for p in tracked}, indent=2) + "\n")
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"),
               CLANG_MODULE_CACHE_PATH=str(output / "clang-cache"))
    command = ["/usr/bin/swiftc", "-parse-as-library", *map(str, sources),
                str(app / "AppLocalization.swift"), str(output / "LocationService.swift"),
                str(output / "Probe.swift"), "-o", str(executable)]
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
