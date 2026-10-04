import Foundation

public enum MeasurementReplayError: Error, Equatable, Sendable {
    case invalidExport
    case sessionMismatch
    case malformedRow(String)
    case unsupportedKind(String)
    case rowLimitExceeded
}

/// Restores a persisted snapshot into the store only. It has no transport or
/// recorder reference. Callers must stop live ingestion before starting replay.
/// Invalid input never leaves a partially restored or mixed-session snapshot.
public enum MeasurementReplay {
    public enum SignalFreshness: String, Sendable { case unknown, fresh, stale }
    public struct Snapshot: Sendable {
        public let timestamp: Double
        public let signals: [LatestSignalState]
        public let frame: CANFrame?
        public let diagnostic: OBDResponse?
        public let location: LocationSample?
        public let markTimestamp: Double?
        public let signalAges: [String: Double]
        public let signalFreshness: [String: SignalFreshness]
    }

    /// Original rows remain intact; elapsed time is only a display projection.
    public struct RecordedSignalSource: Hashable, Sendable {
        public let kind: String
        public let adapter: String?
        public let transport: String?
    }
    public struct RecordedMeasurementID: Hashable, Sendable {
        public let sessionID: String
        public let sequence: Int64
    }
    public struct RecordedSignalPoint: Identifiable, Equatable, Sendable {
        public var id: RecordedMeasurementID { .init(sessionID: measurement.sessionID, sequence: measurement.sequence) }
        public let elapsedSeconds: Double
        public let value: Double
        public let unit: String
        public let source: RecordedSignalSource
        public let sourceSegment: Int
        public let measurement: PersistedMeasurement
    }
    public struct SignalHistory: Sendable {
        public let samples: [RecordedSignalPoint]
        public let totalSamplesInWindow: Int
        public let startSeconds: Double
        public let endSeconds: Double
        public var truncated: Bool { samples.count < totalSamplesInWindow }
    }

    public struct RecordedLocationPoint: Identifiable, Equatable, Sendable {
        public var id: RecordedMeasurementID { .init(sessionID: measurement.sessionID, sequence: measurement.sequence) }
        public let elapsedSeconds: Double
        public let location: LocationSample
        public let measurement: PersistedMeasurement
        public let sourceSegment: Int
        public var isPlottable: Bool { location.horizontalAccuracy.map { $0 >= 0 } ?? true }
    }
    public struct ProjectedRoutePoint: Identifiable, Sendable {
        public let id: RecordedMeasurementID
        public let x: Double
        public let y: Double
        public let sourceSegment: Int
    }
    public struct LocationHistory: Sendable {
        public let samples: [RecordedLocationPoint]
        public let totalRowsInPrefix: Int
        public let endSeconds: Double
        public var truncated: Bool { samples.count < totalRowsInPrefix }
        public var plottableSamples: [RecordedLocationPoint] { samples.filter(\.isPlottable) }

        /// Local geographic outline only. Raw coordinates/times never change.
        /// Longitude unwrap uses the shortest signed delta (ties retain sign).
        public var projectedPoints: [ProjectedRoutePoint] {
            let valid = plottableSamples
            guard let first = valid.first else { return [] }
            let latitudes = valid.map { $0.location.latitude }
            let centerLatitude = ((latitudes.min() ?? 0) + (latitudes.max() ?? 0)) / 2
            let longitudeScale = abs(centerLatitude) == 90 ? 0 : cos(centerLatitude * .pi / 180)
            let originLongitude = first.location.longitude
            var previousLongitude = originLongitude, previousSegment = first.sourceSegment
            var unwrapped: [(RecordedLocationPoint, Double)] = []
            for point in valid {
                let anchor = point.sourceSegment == previousSegment ? previousLongitude : originLongitude
                var delta = (point.location.longitude - anchor).truncatingRemainder(dividingBy: 360)
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                let longitude = anchor + delta
                unwrapped.append((point, (longitude - originLongitude) * longitudeScale))
                previousLongitude = longitude; previousSegment = point.sourceSegment
            }
            let minX = unwrapped.map { $0.1 }.min() ?? 0, maxX = unwrapped.map { $0.1 }.max() ?? 0
            let minY = latitudes.min() ?? 0, maxY = latitudes.max() ?? 0
            let span = max(maxX - minX, maxY - minY)
            return unwrapped.map { point, x in
                let px = span > 0 ? 0.5 + (x - (minX + maxX) / 2) / span : 0.5
                let py = span > 0 ? 0.5 - (point.location.latitude - (minY + maxY) / 2) / span : 0.5
                return ProjectedRoutePoint(id: point.id, x: min(1, max(0, px)), y: min(1, max(0, py)), sourceSegment: point.sourceSegment)
            }
        }
    }

