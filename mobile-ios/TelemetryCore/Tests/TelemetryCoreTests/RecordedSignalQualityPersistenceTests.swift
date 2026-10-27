import Foundation
import XCTest
@testable import TelemetryCore

final class RecordedSignalQualityPersistenceTests: XCTestCase {
    private let sessionID = "recorded-quality-fixture"
    private let originNanos: UInt64 = 1_000_000_000

    func testManualSignalConstructorsRemainUnknownAndDecoderSuccessIsRecordedValid() throws {
        let voltage = try voltageDefinition()
        let frame = try energyFrame(second: 0)
        let manualDecoded = DecodedSignal(rawValue: 360, signedRawValue: nil, value: 360, enumName: nil)
        let manualCANSignal = DecodedCANSignal(definition: voltage, frame: frame, decoded: manualDecoded)
        XCTAssertNil(try recordedQualityValue(in: manualCANSignal.sample))

        let pipeline = try CANSignalPipeline(definitions: [voltage])
        let decoded = try XCTUnwrap(pipeline.decode(frame).first)
        XCTAssertEqual(try recordedQualityValue(in: decoded.sample), "valid")

        let manualSample = DecodedSignalSample(
            signalID: "manual-voltage", value: 360, rawValue: 360, enumName: nil, unit: "V",
            frameSequence: frame.sequence, receivedAtEpoch: frame.receivedAtEpoch,
            receivedAtMonotonicNanos: frame.receivedAtMonotonicNanos
        )
        XCTAssertNil(try recordedQualityValue(in: manualSample))

        let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
        let response = try OBDResponseParser.parse(
            "7EC 08 62 01 01 00 00 00 00 64\r",
            for: query,
            receivedAtEpoch: 100,
            receivedAtMonotonicNanos: originNanos,
            sequence: 1,
            sourceAdapter: "fixture",
            sourceTransport: "mock"
        )
        let obdSignal = try OBDSignalDecoder.decode(query.signals[0], response: response)
        XCTAssertEqual(try recordedQualityValue(in: obdSignal), "valid")

        let manualOBDSignal = DecodedOBDSignal(
            signal: query.signals[0], rawValue: 100, signedRawValue: nil, value: 50,
            enumName: nil, response: response
        )
        XCTAssertNil(try recordedQualityValue(in: manualOBDSignal))

        let encodedCAN = try JSONEncoder().encode(decoded.sample)
        XCTAssertEqual(
            try JSONDecoder().decode(LegacyDecodedSignalSample.self, from: encodedCAN).signalID,
            "hv_voltage"
        )
        let encodedOBD = try JSONEncoder().encode(obdSignal)
        XCTAssertEqual(
            try JSONDecoder().decode(LegacyDecodedOBDSignal.self, from: encodedOBD).signalID,
            obdSignal.signalID
        )
    }

    func testLegacyAbsentOrNullQualityStaysUnknownAndUnknownQualityIsRejected() throws {
        let oldSignalPayload = Data(#"{"signalID":"hv_voltage","value":360,"rawValue":360,"unit":"V","frameSequence":1,"receivedAtEpoch":100,"receivedAtMonotonicNanos":1000000000,"source":"rawCAN"}"#.utf8)
        let oldSignal = try JSONDecoder().decode(DecodedSignalSample.self, from: oldSignalPayload)
        XCTAssertNil(try recordedQualityValue(in: oldSignal))

        var signalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: oldSignalPayload) as? [String: Any])
        signalObject["recordedQuality"] = NSNull()
        let nullSignal = try JSONDecoder().decode(
            DecodedSignalSample.self,
            from: JSONSerialization.data(withJSONObject: signalObject)
        )
        XCTAssertNil(try recordedQualityValue(in: nullSignal))
        signalObject["recordedQuality"] = "future-quality"
        XCTAssertThrowsError(try JSONDecoder().decode(
            DecodedSignalSample.self,
            from: JSONSerialization.data(withJSONObject: signalObject)
        ))

