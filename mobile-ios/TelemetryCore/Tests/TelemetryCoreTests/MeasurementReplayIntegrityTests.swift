import Foundation
import XCTest
@testable import TelemetryCore

final class MeasurementReplayIntegrityTests: XCTestCase {
    private func signalRow(sequence: Int64 = 1, session: String = "session", id: String = "soc",
                           value: Double = 50.5, timestamp: Double = 100.125) throws -> PersistedMeasurement {
        let sample = DecodedSignalSample(signalID: id, value: value, rawValue: 101,
            enumName: nil, unit: "percent", frameSequence: 7, receivedAtEpoch: timestamp,
            receivedAtMonotonicNanos: 9_876_543_210, source: .diagnostic)
        return PersistedMeasurement(sequence: sequence, sessionID: session, kind: "SIGNAL",
            sourceTimestamp: timestamp, receivedAtEpoch: timestamp,
            receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos,
            payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
    }

    private func envelope(_ rows: [PersistedMeasurement], mode: TelemetryRunMode = .live) -> MeasurementExport {
        MeasurementExport(session: .init(sessionID: "session", startedAt: 90, endedAt: 110, mode: mode),
                          measurements: rows)
    }

    private func assertRejected(_ data: Data, store: TelemetryStore,
                                file: StaticString = #filePath, line: UInt = #line) async {
        do {
            try await MeasurementReplay.replay(data, into: store)
            XCTFail("Invalid export was accepted", file: file, line: line)
        } catch {
            XCTAssertTrue(error is MeasurementReplayError, "Unexpected error: \(error)", file: file, line: line)
        }
    }

    func testMalformedTrailingRowDoesNotPartiallyReplaceStore() async throws {
        let store = TelemetryStore()
        let original = DecodedSignalSample(signalID: "soc", value: 12, rawValue: 24, enumName: nil,
            unit: "percent", frameSequence: 1, receivedAtEpoch: 80,
            receivedAtMonotonicNanos: 80, source: .diagnostic)
        await store.ingest(signal: original)
        let bad = PersistedMeasurement(sequence: 2, sessionID: "session", kind: "LOCATION",
            sourceTimestamp: 101, receivedAtEpoch: 101, receivedAtMonotonicNanos: 101,
            payloadJSON: "{broken")
        await assertRejected(try JSONEncoder().encode(envelope([try signalRow(), bad])), store: store)
        let state = await store.signalState(for: "soc", now: 100)
        XCTAssertEqual(state?.value, 12, "A failed import must leave the original state untouched")
    }

    func testUnsupportedTrailingKindDoesNotPartiallyPopulateStore() async throws {
        let store = TelemetryStore()
        let bad = PersistedMeasurement(sequence: 2, sessionID: "session", kind: "FUTURE_KIND",
            sourceTimestamp: 101, receivedAtEpoch: 101, receivedAtMonotonicNanos: 101, payloadJSON: "{}")
        await assertRejected(try JSONEncoder().encode(envelope([try signalRow(), bad])), store: store)
        let state = await store.signalState(for: "soc", now: 100)
        XCTAssertNil(state)
    }

    func testUnsupportedSchemaIsRejectedBeforeAnyMutation() async throws {
        let store = TelemetryStore()
        let data = try JSONEncoder().encode(envelope([try signalRow()]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["schemaVersion"] = 999
        await assertRejected(try JSONSerialization.data(withJSONObject: json), store: store)
        let state = await store.signalState(for: "soc", now: 100)
        XCTAssertNil(state)
    }

    func testLegacyArrayRejectsMixedSessionsBeforeAnyMutation() async throws {
        let store = TelemetryStore()
        let rows = [try signalRow(), try signalRow(sequence: 2, session: "another-session")]
        await assertRejected(try JSONEncoder().encode(rows), store: store)
        let state = await store.signalState(for: "soc", now: 100)
        XCTAssertNil(state)
    }

    func testDuplicateSequencesAreRejected() async throws {
        let store = TelemetryStore()
        await assertRejected(try JSONEncoder().encode(envelope([
            try signalRow(value: 1), try signalRow(value: 2)
        ])), store: store)
        let state = await store.signalState(for: "soc", now: 100)
        XCTAssertNil(state)
    }

    func testReplayUsesPersistedSequenceNotInputArrayOrWallClockOrder() async throws {
        let store = TelemetryStore()
        // The wall clock moved backwards; SQLite sequence remains the replay order.
        let first = try signalRow(sequence: 1, value: 10, timestamp: 102)
        let second = try signalRow(sequence: 2, value: 20, timestamp: 101)
        try await MeasurementReplay.replay(envelope([second, first]), into: store)
        let state = await store.signalState(for: "soc", now: 102)
        XCTAssertEqual(state?.value, 20)
        XCTAssertEqual(state?.receivedAtEpoch, 101)
    }

    func testSuccessfulReplayReplacesOldSessionSignalsAndLocation() async throws {
        let store = TelemetryStore()
        let oldData = try JSONEncoder().encode([try signalRow(id: "previous-only")])
        try await MeasurementReplay.replay(oldData, into: store)
        await store.ingest(location: LocationSample(originalTimestamp: 1, receivedAtEpoch: 2,
            receivedAtMonotonicNanos: 3, latitude: 0, longitude: 0, altitude: nil,
            speed: nil, course: nil, horizontalAccuracy: nil, verticalAccuracy: nil))
        try await MeasurementReplay.replay(envelope([try signalRow()]), into: store)
        let old = await store.signalState(for: "previous-only", now: 100)
        let location = await store.latestLocation()
        let current = await store.signalState(for: "soc", now: 100.2)
        XCTAssertNil(old)
        XCTAssertNil(location)
        XCTAssertEqual(current?.value, 50.5)
        XCTAssertEqual(current?.source, .diagnostic)
        XCTAssertEqual(current?.receivedAtEpoch, 100.125)
        XCTAssertEqual(current?.receivedAtMonotonicNanos, 9_876_543_210)
    }

    func testEnvelopeAndPayloadTimestampDisagreementIsRejected() async throws {
        let valid = try signalRow()
        let row = PersistedMeasurement(sequence: valid.sequence, sessionID: valid.sessionID, kind: valid.kind,
            sourceTimestamp: valid.sourceTimestamp, receivedAtEpoch: 999,
            receivedAtMonotonicNanos: valid.receivedAtMonotonicNanos, payloadJSON: valid.payloadJSON)
        let store = TelemetryStore()
        await assertRejected(try JSONEncoder().encode(envelope([row])), store: store)
        let state = await store.signalState(for: "soc", now: 100)
        XCTAssertNil(state)
    }

    func testMalformedSystemRowIsRejectedRatherThanSilentlySkipped() async throws {
        let row = PersistedMeasurement(sequence: 1, sessionID: "session", kind: "SYSTEM",
            sourceTimestamp: 100, receivedAtEpoch: 100, receivedAtMonotonicNanos: 100, payloadJSON: "{}")
        await assertRejected(try JSONEncoder().encode(envelope([row])), store: TelemetryStore())
    }

    func testRecorderCSVPreservesRowIdentityTimestampsAndPayloadWithoutDashboard() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try MeasurementRecorder(path: directory.appendingPathComponent("measurements.sqlite"),
            sessionID: "session,\"quoted\"", startedAt: 90, mode: .demo)
        let row = try signalRow()
        let signal = try JSONDecoder().decode(DecodedSignalSample.self, from: Data(row.payloadJSON.utf8))
        let location = LocationSample(originalTimestamp: 98.125, receivedAtEpoch: 100.25,
            receivedAtMonotonicNanos: UInt64.max - 10, latitude: 0, longitude: 0, altitude: nil,
            speed: 0, course: nil, horizontalAccuracy: 5, verticalAccuracy: nil)
        try await recorder.append(.signal(signal))
        try await recorder.append(.location(location))
        try await recorder.append(.system(name: "MARK,\"quoted\"\nnext", timestamp: 100.5, monotonicNanos: 999))
        try await recorder.finish(endedAt: 101)
        let rows = try await recorder.export()
        let csv = try await recorder.exportCSV()
        let cells = parseCSV(String(decoding: csv, as: UTF8.self))
        XCTAssertEqual(cells.count, rows.count + 1)
        for (expected, actual) in zip(rows, cells.dropFirst()) {
            XCTAssertEqual(actual.count, 7)
            XCTAssertEqual(Int64(actual[0]), expected.sequence)
            XCTAssertEqual(actual[1], expected.sessionID)
            XCTAssertEqual(actual[2], expected.kind)
            XCTAssertEqual(Double(actual[3]), expected.sourceTimestamp)
            XCTAssertEqual(Double(actual[4]), expected.receivedAtEpoch)
            XCTAssertEqual(UInt64(actual[5]), expected.receivedAtMonotonicNanos)
            XCTAssertEqual(actual[6], expected.payloadJSON)
        }
        let export = try await recorder.exportSessionJSON()
        let store = TelemetryStore()
        try await MeasurementReplay.replay(export, into: store)
        let replayLocation = await store.latestLocation()
        let count = try await recorder.count()
        XCTAssertEqual(replayLocation, location)
        XCTAssertEqual(count, 3, "Replay must not append to the recorder")
        XCTAssertEqual(try JSONDecoder().decode(MeasurementExport.self, from: export).session.mode, .demo)
    }

    func testDiagnosticRawResponseAndSessionProvenanceSurviveReplay() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = try MeasurementRecorder(path: directory.appendingPathComponent("measurements.sqlite"),
            sessionID: "diagnostic-fixture", startedAt: 90, mode: .demo)
        let response = OBDResponse(receivedAtEpoch: 100.125, receivedAtMonotonicNanos: 9_876_543_210,
            responseCANID: 0x7EC, isExtended: false, service: .service22, command: "0101",
            payload: [0, 0, 0, 0, 101], sequence: 7, sourceAdapter: "fixture", sourceTransport: "ble")
        let definition = try OBDSignalDefinition(id: "soc", name: "SOC", startBit: 32,
            bitLength: 8, byteOrder: .intel, isSigned: false, factor: 0.5, offset: 0,
            minimum: 0, maximum: 100, unit: "percent", timeout: 2)
        // Independent fixture expectation: raw 101 / 2 = 50.5 percent.
        let signal = DecodedOBDSignal(signal: definition, rawValue: 101, signedRawValue: nil,
            value: 50.5, enumName: nil, response: response)
        let marker = MeasurementEvent.system(name: "MARK", timestamp: 100.5, monotonicNanos: 9_876_543_220)
        try await recorder.append(.diagnosticResponse(response))
        try await recorder.append(.diagnosticSignal(signal))
        try await recorder.append(marker)
        try await recorder.finish(endedAt: 101)
        let data = try await recorder.exportSessionJSON()
        let before = try await recorder.export()
        let csv = parseCSV(String(decoding: try await recorder.exportCSV(), as: UTF8.self))
        let csvResponse = try JSONDecoder().decode(OBDResponse.self, from: Data(csv[1][6].utf8))
        XCTAssertEqual(csvResponse, response)
        let store = TelemetryStore()
        try await MeasurementReplay.replay(data, into: store)
        let raw = await store.latestDiagnosticResponse()
        let replayMarker = await store.latestSystemEvent()
        let session = await store.replayedSession()
        let state = await store.signalState(for: "soc", now: 100.5)
        let after = try await recorder.export()
        XCTAssertEqual(raw, response)
        XCTAssertEqual(replayMarker, marker)
        XCTAssertEqual(session?.mode, .demo)
        XCTAssertEqual(session?.sessionID, "diagnostic-fixture")
        XCTAssertEqual(state?.value, 50.5)
        XCTAssertEqual(state?.source, .diagnostic)
        XCTAssertEqual(state?.frameSequence, response.sequence)
        XCTAssertEqual(state?.receivedAtMonotonicNanos, response.receivedAtMonotonicNanos)
        XCTAssertEqual(after, before, "Replay must not mutate the original recording")
    }

    func testEmptyReplayClearsPreviousRawFramesAndSessionMetadata() async throws {
        let store = TelemetryStore()
        let frame = try CANFrame(receivedAtEpoch: 100, receivedAtMonotonicNanos: 1_000,
            canID: 0x123, isExtended: false, dlc: 1, payload: [1],
            sourceAdapter: "fixture", sourceTransport: "ble", sequence: 1)
        await store.ingest(frame: frame)
        await store.disconnect()
        try await MeasurementReplay.replay(Data("[]".utf8), into: store)
        let raw = await store.latestFrame()
        let session = await store.replayedSession()
        XCTAssertNil(raw)
        XCTAssertNil(session, "Legacy arrays must not invent session metadata")
    }

    func testMalformedCANPayloadCannotBypassFrameValidationViaCodable() async throws {
        let frame = try CANFrame(receivedAtEpoch: 100, receivedAtMonotonicNanos: 1_000,
            canID: 0x123, isExtended: false, dlc: 1, payload: [1],
            sourceAdapter: "fixture", sourceTransport: "ble", sequence: 1)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(frame)) as? [String: Any])
        json["dlc"] = 8
        let row = PersistedMeasurement(sequence: 1, sessionID: "session", kind: "CAN",
            sourceTimestamp: 100, receivedAtEpoch: 100, receivedAtMonotonicNanos: 1_000,
            payloadJSON: String(decoding: try JSONSerialization.data(withJSONObject: json), as: UTF8.self))
        let store = TelemetryStore()
        await assertRejected(try JSONEncoder().encode(envelope([row])), store: store)
        let raw = await store.latestFrame()
        XCTAssertNil(raw)
    }

    func testSingleSessionLegacyArrayRemainsSupported() async throws {
        let store = TelemetryStore(signalTimeouts: ["soc": 1])
        try await MeasurementReplay.replay(try JSONEncoder().encode([try signalRow()]), into: store)
        let state = await store.signalState(for: "soc", now: 102)
        let session = await store.replayedSession()
        XCTAssertEqual(state?.value, 50.5)
        XCTAssertEqual(state?.quality, .stale)
        XCTAssertEqual(state?.source, .diagnostic)
        XCTAssertNil(session)
    }

    // Independent RFC-4180-style reader for testing the production CSV writer.
    private func parseCSV(_ text: String) -> [[String]] {
        let chars = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" {
                    field.append("\""); index += 1
                } else { quoted.toggle() }
            } else if char == "," && !quoted {
                row.append(field); field = ""
            } else if char == "\n" && !quoted {
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(char) }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
