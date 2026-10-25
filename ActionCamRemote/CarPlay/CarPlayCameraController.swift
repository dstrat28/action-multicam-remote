import CarPlay
import OSLog

@MainActor
final class CarPlayCameraController {
    private let store: CameraStore
    private let interfaceController: CPInterfaceController
    private let template = CPListTemplate(title: "Multicam", sections: [])
    private let logger = Logger(subsystem: "com.ds.ActionCamRemote", category: "carplay")
    private var lastState: CarPlayCameraState?
    private var refreshTask: Task<Void, Never>?
    private var isConnected = false

    init(store: CameraStore, interfaceController: CPInterfaceController) {
        self.store = store
        self.interfaceController = interfaceController
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
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    // Driving Task apps may not periodically refresh more often.
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

        let start = CPListItem(
            text: "Start Recording",
            detailText: state.startDetail,
            image: UIImage(systemName: "record.circle")
        )
        start.isEnabled = state.canStart
        start.handler = { [weak self] _, completion in
            defer { completion() }
            guard let self, self.isConnected else { return }
            _ = self.store.startCarPlayRecording()
            self.refresh()
        }

        let stop = CPListItem(
            text: "Stop Recording",
            detailText: state.stopDetail,
            image: UIImage(systemName: "stop.circle")
        )
        stop.isEnabled = state.canStop
        stop.handler = { [weak self] _, completion in
            defer { completion() }
            guard let self, self.isConnected else { return }
            _ = self.store.stopCarPlayRecording()
            self.refresh()
        }

        // Reserve room for both actions and respect the vehicle's list limit.
        let visibleCameras = state.cameras.prefix(max(0, CPListTemplate.maximumItemCount - 2))
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
        let subtitle: String?
        if state.cameras.isEmpty {
            subtitle = "Pair cameras before your drive."
        } else if visibleCameras.count < state.cameras.count {
            subtitle = "Showing \(visibleCameras.count) of \(state.cameras.count) paired cameras."
        } else {
            subtitle = nil
        }
        template.updateSections([
            CPListSection(items: [start, stop], header: "Recording", sectionIndexTitle: nil),
            CPListSection(
                items: items,
                header: "Paired Cameras",
                headerSubtitle: subtitle,
                headerImage: nil,
                headerButton: nil,
                sectionIndexTitle: nil
            )
        ])
    }
}
