import XCTest
@testable import TelemetryCore

// UNRUN: compiling and executing Swift are explicitly deferred.
final class Mode01SupportPageTests: XCTestCase {
    typealias P = Mode01SupportPage
    func context(vehicle: String = "vehicle-local", adapter: String = "adapter", session: String = "session",
                 generation: String = "generation", variant: P.ProtocolVariant = .can11_500,
                 request: UInt32 = 0x7E0, response: UInt32 = 0x7E8) throws -> P.Context {
        try P.Context(vehicle: vehicle, adapter: adapter, session: session, generation: generation,
                      protocolVariant: variant, requestCANID: request, responseCANID: response)
    }
    func page(_ page: UInt8 = 0, mask: UInt32 = 0x80000001, observed: P.Context? = nil,
              origin: P.Origin = .vehicle) throws -> P.Evidence {
        let c = try context()
        return try P.decode(expected: c, observed: observed ?? c, page: page,
            positivePDU: [0x41,page,UInt8(truncatingIfNeeded: mask >> 24),UInt8(truncatingIfNeeded: mask >> 16),UInt8(truncatingIfNeeded: mask >> 8),UInt8(truncatingIfNeeded: mask)], origin: origin)
    }
    func testEveryBitEveryPage() throws {
        let c = try context()
        for base in stride(from: 0, through: 0xC0, by: 32) {
            for offset in 1...32 {
                let e = try page(UInt8(base), mask: UInt32(1) << (32-offset))
                for candidate in 1...32 {
                    let a = P.assess(e, current: c, pid: UInt8(base+candidate), isCandidate: true, availability: .unknown)
                    XCTAssertEqual(a.observedSupport, offset == candidate ? .supported : .unsupported)
                    XCTAssertTrue(a.isCandidate); XCTAssertEqual(a.currentAvailability, .unknown)
                }
            }
        }
    }
    func testUnknownCandidateAndAvailabilityAreSeparate() throws {
        let c = try context()
        let absent = P.assess(nil, current: c, pid: 4, isCandidate: true, availability: .noData)
        XCTAssertEqual(absent.observedSupport, .unknown); XCTAssertTrue(absent.isCandidate); XCTAssertEqual(absent.currentAvailability, .noData)
        let timed = P.assess(try page(), current: c, pid: 1, isCandidate: false, availability: .timedOut)
        XCTAssertEqual(timed.observedSupport, .supported); XCTAssertFalse(timed.isCandidate); XCTAssertEqual(timed.currentAvailability, .timedOut)
        for pid in [UInt8(0),33] { XCTAssertEqual(P.assess(try page(), current: c, pid: pid, isCandidate: true, availability: .unknown).observedSupport, .unknown) }
    }
    func testExactContext() throws {
        let variants = try [context(vehicle: "other"),context(adapter: "other"),context(session: "other"),context(generation: "other"),context(variant: .can11_250),context(request: 0x7E1),context(response: 0x7E9)]
        for c in variants {
            XCTAssertThrowsError(try page(observed: c))
            XCTAssertEqual(P.assess(try page(), current: c, pid: 1, isCandidate: true, availability: .unknown).observedSupport,.unknown)
            XCTAssertThrowsError(try P.plan([page()], current: c, maximumPages: 7))
        }
    }
    func testContextValidation() throws {
        XCTAssertThrowsError(try context(vehicle: "")); XCTAssertThrowsError(try context(adapter: ""))
        XCTAssertThrowsError(try context(session: " ")); XCTAssertThrowsError(try context(generation: ""))
        XCTAssertThrowsError(try context(response: 0x800)); XCTAssertThrowsError(try context(request: 0x800))
        let c = try context(variant: .can29_250, request: 0x18DA10F1, response: 0x18DAF110)
        XCTAssertEqual(try P.decode(expected: c, observed: c, page: 0, positivePDU: [0x41,0,0x80,0,0,0], origin: .synthetic).origin, .synthetic)
        XCTAssertThrowsError(try context(variant: .can29_250, response: 0x20000000))
    }
    func testFramingServicePIDAndLength() throws {
        let c = try context()
        let malformed: [[UInt8]] = [[],Array("NO DATA".utf8),[0x7F,1,0x12],[0x41,0,0x80,0,0],[0x41,0,0x80,0,0,0,0],[6,0x41,0,0x80,0,0,0,0],[0x42,0,0x80,0,0,0],[0x41,0x20,0x80,0,0,0],[0x41,0,0x80,0,0,0,0x41,0,0x80,0,0,0]]
        for raw in malformed {
            XCTAssertThrowsError(try P.decode(expected: c, observed: c, page: 0, positivePDU: raw, origin: .vehicle))
        }
        for pid in [UInt8(1),0xE0,0xFF] { XCTAssertThrowsError(try page(pid)) }
    }
    func testTerminalDoesNotInferOtherPages() throws {
        let c = try context(), e = try page(mask: 0)
        let p = try P.plan([e], current: c, maximumPages: 7)
        XCTAssertNil(p.nextCandidatePage); XCTAssertEqual(p.reason,.terminal)
        XCTAssertEqual(P.assess(e,current:c,pid:33,isCandidate:true,availability:.unknown).observedSupport,.unknown)
    }
    func testBoundedPlan() throws {
        let c = try context()
        XCTAssertEqual(try P.plan([],current:c,maximumPages:7).nextCandidatePage,0)
        XCTAssertEqual(try P.plan([page()],current:c,maximumPages:7).nextCandidatePage,32)
        let limited = try P.plan([page()],current:c,maximumPages:1)
        XCTAssertNil(limited.nextCandidatePage); XCTAssertEqual(limited.reason,.budget)
        let chain = try stride(from:0,through:0xC0,by:32).map { try page(UInt8($0),mask:1) }
        let boundary = try P.plan(chain,current:c,maximumPages:7)
        XCTAssertNil(boundary.nextCandidatePage); XCTAssertEqual(boundary.reason,.variantBoundary)
        for budget in [-1,0,8] { XCTAssertThrowsError(try P.plan([],current:c,maximumPages:budget)) }
    }
    func testInvalidChainAndSyntheticDoesNotAdmit() throws {
        let c = try context()
        for chain in try [[page(32)],[page(),page()],[page(mask:0),page(32)],[page(),page(64)]] {
            XCTAssertThrowsError(try P.plan(chain,current:c,maximumPages:7))
        }
        let e = try page(origin:.synthetic)
        XCTAssertEqual(P.assess(e,current:c,pid:1,isCandidate:true,availability:.unknown).observedSupport,.unknown)
        XCTAssertThrowsError(try P.plan([e],current:c,maximumPages:7))
    }
}
