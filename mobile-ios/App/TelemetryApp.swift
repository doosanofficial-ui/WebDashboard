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
    private let legacyCancellation = LocalOnlyBackgroundTaskCancellation(
        identifier: BackgroundUploader.identifier,
        makeSession: { LegacyURLSessionCancellationSession(identifier: $0) }
    )

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if !TelemetryProductScope.allowsRemoteDelivery {
            legacyCancellation.cancelLegacyTasks(identifier: BackgroundUploader.identifier, completion: {})
        }
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        Task { @MainActor in
            TelemetryModel.shared.finishLocalMeasurement()
        }
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundUploader.identifier else { completionHandler(); return }
        if !TelemetryProductScope.allowsRemoteDelivery {
            legacyCancellation.cancelLegacyTasks(identifier: identifier) {
                DispatchQueue.main.async(execute: completionHandler)
            }
            return
        }
        let uploader = TelemetryModel.shared.uploader
        uploader?.backgroundCompletion = completionHandler
        TelemetryModel.shared.restoreBackgroundSession()
        if uploader == nil { completionHandler() }
    }
}
