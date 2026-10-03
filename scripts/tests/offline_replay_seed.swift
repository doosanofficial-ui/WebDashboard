import Foundation
import TelemetryCore

// Synthetic recording built through the real parser/decoder/recorder, using
// captured SOC bytes. Not a new vehicle or GPS measurement.
let root = URL(fileURLWithPath: CommandLine.arguments[1])
let recorder = try MeasurementRecorder(path: root.appendingPathComponent("measurements.sqlite3"),
    sessionID: "offline-replay-fixture", startedAt: 100, mode: .demo)
let query = try SantaFeMX5HybridQueryCatalog.hvBatterySOC()
let response = try OBDResponseParser.parse(
    "7EC 10 08 62 01 01 8F F3 FF\r7EC 21 EF 61 00 00 00 00 00\r>", for: query,
    receivedAtEpoch: 101, receivedAtMonotonicNanos: 10, sequence: 1,
    sourceAdapter: "captured-payload-fixture", sourceTransport: "fixture")
let signal = try OBDSignalDecoder.decode(query.signals[0], response: response)
let location = LocationSample(originalTimestamp: 101.4, receivedAtEpoch: 101.5,
    receivedAtMonotonicNanos: 11, latitude: 0, longitude: 0, altitude: nil,
    speed: nil, course: nil, horizontalAccuracy: 10, verticalAccuracy: nil, source: .demo)
try await recorder.append(contentsOf: [.diagnosticResponse(response), .diagnosticSignal(signal), .location(location)])
try await recorder.finish(endedAt: 102)
let types: [DashboardWidgetType] = [.numericGauge, .semiCircularGauge, .horizontalBar]
var widgets = types.enumerated().map { index, type in
    DashboardWidgetDefinition(id: "fixture-\(index)", type: type, signalID: signal.signalID,
        rect: DashboardRect(x: index < 2 ? index * 2 : 0, y: index < 2 ? 0 : 2,
                            width: index < 2 ? 2 : 4, height: 2), zIndex: index,
        configuration: DashboardWidgetConfiguration(label: "HV SOC fixture", unit: "%", decimals: 1,
            minimum: 0, maximum: 100, warningThreshold: nil, criticalThreshold: nil))
}
widgets.append(DashboardWidgetDefinition(id: "fixture-condition", type: .led, signalID: signal.signalID,
    rect: DashboardRect(x: 0, y: 5, width: 4, height: 1), zIndex: 4,
    configuration: DashboardWidgetConfiguration(label: "Recorded condition fixture", unit: "%", decimals: 1,
        minimum: 0, maximum: 100, warningThreshold: nil, criticalThreshold: nil,
        condition: DashboardCondition(op: .greaterThan, threshold: 40))))
widgets.append(DashboardWidgetDefinition(id: "fixture-status", type: .statusIcon, signalID: signal.signalID,
    rect: DashboardRect(x: 0, y: 4, width: 4, height: 1), zIndex: 3,
    configuration: DashboardWidgetConfiguration(label: "HV SOC status fixture", unit: "%", decimals: 1,
        minimum: 0, maximum: 100, warningThreshold: nil, criticalThreshold: nil)))
widgets.append(DashboardWidgetDefinition(id: "fixture-history", type: .timeSeries, signalID: signal.signalID,
    rect: DashboardRect(x: 0, y: 6, width: 4, height: 4), zIndex: 5,
    configuration: DashboardWidgetConfiguration(label: "Recorded SOC history fixture", unit: "%", decimals: 1,
        minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil)))
widgets.append(DashboardWidgetDefinition(id: "fixture-route", type: .map, signalID: nil,
    rect: DashboardRect(x: 0, y: 10, width: 4, height: 5), zIndex: 6,
    configuration: DashboardWidgetConfiguration(label: "Recorded GPS route fixture", unit: "", decimals: 1,
        minimum: nil, maximum: nil, warningThreshold: nil, criticalThreshold: nil)))
let profile = try DashboardProfile(id: "offline-fixture", name: "Offline Replay Fixture",
    pages: [DashboardPage(id: "fixture", name: "Fixture", orientation: .portrait, widgets: widgets)])
try JSONEncoder().encode(profile).write(to: root.appendingPathComponent("dashboard.json"))
print("Offline fixture seeded: 3 recorded rows; expected SOC 48.5; no acquisition")

// Additional recorded-time fixture. All positions and GPS are invented.
do {
    let seekRecorder = try MeasurementRecorder(path: root.appendingPathComponent("measurements.sqlite3"),
        sessionID: "offline-seek-fixture", startedAt: 300, mode: .demo)
    let start = try OBDResponseParser.parse("7EC 10 08 62 01 01 8F F3 FF\r7EC 21 EF 61 00 00 00 00 00\r>",
        for: query, receivedAtEpoch: 301, receivedAtMonotonicNanos: 1_000_000_000, sequence: 1,
        sourceAdapter: "invented-seek-fixture", sourceTransport: "fixture")
    let end = try OBDResponseParser.parse("7EC 10 08 62 01 01 8F F3 FF\r7EC 21 EF 6A 00 00 00 00 00\r>",
        for: query, receivedAtEpoch: 304, receivedAtMonotonicNanos: 4_000_000_000, sequence: 2,
        sourceAdapter: "invented-seek-fixture", sourceTransport: "fixture")
    try await seekRecorder.append(contentsOf: [.system(name: "recording_started", timestamp: 300, monotonicNanos: 0),
        .diagnosticResponse(start), .diagnosticSignal(try OBDSignalDecoder.decode(query.signals[0],response:start)),
        .system(name: "MARK",timestamp:302,monotonicNanos:2_000_000_000),
        .diagnosticResponse(end), .diagnosticSignal(try OBDSignalDecoder.decode(query.signals[0],response:end)),
        .location(.init(originalTimestamp:304.4,receivedAtEpoch:304.5,receivedAtMonotonicNanos:4_500_000_000,
            latitude:0,longitude:0,altitude:-30,speed:nil,course:nil,horizontalAccuracy:5,verticalAccuracy:5,source:.demo))])
    try await seekRecorder.finish(endedAt:305,terminalEvent:.system(name:"recording_stopped",timestamp:305,monotonicNanos:5_000_000_000))
    print("Recorded-time fixture seeded: 8 original rows, duration5s, SOC48.5→53, MARK2s, invented GPS0/0; no acquisition")
}

