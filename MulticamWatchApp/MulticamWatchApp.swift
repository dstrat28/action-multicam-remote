import SwiftUI

@main
struct MulticamWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchRemoteView()
                .environmentObject(session)
                .task(id: scenePhase) {
                    guard scenePhase == .active else { return }
                    await session.refreshWhileActive()
                }
        }
    }
}
