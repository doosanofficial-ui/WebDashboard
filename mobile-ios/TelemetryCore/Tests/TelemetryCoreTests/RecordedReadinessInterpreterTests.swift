import XCTest
@testable import TelemetryCore

final class RecordedReadinessInterpreterTests: XCTestCase {
    private func input(_ b: UInt8 = 0, _ c: UInt8 = 0, _ d: UInt8 = 0,
                       ecu: String = "ECU-A", service: RecordedDiagnosticService = .monitorStatus,
                       classification: RecordedDiagnosticClassification = .payload,
                       payload: [UInt8]? = nil) -> RecordedDiagnosticInterpretation {
        RecordedDiagnosticInterpreter.interpret(RecordedDiagnosticResponse(ecu: ecu, service: service,
            framing: .iso15765CAN, classification: classification, payload: payload ?? [65, 1, 0, b, c, d]))
    }
    private func decode(_ b: UInt8 = 0, _ c: UInt8 = 0, _ d: UInt8 = 0) -> RecordedReadinessInterpretation {
        RecordedReadinessInterpreter.interpret(input(b,c,d), schema: .j1979DA2011)
    }
    func testZero() { let r = decode(); XCTAssertEqual(r.status, .decoded); XCTAssertEqual(r.supportedCount, 0); XCTAssertTrue(r.monitors!.allSatisfy { $0.completion == .notApplicable }) }
    func testSupportSeparate() { let r = decode(1); XCTAssertEqual(r.monitors?[0].completion, .complete); XCTAssertEqual(r.completedCount, 1) }
    func testPolarity() { let r = decode(17,1,1); XCTAssertEqual(r.incompleteCount, 2); XCTAssertEqual(r.completedCount, 0) }
    func testByteBPositions() {
        for i in 0..<3 { let r = decode((1 << i) | (1 << (i+4))); XCTAssertEqual(r.monitors?[i].completion, .incomplete); XCTAssertEqual(r.supportedCount, 1) }
    }
    func testSparkMapping() { let r = decode(0,239); XCTAssertEqual(r.monitors!.dropFirst(3).map(\.id), ["catalyst","heatedCatalyst","evaporative","secondaryAir","oxygenSensor","oxygenHeater","egrVVT"]); XCTAssertEqual(r.completedCount, 7) }
    func testCompressionMapping() { let r = decode(8,235); XCTAssertEqual(r.family, .compressionMonitors); XCTAssertEqual(r.monitors!.dropFirst(3).map(\.id), ["nmhcCatalyst","noxSCR","boostPressure","exhaustGasSensor","particulateFilter","egrVVT"]); XCTAssertEqual(r.completedCount, 6) }
    func testNoncontinuousBits() {
        let cases: [(UInt8,[Int])] = [(0,[0,1,2,3,5,6,7]),(8,[0,1,3,5,6,7])]
        for (family,bits) in cases {
            for bit in bits { let r = decode(family,1 << bit,1 << bit); XCTAssertEqual(r.incompleteCount, 1); XCTAssertEqual(r.supportedCount, 1) }
        }
    }
    func testReserved() { let cases: [(UInt8,UInt8,UInt8)] = [(128,0,0),(0,16,16),(8,20,20)]; for (b,c,d) in cases { let r = decode(b,c,d); XCTAssertEqual(r.status, .partial); XCTAssertTrue(r.issues.contains("reservedBitsSet")); XCTAssertEqual(r.supportedCount, 0) } }
    func testUnsupportedStatusUnknown() { let r = decode(16,0,1); XCTAssertEqual(r.monitors?[0].completion, .unknown); XCTAssertEqual(r.monitors?[3].completion, .unknown); XCTAssertEqual(r.incompleteCount, 0); XCTAssertEqual(r.status, .partial) }
    func testNonpositive() {
        let cases: [(RecordedDiagnosticClassification,RecordedReadinessStatus)] = [(.noData,.noData),(.unsupported,.unsupported),(.unknown,.unknown),(.malformed,.malformed),(.negative,.negative)]
        for (classification,status) in cases {
            let r = RecordedReadinessInterpreter.interpret(input(classification: classification, payload: [127,1,17]), schema: .j1979DA2011)
            XCTAssertEqual(r.status, status); XCTAssertNil(r.monitors); XCTAssertNil(r.supportedCount)
        }
    }
    func testUnknownSchema() { let r = RecordedReadinessInterpreter.interpret(input()); XCTAssertEqual(r.status, .unknownSchema); XCTAssertEqual(r.raw, [0,0,0]); XCTAssertNil(r.monitors) }
    func testOtherService() { XCTAssertEqual(RecordedReadinessInterpreter.interpret(input(service: .stored)).status, .notApplicable) }
    func testShape() { let cases: [[UInt8]] = [[],[65,1,0,0,0],[65,1,0,0,0,0,0],[65,65,0,0,0,0],[66,1,0,0,0,0]]; for p in cases { XCTAssertEqual(RecordedReadinessInterpreter.interpret(input(payload:p), schema:.j1979DA2011).status,.malformed) } }
    func testRawConsistency() {
        let good = input()
        let cases: [[UInt8]?] = [nil,[],[0,0],[1,0,0]]
        for raw in cases {
            let forged = RecordedDiagnosticInterpretation(response:good.response,status:.positive,codes:nil,mil:false,storedCount:0,readinessRaw:raw,negativeCode:nil,issue:nil)
            XCTAssertEqual(RecordedReadinessInterpreter.interpret(forged,schema:.j1979DA2011).status,.malformed)
        }
    }
    func testSource() { for ecu in [""," \n",String(repeating:"A",count:257)] { XCTAssertEqual(RecordedReadinessInterpreter.interpret(input(ecu:ecu),schema:.j1979DA2011).status,.malformed) } }
    func testCap() { let r = RecordedReadinessInterpreter.interpret(input(payload:Array(repeating:0,count:1025))); XCTAssertEqual(r.status,.malformed); XCTAssertEqual(r.payload.count,1024); XCTAssertTrue(r.evidenceTruncated) }
    func testProvenance() { let x = input(7,239,128); let r = RecordedReadinessInterpreter.interpret(x,schema:.j1979DA2011); XCTAssertEqual(r.ecu,"ECU-A"); XCTAssertEqual(r.raw,[7,239,128]); XCTAssertEqual(x,input(7,239,128)) }
    func testFixture() { let r = decode(7,239,128); XCTAssertEqual(r.supportedCount,10); XCTAssertEqual(r.completedCount,9); XCTAssertEqual(r.incompleteCount,1) }
}
