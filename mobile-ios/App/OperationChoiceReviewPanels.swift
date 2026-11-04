import SwiftUI
import TelemetryCore

/// Choice describes what to review; it does not mutate a grant, policy, or recorder.
enum RecordingChoiceReview: String, CaseIterable, Identifiable {
    case keepOff = "Review keeping automatic recording off"
    case arm = "Review arming automatic recording"
    case disarm = "Review disarming automatic recording"
    var id: String { rawValue }
}
struct RecordingChoiceReviewRequest {
    let choice: RecordingChoiceReview
    let snapshot: RecordingTriggerPolicy?
    let context: OperationReviewContext
}
@MainActor
struct RecordingChoiceReviewPanel: View {
    let snapshot: RecordingTriggerPolicy?
    var context: OperationReviewContext = .unknown
    var onReviewRequested: ((RecordingChoiceReviewRequest) -> Void)? = nil
    init(snapshot: RecordingTriggerPolicy? = nil, context: OperationReviewContext = .unknown,
         onReviewRequested: ((RecordingChoiceReviewRequest) -> Void)? = nil) {
        self.snapshot = snapshot; self.context = context; self.onReviewRequested = onReviewRequested
    }
    var body: some View {
        OperationReviewFrame(title: "Recording choices", context: context) {
            OperationReviewField(label: "Recording state", value: snapshot?.state.rawValue ?? "Unknown")
            OperationReviewField(label: "Permission observed", value: snapshot.map { String($0.permitted) } ?? "Unknown")
            OperationReviewField(label: "Connection observed", value: snapshot.map { String($0.connected) } ?? "Unknown")
            OperationReviewField(label: "Generation", value: snapshot.map { String($0.generation) } ?? "Unknown")
            OperationReviewField(label: "Source", value: snapshot?.source ?? "Unknown")
            OperationReviewField(label: "Session", value: snapshot?.session ?? "Unknown")
            OperationReviewField(label: "Instance", value: snapshot?.instance ?? "Unknown")
            OperationReviewText(key: "No choice is selected. Review does not change the observed recording state. Automatic recording defaults off.")
            ForEach(RecordingChoiceReview.allCases) { choice in
                OperationReviewButton(title: choice.rawValue, action: onReviewRequested.map { callback in
                    { callback(.init(choice: choice, snapshot: snapshot, context: context)) }
                })
            }
        }
    }
}

enum ConnectionChoiceReview: String, CaseIterable, Identifiable {
    case keepOff = "Review keeping launch connection off"
    case once = "Review one launch connection"
    case future = "Review bounded future launch connections"
    var id: String { rawValue }
}
struct ConnectionChoiceReviewRequest {
    let choice: ConnectionChoiceReview
    let grant: LaunchConnectionPolicy.Grant?
    let state: LaunchConnectionPolicy.State
    let context: OperationReviewContext
}
@MainActor
struct ConnectionChoiceReviewPanel: View {
    var grant: LaunchConnectionPolicy.Grant? = nil
    var state: LaunchConnectionPolicy.State = .unknown
    var context: OperationReviewContext = .unknown
    var onReviewRequested: ((ConnectionChoiceReviewRequest) -> Void)? = nil
    var body: some View {
        OperationReviewFrame(title: "Launch connection choices", context: context) {
            OperationReviewField(label: "Connection state", value: state.rawValue)
            OperationReviewField(label: "Grant enabled", value: grant.map { String($0.enabled) } ?? "Unknown")
            OperationReviewField(label: "Future launches", value: grant.map { String($0.futureLaunches) } ?? "Unknown")
            OperationReviewField(label: "Attempt limit", value: grant.map { String($0.maxAttempts) } ?? "Unknown")
            OperationReviewField(label: "Generation", value: grant.map { String($0.generation) } ?? "Unknown")
            OperationReviewField(label: "Profile", value: grant?.profile ?? "Unknown")
            OperationReviewField(label: "Fingerprint", value: grant?.fingerprint ?? "Unknown")
            OperationReviewText(key: "No choice is selected. This panel cannot connect or change a grant.")
            ForEach(ConnectionChoiceReview.allCases) { choice in
                OperationReviewButton(title: choice.rawValue, action: onReviewRequested.map { callback in
                    { callback(.init(choice: choice, grant: grant, state: state, context: context)) }
                })
            }
        }
    }
}
