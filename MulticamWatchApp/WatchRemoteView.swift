import SwiftUI

struct WatchRemoteView: View {
    @EnvironmentObject private var session: WatchSessionModel

    var body: some View {
        Group {
            if session.isRecording {
                stopOnlyView
            } else {
                cameraListView
            }
        }
        .background(Color.black)
        .tint(.red)
    }

    private var cameraListView: some View {
        ScrollView {
            VStack(spacing: 12) {
                if session.cameras.isEmpty {
                    ContentUnavailableView {
                        Label("No Cameras", systemImage: "video.slash")
                    } description: {
                        Text("Connect cameras in Multicam on iPhone.")
                    }
                    .padding(.top, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach(session.cameras) { camera in
                            cameraRow(camera)
                        }
                    }

                    recordButton
                }

                if !session.isPhoneReachable {
                    Text("Open Multicam on iPhone")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else if let statusMessage = session.statusMessage {
                    Text(statusMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .navigationTitle("Multicam")
    }

    private func cameraRow(_ camera: WatchCamera) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.green)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 1) {
                Text(camera.name)
                    .font(.headline)
                    .lineLimit(1)

                Text(camera.model)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(camera.name), \(camera.model), connected")
    }

    private var recordButton: some View {
        Button {
            session.record()
        } label: {
            Label("Record", systemImage: "record.circle")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .tint(.red)
        .disabled(!session.isPhoneReachable)
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
        .accessibilityLabel("Stop recording")
        .accessibilityHint("Stops recording on all connected cameras")
    }
}
