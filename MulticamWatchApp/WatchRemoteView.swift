import SwiftUI

struct WatchRemoteView: View {
    private enum Route: Hashable {
        case cameras
        case camera(String)
    }

    @EnvironmentObject private var session: WatchSessionModel
    @State private var path: [Route] = []
    @State private var highlightFeedbackTrigger = 0
    @State private var recordingFeedbackTrigger = 0

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if session.isRecording {
                    recordingControlsView
                } else {
                    remoteView
                }
            }
            .background(Color.black)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .cameras:
                    cameraListView
                case .camera(let cameraID):
                    cameraDetailView(cameraID: cameraID)
                }
            }
        }
        .tint(.red)
        .sensoryFeedback(.impact(weight: .medium), trigger: recordingFeedbackTrigger)
        .onChange(of: session.isRecording) { _, isRecording in
            if isRecording {
                path.removeAll()
            }
        }
    }

    private var remoteView: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            statusView

            recordButton

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .navigationTitle("Multicam")
    }

    @ViewBuilder
    private var statusView: some View {
        if !session.cameras.isEmpty {
            NavigationLink(value: Route.cameras) {
                statusLabel(
                    title: connectedCameraTitle,
                    systemImage: "video.fill",
                    showsDisclosure: true
                )
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows connected cameras")
        } else {
            statusLabel(
                title: unavailableStatusTitle,
                systemImage: session.hasReceivedState ? "video.slash" : "iphone.slash",
                showsDisclosure: false
            )
        }
    }

    private func statusLabel(
        title: String,
        systemImage: String,
        showsDisclosure: Bool
    ) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage)
                .foregroundStyle(session.cameras.isEmpty ? Color.secondary : Color.green)

            Text(title)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .minimumScaleFactor(0.95)
                .allowsTightening(true)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)

            Spacer(minLength: 0)

            if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var connectedCameraTitle: String {
        let count = session.cameras.count
        return count == 1 ? "1 camera\nconnected" : "\(count) cameras\nconnected"
    }

    private var unavailableStatusTitle: String {
        if !session.hasReceivedState {
            return "Open iPhone\napp"
        }

        if let statusMessage = session.statusMessage {
            return statusMessage
        }

        return "No cameras connected"
    }

    private var cameraListView: some View {
        List(session.cameras) { camera in
            NavigationLink(value: Route.camera(camera.id)) {
                cameraRow(camera)
            }
        }
        .navigationTitle("Cameras")
    }

    @ViewBuilder
    private func cameraDetailView(cameraID: String) -> some View {
        if let camera = session.cameras.first(where: { $0.id == cameraID }) {
            WatchCameraDetailView(camera: camera)
        } else {
            ContentUnavailableView("Camera unavailable", systemImage: "video.slash")
                .navigationTitle("Camera")
        }
    }

    private func cameraRow(_ camera: WatchCamera) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.name)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                if camera.model != camera.name {
                    Text(camera.model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(camera.name), \(camera.model), connected, show details")
    }

    private var recordButton: some View {
        Button {
            session.record()
            recordingFeedbackTrigger += 1
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    if session.isCommandPending {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "record.circle")
                    }
                }
                .frame(width: 18, height: 18)

                Text(session.isCommandPending ? "Starting" : "Record")
            }
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 48)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(.red)
        .disabled(session.cameras.isEmpty || session.isCommandPending)
        .accessibilityLabel(session.isCommandPending ? "Starting recording" : "Record")
        .accessibilityHint("Starts recording on all connected cameras")
    }

    private var recordingControlsView: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)

            if session.canAddHighlight {
                highlightButton
            }

            stopButton

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var highlightButton: some View {
        Button {
            guard session.pendingCommand != "highlight" else { return }
            session.highlight()
            highlightFeedbackTrigger += 1
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "bookmark.fill")
                    .frame(width: 18, height: 18)

                Text("Highlight")
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(.yellow)
        .allowsHitTesting(session.pendingCommand != "highlight")
        .sensoryFeedback(.selection, trigger: highlightFeedbackTrigger)
        .accessibilityLabel("Add Highlight")
        .accessibilityHint("Adds a highlight tag to supported cameras that are recording")
    }

    private var stopButton: some View {
        Button {
            session.stop()
            recordingFeedbackTrigger += 1
        } label: {
            HStack(spacing: 7) {
                ZStack {
                    if session.pendingCommand == "stop" {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "stop.fill")
                    }
                }
                .frame(width: 18, height: 18)

                Text(session.pendingCommand == "stop" ? "Stopping" : "Stop")
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(.red)
        .disabled(session.pendingCommand == "stop")
        .accessibilityLabel(session.pendingCommand == "stop" ? "Stopping recording" : "Stop recording")
        .accessibilityHint("Stops recording on all connected cameras")
    }
}