        let oldOBDPayload = Data(#"{"signalID":"hv_current","name":"HV current","rawValue":10,"signedRawValue":null,"value":10,"enumName":null,"unit":"A","receivedAtEpoch":100,"receivedAtMonotonicNanos":1000000000,"sequence":1,"sourceAdapter":"fixture","sourceTransport":"mock"}"#.utf8)
        let oldOBD = try JSONDecoder().decode(DecodedOBDSignal.self, from: oldOBDPayload)
        XCTAssertNil(try recordedQualityValue(in: oldOBD))

        var obdObject = try XCTUnwrap(JSONSerialization.jsonObject(with: oldOBDPayload) as? [String: Any])
        obdObject["recordedQuality"] = NSNull()
        let nullOBD = try JSONDecoder().decode(
            DecodedOBDSignal.self,
            from: JSONSerialization.data(withJSONObject: obdObject)
        )
        XCTAssertNil(try recordedQualityValue(in: nullOBD))
        obdObject["recordedQuality"] = "future-quality"
        XCTAssertThrowsError(try JSONDecoder().decode(
            DecodedOBDSignal.self,
            from: JSONSerialization.data(withJSONObject: obdObject)
        ))
    }

    func testLegacyFiniteRowsDoNotBorrowValidQualityFromCurrentSnapshot() async throws {
        let rows = [
            try signalRow(sequence: 1, id: "hv_voltage", value: 360, unit: "V", second: 0, quality: nil),
            try signalRow(sequence: 2, id: "hv_current", value: 10, unit: "A", second: 0, quality: nil),
            try signalRow(sequence: 3, id: "hv_voltage", value: 360, unit: "V", second: 1, quality: nil),
            try signalRow(sequence: 4, id: "hv_current", value: 10, unit: "A", second: 1, quality: nil)
        ]
        let timeline = try await MeasurementReplay.timeline(export(rows, endedAt: 101))
        let snapshot = try await timeline.snapshot(at: 1)
        XCTAssertEqual(snapshot.signals.first(where: { $0.signalID == "hv_voltage" })?.quality, .valid)
        XCTAssertEqual(snapshot.signals.first(where: { $0.signalID == "hv_current" })?.quality, .valid)

        let voltage = try timeline.signalHistory(signalID: "hv_voltage", at: 1)
        let current = try timeline.signalHistory(signalID: "hv_current", at: 1)
        let projection = try RecordedEnergyReplayProjection.summarize(
            selectedSessionID: timeline.sessionID,
            recordedMonotonicOrigin: originNanos,
            voltageSignalID: "hv_voltage",
            voltageHistory: voltage,
            currentSignalID: "hv_current",
            currentHistory: current,
            selectedWindowStartSeconds: 0,
            cursorSeconds: 1,
            policy: energyPolicy(maxGapSeconds: 2)
        )
        XCTAssertEqual(projection.summary.availability, .unavailable(.noQualifiedInterval))
        XCTAssertEqual(projection.summary.validDurationSeconds, 0, accuracy: 1e-12)
    }

