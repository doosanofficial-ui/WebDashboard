import Foundation

/// Pure, local-only presentation state. This does not read or control any player.
/// Keep metadata out of recordings, support reports, logs and upload pipelines.
public struct ScopedMediaPresentation {
    public init() {}
    public enum Source: Equatable { case none, appOwned, appleMusic, unsupportedOtherApp }
    public enum Authorization: Equatable { case notRequired, notDetermined, denied, authorized }
    public enum Playback: Equatable { case unavailable, stopped, paused, playing, buffering, interrupted }
    public enum Action: Hashable { case play, pause, previous, next }
    public struct Intent: Equatable {
        public let generation: UUID
        public let nonce: UUID
        public let action: Action
        fileprivate init(generation: UUID, action: Action) {
            self.generation = generation
            self.nonce = UUID()
            self.action = action
        }
    }

    public static let allowsExport = false
    public private(set) var generation = UUID()
    public private(set) var source: Source = .none
    public private(set) var authorization: Authorization = .notDetermined
    /// Must come from a future verified source adapter, never inferred from app presence.
    public private(set) var capabilities: Set<Action> = []
    public private(set) var sequence: Int64 = -1
    public private(set) var playback: Playback = .unavailable
    public private(set) var title: String?
    public private(set) var artist: String?
    /// Opaque local asset token; never a path or remote URL.
    public private(set) var artwork: String?
    public private(set) var duration: Double?
    public private(set) var elapsed: Double?
    public private(set) var pending: Intent?
    private var interrupted = false

    public var eligible: Bool {
        (source == .appOwned && authorization == .notRequired) ||
        (source == .appleMusic && authorization == .authorized)
    }

    /// Also use replacement for authorization/capability changes; it invalidates all old work.
    public mutating func replace(source: Source, authorization: Authorization, capabilities: Set<Action>) {
        generation = UUID()
        self.source = source
        self.authorization = authorization
        self.capabilities = capabilities
        sequence = -1
        pending = nil
        interrupted = false
        playback = .unavailable
        clearMetadata()
    }

    /// Caller supplies monotonically increasing observations within this generation.
    /// Unknown values remain nil, distinct from an observed zero. No clock extrapolation.
    @discardableResult
    public mutating func update(generation: UUID, sequence: Int64, playback: Playback,
                         title: String? = nil, artist: String? = nil, artwork: String? = nil,
                         duration: Double? = nil, elapsed: Double? = nil) -> Bool {
        guard generation == self.generation, sequence >= 0, sequence > self.sequence,
              eligible, !interrupted, playback != .interrupted else { return false }
        self.sequence = sequence
        pending = nil
        self.playback = playback
        guard playback != .unavailable else { clearMetadata(); return true }
        self.title = Self.boundedText(title)
        self.artist = Self.boundedText(artist)
        self.artwork = Self.localAsset(artwork)
        self.duration = Self.nonnegativeFinite(duration)
        self.elapsed = Self.nonnegativeFinite(elapsed)
        if let duration = self.duration, let elapsed = self.elapsed {
            self.elapsed = min(elapsed, duration)
        }
        return true
    }

    /// Emits a declarative intent only. Never starts playback or changes authorization.
    public mutating func intent(_ action: Action) -> Intent? {
        guard eligible, !interrupted, pending == nil, capabilities.contains(action),
              playback == .playing || playback == .paused || playback == .stopped else { return nil }
        if action == .play && playback != .paused && playback != .stopped { return nil }
        if action == .pause && playback != .playing { return nil }
        let intent = Intent(generation: generation, action: action)
        pending = intent
        return intent
    }

    /// A completion only settles its ticket; it cannot assert that playback changed.
    /// A fresh source observation is required for any playback-state change.
    @discardableResult
    public mutating func finish(_ intent: Intent) -> Bool {
        guard intent.generation == generation, pending == intent else { return false }
        pending = nil
        return true
    }

    public mutating func interrupt() {
        generation = UUID() // Reject callbacks captured before interruption, even after it ends.
        sequence = -1
        pending = nil
        interrupted = true
        playback = .interrupted
        clearMetadata()
    }

    /// No resume command is emitted. A deliberate later play intent is required.
    public mutating func endInterruption() {
        guard interrupted else { return }
        interrupted = false
        pending = nil
        playback = eligible ? .paused : .unavailable
    }

    private mutating func clearMetadata() {
        title = nil; artist = nil; artwork = nil; duration = nil; elapsed = nil
    }
    private static func nonnegativeFinite(_ value: Double?) -> Double? {
        guard let value = value, value.isFinite, value >= 0 else { return nil }
        return value
    }
    private static func boundedText(_ value: String?) -> String? {
        guard let value = value else { return nil }
        let clean = String(String.UnicodeScalarView(value.unicodeScalars.filter {
            $0.properties.generalCategory != .control && $0.properties.generalCategory != .format
        })).trimmingCharacters(in: .whitespacesAndNewlines)
        let bounded = String(String.UnicodeScalarView(clean.unicodeScalars.prefix(160)))
        return bounded.isEmpty ? nil : bounded
    }
    private static func localAsset(_ value: String?) -> String? {
        guard let value = value, !value.isEmpty, value.utf8.count <= 64,
              value.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte) ||
                  (48...57).contains(byte) || byte == 95 || byte == 45
              }) else { return nil }
        return value
    }
}
