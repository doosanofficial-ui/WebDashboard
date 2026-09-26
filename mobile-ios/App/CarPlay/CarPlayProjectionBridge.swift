#if canImport(CarPlay)
import CarPlay
import TelemetryCore

@available(iOS 14.0, *)
final class CarPlayProjectionBridge {
    static let shared = CarPlayProjectionBridge()

    private weak var interfaceController: CPInterfaceController?
    private var state = CarPlayProjectionState(
        adapterState: "disconnected",
        recordingState: "idle",
        profileName: "Unselected",
        elapsedSeconds: 0,
        primaryValues: [:]
    )

    private init() {}

    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        render()
    }

    func disconnect(_ interfaceController: CPInterfaceController) {
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
        }
    }

    func update(_ state: CarPlayProjectionState) {
        self.state = state
        render()
    }

    private func render() {
        guard let interfaceController else { return }
        interfaceController.setRootTemplate(
            CarPlayProjection.template(for: state),
            animated: false,
            completion: nil
        )
    }
}
#endif
