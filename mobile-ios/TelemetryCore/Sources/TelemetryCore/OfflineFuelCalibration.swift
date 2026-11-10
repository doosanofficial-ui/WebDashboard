import Foundation

/// Offline proposal only. No sensor, record, setting, provider or persistence mutation.
/// Validation checks internal consistency, NOT real-world truth or measurement accuracy.
public enum OfflineFuelCalibration {
    /// Adapter asserts EVERY supplied fill and coverage piece belongs to this one context.
    /// timelineID identifies an exact validated mapping of post-fill times and coverage times.
    public struct Context: Equatable, Sendable {
        public let vehicleID, tankID, epochID, timelineID, rawSourceID: String
        public init(vehicleID: String, tankID: String, epochID: String, timelineID: String, rawSourceID: String) {
            self.vehicleID = vehicleID; self.tankID = tankID; self.epochID = epochID
            self.timelineID = timelineID; self.rawSourceID = rawSourceID
        }
    }
    /// These claims must come from an independently verified evidence adapter, not inferred
    /// from file names, adjacent rows, a session total, or a coverage fraction of one.
    public struct Claims: Equatable, Sendable {
        public let postFillAnchors, completeHistory, completeCoverage: Bool
        public let compatibleUnadjustedConsumedLiters, originalProvenance: Bool
        public init(postFillAnchors: Bool, completeHistory: Bool, completeCoverage: Bool,
                    compatibleUnadjustedConsumedLiters: Bool, originalProvenance: Bool) {
            self.postFillAnchors = postFillAnchors; self.completeHistory = completeHistory
            self.completeCoverage = completeCoverage
            self.compatibleUnadjustedConsumedLiters = compatibleUnadjustedConsumedLiters
            self.originalProvenance = originalProvenance
        }
    }
    /// Adapter snapshot, not a native LocalFillUpRecord. Times are verified post-fill instants.
    /// All units are original or traceably converted liters, with conversion proof in evidence.
    /// No missing/unknown fill state: false full means positively known partial, not unknown.
    public struct Fill: Equatable, Sendable {
        public let id: String
        public let postFillSeconds: Double
        public let litersAdded: Double?
        public let full, completeSincePrevious: Bool
        public init(id: String, postFillSeconds: Double, litersAdded: Double?, full: Bool, completeSincePrevious: Bool) {
            self.id = id; self.postFillSeconds = postFillSeconds; self.litersAdded = litersAdded
            self.full = full; self.completeSincePrevious = completeSincePrevious
        }
    }
    /// Exact consumed-fuel integral on [start, end), traceable to original unadjusted evidence.
    /// Proof must explain boundary handling, zero-consumption periods and every original row.
    /// No excluded, unknown, gap-filled, interpolated-as-measured or overlapping intervals.
    public struct Piece: Equatable, Sendable {
        public let id, originalProofReference: String
        public let startSeconds, endSeconds, consumedLiters: Double
        public init(id: String, originalProofReference: String, startSeconds: Double,
                    endSeconds: Double, consumedLiters: Double) {
            self.id = id; self.originalProofReference = originalProofReference
            self.startSeconds = startSeconds; self.endSeconds = endSeconds; self.consumedLiters = consumedLiters
        }
    }
    /// No initializer default grants trust. Caller is responsible for verification authenticity.
    /// proofReference binds immutable originals, per-row context and all claims to this snapshot.
    /// This is NOT a security boundary: callers can lie; this calculator cannot authenticate proof.
    public struct Evidence: Equatable, Sendable {
        public let adapterID, proofReference: String
        public let externallyVerified: Bool
        public let context: Context
        public let claims: Claims
        public let fills: [Fill]
        public let pieces: [Piece]
        /// Explicit reviewer bounds, not universal vehicle truth or an accuracy guarantee.
        public let reviewerMinimumFactor, reviewerMaximumFactor: Double
        public init(adapterID: String, proofReference: String, externallyVerified: Bool,
                    context: Context, claims: Claims, fills: [Fill], pieces: [Piece],
                    reviewerMinimumFactor: Double, reviewerMaximumFactor: Double) {
            self.adapterID = adapterID; self.proofReference = proofReference; self.externallyVerified = externallyVerified
            self.context = context; self.claims = claims; self.fills = fills; self.pieces = pieces
            self.reviewerMinimumFactor = reviewerMinimumFactor; self.reviewerMaximumFactor = reviewerMaximumFactor
        }
    }
    public struct Proposal: Equatable, Sendable {
        /// Reference added liters / original unadjusted measured consumed liters. Never auto-apply.
        public let factor, referenceLiters, measuredLiters: Double
        public let evidence: Evidence
        public var uncertainty: String { "Conditional proposal only. Tank repeatability, entry error and sensor accuracy remain unquantified." }
    }
    private static func normalPositive(_ x: Double) -> Bool { x.isFinite && x >= Double.leastNormalMagnitude }
    private static func present(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// nil means unavailable. No fallback factor, extrapolation, sorting, epsilon snapping or application.
    public static func propose(_ input: Evidence? = nil) -> Proposal? {
        guard let e = input, e.externallyVerified else { return nil }
        let c = e.claims
        guard c.postFillAnchors, c.completeHistory, c.completeCoverage,
              c.compatibleUnadjustedConsumedLiters, c.originalProvenance else { return nil }
        let s = e.context
        guard [e.adapterID, e.proofReference, s.vehicleID, s.tankID, s.epochID, s.timelineID, s.rawSourceID].allSatisfy(present),
              normalPositive(e.reviewerMinimumFactor), normalPositive(e.reviewerMaximumFactor),
              e.reviewerMinimumFactor <= e.reviewerMaximumFactor else { return nil }
        guard e.fills.count >= 2, e.fills.count <= 10_000,
              !e.pieces.isEmpty, e.pieces.count <= 200_000,
              let first = e.fills.first, let last = e.fills.last, first.full, last.full else { return nil }
        var fillIDs = Set<String>(), pieceIDs = Set<String>(), proofIDs = Set<String>()
        var previousTime: Double?
        var reference = 0.0
        for (i, f) in e.fills.enumerated() {
            guard present(f.id), fillIDs.insert(f.id).inserted,
                  f.postFillSeconds.isFinite, f.postFillSeconds >= 0 else { return nil }
            if let previousTime, f.postFillSeconds <= previousTime { return nil }
            if i > 0 {
                guard f.completeSincePrevious, let liters = f.litersAdded, normalPositive(liters) else { return nil }
                if i < e.fills.count - 1 && f.full { return nil } // One consecutive full-to-full interval.
                reference += liters
            }
            previousTime = f.postFillSeconds
        }
        var cursor = first.postFillSeconds, measured = 0.0
        for p in e.pieces {
            guard present(p.id), present(p.originalProofReference),
                  pieceIDs.insert(p.id).inserted, proofIDs.insert(p.originalProofReference).inserted,
                  p.startSeconds.isFinite, p.endSeconds.isFinite,
                  p.startSeconds == cursor, p.endSeconds > p.startSeconds,
                  p.endSeconds <= last.postFillSeconds,
                  p.consumedLiters == 0 || normalPositive(p.consumedLiters) else { return nil }
            measured += p.consumedLiters
            cursor = p.endSeconds
        }
        guard cursor == last.postFillSeconds, normalPositive(reference), normalPositive(measured) else { return nil }
        let factor = reference / measured // Divisor is finite, normal and strictly positive.
        guard normalPositive(factor), factor >= e.reviewerMinimumFactor,
              factor <= e.reviewerMaximumFactor else { return nil }
        return Proposal(factor: factor, referenceLiters: reference, measuredLiters: measured, evidence: e)
    }
}
