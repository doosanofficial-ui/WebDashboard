import Foundation

public struct ServerRecordingStatus: Decodable, Sendable {
    private enum State: String, Decodable { case ready, delayed, failed, starting, closed, unknown }
    private let state: State
    private let pending: Int
    private let unconfirmed: Int
    private let rejected: Int
    private var unresolved: Int { pending + unconfirmed + rejected }
    public var isWarning: Bool { state != .ready }
    public var text: String {
        switch state {
        case .ready: return "Server CSV: \(pending) pending"
        case .delayed: return "Server CSV delayed: \(pending) pending"
        case .failed: return "Server CSV failed: \(unresolved) unresolved"
        case .starting: return "Server CSV starting"
        case .closed: return "Server CSV closed"
        case .unknown: return "Server CSV status unknown"
        }
    }
    fileprivate static let unknown = Self(state: .unknown, pending: 0, unconfirmed: 0, rejected: 0)
    private init(state: State, pending: Int, unconfirmed: Int, rejected: Int) {
        self.state = state; self.pending = pending; self.unconfirmed = unconfirmed; self.rejected = rejected
    }
    private enum CodingKeys: CodingKey { case state, pending, unconfirmed, rejected }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state)
        pending = try c.decode(Int.self, forKey: .pending)
        unconfirmed = try c.decode(Int.self, forKey: .unconfirmed)
        rejected = try c.decode(Int.self, forKey: .rejected)
        let partial = pending.addingReportingOverflow(unconfirmed)
        let total = partial.partialValue.addingReportingOverflow(rejected)
        guard pending >= 0, unconfirmed >= 0, rejected >= 0,
              !partial.overflow, !total.overflow else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid recording counts"))
        }
    }
}

public struct RecordingStatusUpdate: Sendable {
    public let status: ServerRecordingStatus
    public let isControl: Bool

    public static func decode(_ data: Data) -> Self? {
        struct Header: Decodable { let v: Int; let type: String? }
        guard data.count <= 256 * 1024, let header = try? JSONDecoder().decode(Header.self, from: data), header.v == 1,
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        let control = header.type == "recording_status"
        let raw = control ? root["recording"] : (root["status"] as? [String: Any])?["recording"]
        if raw == nil && !control { return nil }
        guard let object = raw as? [String: Any], let encoded = try? JSONSerialization.data(withJSONObject: object),
              let status = try? JSONDecoder().decode(ServerRecordingStatus.self, from: encoded) else {
            return .init(status: .unknown, isControl: control)
        }
        return .init(status: status, isControl: control)
    }
}
