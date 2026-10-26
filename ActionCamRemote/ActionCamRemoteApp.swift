import SwiftUI

@main
struct ActionCamRemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: CameraStore

    init() {
        _store = State(initialValue: MulticamAppServices.shared.store)
    }

    var body: some Scene {
        WindowGroup {
            CameraDashboardView()
                .environment(store)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        store.resumeCameraConnections()
                    case .background:
                        store.saveDiagnosticsBeforeBackgrounding()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}
