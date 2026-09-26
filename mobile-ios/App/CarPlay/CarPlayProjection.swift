#if canImport(CarPlay)
import CarPlay
import TelemetryCore

@available(iOS 14.0, *)
enum CarPlayProjection {
    static func template(for state: CarPlayProjectionState) -> CPTemplate {
        var items = [
            CPListItem(text: "Adapter", detailText: state.adapterState),
            CPListItem(text: "Recording", detailText: state.recordingState),
            CPListItem(text: "Profile", detailText: state.profileName),
            CPListItem(text: "Session", detailText: "\(state.elapsedSeconds) s")
        ]
        items.append(contentsOf: state.primaryValues
            .sorted { $0.key < $1.key }
            .map { CPListItem(text: $0.key, detailText: String(format: "%.2f", $0.value)) })
        return CPListTemplate(title: "Telemetry", sections: [CPListSection(items: items)])
    }
}
#endif
