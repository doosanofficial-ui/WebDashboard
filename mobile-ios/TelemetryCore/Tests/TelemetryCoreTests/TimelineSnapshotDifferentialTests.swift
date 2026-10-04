import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#endif
@testable import TelemetryCore

final class TimelineSnapshotDifferentialTests: XCTestCase {
    private func row<T: Encodable>(_ value: T, kind: String, sequence: Int64, epoch: Double, nanos: UInt64, source: Double? = nil) throws -> PersistedMeasurement {
        .init(sequence: sequence, sessionID: "differential", kind: kind, sourceTimestamp: source ?? epoch,
              receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos,
              payloadJSON: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
    }
    private func fixture() throws -> MeasurementExport {
        var rows: [PersistedMeasurement] = []
        for i in 0..<48 {
            let sequence = Int64(i + 1), epoch = 200 - Double(i), nanos = UInt64(i / 4) * 1_000_000_000
            switch i % 8 {
            case 0, 3, 6:
                let source: TelemetrySource = i % 8 == 3 ? .diagnostic : .rawCAN
                let sample = DecodedSignalSample(signalID: i < 24 ? "soc" : "later", value: Double(i), rawValue: UInt64(i + 17),
                    enumName: "raw-\(i)", unit: i % 8 == 6 ? "V" : "%", frameSequence: UInt64(i + 99),
                    receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos, source: source)
                rows.append(try row(sample, kind: "SIGNAL", sequence: sequence, epoch: epoch, nanos: nanos))
            case 1:
                let frame = try CANFrame(receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos, canID: 0x123,
                    isExtended: false, dlc: 1, payload: [UInt8(i)], sourceAdapter: "a", sourceTransport: "fixture", sequence: UInt64(i))
                rows.append(try row(frame, kind: "CAN", sequence: sequence, epoch: epoch, nanos: nanos))
            case 2:
                let response = OBDResponse(receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos, responseCANID: 0x7EC,
                    isExtended: false, service: .service22, command: "0101", payload: [1,2], sequence: UInt64(i), sourceAdapter: "b", sourceTransport: "fixture")
                rows.append(try row(response, kind: "DIAGNOSTIC_RESPONSE", sequence: sequence, epoch: epoch, nanos: nanos))
            case 4:
                let sample = LocationSample(originalTimestamp: epoch - 0.25, receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos,
                    latitude: Double(i)/100, longitude: 0, altitude: -30, speed: -1, course: -1,
                    horizontalAccuracy: i % 16 == 4 ? -1 : 5, verticalAccuracy: -1, source: i % 24 == 4 ? .demo : .gps)
                rows.append(try row(sample, kind: "LOCATION", sequence: sequence, epoch: epoch, nanos: nanos, source: epoch - 0.25))
            default:
                rows.append(.init(sequence: sequence, sessionID: "differential", kind: "SYSTEM", sourceTimestamp: epoch,
                    receivedAtEpoch: epoch, receivedAtMonotonicNanos: nanos, payloadJSON: i % 8 == 5 ? "{\"name\":\"MARK\"}" : "{\"name\":\"other\"}"))
            }
        }
        return .init(session: .init(sessionID: "differential", startedAt: 190, endedAt: 210, mode: .live), measurements: Array(rows.reversed()))
    }
    private func assertSnapshot(_ actual: MeasurementReplay.Snapshot, _ expected: MeasurementReplay.Snapshot, elapsed: Double,
                                origin: UInt64, timeouts: [String: Double], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.timestamp, expected.timestamp, file: file, line: line)
        XCTAssertEqual(actual.signals, expected.signals, file: file, line: line)
        XCTAssertEqual(actual.frame, expected.frame, file: file, line: line)
        XCTAssertEqual(actual.diagnostic, expected.diagnostic, file: file, line: line)
        XCTAssertEqual(actual.location, expected.location, file: file, line: line)
        XCTAssertEqual(actual.markTimestamp, expected.markTimestamp, file: file, line: line)
        var ages: [String: Double] = [:]; var freshness: [String: MeasurementReplay.SignalFreshness] = [:]
        for signal in expected.signals {
            let mono = signal.receivedAtMonotonicNanos
            let offset = mono >= origin ? Double(mono-origin)/1e9 : -Double(origin-mono)/1e9
            let age = max(0, elapsed-offset); ages[signal.signalID] = age
            freshness[signal.signalID] = timeouts[signal.signalID].map { age > $0 ? .stale : .fresh } ?? .unknown
        }
        XCTAssertEqual(actual.signalAges, ages, file: file, line: line)
        XCTAssertEqual(actual.signalFreshness, freshness, file: file, line: line)
    }
    func testAllSnapshotFieldsMatchSequencePrefixOracleAcrossForwardAndReverseSeeks() async throws {
        let saved = try fixture(), timeouts = ["soc": 0.5]
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let before = try encoder.encode(saved), csv = MeasurementRecorder.csvData(for: saved.measurements)
        let timeline = try await MeasurementReplay.timeline(saved, signalTimeouts: timeouts)
        let rows = saved.measurements.sorted { $0.sequence < $1.sequence }
        let positions = [-1.0,0,0.5,1,2,4,6,8,11,12,11,8,4,1,0]
        for position in positions {
            let end = min(timeline.duration,max(0,position))
            let prefix = rows.filter { Double($0.receivedAtMonotonicNanos)/1e9 <= end }
            let expected = try await MeasurementReplay.snapshot(.init(session: saved.session, measurements: prefix))
            let actual = try await timeline.snapshot(at: position)
            assertSnapshot(actual, expected, elapsed: end, origin: 0, timeouts: timeouts)
            for id in ["soc","later"] {
                let wanted = prefix.filter { $0.kind == "SIGNAL" && $0.payloadJSON.contains("\"signalID\":\"\(id)\"") && Double($0.receivedAtMonotonicNanos)/1e9 >= max(0,end-2) }
                let h = try timeline.signalHistory(signalID: id, at: position, windowSeconds: 2, maximumSamples: 2)
                XCTAssertEqual(h.totalSamplesInWindow, wanted.count)
                XCTAssertEqual(h.samples.map(\.measurement), Array(wanted.suffix(2)))
                XCTAssertEqual(h.startSeconds,max(0,end-2)); XCTAssertEqual(h.endSeconds,end)
                XCTAssertEqual(h.truncated,wanted.count>2)
            }
            let locations = prefix.filter { $0.kind == "LOCATION" }
            let h = try timeline.locationHistory(at: position, maximumSamples: 2)
            XCTAssertEqual(h.samples.map(\.measurement), Array(locations.suffix(2)))
            XCTAssertEqual(h.totalRowsInPrefix,locations.count); XCTAssertEqual(h.endSeconds,end)
            XCTAssertEqual(h.truncated,locations.count>2)
        }
        XCTAssertEqual(try encoder.encode(saved),before)
        XCTAssertEqual(MeasurementRecorder.csvData(for:saved.measurements),csv)
        let history = try timeline.signalHistory(signalID: "soc", at: 5)
        XCTAssertEqual(Array(history.samples.prefix(3)).map(\.sourceSegment),[0,1,2])
        XCTAssertTrue(try timeline.locationHistory(at: 1).plottableSamples.isEmpty)
    }
    func testEmptyPrefixTimestampTracksUnindexedSystemRows() async throws {
        let saved = MeasurementExport(session: .init(sessionID:"differential",startedAt:90,endedAt:110,mode:.demo),measurements:[
            .init(sequence:1,sessionID:"differential",kind:"SYSTEM",sourceTimestamp:100,receivedAtEpoch:100,receivedAtMonotonicNanos:0,payloadJSON:"{\"name\":\"other\"}"),
            .init(sequence:2,sessionID:"differential",kind:"SYSTEM",sourceTimestamp:99,receivedAtEpoch:99,receivedAtMonotonicNanos:1_000_000_000,payloadJSON:"{\"name\":\"other\"}")])
        let t = try await MeasurementReplay.timeline(saved)
        for position in [0.0,1,0] {
            let prefix = saved.measurements.filter { Double($0.receivedAtMonotonicNanos)/1e9 <= position }
            let oracle = try await MeasurementReplay.snapshot(.init(session:saved.session,measurements:prefix))
            let actual = try await t.snapshot(at:position)
            assertSnapshot(actual,oracle,elapsed:position,origin:0,timeouts:[:])
        }
        let empty = try await MeasurementReplay.timeline(.init(session:saved.session,measurements:[]))
        let result = try await empty.snapshot(at:0)
        let oracle = try await MeasurementReplay.snapshot(.init(session:saved.session,measurements:[]))
        assertSnapshot(result,oracle,elapsed:0,origin:0,timeouts:[:])
    }
    func testDiagnosticSignalAndRegressedMonotonicTimeMatchOracle() async throws {
        let definition = try OBDSignalDefinition(id:"soc",name:"SOC",startBit:0,bitLength:8,byteOrder:.intel,isSigned:false,factor:1,offset:0,minimum:0,maximum:100,unit:"percent",timeout:2)
        var rows: [PersistedMeasurement] = []
        for i in 0..<3 {
            let epoch = 100-Double(i), nanos: UInt64 = i == 0 ? 10 : (i == 1 ? 2_000_000_010 : 5)
            let response = OBDResponse(receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,responseCANID:0x7EC,isExtended:false,service:.service22,command:"0101",payload:[UInt8(i)],sequence:UInt64(i+20),sourceAdapter:i == 1 ? "B" : "A",sourceTransport:"fixture")
            let signal = DecodedOBDSignal(signal:definition,rawValue:UInt64(i+7),signedRawValue:nil,value:Double(i+30),enumName:"raw",response:response)
            rows.append(try row(signal,kind:"DIAGNOSTIC_SIGNAL",sequence:Int64(i+1),epoch:epoch,nanos:nanos))
        }
        let saved = MeasurementExport(session:.init(sessionID:"differential",startedAt:90,endedAt:110,mode:.live),measurements:Array(rows.reversed()))
        let timeline = try await MeasurementReplay.timeline(saved,signalTimeouts:["soc":1])
        for t in [0.0,1,2,0,2] {
            let prefix = t < 2 ? [rows[0]] : rows
            let oracle = try await MeasurementReplay.snapshot(.init(session:saved.session,measurements:prefix))
            let actual = try await timeline.snapshot(at:t)
            assertSnapshot(actual,oracle,elapsed:t,origin:10,timeouts:["soc":1])
        }
        let h = try timeline.signalHistory(signalID:"soc",at:2)
        XCTAssertEqual(h.samples.map(\.elapsedSeconds),[0,2,2])
        XCTAssertEqual(h.samples.map(\.sourceSegment),[0,1,2])
        XCTAssertEqual(h.samples.map(\.measurement),rows)
    }
    func testCANAndDiagnosticAreMutuallyExclusiveAcrossReverseSeeks() async throws {
        var rows: [PersistedMeasurement] = []
        for i in 0..<4 {
            let epoch = 100-Double(i), nanos = UInt64(i)*1_000_000_000
            if i % 2 == 0 {
                let frame = try CANFrame(receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,canID:0x123,isExtended:false,dlc:1,payload:[UInt8(i)],sourceAdapter:"A",sourceTransport:"fixture",sequence:UInt64(i+1))
                rows.append(try row(frame,kind:"CAN",sequence:Int64(i+1),epoch:epoch,nanos:nanos))
            } else {
                let response = OBDResponse(receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,responseCANID:0x7EC,isExtended:false,service:.service22,command:"0101",payload:[UInt8(i)],sequence:UInt64(i+1),sourceAdapter:"B",sourceTransport:"fixture")
                rows.append(try row(response,kind:"DIAGNOSTIC_RESPONSE",sequence:Int64(i+1),epoch:epoch,nanos:nanos))
            }
        }
        let session = PersistedMeasurementSession(sessionID:"differential",startedAt:90,endedAt:110,mode:.live)
        let timeline = try await MeasurementReplay.timeline(.init(session:session,measurements:rows))
        for time in [0,1,2,3,2,1,0] {
            let oracle = try await MeasurementReplay.snapshot(.init(session:session,measurements:Array(rows.prefix(time+1))))
            let actual = try await timeline.snapshot(at:Double(time))
            assertSnapshot(actual,oracle,elapsed:Double(time),origin:0,timeouts:[:])
            XCTAssertEqual(actual.frame != nil,time % 2 == 0)
            XCTAssertEqual(actual.diagnostic != nil,time % 2 == 1)
        }
    }
    func testManySignalKindsMatchAllFieldsAndHistoryAcrossSourceReturns() async throws {
        let budget = ReplayStressBudget(); defer { budget.finish() }
        var rows: [PersistedMeasurement] = []
        for layer in 0..<3 {
            for id in 0..<(layer == 2 ? 512 : 256) {
                let sequence = Int64(rows.count + 1), epoch = 300 - Double(layer), nanos = UInt64(layer)*1_000_000_000
                let name = String(format:"signal-%04d",id)
                if layer == 1 {
                    let definition = try OBDSignalDefinition(id:name,name:name,startBit:0,bitLength:8,byteOrder:.intel,isSigned:false,factor:1,offset:0,minimum:0,maximum:1000,unit:"V",timeout:2)
                    let response = OBDResponse(receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,responseCANID:0x7EC,isExtended:false,service:.service22,command:"0101",payload:[1],sequence:UInt64(sequence),sourceAdapter:"B",sourceTransport:"fixture")
                    let sample = DecodedOBDSignal(signal:definition,rawValue:UInt64(id+100),signedRawValue:nil,value:Double(id+10),enumName:"B",response:response)
                    rows.append(try row(sample,kind:"DIAGNOSTIC_SIGNAL",sequence:sequence,epoch:epoch,nanos:nanos))
                } else {
                    let sample = DecodedSignalSample(signalID:name,value:Double(id+layer),rawValue:UInt64(id+layer+7),enumName:"A",unit:"%",frameSequence:UInt64(sequence),receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,source:.rawCAN)
                    rows.append(try row(sample,kind:"SIGNAL",sequence:sequence,epoch:epoch,nanos:nanos))
                }
            }
            budget.checkpoint()
        }
        let session = PersistedMeasurementSession(sessionID:"differential",startedAt:290,endedAt:310,mode:.live)
        let saved = MeasurementExport(session:session,measurements:Array(rows.reversed()))
        let timeouts = ["signal-0000":0.5,"signal-0001":2.0]
        let timeline = try await MeasurementReplay.timeline(saved,signalTimeouts:timeouts)
        for time in [0.0,1,2,1,0] {
            let prefix = rows.filter {Double($0.receivedAtMonotonicNanos)/1e9 <= time}
            let oracle = try await MeasurementReplay.snapshot(.init(session:session,measurements:prefix))
            let actual = try await timeline.snapshot(at:time)
            assertSnapshot(actual,oracle,elapsed:time,origin:0,timeouts:timeouts)
            XCTAssertEqual(actual.signals.count,time == 2 ? 512 : 256)
            XCTAssertEqual(actual.signals.map(\.signalID),actual.signals.map(\.signalID).sorted())
            for id in ["signal-0000","signal-0255","signal-0511"] {
                let history = try timeline.signalHistory(signalID:id,at:time,windowSeconds:2,maximumSamples:2)
                let expected = prefix.filter {$0.payloadJSON.contains("\"signalID\":\"\(id)\"")}
                XCTAssertEqual(history.samples.map(\.measurement),Array(expected.suffix(2)))
                XCTAssertEqual(history.totalSamplesInWindow,expected.count)
                XCTAssertEqual(history.truncated,expected.count>2)
            }
            budget.checkpoint()
        }
        XCTAssertEqual(try timeline.signalHistory(signalID:"signal-0000",at:2).samples.map(\.sourceSegment),[0,1,2])
    }

