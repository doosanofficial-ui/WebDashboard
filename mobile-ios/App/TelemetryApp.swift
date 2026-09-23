import SwiftUI

@main
struct TelemetryApp: App {
    @UIApplicationDelegateAdaptor(TelemetryAppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = TelemetryModel.shared
    var body: some Scene {
        WindowGroup {
            DashboardView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.sceneChanged(background: false) }
                    if phase == .background { model.sceneChanged(background: true) }
                }
        }
    }
}

final class TelemetryAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.identifier else { completionHandler(); return }
        let uploader = TelemetryModel.shared.uploader
        uploader?.backgroundCompletion = completionHandler
        TelemetryModel.shared.restoreBackgroundSession()
        if uploader == nil { completionHandler() }
    }
}
