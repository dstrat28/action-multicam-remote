import Foundation

/// Owns the same camera connections regardless of which scene launches first.
@MainActor
final class MulticamAppServices {
    static let shared = MulticamAppServices()

    let store: CameraStore
    private let watchConnectivity: WatchConnectivityController

    private init() {
        let store = CameraStore()
        self.store = store
        watchConnectivity = WatchConnectivityController(store: store)
        MulticamSystemCommandRouter.shared.register(store: store)
        MulticamAppShortcuts.updateAppShortcutParameters()
    }
}
