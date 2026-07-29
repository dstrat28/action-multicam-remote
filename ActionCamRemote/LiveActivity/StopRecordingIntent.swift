import AppIntents
import Foundation

extension Notification.Name {
    static let stopRecordingFromLiveActivity = Notification.Name(
        "com.ds.ActionCamRemote.stopRecordingFromLiveActivity"
    )
    static let addHighlightFromLiveActivity = Notification.Name(
        "com.ds.ActionCamRemote.addHighlightFromLiveActivity"
    )
}

struct AddHighlightIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Add Highlight"
    static var description = IntentDescription("Adds a highlight tag to supported cameras that are recording.")
    static var isDiscoverable = false

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .addHighlightFromLiveActivity, object: nil)
        }
        return .result()
    }
}

struct StopRecordingIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var description = IntentDescription("Stops every camera that is currently recording.")
    static var isDiscoverable = false

    @available(iOS 26.0, *)
    static var supportedModes: IntentModes {
        [.background, .foreground(.deferred)]
    }

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .stopRecordingFromLiveActivity, object: nil)
        }

#if APP_MAIN_TARGET
        if #available(iOS 26.0, *) {
            // Deferred foreground mode presents the app after the background work above completes.
        } else {
            try await requestToContinueInForeground()
        }
#endif

        return .result()
    }
}

#if APP_MAIN_TARGET
@available(iOS, introduced: 17.0, deprecated: 26.0)
extension StopRecordingIntent: ForegroundContinuableIntent {}
#endif
