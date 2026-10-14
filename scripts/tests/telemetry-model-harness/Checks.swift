import Foundation

@main struct Checks {
    @MainActor static var failures = 0
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: Bool, _ name: String) {
        checks += 1
        print("\(value ? "PASS" : "FAIL"): \(name)")
        if !value { failures += 1 }
    }
    @MainActor static func settle() async {
        for _ in 0..<100 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    @MainActor static func result(_ name: String, _ value: Double, _ time: Double, _ sequence: UInt64) -> OBDQueryResult {
        OBDQueryResult(response: .init(sequence: sequence, receivedAtEpoch: time, responseCANID: 0x7EC),
            signals: [.init(signalID: name, value: value, receivedAtEpoch: time)])
    }
    @MainActor static func main() async {
        // No destination/credential: local samples, MARK and background events
        // must not accumulate in an unused optional upload queue.
        CredentialStore.credential = nil
        let offline = Coordinator()
        let unused = DurableOutbox()
        offline.outbox = unused
        offline.handleLocations([CLLocation(timestamp: Date(timeIntervalSince1970: 100))])
        offline.mark()
        await settle()
        expect(await unused.attempts == 0, "offline collection does not enqueue uploads")
        expect(offline.recorded.count == 2, "offline location and MARK reach local recording")
        expect(offline.lastMarkAt != nil, "offline MARK remains visible")

        let noQueue = Coordinator()
        noQueue.startLocation()
        noQueue.mark()
        expect(noQueue.locationService.starts == 1, "GPS can start without optional upload storage")
        expect(noQueue.lastMarkAt != nil, "MARK does not depend on optional upload storage")
        let localFailure = Coordinator()
        localFailure.storageStatus = "Local disk unavailable"
        localFailure.startLocation()
        expect(localFailure.locationService.starts == 0, "real local failure still blocks start")

        let stoppedGPS = Coordinator()
        stoppedGPS.handleLocations([CLLocation(timestamp: Date(timeIntervalSince1970: 100))])
        let retainedFix = stoppedGPS.lastLocation?.capturedAt
        let retainedTrackCount = stoppedGPS.locationTrack.count
        stoppedGPS.stopLocation()
        let eventsAtStop = stoppedGPS.recorded.count
        stoppedGPS.handleLocations([CLLocation(timestamp: Date(timeIntervalSince1970: 101))])
        expect(!stoppedGPS.collecting && stoppedGPS.locationService.stops == 1,
               "GPS Stop changes collection state before a late callback")
        expect(stoppedGPS.lastLocation?.capturedAt == retainedFix && stoppedGPS.locationTrack.count == retainedTrackCount,
               "late GPS callback after Stop preserves the last fix and track")
        expect(stoppedGPS.recorded.count == eventsAtStop,
               "late GPS callback after Stop cannot append recorded measurements")
        stoppedGPS.collecting = true
        stoppedGPS.localRecordingEnabled = false
        stoppedGPS.handleLocations([CLLocation(timestamp: Date(timeIntervalSince1970: 102))])
        expect(stoppedGPS.lastLocation?.capturedAt == 102 && stoppedGPS.recorded.count == eventsAtStop,
               "GPS presentation can update while recording remains off")

        CredentialStore.credential = "test-only-not-a-real-token"
        let full = Coordinator()
        full.serverText = "https://telemetry.example.invalid"
        let queue = DurableOutbox(capacity: 1)
        full.outbox = queue
        try! await queue.enqueue(.init(type: "GPS", capturedAt: 90))
        full.handleLocations([CLLocation(timestamp: Date(timeIntervalSince1970: 100))])
        await settle()
        expect(await queue.attempts == 1, "legacy configured upload is disabled; prior queue remains")
        expect(full.collecting && full.locationService.stops == 0, "queue saturation cannot stop GPS")
        expect(full.storageStatus == nil, "disabled legacy delivery does not poison local storage")
        full.handleLocations([CLLocation(timestamp: Date(timeIntervalSince1970: 101))])
        expect(full.recorded.count == 2, "next GPS sample still reaches local recording after queue failure")
        expect(try! await queue.count() == 1, "previous queued data is not deleted")
        await settle()

        let unreadable = Coordinator()
        let badQueue = DurableOutbox()
        unreadable.outbox = badQueue
        unreadable.queueDepth = 9
        await badQueue.failCount()
        await unreadable.refreshQueueDepth()
        expect(unreadable.storageStatus == nil && unreadable.queueDepth == 9, "queue count error does not poison local storage or invent zero")

        let uploadOpenFailure = Coordinator()
        uploadOpenFailure.configureOptionalUpload(at: URL(fileURLWithPath: "/upload-failure"))
        expect(uploadOpenFailure.storageStatus == nil && uploadOpenFailure.localRecordingEnabled,
               "optional upload setup failure cannot poison local recorder state")
        uploadOpenFailure.startLocation()
        expect(uploadOpenFailure.locationService.starts == 1, "GPS remains startable after upload setup failure")
        expect(uploadOpenFailure.uploadStatus != "Not paired", "optional upload setup failure is visible")

        let model = Coordinator()
        model.handleDiagnosticResult(result("soc", 50.5, 100, 1))
        model.handleDiagnosticResult(result("rpm", 900, 101, 2))
        expect(model.frame?.sig == ["soc": 50.5, "rpm": 900], "alternating diagnostic queries retain both latest values")
        expect(model.localSignalReceivedAt["soc"] == 100 && model.localSignalReceivedAt["rpm"] == 101,
               "retained SOC timestamp is not refreshed by RPM")
        expect(model.points.count == 2 && model.points.last?.signals == ["rpm": 900], "chart appends only actual callback samples")
        expect(model.recorded.count == 4, "recording contains only original response/signal pairs")
        expect(model.conditionInputs.last == ["rpm": 900], "retained SOC does not retrigger a condition")

        model.stopDemoAdapter()
        model.handleDiagnosticResult(result("rpm", 800, 102, 1))
        expect(model.frame?.sig == ["rpm": 800] && model.localSignalReceivedAt["soc"] == nil,
               "new acquisition does not inherit old session signals")

        let raw = Coordinator()
        raw.applyLocalSignals(CANFrame(receivedAtEpoch: 200), values: ["fl": 0], source: "Adapter")
        raw.applyLocalSignals(CANFrame(receivedAtEpoch: 201, sequence: 2), values: ["fr": 1], source: "Adapter")
        expect(raw.frame?.sig == ["fl": 0, "fr": 1], "alternating raw CAN IDs retain genuine zero")
        raw.applyLocalDiagnosticSignals(values: ["soc": 50], rawValues: [:], source: "Diagnostic",
            sequence: 3, timestamp: 202, responseCANID: 0x7EC)
        expect(raw.frame?.sig == ["soc": 50], "diagnostic snapshot cannot inherit raw source values")
        let replay = Coordinator()
        replay.collecting = false
        replay.runMode = .replay
        replay.startLocation()
        replay.mark()
        expect(!replay.collecting, "Replay cannot start GPS collection")
        expect(replay.locationService.starts == 0, "Replay does not request native location acquisition")
        expect(replay.recorded.isEmpty, "Replay MARK cannot add recorded events")
        // These checks fail if stopping a non-recording Demo clears the values
        // but leaves DEMO selected, or resets the mode while a session is active.
        let preview = Coordinator()
        preview.runMode = .demo
        preview.localRecordingEnabled = false
        preview.collecting = false
        preview.adapterStatus = "Demo adapter monitoring"
        preview.adapterSignalValue = 100
        preview.rawCANText = "0x123  01"
        preview.applyLocalSignals(CANFrame(receivedAtEpoch: 300), values: ["demo.signal": 100], source: "Demo")
        preview.stopDemoAdapter()
        expect(preview.runMode == .live, "stopping an idle Demo returns to LIVE without a profile")
        expect(preview.adapterStatus == "Adapter disconnected" && preview.canSource == "None",
               "Demo Stop presents LIVE as disconnected")
        expect(preview.frame == nil && preview.points.isEmpty && preview.rawCANText == "-" && preview.adapterSignalValue == nil,
               "Demo Stop clears synthetic presentation")
        expect(!preview.localRecordingEnabled && !preview.collecting && preview.recorded.isEmpty && preview.locationService.starts == 0,
               "Demo Stop does not start recording or GPS")
        expect(preview.demoAdapter.starts == 0 && preview.liveAdapter.starts == 0 && preview.diagnosticAdapter.starts == 0,
               "Demo Stop does not start any adapter")
        preview.stopDemoAdapter()
        expect(preview.runMode == .live && preview.recorded.isEmpty && preview.locationService.starts == 0,
               "repeated Demo Stop remains disconnected and inactive")

        let stopLive = Coordinator()
        stopLive.runMode = .demo
        stopLive.localRecordingEnabled = false
        stopLive.collecting = false
        stopLive.stopLiveAdapter()
        expect(stopLive.runMode == .live && stopLive.canSource == "None",
               "Stop live alias also leaves an idle Demo in LIVE")

        // Each pending recording boundary independently blocks a mode change.
        for boundary in ["enabled", "recorder", "queue", "closing"] {
            let retained = Coordinator()
            retained.runMode = .demo
            retained.localRecordingEnabled = boundary == "enabled"
            let recorder = RecorderBoundary(), queue = WriteQueueBoundary()
            if boundary == "recorder" { retained.localRecorder = recorder }
            if boundary == "queue" { retained.recordingWriteQueue = queue }
            retained.recordingClosing = boundary == "closing"
            retained.stopDemoAdapter()
            expect(retained.runMode == .demo, "Demo Stop retains session mode while \(boundary) is pending")
            expect(retained.localRecordingEnabled == (boundary == "enabled")
                && retained.recordingClosing == (boundary == "closing")
                && (boundary != "recorder" || retained.localRecorder === recorder)
                && (boundary != "queue" || retained.recordingWriteQueue === queue),
                "Demo Stop preserves the \(boundary) recording boundary")
        }

        let stoppedReplay = Coordinator()
        stoppedReplay.runMode = .replay
        stoppedReplay.localRecordingEnabled = false
        stoppedReplay.collecting = false
        stoppedReplay.stopDemoAdapter()
        expect(stoppedReplay.runMode == .replay, "Demo Stop never selects LIVE over Replay")

        print("APP COORDINATOR SOURCE HARNESS: \(checks) assertions, \(failures) failures (not UIKit/device evidence)")
        if failures > 0 { exit(1) }
    }
}
