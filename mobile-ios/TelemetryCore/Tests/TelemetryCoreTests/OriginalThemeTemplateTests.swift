import Foundation
import XCTest
@testable import TelemetryCore

final class OriginalThemeTemplateTests: XCTestCase {
    func testOrientationsAndVersion() throws {
        for (w,h,o) in [(1200,800,"landscape"),(800,1200,"portrait"),(800,800,"square")] {
            let s = try XCTUnwrap(OriginalThemeTemplate.make(width: w, height: h))
            XCTAssertEqual(s.orientation, o)
            XCTAssertEqual(s.schemaVersion, 1)
        }
    }
    func testDimensionLimits() {
        for (w,h) in [(319,800),(800,319),(4097,800),(800,4097),(4096,4096),(-1,800),(Int.max,800)] {
            XCTAssertNil(OriginalThemeTemplate.make(width: w, height: h))
        }
        XCTAssertNotNil(OriginalThemeTemplate.make(width: 320, height: 320))
        XCTAssertNotNil(OriginalThemeTemplate.make(width: 4096, height: 1024))
    }
    func testGeometryAndSeparation() throws {
        for (w,h) in [(320,320),(1200,800),(800,1200),(4096,1024),(1024,4096)] {
            let s = try XCTUnwrap(OriginalThemeTemplate.make(width: w, height: h))
            XCTAssertEqual(s.reservedRegions.map(\.role), ["primaryGauge","secondaryGauge","statusText","footerText"])
            for (i,r) in s.reservedRegions.enumerated() {
                XCTAssertGreaterThanOrEqual(r.x, 0); XCTAssertGreaterThanOrEqual(r.y, 0)
                XCTAssertGreaterThan(r.width, 0); XCTAssertGreaterThan(r.height, 0)
                XCTAssertLessThanOrEqual(r.x+r.width,w); XCTAssertLessThanOrEqual(r.y+r.height,h)
                for b in s.reservedRegions.dropFirst(i+1) {
                    XCTAssertTrue(r.x+r.width <= b.x || b.x+b.width <= r.x || r.y+r.height <= b.y || b.y+b.height <= r.y)
                }
            }
        }
    }
    func testOriginalCoordinates() throws {
        let s = try XCTUnwrap(OriginalThemeTemplate.make(width: 1200, height: 800))
        let r = try XCTUnwrap(s.reservedRegions.first)
        XCTAssertEqual(r.x,60); XCTAssertEqual(r.y,40)
        XCTAssertEqual(r.width,510); XCTAssertEqual(r.height,480)
    }
    func testBoundedOutputOnlyEnvelope() throws {
        let s = try XCTUnwrap(OriginalThemeTemplate.make(width: 1200, height: 800))
        let bytes = try s.previewSpecificationBytes()
        XCTAssertLessThanOrEqual(bytes.count,4096)
        XCTAssertEqual(bytes,try s.previewSpecificationBytes())
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: bytes) as? [String:Any])
        XCTAssertEqual(Set(object.keys),Set(["schemaVersion","width","height","orientation","reservedRegions","instructionKeys","requiresNativePreview","requiresUserExportConsent"]))
        XCTAssertEqual(object["requiresNativePreview"] as? Bool,true)
        XCTAssertEqual(object["requiresUserExportConsent"] as? Bool,true)
        XCTAssertEqual(s.instructionKeys,["theme.template.ownBackground","theme.template.keepClear","theme.template.preview","theme.template.shareReview"])
        XCTAssertEqual(OriginalThemeTemplate.instructions.count,4)
        XCTAssertTrue(OriginalThemeTemplate.instructions.allSatisfy { !$0.english.isEmpty && !$0.korean.isEmpty })
    }
}
