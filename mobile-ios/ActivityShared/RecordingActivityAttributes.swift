import ActivityKit
import Foundation
import TelemetryCore

struct RecordingActivityAttributes: ActivityAttributes {
    typealias ContentState = RecordingActivitySnapshot
    let sessionID: String
    let startedAt: Date
    let isDemo: Bool
    let korean: Bool
}