    func testPersistedNonvalidRowRemainsAnIntegrationBarrier() async throws {
        let rows = [
            try signalRow(sequence: 1, id: "hv_voltage", value: 360, unit: "V", second: 0, quality: .valid),
            try signalRow(sequence: 2, id: "hv_current", value: 10, unit: "A", second: 0, quality: .valid),
            try signalRow(sequence: 3, id: "hv_voltage", value: 360, unit: "V", second: 1, quality: .invalid),
            try signalRow(sequence: 4, id: "hv_voltage", value: 360, unit: "V", second: 2, quality: .valid),
            try signalRow(sequence: 5, id: "hv_current", value: 10, unit: "A", second: 2, quality: .valid)
        ]
        let timeline = try await MeasurementReplay.timeline(export(rows, endedAt: 103))
        let voltage = try timeline.signalHistory(signalID: "hv_voltage", at: 2)
        let current = try timeline.signalHistory(signalID: "hv_current", at: 2)
        let projection = try RecordedEnergyReplayProjection.summarize(
            selectedSessionID: timeline.sessionID,
            recordedMonotonicOrigin: originNanos,
            voltageSignalID: "hv_voltage",
            voltageHistory: voltage,
            currentSignalID: "hv_current",
            currentHistory: current,
            selectedWindowStartSeconds: 0,
            cursorSeconds: 2,
            policy: energyPolicy(maxGapSeconds: 3)
        )
        XCTAssertEqual(projection.summary.availability, .unavailable(.noQualifiedInterval))
        XCTAssertEqual(projection.summary.validDurationSeconds, 0, accuracy: 1e-12)
        XCTAssertTrue(projection.summary.excludedIntervals.flatMap(\.reasons).contains(
            .qualityNotValid(signal: .voltage, quality: SignalQuality.invalid.rawValue)
        ))
    }

