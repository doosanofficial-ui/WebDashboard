import ActivityKit
import SwiftUI
import WidgetKit

@main
struct RecordingActivityBundle: WidgetBundle {
    var body: some Widget { compatibleWidget }

    // WidgetBundleBuilder supports #available without else, not #unavailable.
    // Its public availability erasure gives both branches the same result type.
    private var compatibleWidget: some Widget {
        if #available(iOS 18.0, *) {
            return WidgetBundleBuilder.buildOptional(
                WidgetBundleBuilder.buildLimitedAvailability(SupplementalRecordingActivityWidget()))
        } else {
            return WidgetBundleBuilder.buildOptional(
                WidgetBundleBuilder.buildLimitedAvailability(RecordingActivityWidget()))
        }
    }
}

@available(iOSApplicationExtension 18.0, *)
private struct SupplementalRecordingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        RecordingActivityWidget().configuration.supplementalActivityFamilies([.small])
    }
}

struct RecordingActivityWidget: Widget {
    var body: some WidgetConfiguration { configuration }
    fileprivate var configuration: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            if #available(iOS 18.0, *) {
                AdaptiveRecordingActivity(context: context)
            } else {
                RecordingActivityCard(context: context, compact: false)
            }
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { status(context).font(.headline) }
                DynamicIslandExpandedRegion(.trailing) { elapsed(context).font(.headline.monospacedDigit()) }
                DynamicIslandExpandedRegion(.bottom) { readings(context).padding(.bottom, 4) }
            } compactLeading: {
                Text(context.attributes.isDemo ? "DEMO" : (!context.isStale && context.state.phase == .recording ? "REC" : "—"))
                    .font(.caption2.bold()).foregroundStyle(context.isStale ? .orange : .cyan)
            } compactTrailing: {
                Text(!context.isStale && context.state.phase == .recording ? "●" : "—").foregroundStyle(context.isStale ? .orange : .red)
            } minimal: {
                Text(context.attributes.isDemo ? "DEMO" : (!context.isStale && context.state.phase == .recording ? "R" : "—"))
                    .font(.caption.bold()).foregroundStyle(context.isStale ? .orange : .cyan)
            }
        }
    }
}

@available(iOSApplicationExtension 18.0, *)
private struct AdaptiveRecordingActivity: View {
    @Environment(\.activityFamily) private var family
    let context: ActivityViewContext<RecordingActivityAttributes>
    var body: some View { RecordingActivityCard(context: context, compact: family == .small) }
}

private struct RecordingActivityCard: View {
    let context: ActivityViewContext<RecordingActivityAttributes>
    let compact: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 10) {
            HStack {
                status(context).font(compact ? .caption.bold() : .headline)
                Spacer(minLength: 4)
                elapsed(context).font(.caption.monospacedDigit())
            }
            readings(context)
            // ActivityKit may delay stale-state rendering. Keep the actual
            // snapshot time visible even before iOS delivers that transition.
            let timestamp = Date(timeIntervalSince1970: context.state.sampledAt).formatted(date: .omitted, time: .standard)
            let updated = context.attributes.korean ? "화면 정보 갱신" : "Snapshot updated"
            if compact {
                VStack(alignment: .leading, spacing: 1) {
                    Text(updated)
                    Text(timestamp).monospacedDigit()
                }.font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Text(updated + " " + timestamp)
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(compact ? 10 : 16)
        .activityBackgroundTint(.black)
        .activitySystemActionForegroundColor(.cyan)
    }
}

private func status(_ context: ActivityViewContext<RecordingActivityAttributes>) -> Text {
    let ko = context.attributes.korean
    let prefix = context.attributes.isDemo ? "DEMO · " : ""
    if context.state.phase == .interrupted { return Text(prefix + (ko ? "기록 중단" : "Interrupted")).foregroundColor(.orange) }
    if context.state.phase == .stopped { return Text(prefix + (ko ? "기록 종료" : "Stopped")).foregroundColor(.secondary) }
    if context.isStale { return Text(prefix + (ko ? "업데이트 지연" : "Update delayed")).foregroundColor(.orange) }
    return Text(prefix + (ko ? "기록 중" : "Recording")).foregroundColor(.cyan)
}

@ViewBuilder
private func elapsed(_ context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
    if !context.isStale && context.state.phase == .recording {
        Text(context.attributes.startedAt, style: .timer)
    } else {
        Text("—")
    }
}

private func readings(_ context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
    HStack(alignment: .top, spacing: 12) {
        if context.state.readings.isEmpty {
            Text(context.attributes.korean ? "신호 선택 없음" : "No signals selected")
                .font(.caption).foregroundStyle(.secondary)
        }
        ForEach(Array(context.state.readings.enumerated()), id: \.offset) { _, reading in
            VStack(alignment: .leading, spacing: 2) {
                Text(reading.name).font(.caption).lineLimit(1)
                Text(!context.isStale && context.state.phase == .recording ? reading.value.map { $0 + " " + reading.unit } ?? "—" : "—")
                    .font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
