import SwiftUI

struct WatchRemoteView: View {
    private enum Route: Hashable {
        case cameras
    }

    @EnvironmentObject private var session: WatchSessionModel
    @State private var path: [Route] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if session.isRecording {
                    stopOnlyView
                } else {
                    remoteView
                }
            }
            .background(Color.black)
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .cameras:
                    cameraListView
                }
            }
        }
        .tint(.red)
        .onChange(of: session.isRecording) { _, isRecording in
            if isRecording {
                path.removeAll()
            }
        }
    }

    private var remoteView: some View {
        VStack(spacing: 14) {
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
            cameraRow(camera)
        }
        .navigationTitle("Cameras")
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
        .accessibilityLabel("\(camera.name), \(camera.model), connected")
    }

    private var recordButton: some View {
        Button {
            session.record()
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

    private var stopOnlyView: some View {
        Button {
            session.stop()
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 34, weight: .bold))

                Text("Stop")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.red, in: Circle())
            .padding(12)
        }
        .buttonStyle(.plain)
        .disabled(session.isCommandPending)
        .accessibilityLabel("Stop recording")
        .accessibilityHint("Stops recording on all connected cameras")
    }
}
