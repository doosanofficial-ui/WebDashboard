import XCTest
import SwiftUI
import UIKit
import Vision
import TelemetryCore
@testable import TelemetryLifecycleHost

@MainActor
final class ConceptPresentationHostedTests: XCTestCase {
    func testMetricReadsNameThenValueThenQualityAtEveryReadingSize() throws {
        for size in [DynamicTypeSize.large, .xxxLarge, .accessibility5] {
            let content = TelemetryMetricCard(label: "BATTERY", value: "1234.5", unit: "%", state: "STALE", accent: .cyan)
                .frame(width: 343).fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, size).preferredColorScheme(.dark)
            let host = UIHostingController(rootView: content)
            let measured = host.sizeThatFits(in: CGSize(width: 343, height: 2000))
            // A full UIKit viewport reserves system safe areas; the card stays intrinsic.
            let window = UIWindow(frame: CGRect(x: 0, y: 0, width: measured.width, height: measured.height + 200))
            window.rootViewController = host; window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image); attachment.name = "SYNTHETIC-concept-metric-\(size)"
            attachment.lifetime = .keepAlways; add(attachment)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
            let observations = request.results ?? []
            let diagnostic = XCTAttachment(string: observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " | "))
            diagnostic.name = "concept-reading-OCR-\(size)"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            func box(_ text: String) throws -> CGRect {
                try XCTUnwrap(observations.first { $0.topCandidates(1).first?.string.uppercased().contains(text) == true }?.boundingBox)
            }
            let name = try box("BATTERY"); let value = try box("1234.5"); let quality = try box("STALE")
            XCTAssertGreaterThan(name.minY, value.maxY, "Name must precede the measurement at \(size)")
            XCTAssertGreaterThan(value.minY, quality.maxY, "Quality must follow the measurement at \(size)")
        }
    }
    func testLongRecordedTitleRemainsReadableOnSmallPhone() throws {
        for size in [DynamicTypeSize.large, .accessibility5] {
            let content = RecordedHistoryCard(title: "Recorded battery energy and wheel speed analysis") {
                Color.cyan.frame(height: 24)
            } summary: {
                Text("Recorded samples: 2")
            } details: {
                Text("Original measurements")
            }
            .frame(width: 320).fixedSize(horizontal: false, vertical: true)
            .environment(\.dynamicTypeSize, size).preferredColorScheme(.dark)
            let renderer = ImageRenderer(content: content); renderer.scale = 2
            let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image); attachment.name = "SYNTHETIC-long-recorded-title-\(size)"
            attachment.lifetime = .keepAlways; add(attachment)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = true
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            XCTAssertTrue(text.contains("WHEEL SPEED ANALYSIS"), "Recorded title must not truncate its identity: \(text)")
            XCTAssertTrue(text.contains("RECORDED SAMPLES"), "Summary must remain below the plot: \(text)")
        }
    }

    func testRecordingIsThePrimaryIdleAction() throws {
        let model = TelemetryModel.shared
        guard !model.localRecordingEnabled, !model.collecting, model.replayController.sessionID == nil else {
            throw XCTSkip("Primary action fixture requires an idle disposable Simulator")
        }
        let oldMode = model.runMode; defer { model.runMode = oldMode }; model.runMode = .live
        let cockpit = LiveCockpitView(model: model, editorPresented: .constant(false), selectedPageID: .constant(nil))
        let renderer = ImageRenderer(content: cockpit.recordingSessionBar().frame(width: 343).preferredColorScheme(.dark))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage); let cg = try XCTUnwrap(image.cgImage)
        let attachment = XCTAttachment(image: image); attachment.name = "SYNTHETIC-primary-record-action"
        attachment.lifetime = .keepAlways; add(attachment)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        let cyan = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0] < 120 && pixels[$0+1] > 140 && pixels[$0+2] > 170 }.count
        XCTAssertGreaterThan(cyan, 10_000, "Recording needs a filled primary accent action; Mark remains secondary")
    }

    func testReplayHeaderKeepsStorageFailureVisible() throws {
        let model = TelemetryModel.shared
        guard !model.localRecordingEnabled, !model.collecting, model.replayController.sessionID == nil else {
            throw XCTSkip("Storage warning fixture requires an idle disposable Simulator")
        }
        let previous = (model.runMode, model.storageStatus)
        defer { model.runMode = previous.0; model.storageStatus = previous.1 }
        model.runMode = .replay; model.storageStatus = "STORAGE FIXTURE FAILURE"
        for size in [DynamicTypeSize.large, .accessibility5] {
            let renderer = ImageRenderer(content: SessionsView(model: model).replayHeader()
                .frame(width: 343).fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, size).preferredColorScheme(.dark))
            renderer.scale = 2; let image = try XCTUnwrap(renderer.uiImage)
            let attachment = XCTAttachment(image: image); attachment.name = "SYNTHETIC-replay-storage-fault-\(size)"
            attachment.lifetime = .keepAlways; add(attachment)
            let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: XCTUnwrap(image.cgImage), options: [:]).perform([request])
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            XCTAssertTrue(text.contains("STORAGE FIXTURE FAILURE"), "Replay must retain the actual storage error: \(text)")
        }
    }

}