    func testTwoHundredThousandOffsetBoundariesMatchOracleForEveryIndexedKind() async throws {
        let budget = ReplayStressBudget(); defer { budget.finish() }
        let count = 200_000
        for rotation in 0..<3 {
            var rows: [PersistedMeasurement] = []; rows.reserveCapacity(count)
            for offset in 0..<count {
                rows.append(.init(sequence:Int64(offset+1),sessionID:"differential",kind:"SYSTEM",sourceTimestamp:300-Double(offset)/1000,receivedAtEpoch:300-Double(offset)/1000,receivedAtMonotonicNanos:UInt64(offset)*1_000_000,payloadJSON:"{\"name\":\"other\"}"))
                if offset % 4096 == 0 { budget.checkpoint() }
            }
            for (index,offset) in [0,99_999,199_999].enumerated() {
                let epoch = rows[offset].receivedAtEpoch, nanos = rows[offset].receivedAtMonotonicNanos, sequence = Int64(offset+1)
                switch (index+rotation)%3 {
                case 0:
                    let frame = try CANFrame(receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,canID:0x123,isExtended:false,dlc:1,payload:[UInt8(index)],sourceAdapter:"A",sourceTransport:"fixture",sequence:UInt64(sequence))
                    rows[offset] = try row(frame,kind:"CAN",sequence:sequence,epoch:epoch,nanos:nanos)
                case 1:
                    let response = OBDResponse(receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,responseCANID:0x7EC,isExtended:false,service:.service22,command:"0101",payload:[UInt8(index)],sequence:UInt64(sequence),sourceAdapter:"B",sourceTransport:"fixture")
                    rows[offset] = try row(response,kind:"DIAGNOSTIC_RESPONSE",sequence:sequence,epoch:epoch,nanos:nanos)
                default:
                    rows[offset] = .init(sequence:sequence,sessionID:"differential",kind:"SYSTEM",sourceTimestamp:epoch,receivedAtEpoch:epoch,receivedAtMonotonicNanos:nanos,payloadJSON:"{\"name\":\"MARK\"}")
                }
            }
            let session = PersistedMeasurementSession(sessionID:"differential",startedAt:290,endedAt:310,mode:.live)
            let timeline = try await MeasurementReplay.timeline(.init(session:session,measurements:rows))
            for offset in [0,99_998,99_999,199_998,199_999,99_999,0] {
                let time = Double(rows[offset].receivedAtMonotonicNanos)/1e9
                let oracle = try await MeasurementReplay.snapshot(.init(session:session,measurements:Array(rows.prefix(offset+1))))
                let actual = try await timeline.snapshot(at:time)
                assertSnapshot(actual,oracle,elapsed:time,origin:0,timeouts:[:])
                budget.checkpoint()
            }
        }
    }

