import SwiftUI
import UIKit

struct CameraDashboardView: View {
    @Environment(CameraStore.self) private var store
    @State private var isManagingCameras = false
    @State private var manageCameraDetent: PresentationDetent = .large
    @State private var selectedCameraDetails: CameraDetailSelection?
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                ACRAtmosphericBackground()

                ScrollView {
                    ACRGlassEffectContainer(spacing: 10) {
                        VStack(alignment: .leading, spacing: 10) {
                            if !store.pairedCameras.isEmpty {
                                SessionReadiness()
                            }

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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .foregroundStyle(Color.acrToolbarIcon)
                    .accessibilityLabel("Settings")
                    .help("Settings")
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
            .sheet(isPresented: $isShowingSettings) {
                NavigationStack {
                    SettingsView()
                }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            }
            .alert(
                "Confirm Pairing",
                isPresented: Binding(
                    get: { store.nanoPairingConfirmation != nil },
                    set: { isPresented in
                        if !isPresented {
                            store.dismissNanoPairingConfirmation()
                        }
                    }
                )
            ) {
                Button("Got It") {
                    store.dismissNanoPairingConfirmation()
                }
            } message: {
                Text("On your \(store.nanoPairingConfirmation?.cameraName ?? "camera"), confirm the connection to Multicam.")
            }
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
    @AppStorage(ACRPreferences.largerControls) private var largerControls = false

    var body: some View {
        HStack(alignment: .center, spacing: showsSelectionCount ? 8 : 12) {
            if showsSelectionCount {
                selectionLabel
                Spacer(minLength: 4)
            }
            recordingControls
        }
        .frame(minHeight: 56, alignment: .center)
        .padding(.leading, showsSelectionCount ? 18 : 10)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .acrFloatingControlBar()
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var recordingControls: some View {
        if store.canAddHighlight {
            highlightButton
        }
        actionButton
    }

    private var highlightButton: some View {
        ACRPrimaryActionButton(
            title: "Highlight",
            systemImage: "bookmark.fill",
            tint: .yellow,
            size: .large,
            appearance: .outlined,
            showsTitle: false,
            feedback: .success,
            action: {
                store.addHighlight()
            }
        )
        .accessibilityLabel("Add Highlight")
        .accessibilityHint("Adds a highlight tag to every supported camera that is recording")
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
            isLoading: store.isStoppingMulticamRecording || isStarting || isPhotoCaptureInProgress,
            size: .large,
            minimumContentWidth: store.canStopMulticamRecording ? 124 : nil,
            fillsWidth: !showsSelectionCount,
            action: performAction
        )
    }

    private var showsSelectionCount: Bool {
        !largerControls && !store.canStopMulticamRecording && !store.isStoppingMulticamRecording
    }

    private var title: String {
        if store.isStoppingMulticamRecording {
            return "Stopping…"
        }
        if isPhotoCaptureInProgress {
            return "Capturing"
        }
        if isStarting {
            return "Starting"
        }
        if store.canStopMulticamRecording {
            return "Stop"
        }
        return store.isPhotoMulticamSession ? "Capture" : "Record"
    }

    private var systemImage: String {
        if store.canStopMulticamRecording {
            return "stop.fill"
        }
        return store.isPhotoMulticamSession ? "camera.fill" : "record.circle.fill"
    }

    private var isEnabled: Bool {
        store.isStoppingMulticamRecording || store.canStopMulticamRecording || store.canStartMulticamRecording
    }

    private var isStarting: Bool {
        !store.isPhotoMulticamSession
            && store.selectedControllableCameras.contains { $0.recordingState == .starting }
    }

    private var isPhotoCaptureInProgress: Bool {
        store.isPhotoMulticamSession
            && store.selectedControllableCameras.contains {
                $0.recordingState == .starting || $0.recordingState == .recording
            }
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
    @State private var columnCount = 1
    var onManage: () -> Void
    var onShowCameraDetails: (DiscoveredCamera) -> Void

    var body: some View {
        let cameras = dashboardCameras
        let minimumCardWidth: CGFloat = 330
        let columnSpacing: CGFloat = 10

        VStack(alignment: .leading, spacing: 8) {
            if cameras.isEmpty {
                firstCameraPrompt
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: minimumCardWidth), spacing: columnSpacing, alignment: .top)],
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
        .onGeometryChange(for: Int.self) { geometry in
            max(1, Int((geometry.size.width + columnSpacing) / (minimumCardWidth + columnSpacing)))
        } action: { count in
            columnCount = count
        }
    }

    private var firstCameraPrompt: some View {
        VStack(spacing: 24) {
            Image(systemName: "camera.on.rectangle")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(Color.acrAvailable)
                .frame(width: 96, height: 96)
                .background(Color.acrAvailable.opacity(0.10), in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 10) {
                Text("Pair your first camera")
                    .font(.title2.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(Color.acrInk)

                Text("Connect a GoPro, DJI, or Insta360 camera.")
                    .font(.body)
                    .foregroundStyle(Color.acrMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center)

            ACRPrimaryActionButton(
                title: "Pair Camera",
                systemImage: "plus",
                tint: .acrAvailable,
                size: .large,
                fillsWidth: true,
                action: onManage
            )
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 32)
        .frame(maxWidth: 560)
        .acrCard(fill: Color.acrSurface, stroke: Color.acrLine.opacity(0.8))
        .frame(maxWidth: .infinity)
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
        camera.defaultSortRank
    }

    private func shouldMatchConnectedPeerHeight(
        at index: Int,
        in cameras: [DiscoveredCamera]
    ) -> Bool {
        guard columnCount > 1,
              cameras.indices.contains(index),
              !store.isCameraReadyConnected(cameras[index]) else {
            return false
        }

        let rowStart = (index / columnCount) * columnCount
        let rowEnd = min(rowStart + columnCount, cameras.count)
        return cameras[rowStart..<rowEnd].contains { store.isCameraReadyConnected($0) }
    }
}

private struct PairingView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CameraStore.self) private var store

    var body: some View {
        List {
            CameraManagementSection()
        }
        .listStyle(.insetGrouped)
        .contentMargins(.top, 8, for: .scrollContent)
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

struct CameraManagementSection: View {
    @Environment(CameraStore.self) private var store

    var body: some View {
        Section("Cameras") {
            if store.pairingCameras.isEmpty {
                ContentUnavailableView(
                    "No Cameras Found",
                    systemImage: "camera.badge.ellipsis",
                    description: Text("Put a camera in pairing mode.")
                )
                .listRowBackground(Color.acrSurface)
            } else {
                ForEach(managedCameras) { camera in
                    PairingCameraRow(camera: camera)
                        .listRowBackground(Color.acrSurface)
                }
            }
        }
    }

    private var managedCameras: [DiscoveredCamera] {
        store.pairingCameras
            .enumerated()
            .sorted { lhs, rhs in
                let lhsRank = managementSortRank(for: lhs.element)
                let rhsRank = managementSortRank(for: rhs.element)
                return lhsRank == rhsRank ? lhs.offset < rhs.offset : lhsRank < rhsRank
            }
            .map(\.element)
    }

    private func managementSortRank(for camera: DiscoveredCamera) -> Int {
        camera.defaultSortRank
    }
}

private struct PairingCameraRow: View {
    @Environment(CameraStore.self) private var store
    @State private var isRenaming = false
    @State private var proposedName = ""
    var camera: DiscoveredCamera
    private let actionContentHeight: CGFloat = 20
    private let cameraInfoLeadingInset: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                CameraProductThumbnail(model: camera.model, brand: camera.brand, size: .small)

                VStack(alignment: .leading, spacing: 3) {
                    Text(camera.displayName)
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
                    pairedCameraActions
                } else if camera.unsupportedReason == nil {
                    Button {
                        store.connect(camera)
                    } label: {
                        actionLabel(isConnecting ? "Connecting…" : "Pair")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.acrAvailable)
                    .controlSize(.small)
                    .fixedSize()
                    .disabled(isConnecting || camera.needsGoProPairingMode)
                }
            }

            if showsInsta360PairingGuide {
                insta360PairingGuide
            } else if showsInitialPairingGuide {
                initialPairingGuide
            }

            if let detail = pairingDetail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.acrMutedText)
                    .padding(.leading, cameraInfoLeadingInset)
            }
        }
        .padding(.vertical, 4)
        .alert("Camera Nickname", isPresented: $isRenaming) {
            TextField("Nickname", text: $proposedName)

            Button("Cancel", role: .cancel) {}
            Button("Save") {
                store.renameCamera(camera, to: proposedName)
            }
        } message: {
            Text("Leave this blank to use the device name.")
        }
    }