private struct WatchCameraDetailView: View {
    var camera: WatchCamera

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header

                if hasRingMetrics {
                    metricRings
                }

                cameraDetails
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(camera.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Circle()
                    .fill(camera.isRecording ? Color.red : Color.green)
                    .frame(width: 7, height: 7)

                Text(camera.isRecording ? "Recording" : "Connected")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(camera.isRecording ? Color.red : Color.green)
            }

            if camera.model != camera.name {
                Text(camera.model)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var metricRings: some View {
        HStack(spacing: 10) {
            if let batteryProgress {
                WatchMetricRing(
                    title: "Battery",
                    value: batteryValue,
                    progress: batteryProgress,
                    color: batteryColor,
                    systemImage: camera.isExternalPowerConnected == true ? "bolt.fill" : nil
                )
            }

            if let storageProgress {
                WatchMetricRing(
                    title: "Storage",
                    value: "\(Int((storageProgress * 100).rounded()))%",
                    progress: storageProgress,
                    color: .cyan,
                    systemImage: nil
                )
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var cameraDetails: some View {
        VStack(alignment: .leading, spacing: 7) {
            detailRow(label: "Mode", value: camera.modeName ?? "Unknown")

            if !camera.modeDetails.isEmpty {
                detailRow(label: "Details", value: camera.modeDetails.joined(separator: " · "))
            }

            if let storageFreeMB = camera.storageFreeMB {
                detailRow(label: "Available", value: Self.storage(mb: storageFreeMB))
            } else if let sdCardCapacityMB = camera.sdCardCapacityMB {
                detailRow(label: "SD Card", value: Self.storage(mb: sdCardCapacityMB))
            } else if let storageState = camera.storageState {
                detailRow(label: "Storage", value: storageState)
            }

            if let remainingVideoSeconds = camera.remainingVideoSeconds {
                detailRow(label: "Video Left", value: Self.duration(seconds: remainingVideoSeconds))
            }

            if let remainingPhotos = camera.remainingPhotos {
                detailRow(label: "Photos Left", value: "\(remainingPhotos)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func detailRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.trailing)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }

    private var batteryProgress: Double? {
        if let percent = camera.batteryPercent {
            return min(max(Double(percent) / 100, 0), 1)
        }
        if let bars = camera.batteryBars {
            return min(max(Double(bars) / 4, 0), 1)
        }
        return nil
    }

    private var batteryValue: String {
        if let percent = camera.batteryPercent { return "\(percent)%" }
        if let bars = camera.batteryBars { return "\(bars)/4" }
        return "—"
    }

    private var batteryColor: Color {
        guard let batteryProgress else { return .green }
        if batteryProgress <= 0.2 { return .red }
        if batteryProgress <= 0.4 { return .yellow }
        return .green
    }

    private var storageProgress: Double? {
        guard let free = camera.storageFreeMB,
              let total = camera.storageTotalMB ?? camera.sdCardCapacityMB,
              total > 0 else {
            return nil
        }
        let freeFraction = min(max(Double(free) / Double(total), 0), 1)
        return 1 - freeFraction
    }

    private var hasRingMetrics: Bool {
        batteryProgress != nil || storageProgress != nil
    }

    private static func storage(mb: Int) -> String {
        if mb >= 1024 {
            return "\(wholeGB(mb: mb)) GB"
        }
        return "\(mb) MB"
    }

    private static func wholeGB(mb: Int) -> Int {
        Int((Double(mb) / 1024).rounded())
    }

    private static func duration(seconds: Int) -> String {
        let totalMinutes = seconds / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0, minutes > 0 { return "\(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h" }
        return "\(max(1, minutes))m"
    }
}

private struct WatchMetricRing: View {
    var title: String
    var value: String
    var progress: Double
    var color: Color
    var systemImage: String?

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .stroke(color.opacity(0.2), lineWidth: 6)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 0) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .font(.caption2.weight(.bold))
                    }
                    Text(value)
                        .font(.caption.weight(.bold))
                        .minimumScaleFactor(0.7)
                }
                .foregroundStyle(color)
            }
            .frame(width: 64, height: 64)

            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }
}