    func testActualTwoHundredThousandAndOneRowsAreRejectedBeforePayloadDecode() async throws {
        let budget = ReplayStressBudget(); defer { budget.finish() }
        let malformed = PersistedMeasurement(sequence:1,sessionID:"differential",kind:"SIGNAL",sourceTimestamp:100,receivedAtEpoch:100,receivedAtMonotonicNanos:0,payloadJSON:"{}")
        let saved = MeasurementExport(session:.init(sessionID:"differential",startedAt:90,endedAt:110,mode:.live),measurements:Array(repeating:malformed,count:200_001))
        do { _ = try await MeasurementReplay.timeline(saved); XCTFail("Exceeded cap") }
        catch { XCTAssertEqual(error as? MeasurementReplayError,.rowLimitExceeded) }
        budget.checkpoint()
    }

    func testMalformedTailIsRejectedBeforeAnyTimelineCanBeReturned() async throws {
        let saved = try fixture()
        for kind in ["SIGNAL","DIAGNOSTIC_SIGNAL","DIAGNOSTIC_RESPONSE","CAN","LOCATION","SYSTEM","FUTURE"] {
            let bad = PersistedMeasurement(sequence:99,sessionID:"differential",kind:kind,sourceTimestamp:300,receivedAtEpoch:300,
                receivedAtMonotonicNanos:99_000_000_000,payloadJSON:"{}")
            do { _ = try await MeasurementReplay.timeline(.init(session:saved.session,measurements:saved.measurements+[bad])); XCTFail("Accepted malformed tail \(kind)") }
            catch { XCTAssertTrue(error is MeasurementReplayError) }
        }
    }
}