    private var connectionStatus: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(camera.displayConnectionStatusColor)
                .frame(width: 6, height: 6)

            Text(camera.displayConnectionLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(camera.displayConnectionStatusColor)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    private var showsInsta360PairingGuide: Bool {
        camera.usesInsta360GPSRemote
            && camera.isSupportedByApp
            && camera.connectionState != .connected
    }

    private var isConnecting: Bool {
        camera.connectionState == .connecting || camera.connectionState == .reconnecting
    }

    private var showsInitialPairingGuide: Bool {
        guard camera.isSupportedByApp, camera.connectionState != .connected else { return false }
        if camera.behavior.kind == .insta360Direct { return true }
        return !camera.isPaired && (camera.brand == .gopro || camera.brand == .dji)
    }

    private var initialPairingGuide: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(initialPairingTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.acrInk)

            Text(initialPairingInstructions)
                .font(.subheadline)
                .foregroundStyle(Color.acrMutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(Color.acrAvailable.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
    }

    private var initialPairingTitle: String {
        if camera.behavior.kind == .insta360Direct {
            return isConnecting ? "Connecting to your Insta360" : "Prepare your Insta360"
        }
        if camera.brand == .gopro {
            return isConnecting ? "Complete Bluetooth pairing" : "Put your GoPro in pairing mode"
        }
        return isConnecting ? "Check your camera" : "Pair with Multicam"
    }

    private var initialPairingInstructions: String {
        if camera.behavior.kind == .insta360Direct {
            if isConnecting {
                return "Keep the camera awake with Bluetooth enabled and normal Video mode selected while Multicam connects."
            }
            let action = camera.isPaired ? "Connect" : "Pair"
            return "Turn on your camera, enable Bluetooth, and select normal Video mode. Then tap \(action) here."
        }
        if camera.brand == .gopro {
            if isConnecting {
                return "If a Bluetooth pairing request appears, tap Pair."
            }
            switch camera.model {
            case .goproHero13Black:
                return "On your GoPro, swipe down, then left and choose Pair Device. Then tap Pair here."
            case .goproHero9Black, .goproHero10Black, .goproHero11Black:
                return "On your GoPro, open Connections → Connect Device → GoPro Quik. Then tap Pair here."
            default:
                return "On your GoPro, start pairing with a phone or app. Then tap Pair here."
            }
        }
        return isConnecting
            ? "Confirm the connection on your camera if prompted."
            : "Tap Pair, then confirm the connection on your camera if prompted."
    }

    private var insta360PairingGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(isConnecting ? "Connecting to GPS Remote" : (camera.isPaired ? "Connect as GPS Remote" : "Pair as GPS Remote"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.acrInk)

                Text(insta360PairingIntroduction)
                    .font(.subheadline)
                    .foregroundStyle(Color.acrMutedText)
            }

            insta360PairingStep("1", title: "Open Settings → Bluetooth Remote")
            insta360PairingStep("2", title: "Choose \(Insta360RemoteProtocol.remoteName)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(Color.acrAvailable.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 4)
    }

    private var insta360PairingIntroduction: String {
        if isConnecting {
            return "If your camera shows “Remote connected,” Multicam is still waiting for controls. Otherwise:"
        }
        guard camera.isPaired else { return "Tap Pair, then on your camera:" }
        return camera.canConnectFromCurrentState
            ? "Tap Connect, then on your camera:"
            : "Turn on your camera, then:"
    }

    private func insta360PairingStep(_ number: String, title: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(number)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.acrInk)
                .frame(width: 22, height: 22)
                .background(Color.acrAvailable.opacity(0.12), in: Circle())

            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.acrInk)
        }
        .accessibilityElement(children: .combine)
    }

    private var canDisconnect: Bool {
        switch camera.connectionState {
        case .connecting, .connected, .reconnecting:
            return true
        case .discovered, .disconnected, .failed, .unsupported:
            return false
        }
    }

    @ViewBuilder
    private var pairedCameraActions: some View {
        HStack(spacing: 6) {
            if isConnecting || camera.canConnectFromCurrentState {
                Button {
                    store.connectAvailableCamera(camera)
                } label: {
                    actionLabel(isConnecting ? "Connecting…" : "Connect")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.acrAvailable)
                .disabled(isConnecting)
            }

            CameraManagementMenu(
                configuration: .init(
                    cameraID: camera.id,
                    displayName: camera.displayName,
                    canDisconnect: canDisconnect
                ),
                onRename: {
                    guard let current = store.cameras.first(where: { $0.id == camera.id }) else { return }
                    proposedName = current.displayName
                    isRenaming = true
                },
                onDisconnect: {
                    guard let current = store.cameras.first(where: { $0.id == camera.id }) else { return }
                    store.disconnect(current)
                },
                onUnpair: {
                    guard let current = store.cameras.first(where: { $0.id == camera.id }) else { return }
                    store.remove(current)
                }
            )
            .equatable()
        }
        .controlSize(.small)
        .fixedSize()
    }

    private func actionLabel(_ title: String) -> some View {
        Text(title)
            .lineLimit(1)
            .frame(height: actionContentHeight)
    }

    private var pairingDetail: String? {
        guard camera.unsupportedReason == nil else { return nil }
        return camera.connectionState.detail
    }
}

