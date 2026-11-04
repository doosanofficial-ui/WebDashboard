import XCTest
@testable import TelemetryCore
// Module name verified against the pinned Package.swift/project.yml inventory.
// These mirrored cases are prepared only: no Swift compilation/execution was performed.

final class ScopedMediaPresentationTests: XCTestCase {
    private func ready(_ source: ScopedMediaPresentation.Source = .appOwned,
                       _ authorization: ScopedMediaPresentation.Authorization = .notRequired,
                       _ capabilities: Set<ScopedMediaPresentation.Action> = [.play, .pause, .previous, .next]) -> ScopedMediaPresentation {
        var model = ScopedMediaPresentation()
        model.replace(source: source, authorization: authorization, capabilities: capabilities)
        return model
    }
    func testDefaultUnavailable() {
        var m = ScopedMediaPresentation()
        XCTAssertEqual(m.playback, .unavailable); XCTAssertNil(m.intent(.play))
    }
    func testArbitraryAppUnavailable() {
        var m = ready(.unsupportedOtherApp, .authorized)
        XCTAssertFalse(m.update(generation: m.generation, sequence: 1, playback: .paused, title: "Synthetic"))
        XCTAssertNil(m.intent(.play)); XCTAssertNil(m.title)
    }
    func testAuthorizationAndCapabilities() {
        let pairs: [(ScopedMediaPresentation.Source, ScopedMediaPresentation.Authorization)] = [(.appleMusic, .denied), (.appleMusic, .notDetermined), (.appOwned, .authorized)]
        for pair in pairs {
            var m = ready(pair.0, pair.1)
            XCTAssertNil(m.intent(.play)); XCTAssertFalse(m.update(generation: m.generation, sequence: 1, playback: .paused))
        }
        var m = ready(.appleMusic, .authorized, [.play])
        m.update(generation: m.generation, sequence: 1, playback: .paused)
        XCTAssertNotNil(m.intent(.play)); XCTAssertNil(m.intent(.next))
    }
    func testStateSpecificIntents() throws {
        var m = ready(); XCTAssertNil(m.intent(.play))
        m.update(generation: m.generation, sequence: 1, playback: .paused)
        XCTAssertNil(m.intent(.pause))
        let ticket = try XCTUnwrap(m.intent(.play)); XCTAssertNil(m.intent(.next))
        XCTAssertTrue(m.finish(ticket)); XCTAssertEqual(m.playback, .paused)
        m.update(generation: m.generation, sequence: 2, playback: .playing)
        XCTAssertNotNil(m.intent(.pause))
    }
    func testNumbersUnknownZeroAndInvalid() {
        var m = ready()
        m.update(generation: m.generation, sequence: 1, playback: .paused)
        XCTAssertNil(m.duration); XCTAssertNil(m.elapsed)
        m.update(generation: m.generation, sequence: 2, playback: .paused, duration: 0, elapsed: 3)
        XCTAssertEqual(m.duration, 0); XCTAssertEqual(m.elapsed, 0)
        for (index, number) in [Double.nan, Double.infinity, -1].enumerated() {
            m.update(generation: m.generation, sequence: Int64(index + 3), playback: .paused, duration: number, elapsed: number)
            XCTAssertNil(m.duration); XCTAssertNil(m.elapsed)
        }
        m.update(generation: m.generation, sequence: 6, playback: .paused, duration: 10, elapsed: 15)
        XCTAssertEqual(m.elapsed, 10)
    }
    func testBoundedLocalMetadata() {
        var m = ready()
        m.update(generation: m.generation, sequence: 1, playback: .paused, title: String(repeating: "A", count: 300), artist: "\u{0}Synthetic\n Artist ", artwork: "https://invalid.test/image")
        XCTAssertEqual(m.title?.unicodeScalars.count, 160); XCTAssertEqual(m.artist, "Synthetic Artist"); XCTAssertNil(m.artwork)
        m.update(generation: m.generation, sequence: 2, playback: .paused, artwork: "asset_01-A")
        XCTAssertEqual(m.artwork, "asset_01-A"); XCTAssertFalse(ScopedMediaPresentation.allowsExport)
    }
    func testStaleGenerationAndSequence() {
        var m = ready(); let old = m.generation
        m.update(generation: old, sequence: 3, playback: .playing, title: "New")
        XCTAssertFalse(m.update(generation: old, sequence: 2, playback: .paused, title: "Old")); XCTAssertEqual(m.title, "New")
        XCTAssertFalse(m.update(generation: old, sequence: 3, playback: .paused))
        m.replace(source: .appOwned, authorization: .notRequired, capabilities: [.play])
        XCTAssertNotEqual(old, m.generation); XCTAssertFalse(m.update(generation: old, sequence: 4, playback: .playing))
    }
    func testReplacedAndDuplicateTicket() throws {
        var m = ready(); m.update(generation: m.generation, sequence: 1, playback: .paused)
        let old = try XCTUnwrap(m.intent(.play))
        m.replace(source: .appOwned, authorization: .notRequired, capabilities: [.play])
        m.update(generation: m.generation, sequence: 1, playback: .paused)
        let current = try XCTUnwrap(m.intent(.play))
        XCTAssertFalse(m.finish(old)); XCTAssertEqual(m.pending, current)
        XCTAssertTrue(m.finish(current)); XCTAssertFalse(m.finish(current))
    }
    func testSnapshotInvalidatesTicket() throws {
        var m = ready(); m.update(generation: m.generation, sequence: 1, playback: .paused)
        let ticket = try XCTUnwrap(m.intent(.play))
        m.update(generation: m.generation, sequence: 2, playback: .playing)
        XCTAssertFalse(m.finish(ticket)); XCTAssertEqual(m.playback, .playing)
    }
    func testInterruptionNeverAutoResumes() throws {
        var m = ready(); m.update(generation: m.generation, sequence: 1, playback: .playing, title: "Synthetic")
        let ticket = try XCTUnwrap(m.intent(.pause)); m.interrupt()
        XCTAssertEqual(m.playback, .interrupted); XCTAssertFalse(m.finish(ticket)); XCTAssertNil(m.intent(.play))
        XCTAssertFalse(m.update(generation: m.generation, sequence: 2, playback: .playing))
        m.endInterruption(); XCTAssertEqual(m.playback, .paused); XCTAssertNil(m.pending); XCTAssertNotNil(m.intent(.play))
    }
    func testInterruptionInvalidatesInflightSnapshot() {
        var m = ready(); let old = m.generation; m.interrupt(); m.endInterruption()
        XCTAssertFalse(m.update(generation: old, sequence: 99, playback: .playing)); XCTAssertEqual(m.playback, .paused)
    }
    func testUnavailableClearsMetadata() {
        var m = ready()
        m.update(generation: m.generation, sequence: 1, playback: .playing, title: "Synthetic", artist: "Synthetic Artist", artwork: "asset", duration: 10, elapsed: 1)
        m.update(generation: m.generation, sequence: 2, playback: .unavailable, title: "Ignored")
        XCTAssertNil(m.title); XCTAssertNil(m.artist); XCTAssertNil(m.artwork); XCTAssertNil(m.duration); XCTAssertNil(m.elapsed); XCTAssertNil(m.intent(.play))
    }
    func testTransportMatrixAndRevocation() {
        let states: [ScopedMediaPresentation.Playback] = [.paused, .playing, .stopped, .buffering]
        let actions: [ScopedMediaPresentation.Action] = [.play, .pause, .previous, .next]
        for state in states {
            for action in actions {
                var m = ready(); m.update(generation: m.generation, sequence: 1, playback: state)
                let expected = state != .buffering && (action == .previous || action == .next ||
                    (action == .play && (state == .paused || state == .stopped)) || (action == .pause && state == .playing))
                XCTAssertEqual(m.intent(action) != nil, expected)
            }
        }
        var m = ready(.appleMusic, .authorized)
        m.update(generation: m.generation, sequence: 1, playback: .playing, title: "Synthetic")
        let old = m.generation
        m.replace(source: .appleMusic, authorization: .denied, capabilities: [.play])
        XCTAssertNil(m.title); XCTAssertFalse(m.update(generation: old, sequence: 2, playback: .playing)); XCTAssertNil(m.intent(.play))
    }
    func testInvalidSequenceAndInterruptedSnapshotRejected() {
        var m = ready()
        XCTAssertFalse(m.update(generation: m.generation, sequence: -1, playback: .paused))
        XCTAssertFalse(m.update(generation: m.generation, sequence: 1, playback: .interrupted))
        XCTAssertEqual(m.sequence, -1)
    }
}