    func testTemporarySQLiteDecoderRecorderReplayProjectsPointZeroOneKWh() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("recorded-energy-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = directory.appendingPathComponent("measurements.sqlite")
        let recorder = try MeasurementRecorder(path: database, sessionID: sessionID, startedAt: 100)
        let store = TelemetryStore()
        let session = ELM327Session(transport: MockCANTransport(), sourceAdapter: "fixture", sourceTransport: "mock")
        let pipeline = try CANMeasurementPipeline(
            session: session,
            definitions: [try voltageDefinition(), try currentDefinition()],
            store: store,
            recorder: recorder
        )

        for second in 0...10 {
            let decoded = try await pipeline.ingest(energyFrame(second: second))
            XCTAssertEqual(decoded.count, 2)
        }
        try await recorder.finish(endedAt: 111)

        let archive = try MeasurementArchive(path: database)
        let loaded = try await archive.load(sessionID: sessionID)
        XCTAssertEqual(loaded.schemaVersion, 1)
        let origin = try XCTUnwrap(loaded.measurements.first?.receivedAtMonotonicNanos)
        let timeline = try await MeasurementReplay.timeline(loaded)
        let voltage = try timeline.signalHistory(signalID: "hv_voltage", at: 10)
        let current = try timeline.signalHistory(signalID: "hv_current", at: 10)
        for point in voltage.samples {
            XCTAssertEqual(try recordedQualityValue(in: point.measurement), "valid")
        }
        for point in current.samples {
            XCTAssertEqual(try recordedQualityValue(in: point.measurement), "valid")
        }

        let projection = try RecordedEnergyReplayProjection.summarize(
            selectedSessionID: timeline.sessionID,
            recordedMonotonicOrigin: origin,
            voltageSignalID: "hv_voltage",
            voltageHistory: voltage,
            currentSignalID: "hv_current",
            currentHistory: current,
            selectedWindowStartSeconds: 0,
            cursorSeconds: 10,
            policy: energyPolicy(maxGapSeconds: 2)
        )
        XCTAssertEqual(projection.summary.availability, .available)
        XCTAssertEqual(projection.summary.validDurationSeconds, 10, accuracy: 1e-12)
        XCTAssertEqual(projection.summary.consumedKWh, 0.01, accuracy: 1e-12)
        XCTAssertEqual(projection.summary.regeneratedKWh, 0, accuracy: 1e-12)

        let firstPayload = try XCTUnwrap(loaded.measurements.first(where: { $0.kind == "SIGNAL" }))
        let firstPayloadObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(firstPayload.payloadJSON.utf8)) as? [String: Any]
        )
        XCTAssertEqual(firstPayloadObject["recordedQuality"] as? String, "valid")
        let legacyReader = try JSONDecoder().decode(
            LegacyDecodedSignalSample.self,
            from: Data(firstPayload.payloadJSON.utf8)
        )
        XCTAssertEqual(legacyReader.unit, "V")
    }

    private func energyPolicy(maxGapSeconds: Double) -> RecordedEnergyPolicy {
        RecordedEnergyPolicy(
            maxGapSeconds: maxGapSeconds,
            maxSampleSkewSeconds: 0.1,
            currentSignConvention: .positiveCurrentMeansConsumption
        )
    }

    private func recordedQualityValue<T: Encodable>(in value: T) throws -> String? {
        let data = try JSONEncoder().encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object["recordedQuality"] as? String
    }

    private func recordedQualityValue(in measurement: PersistedMeasurement) throws -> String? {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(measurement.payloadJSON.utf8)) as? [String: Any]
        )
        return object["recordedQuality"] as? String
    }

    private func voltageDefinition() throws -> SignalDefinition {
        try SignalDefinition(
            id: "hv_voltage", name: "HV voltage", canID: 0x123, isExtended: false,
            startBit: 0, bitLength: 16, byteOrder: .intel, isSigned: false,
            factor: 1, offset: 0, minimum: 0, maximum: 65_535, unit: "V", timeout: 5
        )
    }

    private func currentDefinition() throws -> SignalDefinition {
        try SignalDefinition(
            id: "hv_current", name: "HV current", canID: 0x123, isExtended: false,
            startBit: 16, bitLength: 8, byteOrder: .intel, isSigned: false,
            factor: 1, offset: 0, minimum: 0, maximum: 255, unit: "A", timeout: 5
        )
    }

    private func energyFrame(second: Int) throws -> CANFrame {
        try CANFrame(
            receivedAtEpoch: 100 + Double(second),
            receivedAtMonotonicNanos: originNanos + UInt64(second) * 1_000_000_000,
            canID: 0x123,
            isExtended: false,
            dlc: 3,
            payload: [0x68, 0x01, 0x0A],
            sourceAdapter: "fixture",
            sourceTransport: "mock",
            sequence: UInt64(second + 1)
        )
    }

    private func signalRow(
        sequence: Int64,
        id: String,
        value: Double,
        unit: String,
        second: Int,
        quality: SignalQuality?
    ) throws -> PersistedMeasurement {
        let epoch = 100 + Double(second)
        let nanos = originNanos + UInt64(second) * 1_000_000_000
        var object: [String: Any] = [
            "signalID": id,
            "value": value,
            "rawValue": UInt64(value),
            "enumName": NSNull(),
            "unit": unit,
            "frameSequence": UInt64(sequence),
            "receivedAtEpoch": epoch,
            "receivedAtMonotonicNanos": nanos,
            "source": "rawCAN"
        ]
        if let quality { object["recordedQuality"] = quality.rawValue }
        let payload = String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
        return PersistedMeasurement(
            sequence: sequence,
            sessionID: sessionID,
            kind: "SIGNAL",
            sourceTimestamp: epoch,
            receivedAtEpoch: epoch,
            receivedAtMonotonicNanos: nanos,
            payloadJSON: payload
        )
    }

    private func export(_ rows: [PersistedMeasurement], endedAt: Double) -> MeasurementExport {
        MeasurementExport(
            session: PersistedMeasurementSession(sessionID: sessionID, startedAt: 100, endedAt: endedAt),
            measurements: rows
        )
    }

    private struct LegacyDecodedSignalSample: Decodable {
        let signalID: String
        let value: Double
        let rawValue: UInt64
        let unit: String
        let frameSequence: UInt64
        let receivedAtEpoch: Double
        let receivedAtMonotonicNanos: UInt64
        let source: TelemetrySource
    }

    private struct LegacyDecodedOBDSignal: Decodable {
        let signalID: String
        let name: String
        let rawValue: UInt64
        let signedRawValue: Int64?
        let value: Double
        let unit: String
        let receivedAtEpoch: Double
        let receivedAtMonotonicNanos: UInt64
        let sequence: UInt64
        let sourceAdapter: String
        let sourceTransport: String
    }
}
