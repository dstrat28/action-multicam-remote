import SwiftUI

@main
struct MulticamWatchApp: App {
    @StateObject private var session = WatchSessionModel()

    var body: some Scene {
        WindowGroup {
            WatchRemoteView()
                .environmentObject(session)
        }
    }
}
