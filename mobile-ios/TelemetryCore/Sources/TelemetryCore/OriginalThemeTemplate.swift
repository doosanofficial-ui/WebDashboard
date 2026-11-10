import Foundation

/// Original output-only geometry. No image data, decoder, URL, arbitrary text or dashboard mutation.
/// Pixel coordinates have a top-left origin, positive x right and positive y down.
/// Rectangles use half-open edges. Regions reserve space, not accessible rendering guarantees.
public struct OriginalThemeTemplate: Sendable {
    public struct Region: Encodable, Equatable, Sendable {
        public let role: String
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
        fileprivate init(_ role: String, _ x: Int, _ y: Int, _ width: Int, _ height: Int) {
            self.role=role; self.x=x; self.y=y; self.width=width; self.height=height
        }
    }
    public struct Instruction: Sendable {
        public let key: String
        public let english: String
        public let korean: String
        fileprivate init(_ key: String, _ english: String, _ korean: String) {
            self.key=key; self.english=english; self.korean=korean
        }
    }
    public static let instructions: [Instruction] = [
        .init("theme.template.ownBackground", "Use a background image you own or have permission to use.", "직접 소유하거나 사용 허락을 받은 배경 이미지를 사용하세요."),
        .init("theme.template.keepClear", "Keep the reserved gauge and text areas visually quiet. Do not bake gauge values or labels into the background.", "계기와 글자 예약 영역은 복잡하지 않게 유지하세요. 배경에 계기 값이나 라벨을 넣지 마세요."),
        .init("theme.template.preview", "Review the actual native preview, legibility and contrast before applying. Geometry alone does not establish accessibility.", "적용 전에 실제 앱 미리보기와 가독성, 대비를 확인하세요. 영역 배치만으로 접근성을 보장하지 않습니다."),
        .init("theme.template.shareReview", "Review the exact exported content and its destination before sharing. This specification contains no background image.", "공유 전에 실제 내보낼 내용과 대상을 확인하세요. 이 명세에는 배경 이미지가 없습니다.")
    ]
    public let schemaVersion = 1
    public let width: Int
    public let height: Int
    public let orientation: String
    public let reservedRegions: [Region]
    public let instructionKeys: [String]
    private init(width: Int, height: Int, regions: [Region]) {
        self.width=width; self.height=height
        orientation = width > height ? "landscape" : (height > width ? "portrait" : "square")
        reservedRegions=regions; instructionKeys=Self.instructions.map(\.key)
    }
    public static func make(width: Int, height: Int) -> Self? {
        guard (320...4096).contains(width), (320...4096).contains(height), width <= 4_194_304 / height else { return nil }
        let px=width/20, py=height/20, usable=width-2*(width/20)
        let gauge=(usable-px)/2
        let regions: [Region] = [
            .init("primaryGauge",px,py,gauge,height*3/5),
            .init("secondaryGauge",px+gauge+px,py,gauge,height*3/5),
            .init("statusText",px,height*7/10,usable,height/10),
            .init("footerText",px,height*17/20,usable,height/10)
        ]
        for (i,r) in regions.enumerated() {
            guard r.x >= 0, r.y >= 0, r.width > 0, r.height > 0,
                  r.x+r.width <= width, r.y+r.height <= height else { return nil }
            for b in regions.dropFirst(i+1) {
                guard r.x+r.width <= b.x || b.x+b.width <= r.x || r.y+r.height <= b.y || b.y+b.height <= r.y else { return nil }
            }
        }
        return Self(width: width,height: height,regions: regions)
    }
    private struct Envelope: Encodable {
        let schemaVersion: Int
        let width: Int
        let height: Int
        let orientation: String
        let reservedRegions: [Region]
        let instructionKeys: [String]
        let requiresNativePreview = true
        let requiresUserExportConsent = true
    }
    public enum ExportError: Error { case exceededByteLimit }
    /// Returns neutral local JSON bytes for preview preparation only. Does not share or write files.
    /// There is deliberately no Decodable or arbitrary-template import entry point.
    public func previewSpecificationBytes() throws -> Data {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        let data=try encoder.encode(Envelope(schemaVersion: schemaVersion,width: width,height: height,orientation: orientation,reservedRegions: reservedRegions,instructionKeys: instructionKeys))
        guard data.count <= 4096 else { throw ExportError.exceededByteLimit }
        return data
    }
}
