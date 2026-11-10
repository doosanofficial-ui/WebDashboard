import Foundation

/// Offline, display-only initial bearing between two original adjacent fixes.
/// Not sensor heading, vehicle orientation, current position, or navigation truth.
public enum TrackBearingEstimate {
    public struct Fix: Equatable, Sendable {
        public let sessionID: String
        public let archiveSequence: Int64
        public let predecessorArchiveSequence: Int64?
        public let scope: String
        public let generation: String
        public let segment: Int
        public let gpsOrdinal: Int
        public let timestamp: Double
        public let latitude: Double
        public let longitude: Double
        public let accuracy: Double?
        public let course: Double?
        public let qualified: Bool

        /// Adapter must retain original evidence and assign GPS ordinal and predecessor from all original LOCATION rows before filtering.
        public init(sessionID: String, archiveSequence: Int64, predecessorArchiveSequence: Int64?, scope: String, generation: String, segment: Int, gpsOrdinal: Int,
                    timestamp: Double, latitude: Double, longitude: Double,
                    accuracy: Double?, course: Double?, qualified: Bool) {
            self.sessionID = sessionID; self.archiveSequence = archiveSequence
            self.predecessorArchiveSequence = predecessorArchiveSequence; self.scope = scope; self.generation = generation
            self.segment = segment; self.gpsOrdinal = gpsOrdinal; self.timestamp = timestamp
            self.latitude = latitude; self.longitude = longitude
            self.accuracy = accuracy; self.course = course; self.qualified = qualified
        }
    }
    public enum Reason: String, Sendable {
        case estimated, invalidEvidence, discontinuity, timeGap, polarExcluded
        case separationTooLarge, insufficientSeparation
    }
    public struct Result: Equatable, Sendable {
        public let first: Fix
        public let last: Fix
        /// Valid provider course, independent of the pair estimate; never inferred.
        public let observedCourse: Double?
        /// Spherical initial azimuth clockwise from geographic north at first fix.
        public let bearing: Double?
        /// Spherical baseline only, not traveled distance or an accuracy claim.
        public let distance: Double?
        public let reason: Reason
    }
    public static func estimate(_ a: Fix, _ b: Fix) -> Result {
        let observed = b.course.flatMap { $0.isFinite && $0 >= 0 && $0 < 360 ? $0 : nil }
        func result(_ reason: Reason, bearing: Double? = nil, distance: Double? = nil) -> Result {
            Result(first: a, last: b, observedCourse: observed, bearing: bearing, distance: distance, reason: reason)
        }
        func valid(_ f: Fix) -> Bool {
            guard f.qualified, !f.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !f.scope.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !f.generation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  f.segment >= 0, f.gpsOrdinal >= 0, f.archiveSequence > 0,
                  f.timestamp.isFinite, f.timestamp >= 0, f.latitude.isFinite, f.longitude.isFinite,
                  abs(f.latitude) <= 90, abs(f.longitude) <= 180,
                  let accuracy = f.accuracy, accuracy.isFinite, accuracy >= 0, accuracy <= 20 else { return false }
            return true
        }
        guard valid(a), valid(b) else { return result(.invalidEvidence) }
        guard a.scope == b.scope, a.generation == b.generation, a.segment == b.segment,
              a.sessionID == b.sessionID, b.archiveSequence > a.archiveSequence,
              b.gpsOrdinal > a.gpsOrdinal, b.gpsOrdinal - a.gpsOrdinal == 1,
              b.predecessorArchiveSequence == a.archiveSequence else { return result(.discontinuity) }
        let dt = b.timestamp - a.timestamp
        guard dt >= 0.5, dt <= 10 else { return result(.timeGap) }
        guard abs(a.latitude) <= 80, abs(b.latitude) <= 80 else { return result(.polarExcluded) }
        let p = a.latitude * .pi / 180, q = b.latitude * .pi / 180
        let dl = ((b.longitude - a.longitude + 540).truncatingRemainder(dividingBy: 360) - 180) * .pi / 180
        let h = min(1, max(0, pow(sin((q - p) / 2), 2) + cos(p) * cos(q) * pow(sin(dl / 2), 2)))
        let distance = 6_371_008.8 * 2 * atan2(sqrt(h), sqrt(1 - h))
        guard distance <= 500 else { return result(.separationTooLarge) }
        guard let aAccuracy = a.accuracy, let bAccuracy = b.accuracy,
              distance >= max(20, 4 * (aAccuracy + bAccuracy)) else { return result(.insufficientSeparation) }
        let y = sin(dl) * cos(q)
        let x = cos(p) * sin(q) - sin(p) * cos(q) * cos(dl)
        let angle = atan2(y, x) * 180 / .pi
        let bearing = (angle + 360).truncatingRemainder(dividingBy: 360)
        return result(.estimated, bearing: bearing, distance: distance)
    }

    public enum SmoothingReason: String, Sendable {
        case smoothed, windowCount, staleSelection, windowDuration, invalidPair, lowResultant
    }
    public struct Smoothed: Equatable, Sendable {
        public let fixes: [Fix]
        public let pairs: [Result]
        public let bearing: Double?
        /// Directional concentration only, not confidence or accuracy.
        public let resultant: Double?
        public let reason: SmoothingReason
    }
    /// Equal-weight circular mean of 2–3 qualified consecutive pair estimates.
    /// Historical display only. Can lag turns. No cache, extrapolation or source replacement.
    /// asOf is a historical selection epoch in the SAME source clock, not elapsed replay time.
    public static func smooth(_ fixes: [Fix], asOf: Double) -> Smoothed {
        func result(_ reason: SmoothingReason, pairs: [Result] = [], bearing: Double? = nil,
                    resultant: Double? = nil) -> Smoothed {
            Smoothed(fixes: fixes, pairs: pairs, bearing: bearing, resultant: resultant, reason: reason)
        }
        guard (3...4).contains(fixes.count) else { return result(.windowCount) }
        guard let first = fixes.first, let last = fixes.last, asOf.isFinite,
              asOf - last.timestamp >= 0, asOf - last.timestamp <= 2 else { return result(.staleSelection) }
        guard last.timestamp - first.timestamp <= 6 else { return result(.windowDuration) }
        let pairs = zip(fixes, fixes.dropFirst()).map { estimate($0.0, $0.1) }
        let bearings = pairs.compactMap(\.bearing)
        guard bearings.count == pairs.count else { return result(.invalidPair, pairs: pairs) }
        let count = Double(bearings.count)
        let x = bearings.reduce(0.0) { $0 + cos($1 * .pi / 180) } / count
        let y = bearings.reduce(0.0) { $0 + sin($1 * .pi / 180) } / count
        let resultant = hypot(x, y)
        guard resultant >= 0.8 else { return result(.lowResultant, pairs: pairs, resultant: resultant) }
        let bearing = (atan2(y, x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        return result(.smoothed, pairs: pairs, bearing: bearing, resultant: resultant)
    }
}
