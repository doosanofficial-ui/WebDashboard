import Foundation
import XCTest
import SwiftUI
import UIKit
import Vision
import TelemetryCore
@testable import TelemetryLifecycleHost

@MainActor
final class WidgetPresentationHostedTests: XCTestCase {

    func testWidthCancellationCachesNewGeometryEvenWhenRowHeightDoesNotChange() throws {
        let active = DashboardWidgetDefinition(id: "active", type: .numericGauge, signalID: nil,
            rect: .init(x: 0, y: 0, width: 2, height: 1), zIndex: 0,
            configuration: .init(label: "Active", unit: "%", decimals: 1, minimum: nil, maximum: nil,
                                 warningThreshold: nil, criticalThreshold: nil))
        let page = DashboardPage(id: "page", name: "Page", orientation: .landscape, widgets: [active])
        var viewport = DashboardEditorViewport(); var draft: DashboardEditDraft?
        viewport.observe(.init(width: 360, height: 960), draft: &draft)
        draft = try XCTUnwrap(DashboardEditDraft(profileID: "profile", page: page, widgetID: active.id,
                                                operation: .move, geometry: viewport.geometry(columns: 6, rows: 4)))
        draft?.update(translationX: 60, translationY: 0)
        viewport.observe(.init(width: 720, height: 960), draft: &draft)
        XCTAssertTrue(draft?.isCancelled == true); XCTAssertNil(draft?.releaseRect)
        XCTAssertEqual(viewport.size.width, 720, "A cancelled gesture may not receive another geometry event")
        draft = nil
        // Same content-driven row height, no second observe event after cancellation.
        draft = try XCTUnwrap(DashboardEditDraft(profileID: "profile", page: page, widgetID: active.id,
                                                operation: .move, geometry: viewport.geometry(columns: 6, rows: 4)))
        draft?.update(translationX: 120, translationY: 240)
        XCTAssertEqual(draft?.releaseRect, .init(x: 1, y: 1, width: 2, height: 1))
    }

