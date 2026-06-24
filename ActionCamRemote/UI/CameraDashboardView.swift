import SwiftUI
import UIKit

struct CameraDashboardView: View {
    @Environment(CameraStore.self) private var store
    @State private var isManagingCameras = false
    @State private var manageCameraDetent: PresentationDetent = .large
    @State private var isShowingDiagnostics = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ControlDeckView()
                    CameraListView(isShowingDiagnostics: isShowingDiagnostics) {
                        isManagingCameras = true
                    }
                    DiagnosticsView(isExpanded: $isShowingDiagnostics)
                }
                .padding()
            }
            .background(Color.acrPanel.opacity(0.45))
            .navigationTitle("Multicam")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        store.selectAllSupported()
                    } label: {
                        Image(systemName: "checklist.checked")
                    }
                    .accessibilityLabel("Select supported cameras")
                }
            }
            .sheet(isPresented: $isManagingCameras) {
                NavigationStack {
                    PairingView()
                }
                .presentationDetents([.large], selection: $manageCameraDetent)
            }
        }
    }
}

private struct ControlDeckView: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Multicam Control")
                        .font(.title2.weight(.bold))
                    Text("\(store.selectedControllableCameras.count) selected · \(store.connectedCameras.count) connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }

            HStack(spacing: 10) {
                if store.canStopMulticamRecording {
                    IconActionButton("Stop All Cameras", systemImage: "stop.circle", role: nil) {
                        store.stopMulticamRecording()
                    }
                    .tint(.acrInk)
                } else {
                    IconActionButton(startButtonTitle, systemImage: "record.circle", role: nil) {
                        store.startMulticamRecording()
                    }
                    .tint(.acrRecord)
                    .disabled(!store.canStartMulticamRecording)
                }
            }

            Text(store.multicamReadinessMessage)
                .font(.caption)
                .foregroundStyle(store.canStartMulticamRecording ? Color.acrReady : .secondary)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
            .stroke(Color.acrLine, lineWidth: 1)
        }
    }

    private var startButtonTitle: String {
        guard !store.controllableRecordCameras.isEmpty,
              store.selectedControllableCameras.count == store.controllableRecordCameras.count else {
            return "Start Selected Cameras"
        }

        return "Start All Cameras"
    }
}

private struct CameraListView: View {
    @Environment(CameraStore.self) private var store
    var isShowingDiagnostics: Bool
    var onManage: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Cameras")
                    .font(.headline)
                Spacer()
                Button("Manage") {
                    onManage()
                }
                .buttonStyle(.bordered)
            }

            if store.pairedCameras.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "camera.badge.ellipsis")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text("No Cameras Connected")
                        .font(.headline)

                    Text("Use Manage Cameras to pair cameras. Remembered cameras show here as Connected, Available, or Not Connected.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .padding(.horizontal)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
            } else {
                LazyVStack(spacing: 10) {
                    ForEach(store.pairedCameras) { camera in
                        CameraRowView(
                            camera: camera,
                            isShowingDiagnostics: isShowingDiagnostics
                        )
                    }
                }
            }
        }
    }
}

private struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store

    var body: some View {
        List {
            Section("Discovered") {
                if store.pairingCameras.isEmpty {
                    ContentUnavailableView(
                        "No Cameras Found",
                        systemImage: "camera.badge.ellipsis",
                        description: Text("Put a camera in pairing mode, then scan.")
                    )
                } else {
                    ForEach(store.pairingCameras) { camera in
                        PairingCameraRow(camera: camera)
                    }
                }
            }
        }
        .navigationTitle("Manage Cameras")
        .onAppear {
            store.setPairingModeActive(true)
            store.startScanning()
        }
        .onDisappear {
            store.setPairingModeActive(false)
            if store.pairedCameras.isEmpty {
                store.stopScanning()
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct PairingCameraRow: View {
    @Environment(CameraStore.self) private var store
    var camera: DiscoveredCamera

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(camera.name)
                        .font(.headline)
                        .lineLimit(1)

                    Text("\(camera.brand.rawValue) · \(camera.model.rawValue) · \(camera.connectionState.label)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    if camera.isPaired {
                        Button(role: .destructive) {
                            store.remove(camera)
                        } label: {
                            Text("Remove")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                    } else if camera.unsupportedReason != nil {
                        Button {
                        } label: {
                            Text("Unsupported")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(true)
                    } else {
                        Button {
                            store.connect(camera)
                        } label: {
                            Text(pairButtonTitle)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .fixedSize()
                        .disabled(camera.connectionState == .connecting)
                    }
                }
            }

            if camera.unsupportedReason == nil,
               let detail = camera.connectionState.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var pairButtonTitle: String {
        camera.connectionState == .connecting ? "Pairing" : "Pair"
    }
}

private struct DiagnosticsView: View {
    @Environment(CameraStore.self) private var store
    @Binding var isExpanded: Bool
    @State private var didCopyDiagnostics = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button {
                        UIPasteboard.general.string = store.diagnosticsText
                        didCopyDiagnostics = true
                    } label: {
                        Label(didCopyDiagnostics ? "Copied" : "Copy Diagnostics", systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Spacer()
                }

                DJIStatusProbeView()
                RecentResultsView()
                EventLogView()
            }
            .padding(.top, 10)
        } label: {
            Label("Diagnostics", systemImage: "waveform.path.ecg")
                .font(.headline)
        }
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.acrLine, lineWidth: 1)
        }
    }
}

private struct DJIStatusProbeView: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        let cameras = store.connectedCameras.filter { $0.brand == .dji }

        if !cameras.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("DJI Status Probe")
                    .font(.headline)

                ForEach(cameras) { camera in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(camera.name)
                                .font(.subheadline.weight(.semibold))
                            Text("Tap after setting the camera mode on-device.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            store.probeStatus(camera)
                        } label: {
                            Label("Probe", systemImage: "waveform.path.ecg")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }
}

private struct RecentResultsView: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Command Results")
                .font(.headline)

            if store.commandResults.isEmpty {
                Text("No commands sent yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
            } else {
                ForEach(store.commandResults.prefix(6)) { result in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: result.status))
                            .foregroundStyle(color(for: result.status))
                            .frame(width: 22)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(result.cameraName)
                                .font(.subheadline.weight(.semibold))
                            Text("\(result.command.label): \(result.message)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(10)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func icon(for status: CameraCommandStatus) -> String {
        switch status {
        case .queued, .sent:
            "checkmark.circle.fill"
        case .skipped:
            "minus.circle.fill"
        case .unsupported:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.circle.fill"
        }
    }

    private func color(for status: CameraCommandStatus) -> Color {
        switch status {
        case .queued, .sent:
            .acrReady
        case .skipped:
            .secondary
        case .unsupported:
            .acrWarning
        case .failed:
            .acrRecord
        }
    }
}

private struct EventLogView: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bluetooth Log")
                .font(.headline)

            if store.eventLog.isEmpty {
                Text("Discovery and protocol messages will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background, in: RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(store.eventLog.prefix(30), id: \.self) { line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }
}

#Preview {
    CameraDashboardView()
        .environment(CameraStore.preview)
}