    private struct SystemPayload: Decodable { let name: String }

    /// An immutable, fully validated closed recording. Seeking restores only
    /// the latest rows in the selected prefix, never state from a future seek.
    public struct Timeline: Sendable {
        public let duration: Double
        public let sessionID: String
        public let measurementCount: Int
        private let export: MeasurementExport
        private let elapsed: [Double]
        private let signalTimeouts: [String: Double]
        private let signalIndex: [String: [RecordedSignalPoint]]
        private let locationIndex: [RecordedLocationPoint]
        private let frameOffsets: [UInt32]
        private let diagnosticOffsets: [UInt32]
        private let markOffsets: [UInt32]

        fileprivate init(export: MeasurementExport, signalTimeouts: [String: Double]) throws {
            guard export.measurements.count <= 200_000 else { throw MeasurementReplayError.rowLimitExceeded }
            self.signalTimeouts = signalTimeouts
            self.export = export
            sessionID = export.session.sessionID
            measurementCount = export.measurements.count
            let origin = export.measurements.first?.receivedAtMonotonicNanos ?? 0
            var last = 0.0
            elapsed = export.measurements.map { row in
                let offset = row.receivedAtMonotonicNanos >= origin
                    ? Double(row.receivedAtMonotonicNanos - origin) / 1_000_000_000 : 0
                // Concurrent admissions can share or slightly reorder receive
                // times. Persisted sequence remains authoritative; never rewrite
                // the original wall-clock or monotonic values in exported rows.
                last = max(last, offset)
                return last
            }
            duration = elapsed.last ?? 0
            // Reserve by original kind: the combined requested offset capacity
            // is bounded by the row count, including non-MARK system rows.
            var frameCount = 0, diagnosticCount = 0, systemCount = 0
            for (offset, row) in export.measurements.enumerated() {
                if offset % 256 == 0 { try Task.checkCancellation() }
                switch row.kind {
                case "CAN": frameCount += 1
                case "DIAGNOSTIC_RESPONSE": diagnosticCount += 1
                case "SYSTEM": systemCount += 1
                default: break
                }
            }
            var frames: [UInt32] = [], diagnostics: [UInt32] = [], marks: [UInt32] = []
            frames.reserveCapacity(frameCount)
            diagnostics.reserveCapacity(diagnosticCount)
            marks.reserveCapacity(systemCount)
            var index: [String: [RecordedSignalPoint]] = [:]
            var locations: [RecordedLocationPoint] = []
            var locationSegment = 0
            var previousLocationSource: TelemetrySource?
            for (offset, row) in export.measurements.enumerated() {
                if offset % 256 == 0 { try Task.checkCancellation() }
                guard let rowOffset = UInt32(exactly: offset) else { throw MeasurementReplayError.rowLimitExceeded }
                let id: String, value: Double, unit: String, source: RecordedSignalSource
                switch try MeasurementReplay.decode(row) {
                case .signal(let sample):
                    id = sample.signalID; value = sample.value; unit = sample.unit; source = .init(kind: sample.source.rawValue, adapter: nil, transport: nil)
                case .diagnosticSignal(let sample):
                    id = sample.signalID; value = sample.value; unit = sample.unit; source = .init(kind: "diagnostic", adapter: sample.sourceAdapter, transport: sample.sourceTransport)
                case .location(let location):
                    if let previousLocationSource, previousLocationSource != location.source { locationSegment += 1 }
                    let point = RecordedLocationPoint(elapsedSeconds: elapsed[offset], location: location,
                        measurement: row, sourceSegment: locationSegment)
                    locations.append(point)
                    previousLocationSource = location.source
                    if !point.isPlottable { locationSegment += 1 }
                    continue
                case .can: frames.append(rowOffset); continue
                case .diagnosticResponse: diagnostics.append(rowOffset); continue
                case .system(let name, _, _):
                    if name == "MARK" { marks.append(rowOffset) }
                    continue
                }
                let previous = index[id]?.last
                let segment = (previous?.sourceSegment ?? 0) + (previous != nil && previous?.source != source ? 1 : 0)
                index[id, default: []].append(RecordedSignalPoint(elapsedSeconds: elapsed[offset],
                    value: value, unit: unit, source: source, sourceSegment: segment, measurement: row))
            }
            signalIndex = index
            locationIndex = locations
            frameOffsets = frames
            diagnosticOffsets = diagnostics
            markOffsets = marks
        }

