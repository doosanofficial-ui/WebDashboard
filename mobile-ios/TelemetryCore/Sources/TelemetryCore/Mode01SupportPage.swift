import Foundation

/// Stateless, unintegrated proposal. Never sends commands or owns a support cache.
public enum Mode01SupportPage {
    public enum Failure: Error, Equatable { case identity, address, context, variant, length, positivePID, chain, budget, assessment }
    public enum ProtocolVariant: String, Equatable, Sendable {
        case can11_250, can11_500, can29_250, can29_500
        var maximumID: UInt32 { self == .can29_250 || self == .can29_500 ? 0x1FFFFFFF : 0x7FF }
    }
    public enum Origin: Equatable, Sendable { case vehicle, synthetic }
    public enum Support: Equatable, Sendable { case unknown, supported, unsupported }
    public enum Availability: Equatable, Sendable { case unknown, responseReceived, noData, timedOut, disconnected, failed }
    public enum Stop: Equatable, Sendable { case candidate, terminal, budget, variantBoundary }

    /// Exact current caller identity. Must come from the validated native session,
    /// not inferred from a label or copied from a previously connected vehicle.
    public struct Context: Equatable, Sendable {
        public let vehicle: String
        public let adapter: String
        public let session: String
        public let generation: String
        public let protocolVariant: ProtocolVariant
        public let requestCANID: UInt32
        public let responseCANID: UInt32
        public init(vehicle: String, adapter: String, session: String, generation: String,
                    protocolVariant: ProtocolVariant, requestCANID: UInt32, responseCANID: UInt32) throws {
            guard [vehicle, adapter, session, generation].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else { throw Failure.identity }
            guard requestCANID <= protocolVariant.maximumID, responseCANID <= protocolVariant.maximumID else { throw Failure.address }
            self.vehicle = vehicle; self.adapter = adapter; self.session = session; self.generation = generation
            self.protocolVariant = protocolVariant; self.requestCANID = requestCANID; self.responseCANID = responseCANID
        }
    }
    public struct Evidence: Equatable, Sendable {
        public let context: Context
        public let page: UInt8
        public let mask: UInt32
        public let origin: Origin
        fileprivate init(context: Context, page: UInt8, mask: UInt32, origin: Origin) {
            self.context = context; self.page = page; self.mask = mask; self.origin = origin
        }
    }
    public struct Assessment: Equatable, Sendable {
        public let isCandidate: Bool
        public let observedSupport: Support
        public let currentAvailability: Availability
    }
    public struct Plan: Equatable, Sendable {
        public let nextCandidatePage: UInt8?
        public let reason: Stop
    }

    /// Input framing: exactly one reassembled positive diagnostic PDU including
    /// service and PID. No CAN header, PCI, padding, adapter echo or prompt.
    /// The transport/session must independently associate the response to expected.
    public static func decode(expected: Context, observed: Context, page: UInt8,
                              positivePDU: [UInt8], origin: Origin) throws -> Evidence {
        guard expected == observed else { throw Failure.context }
        guard page <= 0xC0, page % 32 == 0 else { throw Failure.variant }
        guard positivePDU.count == 6 else { throw Failure.length }
        guard positivePDU[0] == 0x41, positivePDU[1] == page else { throw Failure.positivePID }
        let mask = positivePDU.dropFirst(2).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Evidence(context: observed, page: page, mask: mask, origin: origin)
    }

    /// A presentation projection only. Not query admission, selection, scheduling,
    /// or a replacement for ECUCapabilityCatalogue and its existing evidence.
    public static func assess(_ evidence: Evidence?, current: Context, pid: UInt8,
                              isCandidate: Bool, availability: Availability) -> Assessment {
        var support: Support = .unknown
        if let e = evidence, e.context == current, e.origin == .vehicle,
           Int(e.page) < Int(pid), Int(pid) <= Int(e.page) + 32 {
            let bit = UInt32(1) << (32 - (Int(pid) - Int(e.page)))
            support = e.mask & bit == 0 ? .unsupported : .supported
        }
        return Assessment(isCandidate: isCandidate, observedSupport: support, currentAvailability: availability)
    }

    /// Caller-owned ephemeral chain. Returns only the immediate next candidate;
    /// never executes or authorizes a query. Bounds are product policy, not SAE limits.
    public static func plan(_ pages: [Evidence], current: Context, maximumPages: Int) throws -> Plan {
        guard (1...7).contains(maximumPages), pages.count <= 7 else { throw Failure.budget }
        for (index, evidence) in pages.enumerated() {
            guard evidence.context == current, evidence.origin == .vehicle, Int(evidence.page) == index * 32 else { throw Failure.chain }
            if index > 0, pages[index - 1].mask & 1 == 0 { throw Failure.chain }
        }
        guard let last = pages.last else { return Plan(nextCandidatePage: 0, reason: .candidate) }
        guard last.mask & 1 != 0 else { return Plan(nextCandidatePage: nil, reason: .terminal) }
        guard last.page < 0xC0 else { return Plan(nextCandidatePage: nil, reason: .variantBoundary) }
        guard pages.count < maximumPages else { return Plan(nextCandidatePage: nil, reason: .budget) }
        return Plan(nextCandidatePage: last.page + 32, reason: .candidate)
    }
}