// Keep the native menu stable while discovery and telemetry refresh its row.
// Actions resolve the current camera in the store when the user selects them.
private struct CameraManagementMenu: View, Equatable {
    struct Configuration: Equatable {
        let cameraID: UUID
        let displayName: String
        let canDisconnect: Bool
    }

    let configuration: Configuration
    let onRename: () -> Void
    let onDisconnect: () -> Void
    let onUnpair: () -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.configuration == rhs.configuration
    }

    var body: some View {
        Menu {
            Button(action: onRename) {
                Label("Rename Camera", systemImage: "pencil")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.acrInk)
            }
            .tint(Color.acrInk)

            if configuration.canDisconnect {
                Button(action: onDisconnect) {
                    Label("Disconnect Camera", systemImage: "xmark.circle")
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(Color.acrInk)
                }
                .tint(Color.acrInk)
            }

            Button(role: .destructive, action: onUnpair) {
                Label("Unpair Camera", systemImage: "trash")
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(.red)
            }
            .tint(.red)
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.acrMutedText)
                .frame(width: 16, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
        .accessibilityLabel("More options for \(configuration.displayName)")
    }
}

struct DiagnosticsView: View {
    @Environment(CameraStore.self) private var store
    @State private var shareFile: DiagnosticShareFile?
    @State private var isPreparingShare = false
    @State private var shareError: String?

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
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    isPreparingShare = true
                    Task {
                        defer { isPreparingShare = false }
                        do {
                            shareFile = DiagnosticShareFile(url: try await store.exportDiagnostics())
                        } catch {
                            shareError = error.localizedDescription
                        }
                    }
                } label: {
                    Label(isPreparingShare ? "Preparing…" : "Share", systemImage: "square.and.arrow.up")
                }
                .disabled(isPreparingShare)
                .accessibilityLabel("Share saved diagnostics")
            }
        }
        .sheet(item: $shareFile) { file in
            DiagnosticsShareSheet(url: file.url) { shareFile = nil }
        }
        .alert("Could Not Share Diagnostics", isPresented: Binding(
            get: { shareError != nil },
            set: { if !$0 { shareError = nil } }
        )) {
            Button("OK", role: .cancel) { shareError = nil }
        } message: {
            Text(shareError ?? "Please try again.")
        }
    }
}

