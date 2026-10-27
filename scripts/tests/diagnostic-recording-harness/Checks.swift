import Foundation
import TelemetryCore

@main struct DiagnosticRecordingChecks {
    @MainActor static var checks = 0
    @MainActor static var failures = 0
    static let queryID = "query,:\"quoted\"\n진단🚗:05"
    static let detailedName = "diagnostic_query_failed:query,:\"quoted\"\n진단🚗:05:no_data"
    @MainActor static func expect(_ condition: Bool, _ name: String) {
        checks += 1
        if !condition { failures += 1 }
        print("\(condition ? "PASS" : "FAIL"): \(name)")
    }
    static func namedEvents(_ rows: [PersistedMeasurement]) throws -> [String] {
        struct Payload: Decodable { let name: String }
        return try rows.filter { $0.kind == "SYSTEM" }.map {
            try JSONDecoder().decode(Payload.self, from: Data($0.payloadJSON.utf8)).name
        }
    }
    static func query(_ original: OBDQueryDefinition, id: String? = nil) throws -> OBDQueryDefinition {
        try OBDQueryDefinition(id: id ?? original.id, name: original.name,
            requestCANID: original.requestCANID, responseCANID: original.responseCANID,
            isExtended: original.isExtended, service: original.service, command: original.command,
            pollInterval: 0.000_001, timeout: 1, flowControl: original.flowControl,
            sourceRepository: original.sourceRepository, sourcePath: original.sourcePath,
            sourceCommit: original.sourceCommit, signals: original.signals)
    }

    @MainActor static func recordScenario(_ scenario: String, root: URL) async throws {
        let path = root.appendingPathComponent(scenario + ".sqlite")
        let catalog = try SantaFeMX5HybridQueryCatalog.initialQueries()
        let queries = try scenario == "skip-and-success"
            ? [query(catalog[0]), query(catalog[2]), query(catalog[4])]
            : [query(catalog[2], id: queryID)]
        let profile = try AdapterProfile(id: "synthetic", name: "Synthetic diagnostic fixture", transport: .wifi,
            peripheralID: nil, serviceUUID: nil, writeCharacteristicUUID: nil, notifyCharacteristicUUID: nil,
            host: "127.0.0.1", port: 35000, signals: [], diagnosticQueries: queries)
        let transport = DiagnosticTransport()
        LiveAdapterController.transport = transport
        let model = RecordingModel(path: path)
        let finished = AsyncStream<Void>.makeStream()
        var stopped = false
        var failureCallbacks = 0
        let displayedFailure = "Diagnostic \(queryID): no data"
        model.projectionReturned = {
            if stopped && !model.recordingClosing && model.completedRecorder != nil {
                finished.continuation.yield(()); finished.continuation.finish()
            }
        }
        model.callbackReturned = { kind, value in
            if value == "Diagnostic query monitoring" && kind == "state" {
                model.startRecording()
                if scenario == "recording-off" { model.localRecordingEnabled = false }
                if scenario == "replay" { model.runMode = .replay; model.adapterStatus = "REPLAY sentinel" }
            }
            if kind == "failure" { failureCallbacks += 1 }
            let complete = scenario == "skip-and-success"
                ? kind == "result" && value == catalog[4].id : value == displayedFailure
            guard complete, !stopped else { return }
            if scenario == "replay" { expect(model.adapterStatus == "REPLAY sentinel", "Replay ignores diagnostic presentation") }
            else if scenario != "skip-and-success" { expect(model.adapterStatus == displayedFailure, "diagnostic display wording is preserved") }
            // No await/yield between the real callback's queue admission and Stop.
            stopped = true
            model.stopRecording()
            model.diagnosticAdapter.stop()
        }
        model.diagnosticAdapter.start(profile: profile)
        try await waitFor(finished.stream)
        try await waitFor(await transport.closeEvents())
        guard let recorder = model.completedRecorder else { throw ProbeError.deadline }
        let beforeLate = try await recorder.export()
        let originalFailureCallbacks = failureCallbacks
        await transport.pushLateReply()
        model.diagnosticAdapter.onQueryFailure?(
            DiagnosticQueryFailure(queryID: "late,:\"다른 ID\"\n🚗", error: .timeout), "Diagnostic late: timeout")
        expect(failureCallbacks == originalFailureCallbacks + 1, "typed late failure reaches the actual callback after drain")
        let rows = try await recorder.export()
        expect(rows == beforeLate, "late callback after Stop cannot append a row")
        let names = try namedEvents(rows)
        if scenario == "failure-immediate" {
            expect(names == ["recording_started", detailedName, "recording_stopped"], "one accepted failure is detailed and drained exactly once")
            expect(names.filter { $0 == detailedName }.count == 1, "query punctuation and Unicode remain intact")
            expect(!names.contains("adapter_error"), "query failure does not also record a generic error")
        } else {
            expect(names == ["recording_started", "recording_stopped"], "\(scenario) adds no diagnostic failure event")
        }
        if scenario == "skip-and-success" {
            expect(originalFailureCallbacks == 0, "bitmap-skipped PID emits no App failure callback")
            expect(await transport.writes().filter { $0 == "0105\r" }.isEmpty, "bitmap-skipped PID sends no request")
            expect(rows.map(\.kind) == ["SYSTEM", "DIAGNOSTIC_RESPONSE", "DIAGNOSTIC_SIGNAL", "DIAGNOSTIC_RESPONSE", "DIAGNOSTIC_SIGNAL", "SYSTEM"], "normal diagnostic row ordering is unchanged")
            let signals = try rows.filter { $0.kind == "DIAGNOSTIC_SIGNAL" }.map {
                try JSONDecoder().decode(DecodedOBDSignal.self, from: Data($0.payloadJSON.utf8))
            }
            expect(signals.last?.value == 50 && model.renderedSignals["SANTAFEHYB_HVBAT_SOC"] == 50, "supported diagnostic signal stays 50 percent")
        } else {
            expect(originalFailureCallbacks == 1, "one query failure reaches the actual App callback")
        }
        try await recorder.exportSessionJSON().write(to: root.appendingPathComponent(scenario + ".json"))
        model.callbackReturned = nil; model.projectionReturned = nil
        model.completedRecorder = nil
        LiveAdapterController.transport = nil
    }

