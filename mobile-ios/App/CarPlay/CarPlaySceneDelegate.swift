#if canImport(CarPlay)
import CarPlay
import TelemetryCore
import UIKit

@available(iOS 14.0, *)
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let state = CarPlayProjectionState(
            adapterState: "disconnected",
            recordingState: "idle",
            profileName: "Unselected",
            elapsedSeconds: 0,
            primaryValues: [:]
        )
        interfaceController.setRootTemplate(CarPlayProjection.template(for: state), animated: false, completion: nil)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        if self.interfaceController === interfaceController { self.interfaceController = nil }
    }
}
#endif
