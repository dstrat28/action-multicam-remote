import SwiftUI

@main
struct ActionCamRemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: CameraStore
    private let watchConnectivity: WatchConnectivityController

    init() {
        let store = CameraStore()
        _store = State(initialValue: store)
        watchConnectivity = WatchConnectivityController(store: store)
    }

    var body: some Scene {
        WindowGroup {
            CameraDashboardView()
                .environment(store)
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    store.resumeCameraConnections()
                }
        }
    }
}
