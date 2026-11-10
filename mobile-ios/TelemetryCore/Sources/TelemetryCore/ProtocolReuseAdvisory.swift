import Foundation

/// Passive advisory only. This type has no transport, command, cache, or persistence API.
/// Exact snapshots are deliberately not normalized; a mismatch is conservative.
public enum ProtocolReuseAdvisory {
    public struct Binding: Equatable, Sendable {
        /// A complete, deterministic, lossless AdapterProfile snapshot, not its ID/name.
        /// The integration adapter must supply every field, including query/signal definitions.
        public let profileSnapshot: Data
        /// Independently observed endpoint/peripheral + transport configuration fingerprint.
        /// This is not proof of physical adapter identity or vehicle identity.
        public let transportFingerprint: String
        /// Explicit selected vehicle context, never an inferred physical VIN identity.
        public let vehicleContext: String
        /// Exact validated negotiated-protocol evidence token, not a guessed command.
        public let protocolEvidence: String
        public let sessionID: String
        public let generation: UInt64?
        /// Clock lifetime token. Monotonic times from different lifetimes are incomparable.
        public let clockEpoch: String

        public init(profileSnapshot: Data, transportFingerprint: String,
                    vehicleContext: String, protocolEvidence: String,
                    sessionID: String, generation: UInt64?, clockEpoch: String) {
            self.profileSnapshot = profileSnapshot
            self.transportFingerprint = transportFingerprint
            self.vehicleContext = vehicleContext
            self.protocolEvidence = protocolEvidence
            self.sessionID = sessionID
            self.generation = generation
            self.clockEpoch = clockEpoch
        }
        fileprivate var isKnown: Bool {
            !profileSnapshot.isEmpty && generation != nil &&
            [transportFingerprint, vehicleContext, protocolEvidence, sessionID, clockEpoch]
                .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        }
    }

    public struct Observation: Equatable, Sendable {
        public let binding: Binding
        public let observedAtMonotonicNanos: UInt64
        /// Must be derived from an accepted negotiated observation, not user preference.
        public let isVerifiedNegotiatedObservation: Bool
        public init(binding: Binding, observedAtMonotonicNanos: UInt64,
                    isVerifiedNegotiatedObservation: Bool) {
            self.binding = binding
            self.observedAtMonotonicNanos = observedAtMonotonicNanos
            self.isVerifiedNegotiatedObservation = isVerifiedNegotiatedObservation
        }
    }

    public struct Request: Equatable, Sendable {
        public let binding: Binding
        public let nowMonotonicNanos: UInt64
        /// Caller policy, not a manufacturer-approved validity duration. Zero disables.
        public let maximumAgeNanos: UInt64
        /// nil means unknown and invalidates. The caller needs continuous evidence.
        public let resetSinceObservation: Bool?
        public let errorSinceObservation: Bool?
        public let ambiguitySinceObservation: Bool?
        public init(binding: Binding, nowMonotonicNanos: UInt64, maximumAgeNanos: UInt64,
                    resetSinceObservation: Bool? = nil, errorSinceObservation: Bool? = nil,
                    ambiguitySinceObservation: Bool? = nil) {
            self.binding = binding
            self.nowMonotonicNanos = nowMonotonicNanos
            self.maximumAgeNanos = maximumAgeNanos
            self.resetSinceObservation = resetSinceObservation
            self.errorSinceObservation = errorSinceObservation
            self.ambiguitySinceObservation = ambiguitySinceObservation
        }
    }

    public enum Reason: String, Equatable, Sendable {
        case missingObservation, invalidated, unknownBinding, bindingMismatch
        case unverifiedObservation, invalidTime, stale
        case candidateRequiresFreshVerification
    }
    public struct Decision: Equatable, Sendable {
        public let reason: Reason
        /// Unconditional: candidate status never authorizes skipping canonical startup.
        public var requiresFullInitialization: Bool { true }
        public var requiresFreshVerificationBeforeOptimization: Bool { true }
        public var authorizesOptimization: Bool { false }
        fileprivate init(_ reason: Reason) { self.reason = reason }
    }

    public static func evaluate(_ observation: Observation?, request: Request) -> Decision {
        guard let observation else { return Decision(.missingObservation) }
        guard request.resetSinceObservation == false,
              request.errorSinceObservation == false,
              request.ambiguitySinceObservation == false else { return Decision(.invalidated) }
        guard observation.binding.isKnown, request.binding.isKnown else { return Decision(.unknownBinding) }
        guard observation.binding == request.binding else { return Decision(.bindingMismatch) }
        guard observation.isVerifiedNegotiatedObservation else { return Decision(.unverifiedObservation) }
        guard request.maximumAgeNanos > 0,
              request.nowMonotonicNanos >= observation.observedAtMonotonicNanos else {
            return Decision(.invalidTime)
        }
        // Subtract only after ordering, avoiding UInt64 underflow and expiry-addition overflow.
        guard request.nowMonotonicNanos - observation.observedAtMonotonicNanos <= request.maximumAgeNanos else {
            return Decision(.stale)
        }
        return Decision(.candidateRequiresFreshVerification)
    }
}
