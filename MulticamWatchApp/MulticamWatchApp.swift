import SwiftUI

@main
struct MulticamWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchRemoteView()
                .environmentObject(session)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        session.requestLatestState()
                    }
                }
        }
    }
}