// Long synthetic timeline for an actual held slider gesture during playback.
do {
    let r = try MeasurementRecorder(path: root.appendingPathComponent("measurements.sqlite3"),
        sessionID: "offline-slider-fixture", startedAt: 600, mode: .demo)
    let first = try OBDResponseParser.parse("7EC 10 08 62 01 01 8F F3 FF\r7EC 21 EF 61 00 00 00 00 00\r>",
        for: query, receivedAtEpoch:601,receivedAtMonotonicNanos:1_000_000_000,sequence:1,
        sourceAdapter:"invented-slider-fixture",sourceTransport:"fixture")
    let last = try OBDResponseParser.parse("7EC 10 08 62 01 01 8F F3 FF\r7EC 21 EF 6A 00 00 00 00 00\r>",
        for: query, receivedAtEpoch:620,receivedAtMonotonicNanos:20_000_000_000,sequence:2,
        sourceAdapter:"invented-slider-fixture",sourceTransport:"fixture")
    try await r.append(contentsOf:[.system(name:"recording_started",timestamp:600,monotonicNanos:0),
        .diagnosticResponse(first),.diagnosticSignal(try OBDSignalDecoder.decode(query.signals[0],response:first)),
        .system(name:"MARK",timestamp:602,monotonicNanos:2_000_000_000),
        .diagnosticResponse(last),.diagnosticSignal(try OBDSignalDecoder.decode(query.signals[0],response:last))])
    try await r.finish(endedAt:630,terminalEvent:.system(name:"recording_stopped",timestamp:630,monotonicNanos:30_000_000_000))
    print("Slider fixture seeded: 30s invented DEMO recording, SOC48.5→53; no acquisition")
}

// A real zero-duration timeline: every original row belongs to one instant.
do {
    let instant = try MeasurementRecorder(path: root.appendingPathComponent("measurements.sqlite3"),
        sessionID: "offline-instant-fixture", startedAt: 100, mode: .demo)
    try await instant.append(contentsOf: [.diagnosticResponse(response), .diagnosticSignal(signal),
        .system(name: "MARK", timestamp: 101, monotonicNanos: 10)])
    try await instant.finish(endedAt: 101)
    print("Single-instant fixture seeded: 3 original rows at the same monotonic instant; no acquisition")
}

// Empty closed recordings are valid archives, but are not a single sample.
do {
    let empty = try MeasurementRecorder(path: root.appendingPathComponent("measurements.sqlite3"),
        sessionID: "offline-empty-fixture", startedAt: 90, mode: .demo)
    try await empty.finish(endedAt: 90)
    print("Empty fixture seeded: 0 original rows; no acquisition")
}

// Invented antimeridian route; last fix has rejected accuracy, so the pre-fix
// MapKit widget has no coordinate and cannot request a remote basemap in RED.
do {
    let route = try MeasurementRecorder(path: root.appendingPathComponent("measurements.sqlite3"),
        sessionID: "offline-route-fixture", startedAt: 700, mode: .demo)
    try await route.append(contentsOf: [
        .system(name: "recording_started", timestamp: 700, monotonicNanos: 0),
        .location(.init(originalTimestamp: 701.1, receivedAtEpoch: 701.2, receivedAtMonotonicNanos: 1_000_000_000,
            latitude: 0, longitude: 179.9, altitude: nil, speed: nil, course: nil, horizontalAccuracy: nil, verticalAccuracy: nil, source: .demo)),
        .location(.init(originalTimestamp: 699.5, receivedAtEpoch: 703.2, receivedAtMonotonicNanos: 3_000_000_000,
            latitude: 0.001, longitude: -179.9, altitude: -30, speed: nil, course: nil, horizontalAccuracy: 5, verticalAccuracy: 5, source: .demo)),
        .location(.init(originalTimestamp: 704.1, receivedAtEpoch: 704.2, receivedAtMonotonicNanos: 4_000_000_000,
            latitude: 0.001, longitude: -179.9, altitude: nil, speed: nil, course: nil, horizontalAccuracy: -1, verticalAccuracy: nil, source: .demo))])
    try await route.finish(endedAt: 705, terminalEvent: .system(name: "recording_stopped", timestamp: 705, monotonicNanos: 5_000_000_000))
    print("Route fixture seeded: 3 invented GPS rows, last accuracy rejected, duration5s; no acquisition")
}
