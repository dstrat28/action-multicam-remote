import SwiftUI
import UIKit

struct CameraDashboardView: View {
    @Environment(CameraStore.self) private var store
    @State private var isManagingCameras = false
    @State private var manageCameraDetent: PresentationDetent = .large
    @State private var selectedCameraDetails: CameraDetailSelection?
    @State private var isShowingDiagnostics = false

    var body: some View {
        NavigationStack {
            ZStack {
                ACRAtmosphericBackground()

                ScrollView {
                    ACRGlassEffectContainer(spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            SessionReadiness()

                            CameraListView(
                                isShowingDiagnostics: activeDiagnosticsVisibility,
                                onManage: {
                                    isManagingCameras = true
                                },
                                onShowCameraDetails: { camera in
                                    guard camera.isConnected else { return }
                                    selectedCameraDetails = CameraDetailSelection(id: camera.id)
                                }
                            )
                            #if DEBUG
                            DiagnosticsView(isExpanded: $isShowingDiagnostics)
                            #endif
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .background(Color.clear)
            }
            .navigationTitle(Text("Multicam Remote").fontDesign(.rounded))
            .toolbar {
                if !store.pairedCameras.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            isManagingCameras = true
                        } label: {
                            Image(systemName: "plus")
                        }
                        .foregroundStyle(Color.acrToolbarIcon)
                        .accessibilityLabel("Manage cameras")
                        .help("Manage cameras")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !store.pairedCameras.isEmpty {
                    MulticamRecordBar()
                        .padding(.horizontal, 16)
                        .padding(.top, 10)
                        .padding(.bottom, 4)
                }
            }
            .sheet(isPresented: $isManagingCameras) {
                NavigationStack {
                    PairingView()
                }
                .presentationDetents([.large], selection: $manageCameraDetent)
            }
            .sheet(item: $selectedCameraDetails) { selection in
                NavigationStack {
                    CameraDetailView(cameraID: selection.id)
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
        }
    }

    private var activeDiagnosticsVisibility: Bool {
        #if DEBUG
        isShowingDiagnostics
        #else
        false
        #endif
    }
}

private struct CameraDetailSelection: Identifiable {
    var id: UUID
}

private struct SessionReadiness: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            Text(sessionSummary)
                .font(.headline.weight(.semibold))
                .foregroundStyle(statusColor)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
    }

    private var sessionSummary: String {
        let count = store.connectedCameras.count
        guard count > 0 else { return "No cameras connected" }
        return count == 1 ? "1 camera connected" : "\(count) cameras connected"
    }

    private var statusColor: Color {
        store.connectedCameras.isEmpty ? .secondary : .acrReady
    }
}

private struct MulticamRecordBar: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            selectionLabel

            Spacer(minLength: 4)

