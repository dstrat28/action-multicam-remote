import SwiftUI
#if DEBUG
import UIKit
#endif

struct CameraDashboardView: View {
    @Environment(CameraStore.self) private var store
    @State private var isManagingCameras = false
    @State private var manageCameraDetent: PresentationDetent = .large
    @State private var selectedCameraDetails: CameraDetailSelection?
    #if DEBUG
    @State private var isShowingDiagnostics = false
    #endif

    var body: some View {
        NavigationStack {
            ZStack {
                ACRAtmosphericBackground()

                ScrollView {
                    ACRGlassEffectContainer(spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            SessionReadiness()

                            CameraListView(
                                onManage: {
                                    isManagingCameras = true
                                },
                                onShowCameraDetails: { camera in
                                    guard store.isCameraReadyConnected(camera) else { return }
                                    selectedCameraDetails = CameraDetailSelection(id: camera.id)
                                }
                            )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 24)
                }
                .background(Color.clear)
            }
            .navigationTitle("Multicam Remote")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    #if DEBUG
                    Button {
                        isShowingDiagnostics = true
                    } label: {
                        Image(systemName: "waveform.path.ecg")
                    }
                    .foregroundStyle(Color.acrToolbarIcon)
                    .accessibilityLabel("Open diagnostics")
                    .help("Diagnostics")
                    #endif

                    if !store.pairedCameras.isEmpty {
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
            #if DEBUG
            .sheet(isPresented: $isShowingDiagnostics) {
                NavigationStack {
                    DiagnosticsSheet()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            #endif
        }
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
        let count = store.readyConnectedCameras.count
        guard count > 0 else { return "No cameras connected" }
        return count == 1 ? "1 camera connected" : "\(count) cameras connected"
    }

    private var statusColor: Color {
        store.readyConnectedCameras.isEmpty ? .secondary : .acrReady
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
        ACRPrimaryActionButton(
            title: title,
            systemImage: systemImage,
            tint: .acrRecord,
            isEnabled: isEnabled,
            isLoading: isStarting,
            size: .large,
            action: performAction
        )
    }

    private var title: String {
        if isStarting {
            return "Starting"
        }
        return store.canStopMulticamRecording ? "Stop" : "Record"
    }

    private var systemImage: String {
        store.canStopMulticamRecording ? "stop.fill" : "record.circle.fill"
    }

    private var isEnabled: Bool {
        store.canStopMulticamRecording || store.canStartMulticamRecording
    }

    private var isStarting: Bool {
        store.selectedControllableCameras.contains { $0.recordingState == .starting }
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
                let lhsRank = presentationSortRank(for: lhs.element)
                let rhsRank = presentationSortRank(for: rhs.element)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func presentationSortRank(for camera: DiscoveredCamera) -> Int {
        if store.isCameraReadyConnected(camera) {
            return 0
        }
        if store.isCameraConnectInProgress(camera) {
            return 1
        }
        return 2
    }

    private func shouldMatchConnectedPeerHeight(
        at index: Int,
        in cameras: [DiscoveredCamera]
    ) -> Bool {
        guard horizontalSizeClass == .regular,
              cameras.indices.contains(index),
              !store.isCameraReadyConnected(cameras[index]) else {
            return false
        }

        let peerIndex = index.isMultiple(of: 2) ? index + 1 : index - 1
        return cameras.indices.contains(peerIndex)
            && store.isCameraReadyConnected(cameras[peerIndex])
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

#if DEBUG
private struct DiagnosticsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store
    @State private var didCopyDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                CameraDiagnosticsView()
                DJIStatusProbeView()
                RecentResultsView()
                EventLogView()
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(16)
        }
        .background(Color.acrAppBackground)
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    UIPasteboard.general.string = store.diagnosticsText
                    didCopyDiagnostics = true
                } label: {
                    Label(
                        didCopyDiagnostics ? "Copied" : "Copy",
                        systemImage: didCopyDiagnostics ? "checkmark" : "doc.on.doc"
                    )
                }
            }

            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

private struct CameraDiagnosticsView: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Camera State")
                .font(.headline)

            if store.pairedCameras.isEmpty {
                Text("No paired cameras.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .acrInsetPanel()
            } else {
                ForEach(store.pairedCameras) { camera in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(camera.name)
                                .font(.subheadline.weight(.semibold))

                            Spacer()

                            Text(camera.displayConnectionLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(camera.connectionState.statusColor)
                        }

                        if let detail = camera.connectionState.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if let diagnostic = store.cameraDiagnosticDetail(for: camera) {
                            Text(diagnostic)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .acrInsetPanel()
                }
            }
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
#endif

#Preview {
    CameraDashboardView()
        .environment(CameraStore.preview)
}