private struct DiagnosticShareFile: Identifiable {
    let url: URL
    var id: URL { url }
}

struct DiagnosticsShareSheet: UIViewControllerRepresentable {
    let url: URL
    let onComplete: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
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
                            Text(camera.displayName)
                                .font(.subheadline.weight(.semibold))

                            Spacer()

                            Text(camera.displayConnectionLabel)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(camera.displayConnectionStatusColor)
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
                            Text(camera.displayName)
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
            HStack {
                Text("Command Log")
                    .font(.headline)

                Spacer()

                Button("Clear") {
                    store.resetCommandHistory()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.acrToolbarIcon)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .disabled(store.commandHistory.isEmpty && store.commandHistoryStorageError == nil)
                .accessibilityLabel("Clear command log")
            }

            if let error = store.commandHistoryStorageError {
                Text("Command log could not be saved: \(error)")
                    .font(.caption)
                    .foregroundStyle(Color.acrWarning)
            }

            if store.commandHistory.isEmpty {
                Text("No commands logged.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .acrInsetPanel()
            } else {
                ForEach(store.commandHistory.prefix(6)) { result in
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
                            Text(result.timestamp, format: .dateTime.month(.abbreviated).day().hour().minute().second())
                                .font(.caption2)
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
            HStack {
                Text("Bluetooth Log")
                    .font(.headline)

                Spacer()

                Button("Clear") {
                    store.clearDiagnosticLogs()
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Color.acrToolbarIcon)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
                .disabled(store.eventLog.isEmpty)
                .accessibilityLabel("Clear Bluetooth log")
            }

            if let error = store.logStorageError {
                Text("Bluetooth log could not be saved: \(error)")
                    .font(.caption)
                    .foregroundStyle(Color.acrWarning)
            }

            if store.eventLog.isEmpty {
                Text("No Bluetooth messages logged.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .acrInsetPanel()
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(store.eventLog.prefix(30).enumerated()), id: \.offset) { _, line in
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
