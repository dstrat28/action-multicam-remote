import AppIntents

enum MulticamSystemCommand {
    case startAll
    case stopAll
    case addHighlight
}

enum MulticamSystemCommandOutcome {
    case accepted
    case unavailable
    case queued
}

@MainActor
final class MulticamSystemCommandRouter {
    static let shared = MulticamSystemCommandRouter()

    private weak var store: CameraStore?
    private var queuedCommand: MulticamSystemCommand?

    private init() {}

    func register(store: CameraStore) {
        self.store = store

        if let queuedCommand {
            self.queuedCommand = nil
            _ = perform(queuedCommand)
        }
    }

    func perform(_ command: MulticamSystemCommand) -> MulticamSystemCommandOutcome {
        guard let store else {
            queuedCommand = command
            return .queued
        }

        let accepted: Bool
        switch command {
        case .startAll:
            accepted = store.startAllRecording()
        case .stopAll:
            accepted = store.stopAllRecording()
        case .addHighlight:
            accepted = store.addHighlight()
        }

        return accepted ? .accepted : .unavailable
    }
}

struct StartAllCamerasIntent: AppIntent {
    static let title: LocalizedStringResource = "Start All Cameras"
    static let description = IntentDescription("Starts recording on every connected camera that is ready.")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch MulticamSystemCommandRouter.shared.perform(.startAll) {
        case .accepted:
            return .result(dialog: "Starting all ready cameras.")
        case .unavailable:
            return .result(dialog: "No connected cameras are ready to start.")
        case .queued:
            return .result(dialog: "Opening Multicam to start all cameras.")
        }
    }
}

struct StopAllCamerasIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop All Cameras"
    static let description = IntentDescription("Stops every camera that is recording or starting to record.")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch MulticamSystemCommandRouter.shared.perform(.stopAll) {
        case .accepted:
            return .result(dialog: "Stopping all recording cameras.")
        case .unavailable:
            return .result(dialog: "No cameras are currently recording.")
        case .queued:
            return .result(dialog: "Opening Multicam to stop all cameras.")
        }
    }
}

struct HighlightAllCamerasIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Highlight"
    static let description = IntentDescription("Adds a highlight tag to every supported camera that is recording.")
    static let openAppWhenRun = true

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        .foreground(.immediate)
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        switch MulticamSystemCommandRouter.shared.perform(.addHighlight) {
        case .accepted:
            return .result(dialog: "Adding a highlight to all supported recording cameras.")
        case .unavailable:
            return .result(dialog: "No supported cameras are recording.")
        case .queued:
            return .result(dialog: "Opening Multicam to add a highlight.")
        }
    }
}

struct MulticamAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartAllCamerasIntent(),
            phrases: [
                "Start all cameras with \(.applicationName)",
                "Start all \(.applicationName) cameras",
                "Start all with \(.applicationName)",
                "Start recording with \(.applicationName)",
            ],
            shortTitle: "Start All",
            systemImageName: "record.circle"
        )

        AppShortcut(
            intent: StopAllCamerasIntent(),
            phrases: [
                "Stop all cameras with \(.applicationName)",
                "Stop all \(.applicationName) cameras",
                "Stop all with \(.applicationName)",
                "Stop recording with \(.applicationName)",
            ],
            shortTitle: "Stop All",
            systemImageName: "stop.circle"
        )

        AppShortcut(
            intent: HighlightAllCamerasIntent(),
            phrases: [
                "Highlight with \(.applicationName)",
                "Add a highlight with \(.applicationName)",
                "Highlight all cameras with \(.applicationName)",
            ],
            shortTitle: "Highlight",
            systemImageName: "bookmark.fill"
        )
    }

    static var shortcutTileColor: ShortcutTileColor {
        .red
    }
}
