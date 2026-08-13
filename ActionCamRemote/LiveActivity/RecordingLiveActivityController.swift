import ActivityKit
import Foundation

@MainActor
final class RecordingLiveActivityController {
    private let staleInterval: TimeInterval = 30
    private var activity: Activity<RecordingActivityAttributes>?
    private var activeCameraIDs: Set<UUID> = []
    private var isStopping = false
    private var latestCameras: [DiscoveredCamera] = []
    private var stoppingResetTask: Task<Void, Never>?

    init() {
        activity = Activity<RecordingActivityAttributes>.activities.first
    }

    func reconcile(cameras: [DiscoveredCamera]) {
        latestCameras = cameras
        let recordingCameras = cameras.filter { $0.recordingState == .recording }

        if !recordingCameras.isEmpty {
            activeCameraIDs.formUnion(recordingCameras.map(\.id))
            let state = contentState(cameras: cameras, recordingCameras: recordingCameras)

            if let activity {
                update(activity, state: state)
            } else {
                start(state: state)
            }
            return
        }

        guard let activity else { return }

        // Preserve the activity while any tracked camera is still recording or in a
        // genuine connection transition. End only once every tracked camera has
        // reached a terminal, non-recording state.
        guard RecordingActivityReconciliationPolicy.shouldEnd(
            cameras: cameras,
            activeCameraIDs: activeCameraIDs
        ) else { return }

        end(activity)
    }

    func markStopping(cameras: [DiscoveredCamera]) {
        guard let activity else { return }
        let recordingCameras = cameras.filter { $0.recordingState == .recording }
        guard !recordingCameras.isEmpty else { return }

        isStopping = true
        update(
            activity,
            state: contentState(cameras: cameras, recordingCameras: recordingCameras)
        )

        stoppingResetTask?.cancel()
        stoppingResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self else { return }

            self.isStopping = false
            let recordingCameras = self.latestCameras.filter { $0.recordingState == .recording }
            guard let activity = self.activity, !recordingCameras.isEmpty else { return }
            self.update(
                activity,
                state: self.contentState(
                    cameras: self.latestCameras,
                    recordingCameras: recordingCameras
                )
            )
        }
    }

    private func contentState(
        cameras: [DiscoveredCamera],
        recordingCameras: [DiscoveredCamera]
    ) -> RecordingActivityAttributes.ContentState {
        RecordingActivityAttributes.ContentState(
            recordingCameraCount: recordingCameras.count,
            connectedCameraCount: cameras.filter { $0.connectionState == .connected }.count,
            isStopping: isStopping,
            canAddHighlight: recordingCameras.contains {
                $0.supportsHighlight && $0.connectionState == .connected
            }
        )
    }

    private func start(state: RecordingActivityAttributes.ContentState) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        isStopping = false
        do {
            activity = try Activity.request(
                attributes: RecordingActivityAttributes(startedAt: Date()),
                content: ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(staleInterval)
                ),
                pushType: nil
            )
        } catch {
            // Recording control must remain independent from Live Activity availability.
        }
    }

    private func update(
        _ activity: Activity<RecordingActivityAttributes>,
        state: RecordingActivityAttributes.ContentState
    ) {
        Task {
            await activity.update(
                ActivityContent(
                    state: state,
                    staleDate: Date().addingTimeInterval(staleInterval)
                )
            )
        }
    }

    private func end(_ activity: Activity<RecordingActivityAttributes>) {
        self.activity = nil
        activeCameraIDs.removeAll()
        isStopping = false
        stoppingResetTask?.cancel()
        stoppingResetTask = nil

        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}
