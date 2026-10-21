import Foundation
import TelemetryCore

enum CheckFailure: Error, CustomStringConvertible {
    case failed(String)
    var description: String { switch self { case let .failed(message): return message } }
}

func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw CheckFailure.failed(message) }
}

func regularFiles(at root: URL) throws -> Set<String> {
    var files = Set<String>()
    for case let path as String in FileManager.default.enumerator(atPath: root.path)! {
        let type = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(path).path)[.type] as? FileAttributeType
        if type == .typeRegular { files.insert(path) }
    }
    return files
}

@main struct DemoAdapterChecks {
    @MainActor static func main() async {
        do { try await run() }
        catch { print("FAIL: \(error)"); exit(1) }
    }

    @MainActor static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fm = FileManager.default
        try require(!fm.fileExists(atPath: root.path), "fixture must be new")
        try require(!root.path.contains("/CoreSimulator/"), "never use an app container")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var originals: [String: Data] = [:]
        for index in 0..<10 {
            let path = "existing/sentinel-\(index)"
            let file = root.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data("SYNTHETIC existing sentinel \(index)".utf8)
            try data.write(to: file, options: .withoutOverwriting)
            originals[path] = data
        }
        let dbRelative = "Library/Application Support/Telemetry/measurements.sqlite3"
        let db = root.appendingPathComponent(dbRelative)
        // Independent protocol fixtures: initial ramp, 0x03FC -> 0x0401 carry,
        // and the 299 -> 300 period boundary. Do not derive these with the producer.
        let expected: [Int: ([UInt8], UInt64, Double)] = [
            0: ([0xE8, 0x03], 1000, 100.0),
            1: ([0xED, 0x03], 1005, 100.5),
            2: ([0xF2, 0x03], 1010, 101.0),
            3: ([0xF7, 0x03], 1015, 101.5),
            4: ([0xFC, 0x03], 1020, 102.0),
            5: ([0x01, 0x04], 1025, 102.5),
            6: ([0x06, 0x04], 1030, 103.0),
            299: ([0xBF, 0x09], 2495, 249.5),
            300: ([0xE8, 0x03], 1000, 100.0)
        ]
        let demo = DemoAdapterController()
        defer { demo.stop() }
        var frames: [(CANFrame, DecodedSignal)] = []
        var failure: String?
        var checkedTicks: [Int] = []
        demo.onFrame = { frame, decoded in
            let tick = frames.count
            frames.append((frame, decoded))
            guard failure == nil else { return }
            guard frame.canID == 0x123, frame.sourceAdapter == "demo", frame.sourceTransport == "mock" else {
                failure = "non-Demo CAN provenance"; return
            }
            if let (payload, raw, value) = expected[tick] {
                guard frame.payload == payload, decoded.rawValue == raw, abs(decoded.value - value) < 0.000001 else {
                    failure = "tick \(tick): expected payload \(payload), raw \(raw), value \(value); got \(frame.payload), \(decoded.rawValue), \(decoded.value)"
                    return
                }
                checkedTicks.append(tick)
            }
        }
        demo.start()
        let deadline = Date().addingTimeInterval(40)
        while frames.count < 301 && failure == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        demo.stop()
        if let failure { throw CheckFailure.failed(failure) }
        try require(frames.count >= 301, "Demo did not reach its period boundary within 40 seconds")
        try require(checkedTicks == expected.keys.sorted(), "missing independent callback fixtures")
        try require(!fm.fileExists(atPath: db.path), "Demo preview created a database")
        print("PASS: actual Demo callbacks match 9 independent initial/carry/period fixtures")

        let recorder = try MeasurementRecorder(path: db, sessionID: "synthetic-demo-endian-regression",
            startedAt: frames[0].0.receivedAtEpoch, mode: .demo)
        let queue = try MeasurementWriteQueue(recorder: recorder)
        _ = try queue.enqueue(.system(name: "recording_started", timestamp: frames[0].0.receivedAtEpoch,
            monotonicNanos: frames[0].0.receivedAtMonotonicNanos))
        for (frame, decoded) in frames.prefix(7) {
            let sample = DecodedSignalSample(signalID: "demo.signal", value: decoded.value,
                rawValue: decoded.rawValue, enumName: decoded.enumName, unit: "demo",
                frameSequence: frame.sequence, receivedAtEpoch: frame.receivedAtEpoch,
                receivedAtMonotonicNanos: frame.receivedAtMonotonicNanos, source: .demo)
            _ = try queue.enqueue(contentsOf: [.can(frame: frame), .signal(sample)])
        }
        try await queue.finish(endedAt: frames[6].0.receivedAtEpoch,
            monotonicNanos: frames[6].0.receivedAtMonotonicNanos).value
        let archive = try MeasurementArchive(path: db)
        let saved = try await archive.load(sessionID: "synthetic-demo-endian-regression")
        try require(saved.session.mode == .demo && saved.session.endedAt != nil, "session must be closed DEMO")
        try require(saved.measurements.count == 16, "expected 7 CAN + 7 SIGNAL + 2 SYSTEM rows")
        let canRows = saved.measurements.filter { $0.kind == "CAN" }
        let signalRows = saved.measurements.filter { $0.kind == "SIGNAL" }
        try require(canRows.count == 7 && signalRows.count == 7, "unexpected measurement kinds")
        for index in 0..<7 {
            let frame = try JSONDecoder().decode(CANFrame.self, from: Data(canRows[index].payloadJSON.utf8))
            let sample = try JSONDecoder().decode(DecodedSignalSample.self, from: Data(signalRows[index].payloadJSON.utf8))
            let (payload, raw, value) = expected[index]!
            try require(frame.payload == payload && frame.sourceAdapter == "demo" && frame.sourceTransport == "mock", "stored CAN differs")
            try require(sample.source == .demo && sample.signalID == "demo.signal"
                && sample.rawValue == raw && abs(sample.value - value) < 0.000001, "stored SIGNAL differs")
        }
        let snapshot = try await MeasurementReplay.snapshot(saved)
        try require(snapshot.signals.first(where: { $0.signalID == "demo.signal" })?.value == 103.0, "reopened snapshot differs")
        let store = TelemetryStore()
        try await MeasurementReplay.replay(saved, into: store)
        let replayed = await store.signalState(for: "demo.signal", now: snapshot.timestamp)
        try require(replayed?.value == 103.0, "replayed value differs")
        let rowCount = try await recorder.count()
        try require(rowCount == 16, "Replay appended measurements")
        for (path, data) in originals {
            let actual = try Data(contentsOf: root.appendingPathComponent(path))
            try require(actual == data, "existing synthetic sibling changed: \(path)")
        }
        let files = try regularFiles(at: root)
        let added = files.subtracting(originals.keys)
        let allowed = Set([dbRelative, dbRelative + "-wal", dbRelative + "-shm", dbRelative + "-journal"])
        try require(added.contains(dbRelative) && added.isSubset(of: allowed), "unexpected fixture writes: \(added)")
        print("PASS: 16 synthetic rows saved/reopened/replayed; 10 existing sentinels unchanged; only DB/sidecars added")
        print("SCOPE: macOS host, real Demo/Core; no TelemetryModel, Simulator, physical hardware, app data or UI")
    }
}