/// Test-only, bounded synthetic workload monitor. A guard aborts this test
/// process, never a device or another job. Sampling cannot catch every spike.
private final class ReplayStressBudget: @unchecked Sendable {
    private let start = ProcessInfo.processInfo.systemUptime
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var timer: DispatchSourceTimer?
    init() {
        let timer = DispatchSource.makeTimerSource(queue:DispatchQueue.global())
        timer.schedule(deadline:.now(),repeating:.milliseconds(100))
        timer.setEventHandler { [weak self] in self?.checkpoint() }
        self.timer = timer; timer.resume()
    }
    func checkpoint() {
        let seconds = ProcessInfo.processInfo.systemUptime-start
        var bytes: UInt64 = 0
        #if canImport(Darwin)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue:info)/4)
        let result = withUnsafeMutablePointer(to:&info) { pointer in
            pointer.withMemoryRebound(to:integer_t.self,capacity:Int(count)) {
                task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count)
            }
        }
        guard result == KERN_SUCCESS else { fatalError("Stress memory monitor unavailable") }
        bytes = info.phys_footprint
        #endif
        lock.lock(); peak=max(peak,bytes);lock.unlock()
        if bytes > 1_073_741_824 || seconds > 60 { fatalError("Stress 1GiB/60s guard exceeded") }
    }
    func finish() {
        checkpoint();timer?.cancel();timer=nil
        lock.lock();let observed=peak;lock.unlock()
        print("STRESS_BUDGET seconds=\(ProcessInfo.processInfo.systemUptime-start) observedPeakFootprint=\(observed)")
    }
    deinit {timer?.cancel()}
}
