import SwiftUI
import Foundation
import TelemetryCore

struct RetentionPlanReviewRequest {
    let plan: ArchiveRetentionPlanner.Plan
    let context: OperationReviewContext
}
@MainActor
struct RetentionPlanReviewPanel: View {
    var plan: ArchiveRetentionPlanner.Plan? = nil
    var context: OperationReviewContext = .unknown
    var onReviewRequested: ((RetentionPlanReviewRequest) -> Void)? = nil
    var body: some View {
        OperationReviewFrame(title: "Retention proposal", context: context) {
            OperationReviewText(key: "This is a proposed list, not permission to delete. No archives are changed.")
            if let plan {
                OperationReviewField(label: "Plan revision", value: plan.snapshot.revision)
                OperationReviewField(label: "Scope", value: plan.snapshot.scope)
                OperationReviewField(label: "Evaluation time", value: String(plan.evaluatedAt))
                OperationReviewField(label: "Cutoff time", value: plan.cutoff.map { String($0) } ?? "Unknown")
                OperationReviewField(label: "Policy", value: String(describing: plan.policy))
                OperationReviewField(label: "Proposed candidate count", value: String(plan.candidates.count))
                OperationReviewField(label: "Decision count", value: String(plan.decisions.count))
                OperationReviewText(key: "First 100 decisions shown. Full review and fresh validation are required before any separate action.")
                ForEach(Array(plan.decisions.prefix(100)), id: \.id) { decision in
                    OperationReviewField(label: "Archive", value: decision.id)
                    OperationReviewField(label: "Retention reason", value: decision.reason.rawValue)
                }
                OperationReviewButton(title: "Request retention review", action: onReviewRequested.map { callback in
                    { callback(.init(plan: plan, context: context)) }
                })
            } else { OperationReviewText(key: "No proposal supplied") }
        }
    }
}

struct SupportBundleReviewRequest {
    let bundle: LocalSupportBundle
    let context: OperationReviewContext
}
@MainActor
struct SupportBundleReviewPanel: View {
    var bundle: LocalSupportBundle? = nil
    var context: OperationReviewContext = .unknown
    var onReviewRequested: ((SupportBundleReviewRequest) -> Void)? = nil
    var body: some View {
        OperationReviewFrame(title: "Redacted support preview", context: context) {
            OperationReviewText(key: "Redacted support is not anonymous. Aggregates may reveal activity. ZIP is not encrypted.")
            OperationReviewText(key: "Preview is incomplete: at most 1024 UTF-8 bytes per entry, with escaped controls and replacement characters for invalid UTF-8. It cannot authorize sharing.")
            if let bundle {
                OperationReviewField(label: "Archive bytes", value: String(bundle.archive.count))
                OperationReviewField(label: "SHA-256", value: bundle.sha256)
                ForEach(bundle.entries, id: \.name) { entry in
                    OperationReviewField(label: "Entry", value: entry.name)
                    OperationReviewField(label: "Entry bytes", value: String(entry.byteCount))
                    OperationReviewField(label: "SHA-256", value: entry.sha256)
                    Text(verbatim: OperationReviewPlaintext.render(entry.content))
                        .font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                }
                OperationReviewButton(title: "Request support review", action: onReviewRequested.map { callback in
                    { callback(.init(bundle: bundle, context: context)) }
                })
            } else { OperationReviewText(key: "No proposal supplied") }
        }
    }
}

struct RawExportReviewRequest {
    let bundle: SelectedRawBundle
    let context: OperationReviewContext
}
@MainActor
struct RawExportReviewPanel: View {
    var bundle: SelectedRawBundle? = nil
    var context: OperationReviewContext = .unknown
    var onReviewRequested: ((RawExportReviewRequest) -> Void)? = nil
    var body: some View {
        OperationReviewFrame(title: "Sensitive raw export preview", context: context) {
            OperationReviewText(key: "RAW data may contain GPS, VIN and private content. It is not redacted or anonymous. ZIP is not encrypted.")
            OperationReviewText(key: "Preview is incomplete: at most 1024 UTF-8 bytes per entry, with escaped controls and replacement characters for invalid UTF-8. It cannot authorize sharing.")
            if let bundle {
                OperationReviewField(label: "Scope", value: bundle.scope)
                OperationReviewField(label: "Export revision", value: bundle.revision)
                OperationReviewField(label: "Archive bytes", value: String(bundle.archive.count))
                OperationReviewField(label: "SHA-256", value: bundle.sha256)
                ForEach(bundle.entries, id: \.name) { entry in
                    OperationReviewField(label: "Entry", value: entry.name)
                    OperationReviewField(label: "Record revision", value: entry.record.revision)
                    OperationReviewField(label: "Archive", value: entry.record.id)
                    OperationReviewField(label: "Native format", value: entry.record.format.rawValue)
                    OperationReviewField(label: "Native mode", value: entry.record.nativeMode)
                    OperationReviewField(label: "Entry bytes", value: String(entry.byteCount))
                    OperationReviewField(label: "SHA-256", value: entry.sha256)
                    Text(verbatim: OperationReviewPlaintext.render(entry.record.content))
                        .font(.caption.monospaced()).fixedSize(horizontal: false, vertical: true)
                }
                OperationReviewButton(title: "Request raw export review", action: onReviewRequested.map { callback in
                    { callback(.init(bundle: bundle, context: context)) }
                })
            } else { OperationReviewText(key: "No proposal supplied") }
        }
    }
}

struct UpdateNoticeReviewRequest {
    let result: UpdateNoticePolicy.Result
    let context: OperationReviewContext
}
@MainActor
struct UpdateNoticeReviewPanel: View {
    var result: UpdateNoticePolicy.Result? = nil
    var context: OperationReviewContext = .unknown
    var onReviewRequested: ((UpdateNoticeReviewRequest) -> Void)? = nil
    var body: some View {
        OperationReviewFrame(title: "Update notice review", context: context) {
            OperationReviewText(key: "A destination reference is not signing proof. This panel cannot check, open, install or persist an update choice.")
            if let result {
                switch result {
                case .rejected: OperationReviewText(key: "Update rejected")
                case .noUpdate: OperationReviewText(key: "No update offered")
                case .suppressed: OperationReviewText(key: "Update notice suppressed")
                case .deferred: OperationReviewText(key: "Update review deferred")
                case let .available(version, destination):
                    OperationReviewText(key: "Update proposal available")
                    OperationReviewField(label: "Offered version", value: "\(version.major).\(version.minor).\(version.patch)")
                    OperationReviewField(label: "App identity", value: destination.identity.app)
                    OperationReviewField(label: "Bundle identity", value: destination.identity.bundle)
                    OperationReviewField(label: "Distribution channel", value: destination.identity.channel.rawValue)
                    OperationReviewField(label: "Store identity", value: destination.identity.store)
                    OperationReviewField(label: "Destination reference", value: destination.opaqueID.uuidString)
                }
                OperationReviewButton(title: "Request update review", action: onReviewRequested.map { callback in
                    { callback(.init(result: result, context: context)) }
                })
            } else { OperationReviewText(key: "No proposal supplied") }
        }
    }
}
