import SwiftUI

struct CameraRowView: View {
    @Environment(CameraStore.self) private var store
    var camera: DiscoveredCamera
    var isShowingDiagnostics: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                store.toggleSelection(for: camera)
            } label: {
                Image(systemName: camera.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selectionColor)
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .disabled(!camera.canSelectForBatch && !camera.isSelected)
            .accessibilityLabel(camera.isSelected ? "Deselect \(camera.name)" : "Select \(camera.name)")

            VStack(alignment: .leading, spacing: 5) {
                Text(camera.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(cameraSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if let unsupportedReason = camera.unsupportedReason {
                    Text(unsupportedReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                if camera.unsupportedReason == nil,
                   isShowingDiagnostics,
                   let detail = camera.connectionState.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let diagnosticDetail = store.cameraDiagnosticDetail(for: camera),
                   shouldShowDiagnosticDetail,
                   isShowingDiagnostics {
                    Text(diagnosticDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 8)

            HStack(spacing: 8) {
                if camera.canSwitchToVideoMode {
                    CameraVideoModeButton(camera: camera)
                }

                CameraRecordButton(camera: camera)
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(camera.isSelected ? Color.acrReady.opacity(0.55) : Color.acrLine, lineWidth: 1)
        }
    }

    private var selectionColor: Color {
        if camera.isSelected {
            return .acrReady
        }
        return camera.canSelectForBatch ? .secondary : Color.secondary.opacity(0.35)
    }

    private var recordControlLabel: String {
        guard camera.supportsBatchRecord else { return "Record Control Pending" }
        if camera.isAvailableToConnect, camera.recordingState == .unknown {
            return CameraRecordingState.stopped.rawValue
        }
        return camera.recordingState.rawValue
    }

    private var cameraSubtitle: String {
        var parts = [camera.brand.rawValue, camera.model.rawValue, camera.displayConnectionLabel]

        if camera.isConnected {
            if let currentMode = camera.currentMode {
                parts.append(currentMode.rawValue)
            }
            parts.append(recordControlLabel)
        }

        return parts.joined(separator: " · ")
    }

    private var shouldShowDiagnosticDetail: Bool {
        camera.isKnownAction6 || camera.connectionState != .connected
    }
}

private struct CameraVideoModeButton: View {
    @Environment(CameraStore.self) private var store
    var camera: DiscoveredCamera

    var body: some View {
        Button {
            store.switchToVideo(camera)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "video")
                Text("Video")
            }
            .frame(minWidth: 78)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.acrReady)
        .fixedSize()
        .accessibilityLabel("Switch \(camera.name) to Video")
    }
}

private struct CameraRecordButton: View {
    @Environment(CameraStore.self) private var store
    var camera: DiscoveredCamera

    var body: some View {
        Group {
            if camera.recordingState == .recording {
                actionButton
                    .buttonStyle(.borderedProminent)
                    .tint(.acrInk)
            } else {
                actionButton
                    .buttonStyle(.bordered)
                    .tint(.acrRecord)
            }
        }
        .controlSize(.small)
        .disabled(camera.primaryRecordCommand == nil)
        .accessibilityLabel("\(camera.primaryRecordTitle) \(camera.name)")
        .fixedSize()
    }

    private var actionButton: some View {
        Button {
            performAction()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: camera.primaryRecordIcon)
                Text(camera.primaryRecordTitle)
            }
            .frame(minWidth: 82)
        }
    }

    private func performAction() {
        switch camera.primaryRecordCommand {
        case .startRecording:
            store.startRecording(camera)
        case .stopRecording:
            store.stopRecording(camera)
        case .toggleRecording, .setMode, .cycleMode, .applySetting, .keepAlive, nil:
            break
        }
    }
}
