import Foundation

/// Offline proposal only. Does not register queries or issue transport commands.
/// Variant reference: ELM327DSJ, page 45, reassembled application message.
public enum Mode01BatchProposal {
    public static let applicationVariant = "elm327dsj-p45-application-v1"

    public struct Context: Codable, Equatable, Sendable {
        public let request: Int
        public let response: Int
        public let `protocol`: String
        public let session: String
        public let generation: Int64
        public let adapter: String
        public init(request: Int, response: Int, protocol protocolName: String,
                    session: String, generation: Int64, adapter: String) {
            self.request = request; self.response = response; self.protocol = protocolName
            self.session = session; self.generation = generation; self.adapter = adapter
        }
    }
    public struct Item: Codable, Equatable, Sendable {
        public let pid: Int
        public let length: Int
        public let context: Context
        public let supportEvidence: String
        public let lengthEvidence: String
        public let proven: Bool
        public init(pid: Int, length: Int, context: Context, supportEvidence: String,
                    lengthEvidence: String, proven: Bool) {
            self.pid = pid; self.length = length; self.context = context
            self.supportEvidence = supportEvidence; self.lengthEvidence = lengthEvidence; self.proven = proven
        }
    }
    public struct Input: Codable, Equatable, Sendable {
        public let enabled: Bool?
        public let context: Context
        public let items: [Item]
        public let adapterContext: Context
        public let adapterBatchCapable: Bool
        public let adapterEvidence: String
        public let correlation: String
        public let variant: String
        public init(enabled: Bool = false, context: Context, items: [Item], adapterContext: Context,
                    adapterBatchCapable: Bool = false, adapterEvidence: String,
                    correlation: String, variant: String) {
            self.enabled = enabled; self.context = context; self.items = items
            self.adapterContext = adapterContext; self.adapterBatchCapable = adapterBatchCapable
            self.adapterEvidence = adapterEvidence; self.correlation = correlation; self.variant = variant
        }
    }
    /// Payload includes SID; already validated ISO-TP length, no transport padding.
    /// Caller must retain original raw evidence and prove exact response attribution.
    public struct Record: Codable, Equatable, Sendable {
        public let context: Context
        public let correlation: String
        public let variant: String
        public let status: String
        public let payload: [UInt8]
        public let sourceEvidence: String
        public let rawEvidence: String
        public init(context: Context, correlation: String, variant: String, status: String,
                    payload: [UInt8], sourceEvidence: String, rawEvidence: String) {
            self.context = context; self.correlation = correlation; self.variant = variant
            self.status = status; self.payload = payload; self.sourceEvidence = sourceEvidence
            self.rawEvidence = rawEvidence
        }
    }
    public struct Plan: Equatable, Sendable {
        public let request: [UInt8]
        public let evidence: Input
        fileprivate init(request: [UInt8], evidence: Input) {
            self.request = request; self.evidence = evidence
        }
    }
    public struct Value: Equatable, Sendable {
        public let pid: UInt8
        public let bytes: [UInt8]
    }
    public struct Outcome: Equatable, Sendable {
        /// Stable reason codes; no failures imply a new unsupported-PID verdict.
        public let input: Input
        public let reason: String
        public let values: [Value]?
        public let record: Record?
        public let plan: Plan?
        /// Suggestion only, tied to plan.evidence context. Never executed here.
        public let fallback: [[UInt8]]?
    }
    private static func present(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    public static func evaluate(_ input: Input, record: Record? = nil) -> Outcome {
        let c = input.context
        var plan: Plan?
        func failure(_ reason: String) -> Outcome {
            let singles: [[UInt8]]? = plan != nil && record != nil
                ? input.items.map { [UInt8(1), UInt8($0.pid)] } : nil
            return Outcome(input: input, reason: reason, values: nil, record: record, plan: plan, fallback: singles)
        }
        guard input.enabled == true else { return failure("disabled") }
        guard ["iso15765-4-can11-500", "iso15765-4-can11-250"].contains(c.protocol),
              (0x7E0...0x7E7).contains(c.request), c.response == c.request + 8,
              present(c.session), present(c.adapter), c.generation >= 0 else {
            return failure("context_invalid")
        }
        guard input.variant == applicationVariant else { return failure("variant") }
        guard present(input.correlation) else { return failure("correlation") }
        guard input.adapterBatchCapable, present(input.adapterEvidence) else { return failure("adapter_unproven") }
        guard input.adapterContext == c else { return failure("adapter_context") }
        guard (2...6).contains(input.items.count) else { return failure("item_count") }
        var seen = Set<Int>()
        for item in input.items {
            guard (1...255).contains(item.pid), item.pid % 32 != 0,
                  (1...32).contains(item.length) else { return failure("item_invalid") }
            guard seen.insert(item.pid).inserted else { return failure("duplicate_pid") }
            guard item.context == c else { return failure("item_context") }
            guard item.proven, present(item.supportEvidence), present(item.lengthEvidence) else {
                return failure("item_unproven")
            }
        }
        plan = Plan(request: [1] + input.items.map { UInt8($0.pid) }, evidence: input)
        guard let record else {
            return Outcome(input: input, reason: "ok", values: nil, record: nil, plan: plan, fallback: nil)
        }
        guard record.context == c else { return failure("record_context") }
        guard record.correlation == input.correlation else { return failure("record_correlation") }
        guard record.variant == applicationVariant else { return failure("record_variant") }
        guard present(record.sourceEvidence), present(record.rawEvidence) else { return failure("record_evidence") }
        let bytes = record.payload
        guard bytes.count <= 199 else { return failure("payload_bound") }
        guard ["complete", "noData", "timeout", "malformedTransport"].contains(record.status),
              record.status == "complete" || bytes.isEmpty else { return failure("malformed_status") }
        guard record.status == "complete" else { return failure("status:" + record.status) }
        if bytes.first == 0x7F {
            guard bytes.count == 3, bytes[1] == 1 else { return failure("malformed_negative") }
            return failure("negative:\(bytes[2])")
        }
        guard bytes.first == 0x41 else { return failure("service") }
        let lengths = Dictionary(uniqueKeysWithValues: input.items.map { (UInt8($0.pid), $0.length) })
        var values = [UInt8: [UInt8]]()
        var index = 1
        while index < bytes.count {
            guard values.count < lengths.count else { return failure("trailing_bytes") }
            let pid = bytes[index]; index += 1
            guard let count = lengths[pid] else { return failure("unexpected_pid") }
            guard values[pid] == nil else { return failure("duplicate_response_pid") }
            guard bytes.count - index >= count else { return failure("truncated") }
            values[pid] = Array(bytes[index..<(index + count)]); index += count
        }
        guard values.count == lengths.count else { return failure("missing_pid") }
        // All records have been proved present above, but do not fabricate an empty payload.
        var ordered = [Value]()
        for item in input.items {
            guard let data = values[UInt8(item.pid)] else { return failure("missing_pid") }
            ordered.append(Value(pid: UInt8(item.pid), bytes: data))
        }
        return Outcome(input: input, reason: "ok", values: ordered, record: record, plan: plan, fallback: nil)
    }
}
