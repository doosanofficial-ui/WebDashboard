// PROPOSED ONLY: intended TelemetryCore test target; not compiled or integrated.
import XCTest
@testable import TelemetryCore

final class RecordedDiagnosticInterpreterTests: XCTestCase {
    private func read(_ payload: [UInt8], service: RecordedDiagnosticService = .stored,
                      framing: RecordedDiagnosticFraming = .legacy,
                      classification: RecordedDiagnosticClassification = .payload,
                      ecu: String = "ECU-A") -> RecordedDiagnosticInterpretation {
        RecordedDiagnosticInterpreter.interpret(.init(ecu: ecu, service: service, framing: framing,
                                                       classification: classification, payload: payload))
    }
    func testFamiliesAndDigits() {
        XCTAssertEqual(read([0x43,1,0x23,0x45,0x67,0x89,0xAB,0xCD,0xEF]).codes,
                       ["P0123","C0567","B09AB","U0DEF"])
        for n in 0..<16 {
            XCTAssertEqual(read([0x43,UInt8(n * 16 + 1),0x23]).codes,
                           [["P","C","B","U"][n / 4] + String(n % 4) + "123"])
        }
    }
    func testServicesAndExplicitFraming() {
        for s in [RecordedDiagnosticService.stored, .pending, .permanent] {
            XCTAssertEqual(read([s.rawValue + 0x40,1,1,0x23], service:s, framing:.iso15765CAN).codes,["P0123"])
        }
        XCTAssertEqual(read([0x43,1,1,0x23],framing:.legacy).status,.malformed)
    }
    func testPermanentRejectsLegacyPositive() {
        let payloads: [[UInt8]] = [[0x4A,1,2],[0x4A,0,0]]
        for p in payloads {
            let r = read(p,service:.permanent,framing:.legacy)
            XCTAssertEqual(r.status,.malformed); XCTAssertEqual(r.issue,"unsupportedFraming")
            XCTAssertNil(r.codes)
        }
        XCTAssertEqual(read([0x4A,1,1,2],service:.permanent,framing:.iso15765CAN).codes,["P0102"])
        XCTAssertEqual(read([0x4A,0],service:.permanent,framing:.iso15765CAN).codes,[])
    }
    func testPermanentLegacyPreservesClassifiedEvidence() {
        let classifications: [(RecordedDiagnosticClassification,RecordedDiagnosticStatus)] = [
            (.noData,.noData),(.unknown,.unknown),(.unsupported,.unsupported),(.malformed,.malformed)]
        for (classification,status) in classifications {
            let r = read([],service:.permanent,framing:.legacy,classification:classification)
            XCTAssertEqual(r.status,status); XCTAssertNil(r.codes); XCTAssertNil(r.issue)
        }
        let r = read([0x7F,0x0A,0x11],service:.permanent,framing:.legacy,classification:.negative)
        XCTAssertEqual(r.status,.negative); XCTAssertEqual(r.negativeCode,0x11)
        XCTAssertNil(r.codes); XCTAssertNil(r.issue)
    }
    func testZeroVersusMissingEvidence() {
        XCTAssertEqual(read([0x43,0,0]).codes,[])
        XCTAssertEqual(read([0x43,0],framing:.iso15765CAN).codes,[])
        for c in [RecordedDiagnosticClassification.noData,.unknown,.unsupported,.malformed] {
            XCTAssertNil(read([],classification:c).codes)
        }
        XCTAssertEqual(read([],classification:.noData).status,.noData)
        XCTAssertEqual(read([],classification:.unknown).status,.unknown)
        XCTAssertEqual(read([],classification:.unsupported).status,.unsupported)
        XCTAssertEqual(read([],classification:.malformed).status,.malformed)
    }
    func testNegative() {
        let r = read([0x7F,3,0x11],classification:.negative)
        XCTAssertEqual(r.status,.negative); XCTAssertEqual(r.negativeCode,0x11); XCTAssertNil(r.codes)
        for p: [UInt8] in [[0x7F,7,0x11],[0x7F,3],[0x43,3,0x11]] {
            XCTAssertEqual(read(p,classification:.negative).status,.malformed)
        }
    }
    func testMalformedPayloads() {
        let cases: [([UInt8],RecordedDiagnosticFraming)] = [
            ([],.legacy),([0x43],.legacy),([0x43,1],.legacy),([0x47,1,2],.legacy),
            ([0x43,0,0,1,2],.legacy),([0x43],.iso15765CAN),([0x43,2,1,2],.iso15765CAN),
            ([0x43,0,1,2],.iso15765CAN),([0x43,1,0,0],.iso15765CAN),
            ([0x43,1,1,2,0],.iso15765CAN),([0x43,1,1,2,3,4],.iso15765CAN)]
        for (p,f) in cases { let r = read(p,framing:f); XCTAssertEqual(r.status,.malformed); XCTAssertNil(r.codes) }
    }
    func testPaddingAndDuplicates() {
        XCTAssertEqual(read([0x43,1,1,2,0,0],framing:.iso15765CAN).codes,["P0102"])
        XCTAssertEqual(read([0x43,1,2,1,2]).codes,["P0102","P0102"])
    }
    func testMIL() {
        let r = read([0x41,1,0x81,7,0x65,4],service:.monitorStatus)
        XCTAssertEqual(r.mil,true); XCTAssertEqual(r.storedCount,1)
        XCTAssertEqual(r.readinessRaw,[7,0x65,4]); XCTAssertNil(r.codes)
        for a: UInt8 in [0,127,128,255] {
            let r = read([0x41,1,a,0,0,0],service:.monitorStatus)
            XCTAssertEqual(r.mil,a & 128 != 0); XCTAssertEqual(r.storedCount,Int(a & 127))
        }
        for p: [UInt8] in [[0x41,1,0],[0x41,2,0,0,0,0],[0x41,1,0,0,0,0,0]] {
            XCTAssertEqual(read(p,service:.monitorStatus).status,.malformed)
        }
    }
    func testSourcesRemainSeparate() {
        let a = read([0x43,1,2],ecu:"7E8"), b = read([0x43,0,0],ecu:"7E9")
        XCTAssertEqual(a.response.ecu,"7E8"); XCTAssertEqual(b.response.ecu,"7E9")
        XCTAssertEqual(a.codes,["P0102"]); XCTAssertEqual(b.codes,[])
        XCTAssertEqual(read([0x43,0,0],ecu:" ").status,.malformed)
    }
}
