import CarPlay
import Observation
import OSLog

@MainActor
final class CarPlayCameraController {
    private let store: CameraStore
    private let interfaceController: CPInterfaceController
    private let template = CPListTemplate(title: "Multicam", sections: [])
    private let logger = Logger(subsystem: "com.ds.ActionCamRemote", category: "carplay")
    private var lastState: CarPlayCameraState?
    private var refreshTask: Task<Void, Never>?
    private var stateObservationGeneration: UUID?
    private var lastEventState: CarPlayCameraState?
    private var isConnected = false

    init(store: CameraStore, interfaceController: CPInterfaceController) {
        self.store = store
        self.interfaceController = interfaceController
        template.emptyViewTitleVariants = ["No Paired Cameras"]
        template.emptyViewSubtitleVariants = ["Pair cameras before your drive."]
    }

    deinit {
        refreshTask?.cancel()
    }

    func connect() {
        isConnected = true
        refresh()
        interfaceController.setRootTemplate(template, animated: false) { [weak self] success, error in
            guard let self else { return }
            if success {
                self.activate()
            } else {
                self.logger.error("Could not present CarPlay controls: \(error?.localizedDescription ?? "Unknown error", privacy: .public)")
                self.disconnect()
            }
        }
    }

    func activate() {
        guard isConnected else { return }
        refresh()
        guard refreshTask == nil else { return }
        let generation = UUID()
        stateObservationGeneration = generation
        observeCameraEvents(generation: generation)
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    // Continuous telemetry keeps the Driving Task periodic cadence.
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    func pause() {
        refreshTask?.cancel()
        refreshTask = nil
        stateObservationGeneration = nil
        lastEventState = nil
    }

    func disconnect() {
        isConnected = false
        pause()
    }

    private func refresh() {
        guard isConnected else { return }
        let state = CarPlayCameraState(cameras: store.cameras)
        guard state != lastState else { return }
        lastState = state

        let recording = CPBarButton(title: state.recordingActionTitle) { [weak self] _ in
            guard let self, self.isConnected else { return }
            let latestState = CarPlayCameraState(cameras: self.store.cameras)
            guard latestState.canPerformRecordingAction else {
                self.refresh()
                return
            }
            // Keep the action the driver saw. Each store method revalidates the
            // current cameras, so stale Record never becomes an unexpected Stop.
            switch state.recordingAction {
            case .start: _ = self.store.startCarPlayRecording()
            case .stop: _ = self.store.stopCarPlayRecording()
            }
            self.refresh()
        }
        recording.buttonStyle = .rounded
        recording.isEnabled = state.canPerformRecordingAction
        template.trailingNavigationBarButtons = [recording]

        let visibleCameras = state.cameras.prefix(CPListTemplate.maximumItemCount)
        let items = visibleCameras.map { camera in
            let item = CPListItem(
                text: camera.name,
                detailText: camera.detail,
                image: UIImage(systemName: camera.isSelected ? "checkmark.circle.fill" : "circle")
            )
            item.isEnabled = camera.canToggleSelection
            item.handler = { [weak self] _, completion in
                defer { completion() }
                guard let self, self.isConnected,
                      let latest = self.store.cameras.first(where: { $0.id == camera.id }),
                      latest.isPaired else { return }
                self.store.toggleSelection(for: latest)
                self.refresh()
            }
            return item
        }
        template.updateSections([
            CPListSection(
                items: items,
                header: !state.canPerformRecordingAction && !state.isStarting
                    && state.cameras.contains(where: \.isSelected)
                    ? state.recordingActionDetail : nil,
                sectionIndexTitle: nil
            )
        ])
    }

    private func observeCameraEvents(generation: UUID) {
        guard isConnected, stateObservationGeneration == generation else { return }
        let eventState = withObservationTracking {
            CarPlayCameraState.eventSnapshot(cameras: store.cameras)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeCameraEvents(generation: generation)
            }
        }
        guard eventState != lastEventState else { return }
        lastEventState = eventState
        // Connection, selection, and recording/readiness transitions are events.
        // Power-only telemetry changes wait for the periodic refresh above.
        refresh()
    }
}
