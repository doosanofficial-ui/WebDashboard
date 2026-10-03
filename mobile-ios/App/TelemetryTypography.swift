import SwiftUI

/// Semantic roles follow the user's Dynamic Type setting.
enum TelemetryTypography {
    static let measurement = Font.system(.title2, design: .rounded).weight(.semibold)
    static let primaryMeasurement = Font.system(.largeTitle, design: .rounded).weight(.semibold)
    static let gaugeMeasurement = Font.system(.title3, design: .rounded).weight(.semibold)
}
