import Foundation
import XCTest
@testable import TelemetryCore

@MainActor
private final class Scheduler: BackgroundTransferScheduling {
    struct Registration { let request: URLRequest; let file: URL; let earliest: Date? }
    var registrations: [Registration] = []
    var pauseNextQuery = false
    var queryStarted: (() -> Void)?
    var resumeQuery: CheckedContinuation<Void, Never>?
    func hasActiveTransfer(excluding filename: String?) async -> Bool {
        if pauseNextQuery {
            pauseNextQuery = false
            await withCheckedContinuation { continuation in
                resumeQuery = continuation
                queryStarted?()
            }
        }
        return false
    }
    func registerUpload(_ request: URLRequest, from file: URL, earliestBeginDate: Date?) throws {
        registrations.append(.init(request: request, file: file, earliest: earliestBeginDate))
    }
}

@MainActor
final class BackgroundDeliveryTests: XCTestCase {
    func storage() throws -> (URL, DurableOutbox) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (dir, try DurableOutbox(path: dir.appendingPathComponent("outbox.sqlite3")))
    }
    func event() throws -> TelemetryEvent {
        try .gps(latitude: 37, longitude: 127, speed: nil, heading: nil, accuracy: 5,
                 altitude: nil, capturedAt: 1_700_000_000, background: true)
    }

    func testRetryIsRegisteredWithOSBeforeCompletionReturns() async throws {
        let (dir, box) = try storage()
        try await box.enqueue(event())
        let scheduler = Scheduler()
        let delivery = try BackgroundDelivery(outbox: box, clientID: "device-1", directory: dir, scheduler: scheduler)
        var statuses: [String] = []
        delivery.onStatus = { statuses.append($0) }
        try delivery.configure(baseURL: URL(string: "https://example.invalid")!, credential: "test-only")
        await delivery.flush()
        let first = try XCTUnwrap(scheduler.registrations.first)
        let captured = try JSONDecoder().decode(UploadBatch.self, from: Data(contentsOf: first.file))
        let before = Date()
        await delivery.complete(filename: first.file.lastPathComponent, status: 503,
            body: Data(#"{"error":{"code":"storage_unavailable"}}"#.utf8))
        XCTAssertEqual(scheduler.registrations.count, 2, "Retry must already exist outside the process before completion returns")
        let retry = scheduler.registrations[1]
        XCTAssertGreaterThan(try XCTUnwrap(retry.earliest), before)
        let replay = try JSONDecoder().decode(UploadBatch.self, from: Data(contentsOf: retry.file))
        XCTAssertEqual(replay.events, captured.events)
        let count = try await box.count()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(statuses.last?.contains("storage_unavailable") == true, "Retry scheduling must not erase the safe server error code")
    }

    func testCompletionWaitsForConcurrentPreparationBeforeReleasingBackgroundWork() async throws {
        let (dir, box) = try storage()
        try await box.enqueue(event())
        let scheduler = Scheduler()
        let delivery = try BackgroundDelivery(outbox: box, clientID: "device-1", directory: dir, scheduler: scheduler)
        try delivery.configure(baseURL: URL(string: "https://example.invalid")!, credential: "test-only")
        await delivery.flush()
        let original = try XCTUnwrap(scheduler.registrations.first)
        let preparationStarted = expectation(description: "Concurrent preparation started")
        scheduler.queryStarted = { preparationStarted.fulfill() }
        scheduler.pauseNextQuery = true
        let preparation = Task { await delivery.flush() }
        await fulfillment(of: [preparationStarted], timeout: 2)
        let failureObserved = expectation(description: "HTTP failure decoded")
        delivery.onStatus = { if $0.contains("storage_unavailable") { failureObserved.fulfill() } }
        var completed = false
        let completion = Task {
            await delivery.complete(filename: original.file.lastPathComponent, status: 503,
                body: Data(#"{"error":{"code":"storage_unavailable"}}"#.utf8))
            completed = true
        }
        await fulfillment(of: [failureObserved], timeout: 2)
        XCTAssertFalse(completed, "A callback must not finish while the only replacement transfer is still being prepared")
        scheduler.resumeQuery?.resume()
        scheduler.resumeQuery = nil
        await preparation.value
        await completion.value
        XCTAssertGreaterThanOrEqual(scheduler.registrations.count, 2)
    }

    func testBackgroundRelaunchDrainsTheNextBatchFromRestoredConfiguration() async throws {
        let (dir, box) = try storage()
        for _ in 0..<201 { try await box.enqueue(event()) }
        let firstScheduler = Scheduler()
        let first = try BackgroundDelivery(outbox: box, clientID: "device-1", directory: dir, scheduler: firstScheduler)
        try first.configure(baseURL: URL(string: "https://example.invalid")!, credential: "test-only")
        await first.flush()
        let inFlight = try XCTUnwrap(firstScheduler.registrations.first)
        let batch = try JSONDecoder().decode(UploadBatch.self, from: Data(contentsOf: inFlight.file))
        XCTAssertEqual(batch.events.count, 200)
        let restoredScheduler = Scheduler()
        let restored = try BackgroundDelivery(outbox: box, clientID: "device-1", directory: dir, scheduler: restoredScheduler)
        try restored.configure(baseURL: URL(string: "https://example.invalid")!, credential: "test-only")
        let ack = Acknowledgement(version: 2, clientID: "device-1", acked: batch.events.map(\.id))
        await restored.complete(filename: inFlight.file.lastPathComponent, status: 200, body: try JSONEncoder().encode(ack))
        XCTAssertEqual(restoredScheduler.registrations.count, 1)
        let next = try JSONDecoder().decode(UploadBatch.self, from: Data(contentsOf: restoredScheduler.registrations[0].file))
        XCTAssertEqual(next.events.count, 1)
        let count = try await box.count()
        XCTAssertEqual(count, 1)
    }

    func testReconfigurationDuringPreparationDoesNotSubmitOldDestinationOrCredential() async throws {
        let (dir, box) = try storage()
        try await box.enqueue(event())
        let scheduler = Scheduler()
        let delivery = try BackgroundDelivery(outbox: box, clientID: "device-1", directory: dir, scheduler: scheduler)
        try delivery.configure(baseURL: URL(string: "https://old.invalid")!, credential: "test-old")
        let started = expectation(description: "Preparation waiting for OS task query")
        scheduler.pauseNextQuery = true
        scheduler.queryStarted = { started.fulfill() }
        let old = Task { await delivery.flush() }
        await fulfillment(of: [started], timeout: 2)
        try delivery.configure(baseURL: URL(string: "https://new.invalid")!, credential: "test-new")
        let updated = Task { await delivery.flush() }
        scheduler.resumeQuery?.resume()
        scheduler.resumeQuery = nil
        await old.value
        await updated.value
        XCTAssertEqual(scheduler.registrations.count, 1)
        XCTAssertEqual(scheduler.registrations.first?.request.url?.host, "new.invalid")
        XCTAssertTrue(scheduler.registrations.first?.request.value(forHTTPHeaderField: "Authorization") == "Bearer test-new", "Outdated authorization header was submitted")
    }
}
