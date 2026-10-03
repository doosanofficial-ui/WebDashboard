import Foundation
import XCTest
@testable import TelemetryLifecycleHost

final class LegacyCancellationTests: XCTestCase {
    func testUnrelatedIdentifierCompletesWithoutSessionOrTaskAccess() {
        let session = FakeSession(); var factories = 0; var completions = 0
        let c = LocalOnlyBackgroundTaskCancellation(identifier:"legacy",makeSession:{ _ in factories += 1; return session })
        c.cancelLegacyTasks(identifier:"other") { completions += 1 }
        XCTAssertEqual(factories,0);XCTAssertEqual(session.enumerations,0);XCTAssertEqual(completions,1)
    }
    func testEmptySessionStillInvalidatesAndCompletesOnce() {
        let s = FakeSession(); var completed = 0
        let c = LocalOnlyBackgroundTaskCancellation(identifier:"legacy",makeSession:{ _ in s })
        c.cancelLegacyTasks(identifier:"legacy") { completed += 1 }
        XCTAssertEqual(completed,0)
        s.deliver([]); s.deliver([])
        XCTAssertEqual(s.invalidations,1);XCTAssertEqual(completed,1)
    }
    func testConcurrentRequestsCoalesceAndDuplicateEnumerationCannotReprocess() {
        let s = FakeSession(); let task = FakeTask(); var factories = 0; var completed = 0
        let c = LocalOnlyBackgroundTaskCancellation(identifier:"legacy",makeSession:{ _ in factories += 1; return s })
        c.cancelLegacyTasks(identifier:"legacy") { XCTAssertEqual(task.cancels,1);XCTAssertEqual(s.invalidations,1);completed += 1 }
        c.cancelLegacyTasks(identifier:"legacy") { completed += 1 }
        s.deliver([task]); s.deliver([task])
        XCTAssertEqual(factories,1);XCTAssertEqual(s.enumerations,1)
        XCTAssertEqual(task.cancels,1);XCTAssertEqual(s.invalidations,1);XCTAssertEqual(completed,2)
    }
    func testReentrantCancellationRequestJoinsWithoutDeadlockOrEarlyCompletion() {
        let s = FakeSession();let task = FakeTask();var completions = 0
        let c = LocalOnlyBackgroundTaskCancellation(identifier:"legacy",makeSession:{ _ in s })
        task.onCancel = { c.cancelLegacyTasks(identifier:"legacy") { XCTAssertEqual(s.invalidations,1);completions += 1 } }
        c.cancelLegacyTasks(identifier:"legacy") { completions += 1 }
        s.deliver([task])
        XCTAssertEqual(completions,2);XCTAssertEqual(task.cancels,1);XCTAssertEqual(s.invalidations,1)
    }
    func testCompletedMigrationDoesNotRestoreOrRecreateSession() {
        let s = FakeSession();var factories = 0;var completions = 0
        let c = LocalOnlyBackgroundTaskCancellation(identifier:"legacy",makeSession:{ _ in factories += 1;return s })
        c.cancelLegacyTasks(identifier:"legacy") { completions += 1 };s.deliver([])
        c.cancelLegacyTasks(identifier:"legacy") { completions += 1 }
        XCTAssertEqual(factories,1);XCTAssertEqual(s.enumerations,1);XCTAssertEqual(completions,2)
    }
    func testImmediateEnumerationStillCancelsBeforeCompletion() {
        let s = FakeSession();let t = FakeTask();s.immediate = [t];var completions = 0
        let c = LocalOnlyBackgroundTaskCancellation(identifier:"legacy",makeSession:{ _ in s })
        c.cancelLegacyTasks(identifier:"legacy") { XCTAssertEqual(t.cancels,1);XCTAssertEqual(s.invalidations,1);completions += 1 }
        XCTAssertEqual(completions,1)
    }
    func testCancellationPreservesOwnedBodyOutboxAndMeasurementSentinelFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        let sentinels = ["body.json":Data("original body".utf8),"outbox.json":Data("pending unacknowledged".utf8),"measurements.fixture":Data("original rows".utf8)]
        for (name,bytes) in sentinels {try bytes.write(to:root.appendingPathComponent(name))}
        let s = FakeSession();let t = FakeTask()
        let c = LocalOnlyBackgroundTaskCancellation(identifier:"legacy",makeSession:{ _ in s })
        c.cancelLegacyTasks(identifier:"legacy") {};s.deliver([t])
        for (name,bytes) in sentinels {XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent(name)),bytes)}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:root.path).count,3)
    }
}
private final class FakeTask: LegacyBackgroundCancellationTask {
    var cancels = 0;var onCancel:(()->Void)?
    func cancel(){cancels += 1;onCancel?()}
}
private final class FakeSession: LegacyBackgroundCancellationSession {
    var enumerations = 0;var invalidations = 0
    var immediate:[LegacyBackgroundCancellationTask]?
    var callback:(([LegacyBackgroundCancellationTask])->Void)?
    func allTasks(_ callback:@escaping([LegacyBackgroundCancellationTask])->Void){enumerations += 1;self.callback = callback;if let immediate {callback(immediate)}}
    func invalidateAndCancel(){invalidations += 1}
    func deliver(_ tasks:[LegacyBackgroundCancellationTask]){callback?(tasks)}
}
