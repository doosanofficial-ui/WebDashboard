import SwiftUI
import TelemetryCore

/// Recorded coordinates rendered locally, without a network-backed basemap.
struct RecordedRouteView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let history: MeasurementReplay.LocationHistory?

    var body: some View {
        let points = history?.projectedPoints ?? []
        let raw = history?.samples ?? []
        let latest = raw.last
        RecordedHistoryCard(title: title) {
            routePlot(points: points, latest: latest)
        } summary: {
            VStack(alignment: .leading, spacing: 2) {
                summaryLayout {
                    Text("Recorded fixes: \(points.count)").font(.caption)
                    if raw.contains(where: { $0.location.horizontalAccuracy == nil }) {
                        Text("Some recorded accuracy is unknown").font(.caption2)
                    }
                }
                Text(latest?.isPlottable == false ? "Latest recorded fix not plottable" : "Recorded positions · not current position")
                    .font(.caption2)
            }
        } details: {
            VStack(alignment: .leading, spacing: 12) {
                if let history {
                    Text("\(history.samples.count) raw GPS rows · selected \(String(format: "%.1f", history.endSeconds)) seconds")
                    if history.truncated { Text("Latest 1000 of \(history.totalRowsInPrefix) original GPS rows") }
                }
                if let latest {
                    Text("Last raw source time: \(Date(timeIntervalSince1970: latest.location.originalTimestamp).formatted(date: .abbreviated, time: .standard))")
                    Text("Original source epoch: \(String(latest.location.originalTimestamp))")
                    Text("Recorded horizontal accuracy: \(latest.location.horizontalAccuracy.map { String($0) + " m" } ?? "unknown")")
                }
                Text("Local coordinate outline · lines connect recorded observations")
                if latest?.isPlottable == false { Text("Recorded positions · not current position") }
            }
        }
    }

    private var summaryLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 2))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
    }

    @ViewBuilder
    private func routePlot(points: [MeasurementReplay.ProjectedRoutePoint], latest: MeasurementReplay.RecordedLocationPoint?) -> some View {
        if points.isEmpty {
            Text("No plottable recorded fixes at this time").font(.caption)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
                Canvas { context, size in
                    let padding: CGFloat = 8
                    let side = min(size.width, size.height) - padding * 2
                    guard side > 0 else { return }
                    func coordinate(_ point: MeasurementReplay.ProjectedRoutePoint) -> CGPoint {
                        CGPoint(x: (size.width - side) / 2 + CGFloat(point.x) * side,
                                y: (size.height - side) / 2 + CGFloat(point.y) * side)
                    }
                    var path = Path()
                    var previousSegment: Int?
                    for point in points {
                        let coordinate = coordinate(point)
                        if previousSegment == point.sourceSegment { path.addLine(to: coordinate) }
                        else { path.move(to: coordinate) }
                        previousSegment = point.sourceSegment
                    }
                    context.stroke(path, with: .color(TelemetryTheme.accent), lineWidth: 3)
                    for point in points {
                        let position = coordinate(point)
                        context.fill(Path(ellipseIn: CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)),
                                     with: .color(TelemetryTheme.accent))
                    }
                    if let latest, latest.isPlottable, let marker = points.last, marker.id == latest.id {
                        let position = coordinate(marker)
                        context.fill(Path(ellipseIn: CGRect(x: position.x - 5, y: position.y - 5, width: 10, height: 10)),
                                     with: .color(TelemetryTheme.warning))
                    }
                }
                .accessibilityLabel("Local recorded GPS route")
                .accessibilityValue("\(points.count) recorded fixes; not current position")
        }
    }
}
