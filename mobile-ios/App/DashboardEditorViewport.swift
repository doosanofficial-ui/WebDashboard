import SwiftUI
import TelemetryCore

struct DashboardEditorViewport: Equatable {
    private(set) var size: CGSize = .zero
    func geometry(columns: Int, rows: Int) -> DashboardSnapGeometry {
        .init(columnWidth: Double(size.width) / Double(columns), rowHeight: Double(size.height) / Double(rows))
    }
    mutating func observe(_ measured: CGSize, draft: inout DashboardEditDraft?) {
        if draft?.isCancelled == false {
            if abs(measured.width - size.width) > 0.5 { draft?.cancel() }
        }
        // Cancelling owns a frozen draft; the next gesture needs this new size.
        if draft?.isCancelled != false { size = measured }
    }
}
