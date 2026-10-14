import Foundation

// The caller's wall-clock read is frozen; the Timeline tick is intentionally older.
struct Date: Equatable {
    let timeIntervalSince1970: Double
    @MainActor static var renderEpoch: Double = 100.45
    @MainActor init() { timeIntervalSince1970 = Self.renderEpoch }
    init(timeIntervalSince1970 value: Double) { timeIntervalSince1970 = value }
    @MainActor static var now: Date { Date() }
    func timeIntervalSince(_ other: Date) -> Double { timeIntervalSince1970 - other.timeIntervalSince1970 }
}
enum TelemetryRunMode { case live, demo, replay }
enum SignalQuality: String { case valid, stale, invalid }
enum MeasurementReplay { enum SignalFreshness: String { case unknown, fresh, stale } }
struct SignalRow { let id: String; var name: String { id }; var detail = ""; var unit = "" }
struct Frame { var sig: [String: Double] }
@MainActor final class Model {
    var runMode = TelemetryRunMode.demo
    var replayTimestamp: Double?
    var replaySignalFreshness: [String: MeasurementReplay.SignalFreshness] = [:]
    var localSignalReceivedAt = ["demo.signal": 100.4]
    var localSignalTimeouts: [String: Double] = [:]
    var adapterStatus = "Demo adapter monitoring"
    var connection = "Disconnected"
    var frame: Frame? = Frame(sig: ["demo.signal": 0])
    var lastFrameAt: Date? = Date(timeIntervalSince1970: 100.4)
}
struct Timeline { let date: Date }
ACTUAL_DISPLAY_STATE
@MainActor final class Probe {
    let model = Model()
    let timeline = Timeline(date: Date(timeIntervalSince1970: 100))
    var searchText = ""
    var showStaleOnly = false
    var signalRows = [SignalRow(id: "demo.signal")]
    func displayDate() -> Date {
        DISPLAY_DATE_EXPRESSION
        return displayDate
    }
    ACTUAL_SIGNALS_METHODS
}
@main enum Run {
    @MainActor static func main() {
        var checks = 0, failures = 0
        func expect(_ value: Bool, _ title: String) {
            checks += 1
            if !value { failures += 1; print("FAIL: " + title) }
        }
        let p = Probe(), demo = SignalRow(id: "demo.signal")
        let date = p.displayDate()
        expect(p.isFresh(demo, at: date), "new Demo sample between scheduled ticks is fresh at render time")
        expect(TelemetryDisplayState.signalLabel(0, liveFresh: p.isFresh(demo, at: date)) == "VALID",
               "valid zero Demo sample is not mislabeled STALE")
        expect(p.frameAge(at: date) == "50 ms", "frame age uses render time rather than clamping an older tick to zero")
        p.showStaleOnly = true
        expect(p.filteredRows(at: date).isEmpty, "STALE filter excludes the freshly arrived Demo sample")
        p.model.localSignalReceivedAt["soc"] = 97
        p.model.frame?.sig["soc"] = 50
        p.signalRows.append(SignalRow(id: "soc"))
        expect(p.filteredRows(at: date).map(\.id) == ["soc"], "a different signal arrival does not freshen retained SOC")
        Date.renderEpoch = 102
        expect(!p.isFresh(demo, at: p.displayDate()), "a signal becomes stale when wall time exceeds its timeout")
        Date.renderEpoch = 100.44
        p.model.localSignalTimeouts["demo.signal"] = 0.05
        expect(p.isFresh(demo, at: p.displayDate()), "configured timeout is respected inside its boundary")
        Date.renderEpoch = 100.46
        expect(!p.isFresh(demo, at: p.displayDate()), "configured timeout expires independently of the global frame age")
        Date.renderEpoch = 100.45
        p.model.localSignalReceivedAt["demo.signal"] = 101
        expect(!p.isFresh(demo, at: p.displayDate()), "a genuinely future sample timestamp remains non-fresh")
        p.model.runMode = .replay
        p.model.replayTimestamp = 40
        p.model.replaySignalFreshness["demo.signal"] = .fresh
        expect(p.displayDate().timeIntervalSince1970 == 40, "Replay presentation uses its selected recorded timestamp")
        expect(p.isFresh(demo, at: p.displayDate()), "Replay freshness uses recorded timeline state")
        p.model.replaySignalFreshness["demo.signal"] = .unknown
        expect(p.filteredRows(at: p.displayDate()).map(\.id).isEmpty,
               "unknown Replay freshness is not confirmed stale")
        let server = Probe()
        server.model.runMode = .live
        server.model.localSignalReceivedAt = [:]
        server.model.connection = "Connected"
        expect(server.isFresh(demo, at: server.displayDate()), "server samples arriving between ticks are fresh")
        Date.renderEpoch = 103
        expect(!server.isFresh(demo, at: server.displayDate()), "server samples expire on current wall time")
        expect(TelemetryDisplayState.signalLabel(nil, liveFresh: true) == "NO SAMPLE", "missing data is not a valid sample")
        expect(TelemetryDisplayState.signalLabel(.nan, liveFresh: true) == "INVALID", "nonfinite data remains invalid")
        print("SIGNALS PRESENTATION SOURCE HARNESS: \(checks) assertions, \(failures) failures; clock/model doubles, no native UI")
        if failures > 0 { exit(1) }
    }
}
