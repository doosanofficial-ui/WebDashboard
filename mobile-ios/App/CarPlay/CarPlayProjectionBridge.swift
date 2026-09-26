#if canImport(CarPlay)
import CarPlay
import Foundation
import TelemetryCore

@available(iOS 14.0, *)
final class CarPlayProjectionBridge {
    static let shared = CarPlayProjectionBridge()

    private weak var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?
    private var state = CarPlayProjectionState(
        adapterState: "disconnected",
        recordingState: "idle",
        profileName: "Unselected",
        elapsedSeconds: 0,
        primaryValues: [:]
    )
    private var lastRenderedState: CarPlayProjectionState?
    private var lastRenderAt = Date.distantPast
    private let minimumRefreshInterval: TimeInterval = 1

    private init() {}

    func connect(_ interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController
        let template = CarPlayProjection.template(for: state)
        listTemplate = template
        lastRenderedState = state
        lastRenderAt = Date()
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
    }

    func disconnect(_ interfaceController: CPInterfaceController) {
        if self.interfaceController === interfaceController {
            self.interfaceController = nil
            listTemplate = nil
            lastRenderedState = nil
        }
    }

    func update(_ state: CarPlayProjectionState) {
        self.state = state
        guard interfaceController != nil, listTemplate != nil else { return }
        let now = Date()
        let immediateChange = discreteStateChanged(from: lastRenderedState, to: state)
        guard immediateChange || now.timeIntervalSince(lastRenderAt) >= minimumRefreshInterval else {
            return
        }
        renderList(at: now)
    }

    private func discreteStateChanged(from oldState: CarPlayProjectionState?,
                                      to newState: CarPlayProjectionState) -> Bool {
        guard let oldState else { return true }
        return oldState.adapterState != newState.adapterState
            || oldState.recordingState != newState.recordingState
            || oldState.profileName != newState.profileName
    }

    private func renderList(at date: Date) {
        guard let listTemplate else { return }
        listTemplate.updateSections([CPListSection(items: CarPlayProjection.items(for: state))])
        lastRenderedState = state
        lastRenderAt = date
    }
}
#endif
