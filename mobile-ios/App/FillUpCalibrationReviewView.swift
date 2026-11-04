import SwiftUI
import TelemetryCore

/// The host supplies an already computed, independently reviewed proposal. Never calls propose().
/// Nil is unavailable, not factor 1. There is deliberately no apply action or evidence builder.
@MainActor
struct FillUpCalibrationReviewView: View {
    let proposal: OfflineFuelCalibration.Proposal?
    var body: some View {
        VStack(alignment: .leading, spacing: TelemetryTheme.Spacing.small) {
            Text(AppLocalization.text("Conditional calibration proposal")).font(.headline)
            Text(AppLocalization.text("Review only. This is not a correction or proof of fuel accuracy."))
                .fixedSize(horizontal: false, vertical: true)
            if let proposal {
                FillUpReviewValue(label: "Proposed factor", value: FillUpReviewPresentation.number(proposal.factor))
                FillUpReviewValue(label: "Reference added liters", value: FillUpReviewPresentation.number(proposal.referenceLiters))
                FillUpReviewValue(label: "Original measured consumed liters", value: FillUpReviewPresentation.number(proposal.measuredLiters))
                FillUpReviewValue(label: "Evidence adapter", value: proposal.evidence.adapterID)
                FillUpReviewValue(label: "Proof reference", value: proposal.evidence.proofReference)
                FillUpReviewValue(label: "Vehicle identity", value: proposal.evidence.context.vehicleID)
                FillUpReviewValue(label: "Tank identity", value: proposal.evidence.context.tankID)
                FillUpReviewValue(label: "Odometer reset epoch", value: proposal.evidence.context.epochID)
                FillUpReviewValue(label: "Verified timeline reference", value: proposal.evidence.context.timelineID)
                FillUpReviewValue(label: "Original source reference", value: proposal.evidence.context.rawSourceID)
                Text(AppLocalization.text("Eligibility depends on the supplied adapter evidence. Internal consistency cannot authenticate its claims."))
            } else {
                Text(AppLocalization.text("Unavailable: independently verified matching evidence was not supplied."))
                    .foregroundStyle(TelemetryTheme.warning)
            }
            Text(AppLocalization.text("Manual fill entries and session totals cannot establish verified tank scope, exact post-fill anchors, complete measured coverage, compatible units or original provenance."))
                .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
            Text(AppLocalization.text("Tank repeatability, entry error and sensor accuracy remain unquantified."))
                .font(.caption).foregroundStyle(TelemetryTheme.mutedText)
        }
        .fixedSize(horizontal: false, vertical: true)
        .telemetrySurface()
    }
}