        /// Selected-time prefix, bounded per signal. Never substitutes zero for
        /// absent observations or uses today's profile as historical freshness.
        public func signalHistory(signalID: String, at seconds: Double,
                                  windowSeconds: Double = 60, maximumSamples: Int = 600) throws -> SignalHistory {
            guard seconds.isFinite, windowSeconds.isFinite, windowSeconds >= 0,
                  (1...600).contains(maximumSamples) else { throw MeasurementReplayError.invalidExport }
            try Task.checkCancellation()
            let end = min(duration, max(0, seconds)), start = max(0, end - windowSeconds)
            let points = signalIndex[signalID] ?? []
            func bound(_ time: Double, inclusive: Bool) -> Int {
                var low = 0, high = points.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if points[mid].elapsedSeconds < time || (inclusive && points[mid].elapsedSeconds == time) {
                        low = mid + 1
                    } else { high = mid }
                }
                return low
            }
            let lower = bound(start, inclusive: false), upper = bound(end, inclusive: true)
            let visibleLower = max(lower, upper - maximumSamples)
            return SignalHistory(samples: Array(points[visibleLower..<upper]), totalSamplesInWindow: upper - lower,
                                 startSeconds: start, endSeconds: end)
        }

        /// Cap is applied to original GPS rows before filtering rejected fixes.
        public func locationHistory(at seconds: Double, maximumSamples: Int = 1000) throws -> LocationHistory {
            guard seconds.isFinite, (1...1000).contains(maximumSamples) else { throw MeasurementReplayError.invalidExport }
            try Task.checkCancellation()
            let end = min(duration, max(0, seconds))
            var low = 0, high = locationIndex.count
            while low < high {
                let mid = low + (high - low) / 2
                if locationIndex[mid].elapsedSeconds <= end { low = mid + 1 } else { high = mid }
            }
            return LocationHistory(samples: Array(locationIndex[max(0, low - maximumSamples)..<low]), totalRowsInPrefix: low, endSeconds: end)
        }

