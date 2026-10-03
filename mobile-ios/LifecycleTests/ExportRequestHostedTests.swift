import XCTest
@testable import TelemetryLifecycleHost

@MainActor
final class ExportRequestHostedTests: XCTestCase {
    func testSameSelectedIDAfterABAStillRejectsOriginalRequest() throws {
        let model = TelemetryModel.shared
        model.selectedSavedSessionID = "A"
        let state = MeasurementExportRequest()
        let request = try XCTUnwrap(state.begin(format: .json, sessionID: "A", contextGeneration: model.measurementContextGeneration))
        model.selectedSavedSessionID = "B"
        model.selectedSavedSessionID = "A"
        XCTAssertFalse(state.accept(Data("old-A".utf8), request: request, selectedSessionID: model.selectedSavedSessionID, contextGeneration: model.measurementContextGeneration))
        XCTAssertFalse(state.presented)
        model.selectedSavedSessionID = nil
    }

    func testCurrentRecorderReplacedFromAnotherTabRejectsSuspendedExport() async throws {
        let model = TelemetryModel.shared
        model.stopReplay()
        model.selectedSavedSessionID = nil
        let state = MeasurementExportRequest()
        let request = try XCTUnwrap(state.begin(format: .json, sessionID: nil, contextGeneration: model.measurementContextGeneration))
        let gate = ExportGate()
        let old = Task { @MainActor in
            await gate.wait()
            return state.accept(Data("old-recorder-A".utf8), request: request, selectedSessionID: model.selectedSavedSessionID, contextGeneration: model.measurementContextGeneration)
        }
        await gate.waitUntilEntered()
        model.startRecording() // The same operation exposed by Setup.
        XCTAssertTrue(model.localRecordingEnabled)
        XCTAssertNil(model.selectedSavedSessionID)
        await gate.release()
        let accepted = await old.value
        XCTAssertFalse(accepted)
        XCTAssertFalse(state.presented)
        model.stopRecording()
        _ = await model.exportMeasurementJSON() // Drain the owned test recording.
    }

    func testCancelledViewLifetimeRejectsNativeCompletionAfterReentry() throws {
        let state = MeasurementExportRequest()
        let old = try XCTUnwrap(state.begin(format: .json, sessionID: "A"))
        XCTAssertTrue(state.accept(Data("old".utf8), request: old, selectedSessionID: "A"))
        state.cancel() // SessionsView.onDisappear follows this route.
        XCTAssertFalse(state.acceptsCompletion(requestID: old.id))
        let new = try XCTUnwrap(state.begin(format: .csv, sessionID: "A"))
        XCTAssertTrue(state.accept(Data("new".utf8), request: new, selectedSessionID: "A"))
        XCTAssertFalse(state.acceptsCompletion(requestID: old.id))
        state.finish(requestID: old.id)
        XCTAssertTrue(state.presented); XCTAssertEqual(state.request?.id, new.id)
        XCTAssertEqual(state.data, Data("new".utf8))
    }

    func testDismissedCompletionCannotClearNewPreparingRequest() throws {
        let state = MeasurementExportRequest()
        let old = try XCTUnwrap(state.begin(format: .json, sessionID: "A"))
        XCTAssertTrue(state.accept(Data("old".utf8), request: old, selectedSessionID: "A"))
        state.finish(requestID: old.id)
        XCTAssertTrue(state.acceptsCompletion(requestID: old.id))
        let new = try XCTUnwrap(state.begin(format: .csv, sessionID: "A"))
        XCTAssertFalse(state.acceptsCompletion(requestID: old.id))
        state.finish(requestID: old.id)
        XCTAssertTrue(state.busy); XCTAssertEqual(state.request?.id, new.id)
        XCTAssertNil(state.data)
    }

    func testCrossFormatClickCannotReplacePreparingOrPresentedRequest() throws {
        let state = MeasurementExportRequest()
        let json = try XCTUnwrap(state.begin(format: .json, sessionID: "A"))
        XCTAssertNil(state.begin(format: .csv, sessionID: "A"))
        XCTAssertTrue(state.accept(Data("json-A".utf8), request: json, selectedSessionID: "A"))
        XCTAssertNil(state.begin(format: .csv, sessionID: "A"))
        XCTAssertEqual(state.request?.format, .json)
        XCTAssertEqual(state.data, Data("json-A".utf8))
        state.finish(requestID: json.id)
        XCTAssertNotNil(state.begin(format: .csv, sessionID: "A"))
    }
    func testSelectionCancellationAndLateResultNeverReplaceNewRequest() throws {
        let state = MeasurementExportRequest()
        let old = try XCTUnwrap(state.begin(format: .json, sessionID: "A"))
        state.cancel()
        let new = try XCTUnwrap(state.begin(format: .csv, sessionID: "B"))
        XCTAssertFalse(state.accept(Data("old".utf8), request: old, selectedSessionID: "A"))
        state.finish(requestID: old.id)
        XCTAssertEqual(state.request?.id, new.id)
        XCTAssertTrue(state.accept(Data("new".utf8), request: new, selectedSessionID: "B"))
        XCTAssertEqual(state.request?.format, .csv)
        XCTAssertEqual(state.data, Data("new".utf8))
    }
    func testSessionMismatchRejectsPayloadAndReleasesPreparingLock() throws {
        let state = MeasurementExportRequest()
        let request = try XCTUnwrap(state.begin(format: .json, sessionID: "A"))
        XCTAssertFalse(state.accept(Data("A".utf8), request: request, selectedSessionID: "B"))
        XCTAssertFalse(state.busy)
        XCTAssertNil(state.data)
        XCTAssertFalse(state.presented)
    }
}

private actor ExportGate {
    private var continuation: CheckedContinuation<Void,Never>?
    private var arrival: CheckedContinuation<Void,Never>?
    private var entered = false
    func wait() async {
        await withCheckedContinuation { c in continuation = c; entered = true; arrival?.resume(); arrival = nil }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
