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

        // A temporary disconnect can turn an active camera's state unknown. Keep the
        // activity visible and let its stale date communicate that status is uncertain.
        let trackedCameras = cameras.filter { activeCameraIDs.contains($0.id) }
        let hasUncertainTrackedCamera = trackedCameras.contains {
            $0.recordingState == .unknown || $0.recordingState == .starting
        }

        if hasUncertainTrackedCamera {
            return
        }

        // After process restoration there is no in-memory ID set. Do not dismiss an
        // existing activity until the camera list has reached a conclusive state.
        if activeCameraIDs.isEmpty,
           cameras.contains(where: {
               $0.recordingState == .unknown || $0.recordingState == .starting
           }) {
            return
        }

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