            actionButton
        }
        .frame(minHeight: 56, alignment: .center)
        .padding(.leading, 18)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .acrFloatingControlBar()
        .frame(maxWidth: .infinity)
    }

    private var selectionLabel: some View {
        Text(selectionSummary)
            .font(.body.weight(.semibold))
            .fontDesign(.rounded)
            .foregroundStyle(Color.acrInk)
            .lineLimit(1)
    }

    private var actionButton: some View {
        Button {
            performAction()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
                .font(.headline.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(isEnabled ? Color.white : Color.acrMutedText)
                .frame(minWidth: 148)
                .frame(height: 58)
                .padding(.horizontal, 12)
                .background(
                        buttonFill,
                        in: RoundedRectangle(cornerRadius: ACRDesign.buttonCornerRadius, style: .continuous)
                    )
                .overlay {
                    RoundedRectangle(cornerRadius: ACRDesign.buttonCornerRadius, style: .continuous)
                        .stroke(
                            isEnabled
                                ? Color.white.opacity(0.20)
                                : Color.acrLine.opacity(0.46),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: isEnabled ? Color.acrRecord.opacity(0.38) : .clear,
                    radius: 16,
                    y: 6
                )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
    }

    private var title: String {
        store.canStopMulticamRecording ? "Stop" : "Record"
    }

    private var systemImage: String {
        store.canStopMulticamRecording ? "stop.fill" : "record.circle.fill"
    }

    private var isEnabled: Bool {
        store.canStopMulticamRecording || store.canStartMulticamRecording
    }

    private var buttonFill: LinearGradient {
        LinearGradient(
            colors: isEnabled
                ? [Color(red: 1.00, green: 0.22, blue: 0.28), Color.acrRecord, Color(red: 0.78, green: 0.04, blue: 0.12)]
                : [Color.secondary.opacity(0.24), Color.secondary.opacity(0.18)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var selectionSummary: String {
        let count = store.selectedCameras.count
        guard count > 0 else { return "No cameras" }
        return count == 1 ? "1 camera" : "\(count) cameras"
    }

    private func performAction() {
        if store.canStopMulticamRecording {
            store.stopMulticamRecording()
        } else {
            store.startMulticamRecording()
        }
    }
}

private struct CameraListView: View {
    @Environment(CameraStore.self) private var store
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var isShowingDiagnostics: Bool
    var onManage: () -> Void
    var onShowCameraDetails: (DiscoveredCamera) -> Void

    var body: some View {
        let cameras = dashboardCameras

        VStack(alignment: .leading, spacing: 8) {
            if cameras.isEmpty {
                Button {
                    onManage()
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: "plus")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.acrAvailable)
                            .frame(width: 44, height: 44)
                            .background(
                                Color.acrAvailable.opacity(0.12),
                                in: Circle()
                            )

                        Text("Add Camera")
                            .font(.headline.weight(.semibold))
                            .fontDesign(.rounded)
                            .foregroundStyle(Color.acrInk)

                        Spacer(minLength: 8)

                        Image(systemName: "chevron.right")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.acrMutedText)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .frame(minHeight: 72)
                    .contentShape(Rectangle())
                    .acrCard(
                        fill: Color.acrSurface,
                        stroke: Color.acrLine.opacity(0.8),
                        interactive: true
                    )
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .accessibilityLabel("Add Camera")
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 330), spacing: 10, alignment: .top)],
                    alignment: .leading,
                    spacing: 7
                ) {
                    ForEach(Array(cameras.enumerated()), id: \.element.id) { index, camera in
                        CameraRowView(
                            camera: camera,
                            isShowingDiagnostics: isShowingDiagnostics,
                            matchesConnectedPeerHeight: shouldMatchConnectedPeerHeight(
                                at: index,
                                in: cameras
                            ),
                            onShowDetails: {
                                onShowCameraDetails(camera)
                            }
                        )
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var dashboardCameras: [DiscoveredCamera] {
        store.pairedCameras
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isConnected != rhs.element.isConnected {
                    return lhs.element.isConnected
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func shouldMatchConnectedPeerHeight(
        at index: Int,
        in cameras: [DiscoveredCamera]
    ) -> Bool {
        guard horizontalSizeClass == .regular,
              cameras.indices.contains(index),
              !cameras[index].isConnected else {
            return false
        }

        let peerIndex = index.isMultiple(of: 2) ? index + 1 : index - 1
        return cameras.indices.contains(peerIndex) && cameras[peerIndex].isConnected
    }
}

private struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store

    var body: some View {
        List {
            Section {
                if store.pairingCameras.isEmpty {
                    ContentUnavailableView(
                        "No Cameras Found",
                        systemImage: "camera.badge.ellipsis",
                        description: Text("Put a camera in pairing mode.")
                    )
                } else {
                    ForEach(store.pairingCameras) { camera in
                        PairingCameraRow(camera: camera)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.acrAppBackground)
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
                CameraProductThumbnail(model: camera.model, brand: camera.brand, size: .small)

                VStack(alignment: .leading, spacing: 3) {
                    Text(camera.name)
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)

                    Text("\(camera.brand.rawValue) · \(camera.model.rawValue)")
                        .font(.subheadline)
                        .foregroundStyle(Color.acrMutedText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.78)

                    connectionStatus
                        .padding(.top, 1)
                }
                .layoutPriority(1)

                Spacer(minLength: 4)

                if camera.isPaired {
                    Button(role: .destructive) {
                        store.remove(camera)
                    } label: {
                        Text("Remove")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .fixedSize()
                } else if camera.unsupportedReason == nil {
                    Button {
                        store.connect(camera)
                    } label: {
                        Text(pairButtonTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(camera.connectionState == .connecting || camera.needsGoProPairingMode)
                }
            }

            if let detail = pairingDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.acrMutedText)
            }
        }
        .padding(.vertical, 4)
    }

    private var connectionStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(camera.connectionState.statusColor)
                .frame(width: 6, height: 6)

            Text(camera.displayConnectionLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(camera.connectionState.statusColor)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var pairButtonTitle: String {
        if camera.needsGoProPairingMode {
            return "Pairing Mode"
        }
        return camera.connectionState == .connecting ? "Pairing" : "Pair"
    }

    private var pairingDetail: String? {
        if camera.needsGoProPairingMode {
            return "Put the GoPro in pairing mode from the camera UI, then tap Pair again."
        }

        guard camera.unsupportedReason == nil else { return nil }
        return camera.connectionState.detail
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
                .foregroundStyle(Color.acrInk)
        }
        .padding()
        .acrCard(fill: Color.acrSurface.opacity(0.78), stroke: Color.acrLine.opacity(0.9))
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
                    .acrInsetPanel()
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
                    .acrInsetPanel()
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
                    .acrInsetPanel()
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
                    .acrInsetPanel()
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
                .acrInsetPanel()
            }
        }
    }
}

#Preview {
    CameraDashboardView()
        .environment(CameraStore.preview)
}
