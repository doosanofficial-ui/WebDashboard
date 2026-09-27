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
        CarPlayProjectionBridge.shared.connect(interfaceController)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        CarPlayProjectionBridge.shared.disconnect(interfaceController)
        if self.interfaceController === interfaceController { self.interfaceController = nil }
    }
}
#endif
