import Foundation
import Observation

/// A single immutable export request owns preparation and its native sheet.
@MainActor @Observable
final class MeasurementExportRequest {
    enum Format { case json, csv }
    struct Request {
        let id = UUID()
        let format: Format
        let sessionID: String?
        let contextGeneration: UUID?
        var filename: String { "telemetry-measurements-" + id.uuidString }
    }
    private(set) var request: Request?
    private(set) var data: Data?
    private var finishedID: UUID?
    var presented = false
    var busy: Bool { request != nil }

    func begin(format: Format, sessionID: String?, contextGeneration: UUID? = nil) -> Request? {
        guard request == nil else { return nil }
        let request = Request(format: format, sessionID: sessionID, contextGeneration: contextGeneration)
        self.request = request
        finishedID = nil
        data = nil
        return request
    }
    func accept(_ data: Data, request: Request, selectedSessionID: String?, contextGeneration: UUID? = nil) -> Bool {
        guard self.request?.id == request.id else { return false }
        guard selectedSessionID == request.sessionID, contextGeneration == request.contextGeneration else {
            finish(requestID: request.id)
            return false
        }
        self.data = data
        presented = true
        return true
    }
    func finish(requestID: UUID) {
        guard request?.id == requestID else { return }
        finishedID = requestID
        request = nil
        data = nil
        presented = false
    }
    func cancel() {
        finishedID = nil
        request = nil
        data = nil
        presented = false
    }
    func acceptsCompletion(requestID: UUID) -> Bool {
        request?.id == requestID || (request == nil && finishedID == requestID)
    }
}
