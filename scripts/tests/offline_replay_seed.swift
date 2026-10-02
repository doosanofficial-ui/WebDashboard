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
let widgets = types.enumerated().map { index, type in
    DashboardWidgetDefinition(id: "fixture-\(index)", type: type, signalID: signal.signalID,
        rect: DashboardRect(x: index < 2 ? index * 2 : 0, y: index < 2 ? 0 : 2,
                            width: index < 2 ? 2 : 4, height: index < 2 ? 2 : 1), zIndex: index,
        configuration: DashboardWidgetConfiguration(label: "HV SOC fixture", unit: "%", decimals: 1,
            minimum: 0, maximum: 100, warningThreshold: nil, criticalThreshold: nil))
}
let profile = try DashboardProfile(id: "offline-fixture", name: "Offline Replay Fixture",
    pages: [DashboardPage(id: "fixture", name: "Fixture", orientation: .portrait, widgets: widgets)])
try JSONEncoder().encode(profile).write(to: root.appendingPathComponent("dashboard.json"))
print("Offline fixture seeded: 3 recorded rows; expected SOC 48.5; no acquisition")