        public func snapshot(at seconds: Double) async throws -> Snapshot {
            guard seconds.isFinite else { throw MeasurementReplayError.invalidExport }
            try Task.checkCancellation()
            let position = min(duration, max(0, seconds))
            var lower = 0, upper = elapsed.count
            while lower < upper {
                let middle = lower + (upper - lower) / 2
                if elapsed[middle] <= position { lower = middle + 1 } else { upper = middle }
            }
            // Index lookups select original rows. Each latest signal retains
            // raw fields via the same decoder/store projection as full replay.
            var selected: [PersistedMeasurement] = []
            for (index, points) in signalIndex.values.enumerated() {
                if index % 256 == 0 { try Task.checkCancellation() }
                var low = 0, high = points.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if points[mid].elapsedSeconds <= position { low = mid + 1 } else { high = mid }
                }
                if low > 0 { selected.append(points[low - 1].measurement) }
            }
            var locationLow = 0, locationHigh = locationIndex.count
            while locationLow < locationHigh {
                let mid = locationLow + (locationHigh - locationLow) / 2
                if locationIndex[mid].elapsedSeconds <= position { locationLow = mid + 1 } else { locationHigh = mid }
            }
            // Keep even a rejected GPS fix as the latest raw location.
            if locationLow > 0 { selected.append(locationIndex[locationLow - 1].measurement) }
            for offsets in [frameOffsets, diagnosticOffsets, markOffsets] {
                try Task.checkCancellation()
                var low = 0, high = offsets.count
                while low < high {
                    let mid = low + (high - low) / 2
                    if Int(offsets[mid]) < lower { low = mid + 1 } else { high = mid }
                }
                if low > 0 { selected.append(export.measurements[Int(offsets[low - 1])]) }
            }
            try Task.checkCancellation()
            let recorded = try await MeasurementReplay.snapshot(MeasurementExport(session: export.session, measurements: selected))
            try Task.checkCancellation()
            // Non-indexed rows (including other SYSTEM events) still determine
            // the snapshot reference time, even after a wall-clock rollback.
            let timestamp = lower > 0 ? export.measurements[lower - 1].receivedAtEpoch : export.session.startedAt
            let origin = export.measurements.first?.receivedAtMonotonicNanos ?? 0
            var ages: [String: Double] = [:]
            var freshness: [String: SignalFreshness] = [:]
            for signal in recorded.signals {
                let mono = signal.receivedAtMonotonicNanos
                let receivedElapsed = mono >= origin ? Double(mono - origin) / 1_000_000_000
                    : -Double(origin - mono) / 1_000_000_000
                let age = max(0, position - receivedElapsed)
                ages[signal.signalID] = age
                if let timeout = signalTimeouts[signal.signalID] {
                    freshness[signal.signalID] = age > timeout ? .stale : .fresh
                } else { freshness[signal.signalID] = .unknown }
            }
            // Original value/quality/timestamps are evidence. Freshness is a
            // separate derived state; absent recorded policy remains unknown.
            return Snapshot(timestamp: timestamp, signals: recorded.signals, frame: recorded.frame,
                diagnostic: recorded.diagnostic, location: recorded.location, markTimestamp: recorded.markTimestamp,
                signalAges: ages, signalFreshness: freshness)
        }
    }

    public static func timeline(_ export: MeasurementExport, maximumRows: Int = 200_000, signalTimeouts: [String: Double] = [:]) async throws -> Timeline {
        guard (1...200_000).contains(maximumRows), export.measurements.count <= maximumRows else {
            throw MeasurementReplayError.rowLimitExceeded
        }
        guard signalTimeouts.allSatisfy({ !$0.key.isEmpty && $0.value.isFinite && $0.value > 0 }) else { throw MeasurementReplayError.invalidExport }
        guard export.session.endedAt != nil else { throw MeasurementReplayError.invalidExport }
        // Validate every row before exposing seek, including malformed rows after
        // the requested position. Keep the existing archive/snapshot row bound.
        _ = try await snapshot(export)
        return try Timeline(export: MeasurementExport(session: export.session,
            measurements: export.measurements.sorted { $0.sequence < $1.sequence }), signalTimeouts: signalTimeouts)
    }

    /// A validated, recorded end-of-session snapshot, not new acquisition.
    /// Original source times remain untouched and no transport/writer is used.
    public static func snapshot(_ export: MeasurementExport) async throws -> Snapshot {
        let store = TelemetryStore()
        try await replay(export, into: store)
        let ordered = export.measurements.sorted { $0.sequence < $1.sequence }
        let timestamp = ordered.last?.receivedAtEpoch ?? export.session.startedAt
        var signals: [LatestSignalState] = []
        for id in await store.signalIDs() {
            if let state = await store.signalState(for: id, now: timestamp) { signals.append(state) }
        }
        let lastSource = ordered.last { $0.kind == "CAN" || $0.kind == "DIAGNOSTIC_RESPONSE" }?.kind
        return Snapshot(timestamp: timestamp, signals: signals,
            frame: lastSource == "CAN" ? await store.latestFrame() : nil,
            diagnostic: lastSource == "DIAGNOSTIC_RESPONSE" ? await store.latestDiagnosticResponse() : nil,
            location: await store.latestLocation(),
            markTimestamp: ordered.last { row in
                row.kind == "SYSTEM" && (try? JSONDecoder().decode(SystemPayload.self, from: Data(row.payloadJSON.utf8)))?.name == "MARK"
            }?.sourceTimestamp, signalAges: [:],
            signalFreshness: Dictionary(uniqueKeysWithValues: signals.map { ($0.signalID, .unknown) }))
    }

    public static func replay(_ data: Data, into store: TelemetryStore) async throws {
        let decoder = JSONDecoder()
        if let envelope = try? decoder.decode(MeasurementExport.self, from: data) {
            try await replay(envelope, into: store)
            return
        }
        if let rows = try? decoder.decode([PersistedMeasurement].self, from: data) {
            try await replay(rows, session: nil, into: store)
            return
        }
        throw MeasurementReplayError.invalidExport
    }

    public static func replay(_ export: MeasurementExport, into store: TelemetryStore) async throws {
        guard export.schemaVersion == 1, !export.session.sessionID.isEmpty,
              export.session.startedAt.isFinite,
              export.session.endedAt.map({ $0.isFinite }) ?? true else {
            throw MeasurementReplayError.invalidExport
        }
        try await replay(export.measurements, session: export.session, into: store)
    }

    private static func replay(
        _ rows: [PersistedMeasurement],
        session: PersistedMeasurementSession?,
        into store: TelemetryStore
    ) async throws {
        let sessionID = session?.sessionID ?? rows.first?.sessionID
        if let sessionID, sessionID.isEmpty { throw MeasurementReplayError.invalidExport }
        // Persisted SQLite sequence is authoritative even if a wall clock moved
        // backwards or a consumer reordered the JSON array. Gaps are legitimate.
        let ordered = rows.sorted { $0.sequence < $1.sequence }
        var previousSequence: Int64 = 0
        var events: [MeasurementEvent] = []
        events.reserveCapacity(ordered.count)
        for row in ordered {
            guard row.sessionID == sessionID else { throw MeasurementReplayError.sessionMismatch }
            guard row.sequence > previousSequence,
                  row.sourceTimestamp.isFinite, row.receivedAtEpoch.isFinite else {
                throw MeasurementReplayError.invalidExport
            }
            previousSequence = row.sequence
            events.append(try decode(row))
        }
        try Task.checkCancellation()
        await store.replaceForReplay(events, session: session)
    }

    private static func decode(_ row: PersistedMeasurement) throws -> MeasurementEvent {
        let decoder = JSONDecoder()
        let data = Data(row.payloadJSON.utf8)
        func payload<T: Decodable>(_ type: T.Type) throws -> T {
            guard let value = try? decoder.decode(type, from: data) else {
                throw MeasurementReplayError.malformedRow(row.kind)
            }
            return value
        }
        func checkTimes(source: Double, received: Double, monotonic: UInt64) throws {
            guard source.isFinite, received.isFinite,
                  row.sourceTimestamp == source, row.receivedAtEpoch == received,
                  row.receivedAtMonotonicNanos == monotonic else {
                throw MeasurementReplayError.malformedRow(row.kind)
            }
        }
        switch row.kind {
        case "CAN":
            let frame = try payload(CANFrame.self)
            try checkTimes(source: frame.receivedAtEpoch, received: frame.receivedAtEpoch,
                           monotonic: frame.receivedAtMonotonicNanos)
            // Synthesized Codable bypasses CANFrame's validating initializer.
            guard (0...8).contains(frame.dlc), frame.payload.count == frame.dlc,
                  frame.canID <= (frame.isExtended ? 0x1FFF_FFFF : 0x7FF) else {
                throw MeasurementReplayError.malformedRow(row.kind)
            }
            return .can(frame: frame)
        case "SIGNAL":
            let signal = try payload(DecodedSignalSample.self)
            try checkTimes(source: signal.receivedAtEpoch, received: signal.receivedAtEpoch,
                           monotonic: signal.receivedAtMonotonicNanos)
            guard signal.value.isFinite else { throw MeasurementReplayError.malformedRow(row.kind) }
            return .signal(signal)
        case "DIAGNOSTIC_RESPONSE":
            let response = try payload(OBDResponse.self)
            try checkTimes(source: response.receivedAtEpoch, received: response.receivedAtEpoch,
                           monotonic: response.receivedAtMonotonicNanos)
            return .diagnosticResponse(response)
        case "DIAGNOSTIC_SIGNAL":
            let signal = try payload(DecodedOBDSignal.self)
            try checkTimes(source: signal.receivedAtEpoch, received: signal.receivedAtEpoch,
                           monotonic: signal.receivedAtMonotonicNanos)
            guard signal.value.isFinite else { throw MeasurementReplayError.malformedRow(row.kind) }
            return .diagnosticSignal(signal)
        case "LOCATION":
            let location = try payload(LocationSample.self)
            try checkTimes(source: location.originalTimestamp, received: location.receivedAtEpoch,
                           monotonic: location.receivedAtMonotonicNanos)
            guard location.latitude.isFinite, location.longitude.isFinite,
                  (-90...90).contains(location.latitude), (-180...180).contains(location.longitude),
                  [location.altitude, location.speed, location.course, location.horizontalAccuracy,
                   location.verticalAccuracy].allSatisfy({ $0.map(\.isFinite) ?? true }) else {
                throw MeasurementReplayError.malformedRow(row.kind)
            }
            // Optional Core Location sentinels are retained as raw evidence.
            // The GPS display projection applies Protocol.gps normalization;
            // a negative altitude is a valid measurement, not a sentinel.
            return .location(location)
        case "SYSTEM":
            let system = try payload(SystemPayload.self)
            guard !system.name.isEmpty else { throw MeasurementReplayError.malformedRow(row.kind) }
            try checkTimes(source: row.receivedAtEpoch, received: row.receivedAtEpoch,
                           monotonic: row.receivedAtMonotonicNanos)
            return .system(name: system.name, timestamp: row.sourceTimestamp,
                           monotonicNanos: row.receivedAtMonotonicNanos)
        default:
            throw MeasurementReplayError.unsupportedKind(row.kind)
        }
    }
}