    func testMagneticOverlayDrawsGuideAtCardEdgeAndOrangeCollisionPreview() throws {
        let neighbor = DashboardWidgetDefinition(id: "neighbor", type: .numericGauge, signalID: nil,
            rect: .init(x: 2, y: 0, width: 2, height: 1), zIndex: 0,
            configuration: .init(label: "Neighbor", unit: "%", decimals: 1, minimum: nil,
                                 maximum: nil, warningThreshold: nil, criticalThreshold: nil))
        let geometry = DashboardSnapGeometry(columnWidth: 60, rowHeight: 120)
        let result = DashboardMagneticSnap.preview(original: .init(x: 0, y: 0, width: 2, height: 1),
            proposed: .init(x: 2.05, y: 0, width: 2, height: 1), neighbors: [neighbor], operation: .move, geometry: geometry)
        XCTAssertEqual(result.overlappingWidgetIDs, ["neighbor"])
        let renderer = ImageRenderer(content: DashboardSnapOverlay(result: result, geometry: geometry)
            .frame(width: 360, height: 240).background(.black))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage); let cg = try XCTUnwrap(image.cgImage)
        let attachment = XCTAttachment(image: image); attachment.name = "SYNTHETIC-magnetic-guide-collision"
        attachment.lifetime = .keepAlways; add(attachment)
        var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: cg.width, height: cg.height,
            bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        var edgeCyan = 0; var orange = 0
        for y in 0..<cg.height { for x in 0..<cg.width {
            let i = (y * cg.width + x) * 4; let red = pixels[i]; let green = pixels[i + 1]; let blue = pixels[i + 2]
            if abs(x - 248) <= 3 && red < 120 && green > 140 && blue > 180 { edgeCyan += 1 }
            if red > 180 && green > 60 && green < 200 && blue < 90 { orange += 1 }
        } }
        XCTAssertGreaterThan(edgeCyan, 150, "Guide must use the measured leading card edge, including its 4pt gutter")
        XCTAssertGreaterThan(orange, 100, "Active collision preview must remain visibly orange")
    }

    func testShortLandscapeCellsKeepEveryNumericCardVisibleInPortrait() throws {
        try assertNumericGrid(editor: false)
    }
    func testEditorKeepsEveryNumericValueVisibleAtNormalAndAccessibilitySizes() throws {
        try assertNumericGrid(editor: true)
    }
    private func assertNumericGrid(editor: Bool) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Grid fixture must not mutate a physical-device model")
        #endif
        let model = TelemetryModel.shared
        guard !model.localRecordingEnabled, !model.collecting, model.replayController.sessionID == nil else {
            throw XCTSkip("Grid fixture requires an idle disposable Simulator")
        }
        let previous = (model.runMode, model.frame, model.lastFrameAt,
                        model.localSignalReceivedAt, model.localSignalTimeouts)
        defer {
            model.runMode = previous.0; model.frame = previous.1; model.lastFrameAt = previous.2
            model.localSignalReceivedAt = previous.3; model.localSignalTimeouts = previous.4
        }
        let now = Date()
        let names = ["ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX"]
        let numbers = ["11.1", "22.2", "33.3", "44.4", "55.5", "66.6"]
        let definitions = names.enumerated().map { index, name in
            DashboardWidgetDefinition(id: name, type: .numericGauge, signalID: name,
                rect: .init(x: (index % 3) * 2, y: index / 3, width: 2, height: 1), zIndex: index,
                configuration: .init(label: name, unit: "km/h", decimals: 1,
                    minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil))
        }
        let page = DashboardPage(id: "synthetic-short-grid", name: "Short grid", orientation: .landscape, widgets: definitions)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        let original = try encoder.encode(page)
        model.runMode = .live
        model.frame = try ServerCANFrame(version: 1, serverTimestamp: now.timeIntervalSince1970,
            signals: Dictionary(uniqueKeysWithValues: zip(names, numbers.map { Double($0)! })),
            status: .init(sequence: 1, drop: 0))
        model.lastFrameAt = now
        model.localSignalReceivedAt = Dictionary(uniqueKeysWithValues: names.map { ($0, now.timeIntervalSince1970) })
        model.localSignalTimeouts = Dictionary(uniqueKeysWithValues: names.map { ($0, 1.5) })
        let cockpit = LiveCockpitView(model: model, editorPresented: .constant(false), selectedPageID: .constant(nil))
        for size in (editor ? [DynamicTypeSize.large, .xxxLarge, .accessibility5] : [.large, .xxxLarge]) {
            let canvas = editor
                ? AnyView(DashboardEditorCanvas(model: model, page: page, selectedWidgetID: .constant(nil)))
                : AnyView(cockpit.dashboardGrid(page, now: now))
            let content = canvas
                .frame(width: 343).fixedSize(horizontal: false, vertical: true)
                .environment(\.dynamicTypeSize, size).preferredColorScheme(.dark)
            // ImageRenderer omits the production numeric card's horizontal
            // ScrollView fallback. Host the real view so its UIKit descendants
            // materialize; never replace the card or shorten its measurement.
            let host = UIHostingController(rootView: content)
            let measured = host.sizeThatFits(in: CGSize(width: 343, height: 2000))
            let window = UIWindow(frame: CGRect(origin: .zero, size: measured))
            window.rootViewController = host; window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "SYNTHETIC-\(editor ? "editor" : "live")-short-grid-\(size)"
            attachment.lifetime = .keepAlways; add(attachment)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage), options: [:]).perform([request])
            let observations = request.results ?? []
            let labels = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            let diagnostic = XCTAttachment(string: labels)
            diagnostic.name = "short-grid-OCR-\(size)"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            for index in names.indices {
                XCTAssertTrue(labels.contains(names[index]), "Card label must remain visible at \(size): \(labels)")
                XCTAssertTrue(labels.contains(numbers[index]), "Card value must remain visible at \(size): \(labels)")
            }
            for column in 0..<3 {
                if let topValue = observations.first(where: { $0.topCandidates(1).first?.string.contains(numbers[column]) == true }),
                   let nextLabel = observations.first(where: { $0.topCandidates(1).first?.string.uppercased().contains(names[column + 3]) == true }) {
                    // Vision uses bottom-left coordinates: all of the first row's
                    // value must be above the following row's label.
                    XCTAssertGreaterThan(topValue.boundingBox.minY, nextLabel.boundingBox.maxY,
                        "Row content must not cross into its successor at \(size)")
                }
            }
        }
        XCTAssertEqual(try encoder.encode(page), original, "Rendering must preserve stored geometry")
    }


    func testShortRecordedGraphExposesMinimumHeightToGrid() async throws {
        try await assertShortRecordedHistoryGrid(type: .timeSeries)
    }

    func testShortRecordedRouteExposesMinimumHeightToGrid() async throws {
        try await assertShortRecordedHistoryGrid(type: .map)
    }

    private func assertShortRecordedHistoryGrid(type: DashboardWidgetType) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recorded grid fixture is Simulator-only")
        #endif
        let model = TelemetryModel.shared
        guard !model.localRecordingEnabled, !model.collecting, model.replayController.sessionID == nil else {
            throw XCTSkip("Recorded grid fixture requires an idle disposable Simulator")
        }
        let oldMode = model.runMode
        defer { model.replayController.stop(); model.runMode = oldMode }
        var rows: [PersistedMeasurement] = []
        for index in 1...2 {
            let signal = DecodedSignalSample(signalID: "short-grid", value: Double(index * 10), rawValue: UInt64(index),
                enumName: nil, unit: "%", frameSequence: UInt64(index), receivedAtEpoch: 100 + Double(index),
                receivedAtMonotonicNanos: UInt64(index) * 1_000_000_000)
            rows.append(.init(sequence: Int64(index * 2 - 1), sessionID: "short-history", kind: "SIGNAL",
                sourceTimestamp: signal.receivedAtEpoch, receivedAtEpoch: signal.receivedAtEpoch,
                receivedAtMonotonicNanos: signal.receivedAtMonotonicNanos,
                payloadJSON: String(decoding: try JSONEncoder().encode(signal), as: UTF8.self)))
            let location = LocationSample(originalTimestamp: 100 + Double(index), receivedAtEpoch: 100 + Double(index),
                receivedAtMonotonicNanos: UInt64(index) * 1_000_000_000, latitude: Double(index) * 0.001,
                longitude: Double(index) * 0.001, altitude: nil, speed: nil, course: nil,
                horizontalAccuracy: nil, verticalAccuracy: nil, source: .demo)
            rows.append(.init(sequence: Int64(index * 2), sessionID: "short-history", kind: "LOCATION",
                sourceTimestamp: location.originalTimestamp, receivedAtEpoch: location.receivedAtEpoch,
                receivedAtMonotonicNanos: location.receivedAtMonotonicNanos,
                payloadJSON: String(decoding: try JSONEncoder().encode(location), as: UTF8.self)))
        }
        _ = try await model.replayController.load(sessionID: "short-history") {
            MeasurementExport(session: .init(sessionID: "short-history", startedAt: 100, endedAt: 102, mode: .demo),
                              measurements: rows)
        }
        model.runMode = .replay
        let configuration = DashboardWidgetConfiguration(label: type == .map ? "ROUTE" : "GRAPH", unit: "%",
            decimals: 1, minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil)
        let history = DashboardWidgetDefinition(id: "short-history-card", type: type,
            signalID: type == .map ? nil : "short-grid", rect: .init(x: 0, y: 0, width: 6, height: 1),
            zIndex: 0, configuration: configuration)
        let following = DashboardWidgetDefinition(id: "following-card", type: .numericGauge, signalID: nil,
            rect: .init(x: 0, y: 1, width: 6, height: 1), zIndex: 1,
            configuration: .init(label: "FOLLOWING", unit: "%", decimals: 1, minimum: nil,
                                 maximum: nil, warningThreshold: nil, criticalThreshold: nil))
        let page = DashboardPage(id: "short-history-grid", name: "Synthetic", orientation: .landscape,
                                 widgets: [history, following])
        let cockpit = LiveCockpitView(model: model, editorPresented: .constant(false), selectedPageID: .constant(nil))
        for size in [DynamicTypeSize.large, .xxxLarge] {
            let view = cockpit.dashboardGrid(page, now: Date()).frame(width: 360)
                .fixedSize(horizontal: false, vertical: true).dynamicTypeSize(size).preferredColorScheme(.dark)
            let host = UIHostingController(rootView: view)
            let measured = host.sizeThatFits(in: CGSize(width: 360, height: 3000))
            let window = UIWindow(frame: CGRect(origin: .zero, size: measured))
            window.rootViewController = host; window.isHidden = false
            defer { window.isHidden = true }
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            let format = UIGraphicsImageRendererFormat(); format.scale = 2
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
                XCTAssertTrue(host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true))
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "SYNTHETIC-short-\(type.rawValue)-grid-\(size)"
            attachment.lifetime = .keepAlways; add(attachment)
            let cg = try XCTUnwrap(image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
            let observations = request.results ?? []
            let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            let suffix = type == .map ? "FIXES:2" : "SAMPLES:2"
            XCTAssertTrue(text.filter { !$0.isWhitespace }.contains(suffix),
                          "Count must remain readable even when its label wraps at \(size): \(text)")
            let footer = type == .map ? "NOT CURRENT POSITION" : "HISTORICAL FRESHNESS UNKNOWN"
            XCTAssertTrue(text.contains(footer), "Full history footer must remain visible at \(size): \(text)")
            let fontCategory: UIContentSizeCategory = size == .large ? .large : .extraExtraExtraLarge
            let fontSize = UIFont.preferredFont(forTextStyle: .caption2,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: fontCategory)).pointSize
            if let line = observations.first(where: {
                let value = $0.topCandidates(1).first?.string.uppercased() ?? ""
                return type == .map ? value.contains("NOT CURRENT") : value.contains("HISTORICAL")
            }) {
                XCTAssertGreaterThanOrEqual(CGFloat(line.boundingBox.height) * image.size.height, fontSize * 0.6,
                    "Footer glyphs cannot be partly covered by the next card at \(size)")
            }
            XCTAssertTrue(text.contains("FOLLOWING"), text)
            if let count = observations.first(where: { $0.topCandidates(1).first?.string.uppercased().contains(type == .map ? "FIXES" : "SAMPLES") == true }),
               let next = observations.first(where: { $0.topCandidates(1).first?.string.uppercased().contains("FOLLOWING") == true }) {
                XCTAssertGreaterThan(count.boundingBox.minY, next.boundingBox.maxY,
                                     "History summary cannot paint into the next row at \(size)")
            }
            var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try bytes.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4,
                    space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)); context.flush()
            }
            let cyan = stride(from: 0, to: bytes.count, by: 4).filter {
                bytes[$0] < 100 && bytes[$0 + 1] > 140 && bytes[$0 + 2] > 160 && bytes[$0 + 3] > 200
            }.count
            XCTAssertGreaterThan(cyan, 8, "Recorded plot must stay visible at \(size)")
            let diagnostic = XCTAttachment(string: "Canvas \(measured.width)x\(measured.height)pt, cyan=\(cyan), OCR=\(text)")
            diagnostic.name = "short-history-grid-geometry-\(type.rawValue)-\(size)"
            diagnostic.lifetime = .keepAlways; add(diagnostic)
        }
        XCTAssertEqual(page.widgets.map(\.rect), [history.rect, following.rect], "No saved reflow")
    }

    private func renderLabels(value: Double?, replay: Bool = false, quality: SignalQuality = .valid,
                              freshness: MeasurementReplay.SignalFreshness = .unknown, expectedGreen: Bool = false) throws -> String {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Display fixture must not mutate a physical-device model")
        #endif
        let model = TelemetryModel.shared
        guard !model.localRecordingEnabled, !model.collecting, !model.replayController.isPlaying else {
            throw XCTSkip("Display fixture requires an idle disposable Simulator host")
        }
        let previous = (model.runMode, model.frame, model.lastFrameAt, model.dashboardProfile,
                        model.adapterStatus, model.localSignalReceivedAt, model.localSignalTimeouts,
                        model.replaySignalQuality, model.replaySignalFreshness, model.lastLocation)
        defer {
            model.runMode = previous.0; model.frame = previous.1; model.lastFrameAt = previous.2
            model.dashboardProfile = previous.3; model.adapterStatus = previous.4
            model.localSignalReceivedAt = previous.5; model.localSignalTimeouts = previous.6
            model.replaySignalQuality = previous.7; model.replaySignalFreshness = previous.8
            model.lastLocation = previous.9
        }
        let now = Date()
        var signals = ["other": 49.0]
        if let value { signals["target"] = value }
        model.runMode = replay ? .replay : .live
        model.frame = try ServerCANFrame(version: 1, serverTimestamp: now.timeIntervalSince1970,
            signals: signals, status: .init(sequence: 1, drop: 0))
        model.lastFrameAt = now
        model.adapterStatus = "Live adapter monitoring"
        // The other signal is fresh. Target has no metadata: the existing caller
        // falls back to whole-frame freshness, reproducing the false VALID path.
        model.localSignalReceivedAt = ["other": now.timeIntervalSince1970]
        model.localSignalTimeouts = ["other": 1.5]
        model.replaySignalQuality = !replay || value == nil ? [:] : ["target": quality]
        model.replaySignalFreshness = !replay || value == nil ? [:] : ["target": freshness]
        model.lastLocation = nil
        let widgets: [DashboardWidgetType] = [.numericGauge, .statusIcon, .led]
        let definitions = widgets.enumerated().map { index, type in
            DashboardWidgetDefinition(id: "presentation-\(index)", type: type, signalID: "target",
                rect: DashboardRect(x: index < 2 ? index * 2 : 0, y: index < 2 ? 0 : 2,
                    width: index < 2 ? 2 : 4, height: index < 2 ? 2 : 1), zIndex: index,
                configuration: DashboardWidgetConfiguration(label: ["Numeric target", "Status target", "LED target"][index],
                    unit: "%", decimals: 1, minimum: 0, maximum: 100,
                    warningThreshold: nil, criticalThreshold: nil))
        }
        model.dashboardProfile = try DashboardProfile(id: "render-fixture", name: "Widget state fixture",
            pages: [.init(id: "page", name: "Fixture", orientation: .portrait, widgets: definitions)])
        let cockpit = LiveCockpitView(model: model, editorPresented: .constant(false), selectedPageID: .constant(nil))
        // ImageRenderer does not materialize ScrollView/LazyVStack descendants.
        // Call the real production widget factory, including its freshness fallback,
        // in an eager container instead of reproducing presentation logic here.
        let content = VStack(spacing: 12) {
            Text("SIMULATOR FIXTURE · no vehicle acquisition").font(.caption)
            ForEach(definitions) { definition in
                cockpit.dashboardWidget(definition, now: now).frame(height: 170)
            }
        }.padding(16).frame(width: 402).preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: content); renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage, "Production SwiftUI widget rendering must succeed")
        // Replay cards use green only for the status icon; a live numeric VALID
        // label may also be green. Negative cases catch false validity pixels,
        // while the live-zero case checks that valid presentation remains visible.
        // Verify actual production pixels, not a duplicate Boolean policy.
        let cgImage = try XCTUnwrap(image.cgImage)
        var pixels = [UInt8](repeating: 0, count: cgImage.width * cgImage.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cgImage.width, height: cgImage.height,
                bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                space: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB)),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
            context.flush()
        }
        let greenCount = stride(from: 0, to: pixels.count, by: 4).filter {
            pixels[$0] < 130 && pixels[$0 + 1] > 170 && pixels[$0 + 2] < 190 && pixels[$0 + 3] > 200
        }.count
        if (greenCount > 20) != expectedGreen {
            let opaque = stride(from: 0, to: pixels.count, by: 4).filter { pixels[$0 + 3] > 200 }.count
            let description = "Explicit sRGB RGBA raster: green=\(greenCount), opaque=\(opaque), bitmap=\(cgImage.bitmapInfo.rawValue), sourceBits=\(cgImage.bitsPerComponent), dimensions=\(cgImage.width)x\(cgImage.height)"
            let diagnostic = XCTAttachment(string: description)
            diagnostic.name = "renderer-pixel-boundary-diagnostic"; diagnostic.lifetime = .keepAlways; add(diagnostic)
        }
        XCTAssertEqual(greenCount > 20, expectedGreen, "Green validity must match quality and freshness; green pixels=\(greenCount)")
        let attachment = XCTAttachment(image: image)
        let name = "SIMULATOR-render-\(replay ? "replay" : "live")-\(value.map(String.init(describing:)) ?? "missing")-\(quality.rawValue)"
        attachment.name = name
        attachment.lifetime = .keepAlways; add(attachment)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage), options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        let output = XCTAttachment(string: text); output.name = name + "-local-ocr"
        output.lifetime = .keepAlways; add(output)
        return text.uppercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
    func testRecordingFooterKeepsLiveAndDemoRolesVisible() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Footer fixture is Simulator-only")
        #endif
        let model = TelemetryModel.shared
        guard !model.localRecordingEnabled, !model.collecting, model.replayController.sessionID == nil else {
            throw XCTSkip("Footer fixture requires an idle disposable Simulator")
        }
        let oldMode = model.runMode
        defer { model.runMode = oldMode }
        for demo in [false, true] {
            model.runMode = demo ? .demo : .live
            for size in [DynamicTypeSize.large, .accessibility5] {
                let cockpit = LiveCockpitView(model: model, editorPresented: .constant(false), selectedPageID: .constant(nil))
                let content = cockpit.recordingSessionBar()
                    .environment(\.dynamicTypeSize, size)
                    .frame(width: 343).fixedSize(horizontal: false, vertical: true)
                let renderer = ImageRenderer(content: content); renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertLessThanOrEqual(image.size.height, 300, "Footer must leave content space on a small viewport")
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: try XCTUnwrap(image.cgImage), options: [:]).perform([request])
                let labels = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
                XCTAssertTrue(labels.contains(demo ? "DEMO" : "LIVE"), "Persistent footer role must remain readable at \(size): \(labels)")
                let attachment = XCTAttachment(image: image)
                attachment.name = "SIMULATOR-footer-\(demo ? "DEMO" : "LIVE")-\(size)"
                attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }

    func testUnitOnlyHistoryChangeDoesNotDrawOneSharedScale() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic history rendering is Simulator-only")
        #endif
        let model = TelemetryModel.shared
        guard !model.localRecordingEnabled, !model.collecting, model.replayController.sessionID == nil else {
            throw XCTSkip("History rendering requires an idle disposable Simulator host")
        }
        let oldMode = model.runMode
        defer { model.replayController.stop(); model.runMode = oldMode }
        let rows = try ["%", "V"].enumerated().map { index, unit in
            let sample = DecodedSignalSample(signalID: "target", value: Double(index + 1), rawValue: 1,
                enumName: nil, unit: unit, frameSequence: UInt64(index + 1), receivedAtEpoch: 100 + Double(index),
                receivedAtMonotonicNanos: UInt64(index) * 1_000_000_000)
            return PersistedMeasurement(sequence: Int64(index + 1), sessionID: "unit-render", kind: "SIGNAL",
                sourceTimestamp: sample.receivedAtEpoch, receivedAtEpoch: sample.receivedAtEpoch,
                receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos,
                payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
        }
        let saved = MeasurementExport(session: .init(sessionID: "unit-render", startedAt: 100, endedAt: 102, mode: .demo), measurements: rows)
        _ = try await model.replayController.load(sessionID: "unit-render") { saved }
        model.runMode = .replay
        let widget = DashboardWidgetDefinition(id: "unit-render", type: .timeSeries, signalID: "target",
            rect: .init(x: 0, y: 0, width: 4, height: 4), zIndex: 0,
            configuration: .init(label: "Recorded unit change fixture", unit: "%", decimals: 1,
                minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil))
        let cockpit = LiveCockpitView(model: model, editorPresented: .constant(false), selectedPageID: .constant(nil))
        let view = cockpit.dashboardWidget(widget, now: Date()).frame(height: 220).padding(16).frame(width: 402).preferredColorScheme(.dark)
        let renderer = ImageRenderer(content: view); renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let cg = try XCTUnwrap(image.cgImage)
        var bytes = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        }
        let cyan = stride(from: 0, to: bytes.count, by: 4).filter {
            bytes[$0] < 100 && bytes[$0 + 1] > 140 && bytes[$0 + 2] > 160 && bytes[$0 + 3] > 200
        }.count
        XCTAssertEqual(cyan, 0, "Incompatible recorded units must not share a plotted line")
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
        XCTAssertTrue(text.contains("RECORDED UNITS CHANGED"), text)
        XCTAssertTrue(text.contains("MULTIPLE UNITS"), text)
        let attachment = XCTAttachment(image: image); attachment.name = "DEMO-recorded-unit-only-change-no-shared-scale"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testRecordedRouteStaysInsideDefaultLandscapeWidgetAtLargeText() async throws {
        let sample = LocationSample(originalTimestamp: 101, receivedAtEpoch: 101,
            receivedAtMonotonicNanos: 1_000_000_000, latitude: 0, longitude: 179.9,
            altitude: nil, speed: nil, course: nil, horizontalAccuracy: nil, verticalAccuracy: nil, source: .demo)
        let row = PersistedMeasurement(sequence: 1, sessionID: "route-layout", kind: "LOCATION",
            sourceTimestamp: 101, receivedAtEpoch: 101, receivedAtMonotonicNanos: 1_000_000_000,
            payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
        let second = LocationSample(originalTimestamp: 102, receivedAtEpoch: 102,
            receivedAtMonotonicNanos: 2_000_000_000, latitude: 0.001, longitude: -179.9,
            altitude: nil, speed: nil, course: nil, horizontalAccuracy: 5, verticalAccuracy: nil, source: .demo)
        let secondRow = PersistedMeasurement(sequence: 2, sessionID: "route-layout", kind: "LOCATION",
            sourceTimestamp: 102, receivedAtEpoch: 102, receivedAtMonotonicNanos: 2_000_000_000,
            payloadJSON: String(decoding: try JSONEncoder().encode(second), as: UTF8.self))
        let timeline = try await MeasurementReplay.timeline(.init(session: .init(sessionID: "route-layout",
            startedAt: 100, endedAt: 102, mode: .demo), measurements: [row, secondRow]))
        let history = try timeline.locationHistory(at: timeline.duration)
        for size in [DynamicTypeSize.large, .accessibility5] {
            // The default landscape GPS widget is 360 x 172. The un-clipped gap
            // beneath it detects drawing outside the actual production card.
            let content = VStack(spacing: 0) {
                RecordedRouteView(title: "Recorded GPS route", history: history)
                    .frame(width: 360, height: size.isAccessibilitySize ? nil : 172)
                    .fixedSize(horizontal: false, vertical: size.isAccessibilitySize)
                Color.clear.frame(height: 64)
            }.frame(width: 360).background(Color.black).foregroundStyle(Color.white).preferredColorScheme(.dark).dynamicTypeSize(size)
            let renderer = ImageRenderer(content: content); renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage)
            let cg = try XCTUnwrap(image.cgImage)
            if !size.isAccessibilitySize { XCTAssertEqual(cg.height, 236) }
            let cardBottom = cg.height - 64
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            var routePixels = 0
            var brightBelow = 0
            for y in 0..<cg.height {
                for x in 0..<cg.width {
                    let offset = (y * cg.width + x) * 4
                    if y < cardBottom && pixels[offset] < 100 && pixels[offset + 1] > 140 && pixels[offset + 2] > 160 && pixels[offset + 3] > 200 { routePixels += 1 }
                    if y > cardBottom && (pixels[offset] > 35 || pixels[offset + 1] > 35 || pixels[offset + 2] > 35) { brightBelow += 1 }
                }
            }
            XCTAssertGreaterThan(routePixels, 8, "The recorded route must remain visible at \(size)")
            XCTAssertEqual(brightBelow, 0, "Production card must not paint into the next widget at \(size)")
            let attachment = XCTAttachment(image: image); attachment.name = "DEMO-route-default-172pt-\(size)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testRecordedGraphStaysInsideDefaultWidgetWithSourceChanges() async throws {
        let model = TelemetryModel.shared
        guard !model.localRecordingEnabled, !model.collecting, model.replayController.sessionID == nil else {
            throw XCTSkip("Graph fixture requires an idle disposable Simulator host")
        }
        let oldMode = model.runMode
        defer { model.replayController.stop(); model.runMode = oldMode }
        let rows = try [TelemetrySource.rawCAN, .diagnostic, .rawCAN].enumerated().map { index, source in
            let sample = DecodedSignalSample(signalID: "target", value: Double(index + 1), rawValue: 1,
                enumName: nil, unit: "%", frameSequence: UInt64(index + 1), receivedAtEpoch: 100 + Double(index),
                receivedAtMonotonicNanos: UInt64(index) * 1_000_000_000, source: source)
            return PersistedMeasurement(sequence: Int64(index + 1), sessionID: "graph-fit", kind: "SIGNAL",
                sourceTimestamp: sample.receivedAtEpoch, receivedAtEpoch: sample.receivedAtEpoch,
                receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos,
                payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
        }
        _ = try await model.replayController.load(sessionID: "graph-fit") {
            MeasurementExport(session: .init(sessionID: "graph-fit", startedAt: 100, endedAt: 102, mode: .demo), measurements: rows)
        }
        model.runMode = .replay
        let widget = DashboardWidgetDefinition(id: "graph-fit", type: .timeSeries, signalID: "target",
            rect: .init(x: 0, y: 0, width: 6, height: 3), zIndex: 0,
            configuration: .init(label: "Recorded graph", unit: "%", decimals: 1,
                minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil))
        let cockpit = LiveCockpitView(model: model, editorPresented: .constant(false), selectedPageID: .constant(nil))
        for size in [DynamicTypeSize.large, .accessibility5] {
            let content = VStack(spacing: 0) {
                cockpit.dashboardWidget(widget, now: Date())
                    .frame(width: 360, height: size.isAccessibilitySize ? nil : 172)
                    .fixedSize(horizontal: false, vertical: size.isAccessibilitySize)
                Color.clear.frame(height: 120)
            }.frame(width: 360).background(Color.black).foregroundStyle(.white).preferredColorScheme(.dark).dynamicTypeSize(size)
            let renderer = ImageRenderer(content: content); renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage); let cg = try XCTUnwrap(image.cgImage)
            let cardBottom = cg.height - 120
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            var routePixels = 0; var brightBelow = 0
            for y in 0..<cg.height {
                for x in 0..<cg.width {
                    let offset = (y * cg.width + x) * 4
                    if y < cardBottom && pixels[offset] < 100 && pixels[offset + 1] > 140 && pixels[offset + 2] > 160 && pixels[offset + 3] > 200 { routePixels += 1 }
                    if y > cardBottom && (pixels[offset] > 35 || pixels[offset + 1] > 35 || pixels[offset + 2] > 35) { brightBelow += 1 }
                }
            }
            XCTAssertGreaterThan(routePixels, 8, "Recorded samples must remain visible at \(size)")
            XCTAssertEqual(brightBelow, 0, "Production graph must not paint into the next widget at \(size)")
            let attachment = XCTAttachment(image: image); attachment.name = "DEMO-graph-default-172pt-\(size)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    func testRecordedRouteDoesNotDrawConnectingLineAcrossRejectedFix() async throws {
        for rejected in [false, true] {
            let rows = try (0..<3).map { index in
                let sample = LocationSample(originalTimestamp: Double(101 + index), receivedAtEpoch: Double(101 + index),
                    receivedAtMonotonicNanos: UInt64(index + 1) * 1_000_000_000,
                    latitude: Double(index) / 2, longitude: Double(index) / 2,
                    altitude: nil, speed: nil, course: nil,
                    horizontalAccuracy: rejected && index == 1 ? -1 : 5, verticalAccuracy: nil, source: .demo)
                return PersistedMeasurement(sequence: Int64(index + 1), sessionID: "route-gap", kind: "LOCATION",
                    sourceTimestamp: sample.originalTimestamp, receivedAtEpoch: sample.receivedAtEpoch,
                    receivedAtMonotonicNanos: sample.receivedAtMonotonicNanos,
                    payloadJSON: String(decoding: try JSONEncoder().encode(sample), as: UTF8.self))
            }
            let timeline = try await MeasurementReplay.timeline(.init(session: .init(sessionID: "route-gap",
                startedAt: 100, endedAt: 103, mode: .demo), measurements: rows))
            let history = try timeline.locationHistory(at: timeline.duration)
            let view = RecordedRouteView(title: "Recorded GPS route", history: history)
                .frame(width: 360, height: 172).foregroundStyle(.white).preferredColorScheme(.dark).dynamicTypeSize(.large)
            let renderer = ImageRenderer(content: view); renderer.scale = 1
            let image = try XCTUnwrap(renderer.uiImage); let cg = try XCTUnwrap(image.cgImage)
            var pixels = [UInt8](repeating: 0, count: cg.width * cg.height * 4)
            try pixels.withUnsafeMutableBytes { buffer in
                let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: cg.width, height: cg.height,
                    bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            }
            // Both valid endpoints lie away from this central plot region. A
            // continuous control must draw here; rejecting the middle fix must
            // remove that connecting line without inventing a replacement.
            var centerCyan = 0
            for y in 85..<102 {
                for x in 171..<189 {
                    let i = (y * cg.width + x) * 4
                    if pixels[i] < 100 && pixels[i + 1] > 140 && pixels[i + 2] > 160 && pixels[i + 3] > 200 { centerCyan += 1 }
                }
            }
            if rejected { XCTAssertEqual(centerCyan, 0, "Rejected fix must break the actual rendered line") }
            else { XCTAssertGreaterThan(centerCyan, 8, "Continuous control must show its actual rendered line") }
            let attachment = XCTAttachment(image: image); attachment.name = "DEMO-route-rejected-middle-\(rejected)"
            attachment.lifetime = .keepAlways; add(attachment)
        }
    }

    private func count(_ word: String, in text: String) -> Int { text.components(separatedBy: word).count - 1 }

    func testMissingTargetCannotBorrowOtherFreshSignalValidity() throws {
        let labels = try renderLabels(value: nil)
        XCTAssertEqual(count("NO SAMPLE", in: labels), 3, labels)
        XCTAssertEqual(count("VALID", in: labels), 0, labels)
    }
    func testKnownZeroRemainsValidInAllThreeWidgetTypes() throws {
        let labels = try renderLabels(value: 0, expectedGreen: true)
        XCTAssertEqual(count("VALID", in: labels), 3, labels)
        XCTAssertEqual(count("NO SAMPLE", in: labels), 0, labels)
        XCTAssertEqual(count("0.0", in: labels), 2, "Numeric and LED widgets must display the known zero: " + labels)
    }
    func testReplayMissingAndInvalidAreNotGenericRecordedValidity() throws {
        let missing = try renderLabels(value: nil, replay: true)
        XCTAssertEqual(count("NO SAMPLE", in: missing), 3, missing)
        let invalid = try renderLabels(value: 49, replay: true, quality: .invalid)
        XCTAssertEqual(count("INVALID RECORDED", in: invalid), 3, invalid)
    }
    func testRecordedValidZeroRetainsUnknownFreshnessInAllWidgets() throws {
        let labels = try renderLabels(value: 0, replay: true)
        XCTAssertEqual(count("VALID RECORDED", in: labels), 3, labels)
        XCTAssertEqual(count("FRESHNESS UNKNOWN", in: labels), 3, labels)
        let stale = try renderLabels(value: 0, replay: true, freshness: .stale)
        XCTAssertEqual(count("FRESHNESS STALE", in: stale), 3, stale)
        let fresh = try renderLabels(value: 0, replay: true, freshness: .fresh, expectedGreen: true)
        XCTAssertEqual(count("FRESHNESS FRESH", in: fresh), 3, fresh)
    }
}