    @MainActor static func reopenScenario(_ scenario: String, root: URL) async throws {
        // A separate invocation starts only after the writer process exited,
        // so every original SQLite handle is closed before this new connection.
        let expected = try JSONDecoder().decode(MeasurementExport.self,
            from: Data(contentsOf: root.appendingPathComponent(scenario + ".json")))
        let archive = try MeasurementArchive(path: root.appendingPathComponent(scenario + ".sqlite"))
        let loaded = try await archive.load(sessionID: expected.session.sessionID)
        expect(loaded == expected, "\(scenario) rows and session survive SQLite close/reopen")
        let json = try await archive.exportJSON(sessionID: expected.session.sessionID)
        expect(try JSONDecoder().decode(MeasurementExport.self, from: json) == expected, "\(scenario) JSON retains exact row identity/order")
        let cells = parseCSV(String(decoding: try await archive.exportCSV(sessionID: expected.session.sessionID), as: UTF8.self))
        expect(cells.count == loaded.measurements.count + 1, "\(scenario) CSV retains every original row")
        var exact = true
        for (row, columns) in zip(loaded.measurements, cells.dropFirst()) {
            exact = exact && columns.count == 7
            if columns.count == 7 {
                exact = exact && Int64(columns[0]) == row.sequence && columns[1] == row.sessionID
                    && columns[2] == row.kind && Double(columns[3]) == row.sourceTimestamp
                    && Double(columns[4]) == row.receivedAtEpoch && UInt64(columns[5]) == row.receivedAtMonotonicNanos
                    && columns[6] == row.payloadJSON
            }
        }
        expect(exact, "\(scenario) CSV seven columns preserve quotes/newlines/Unicode payload")
        if scenario == "failure-immediate" {
            expect(try namedEvents(loaded.measurements) == ["recording_started", detailedName, "recording_stopped"], "reopened SYSTEM keeps detailed failure identity")
        }
        let timeline = try await MeasurementReplay.timeline(loaded)
        expect(timeline.measurementCount == loaded.measurements.count, "\(scenario) Replay accepts each SYSTEM/diagnostic row")
        try await MeasurementReplay.replay(json, into: TelemetryStore())
        expect(try await archive.load(sessionID: expected.session.sessionID) == loaded, "\(scenario) Replay leaves durable rows unchanged")
    }

    @MainActor static func main() async {
        do {
            let root = URL(fileURLWithPath: CommandLine.arguments[2])
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            for scenario in ["failure-immediate", "recording-off", "replay", "skip-and-success"] {
                if CommandLine.arguments[1] == "reopen" { try await reopenScenario(scenario, root: root) }
                else { try await recordScenario(scenario, root: root) }
            }
        } catch { failures += 1; print("FAIL: unexpected probe error \(error)") }
        print("DIAGNOSTIC APP/CORE SOURCE HARNESS: \(checks) assertions, \(failures) failures; \(CommandLine.arguments[1]); no device/UI/network")
        if failures > 0 { exit(1) }
    }
}

// CSV_PARSER
