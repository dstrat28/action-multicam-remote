import SwiftUI

struct CameraRowView: View {
    @Environment(CameraStore.self) private var store
    @State private var pendingCaptureMode: CaptureMode?
    @State private var captureSettingsTimestampBeforeModeChange: Date?
    var camera: DiscoveredCamera
    var matchesConnectedPeerHeight: Bool = false
    var onShowDetails: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: isReadyConnected ? 6 : 5) {
                identityRow
                connectionRow

                diagnosticContent
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard isReadyConnected else { return }
                onShowDetails()
            }
            .padding(.horizontal, 16)
            .padding(.top, isReadyConnected ? 10 : 9)
            .padding(.bottom, isReadyConnected ? 10 : 13)

            if showsCaptureBar {
                Divider()
                    .overlay(Color.acrLine.opacity(0.58))
                    .padding(.horizontal, 16)

                HStack(spacing: 10) {
                    captureModeAndSettings

                    Spacer(minLength: 4)

                    if camera.isPaired, camera.supportsBatchRecord {
                        CameraRecordButton(camera: camera)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
        }
        .frame(
            minHeight: matchesConnectedPeerHeight ? 168 : nil,
            alignment: .top
        )
        .clipShape(RoundedRectangle(cornerRadius: ACRDesign.cardCornerRadius, style: .continuous))
        .acrCard(fill: Color.acrSurface, stroke: rowStroke, interactive: isReadyConnected)
        .onChange(of: camera.currentMode) { _, confirmedMode in
            if confirmedMode == pendingCaptureMode,
               hasReceivedFreshCaptureSettings {
                setPendingCaptureMode(nil)
            }
        }
        .onChange(of: camera.telemetry?.captureSettingsUpdatedAt) { _, _ in
            if camera.currentMode == pendingCaptureMode,
               hasReceivedFreshCaptureSettings {
                setPendingCaptureMode(nil)
            }
        }
        .onChange(of: camera.connectionState) { _, connectionState in
            if connectionState != .connected {
                setPendingCaptureMode(nil)
            }
        }
        .task(id: pendingCaptureMode) {
            guard pendingCaptureMode != nil else { return }
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            setPendingCaptureMode(nil)
        }
    }

    private var selectionColor: Color {
        if camera.isSelected {
            return .acrAvailable
        }
        return camera.canSelectForBatch ? .secondary : Color.secondary.opacity(0.35)
    }

    private var rowAccent: Color {
        if isConnectInProgress {
            return .acrWarning
        }
        return camera.displayConnectionStatusColor
    }

    private var rowStroke: Color {
        if camera.recordingState == .recording {
            return Color.acrRecord.opacity(0.48)
        }
        if camera.isSelected {
            return Color.acrAvailable.opacity(0.30)
        }
        return Color.acrLine.opacity(0.85)
    }

    @ViewBuilder
    private var selectionButton: some View {
        Button {
            store.toggleSelection(for: camera)
        } label: {
            Image(systemName: camera.isSelected ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(selectionColor)
                .frame(width: 44, height: 44, alignment: .trailing)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!camera.canSelectForBatch && !camera.isSelected)
        .accessibilityLabel(camera.isSelected ? "Deselect \(camera.displayName)" : "Select \(camera.displayName)")
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 6) {
            CameraProductThumbnail(model: camera.model, brand: camera.brand, size: .card)

            VStack(alignment: .leading, spacing: 2) {
                Text(camera.displayName)
                    .font(.headline.weight(.bold))
                    .fontDesign(.rounded)
                    .foregroundStyle(Color.acrInk)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)

                if reservesCaptureSettingsSummarySpace {
                    Text(" ")
                        .font(.footnote)
                        .accessibilityHidden(true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .leading) {
                            if pendingCaptureMode != nil {
                                HStack(spacing: 5) {
                                    ProgressView()
                                        .controlSize(.mini)
                                        .tint(Color.acrAvailable)

                                    Text("Updating…")
                                        .font(.footnote)
                                        .foregroundStyle(Color.acrMutedText)
                                }
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel("Updating capture settings")
                            } else if !captureSettingsSummaryItems.isEmpty {
                                captureSettingsSummaryView
                            }
                        }
                }
            }

            Spacer(minLength: 4)

            selectionButton
        }
    }

    private var connectionRow: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionIndicatorColor)
                .frame(width: 8, height: 8)

            Text(connectionText)
                .font(.subheadline)
                .foregroundStyle(Color.acrMutedText)
                .lineLimit(1)

            Spacer(minLength: 6)

            batteryStatus

            if camera.canConnectFromCurrentState {
                Button {
                    store.connectAvailableCamera(camera)
                } label: {
                    Text("Connect")
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 64, minHeight: 24)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.acrAvailable)
                .controlSize(.mini)
                .accessibilityHint("Connects to this available camera")
            } else if isReadyConnected {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.acrMutedText.opacity(0.7))
                    .frame(width: 18, height: 30)
            }
        }
        .padding(.leading, 6)
    }

    private var connectionIndicatorColor: Color {
        if isConnectInProgress {
            return .acrWarning
        }
        return camera.displayConnectionLabel == CameraConnectionState.disconnected.label
            ? Color.secondary.opacity(0.55)
            : rowAccent
    }

    @ViewBuilder
    private var diagnosticContent: some View {
        if let unsupportedReason = camera.unsupportedReason {
            Text(unsupportedReason)
                .font(.caption)
                .foregroundStyle(Color.acrMutedText)
                .lineLimit(2)
        }

    }

    private var connectionText: String {
        if camera.recordingState == .recording {
            return "Recording"
        }
        if isConnectInProgress {
            return "Connecting"
        }
        return camera.displayConnectionLabel
    }

    @ViewBuilder
    private var captureModeAndSettings: some View {
        VStack(alignment: .leading, spacing: 0) {
            if camera.availableCaptureModes.count > 1 {
                captureModeLabel(showsChevron: true)
                    .overlay {
                        Menu {
                            ForEach(camera.availableCaptureModes) { mode in
                                Button {
                                    guard mode != displayedCaptureMode else { return }
                                    setPendingCaptureMode(mode)
                                    store.switchMode(mode, for: camera)
                                } label: {
                                    if mode == displayedCaptureMode {
                                        Label(mode.displayName(for: camera.model), systemImage: "checkmark")
                                    } else {
                                        Text(mode.displayName(for: camera.model))
                                    }
                                }
                            }
                        } label: {
                            Text("Capture mode for \(camera.displayName)")
                                .foregroundStyle(.clear)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Capsule())
                                .accessibilityLabel("Capture mode for \(camera.displayName)")
                                .accessibilityHint("Changes the capture mode")
                        }
                        .buttonStyle(.plain)
                    }
                    .disabled(!camera.canSwitchCaptureMode)
            } else if let currentMode = camera.currentMode {
                captureModeLabel(for: currentMode, showsChevron: false)
            }
        }
        .frame(width: captureControlWidth, alignment: .leading)
        .layoutPriority(1)
    }

    private func captureModeLabel(
        for mode: CaptureMode? = nil,
        showsChevron: Bool
    ) -> some View {
        let resolvedMode = mode ?? displayedCaptureMode
        return HStack(spacing: 6) {
            Image(systemName: resolvedMode?.cameraCardSystemImage ?? "camera.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.acrAvailable)
                .accessibilityHidden(showsChevron)

            Text(resolvedMode?.displayName(for: camera.model) ?? "Choose Mode")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.acrInk)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .allowsTightening(true)
                .accessibilityHidden(showsChevron)

            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.acrMutedText)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, showsChevron ? 10 : 0)
        .frame(height: 30)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            if showsChevron {
                Capsule()
                    .fill(Color.acrInsetSurface.opacity(0.92))
            }
        }
        .overlay {
            if showsChevron {
                Capsule()
                    .stroke(Color.acrLine.opacity(0.72), lineWidth: 1)
            }
        }
        .contentShape(Capsule())
    }

    private var captureControlWidth: CGFloat { 174 }

    private var displayedCaptureMode: CaptureMode? {
        pendingCaptureMode ?? camera.currentMode
    }

    private func setPendingCaptureMode(_ mode: CaptureMode?) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            captureSettingsTimestampBeforeModeChange = mode == nil
                ? nil
                : camera.telemetry?.captureSettingsUpdatedAt
            pendingCaptureMode = mode
        }
    }

    private var hasReceivedFreshCaptureSettings: Bool {
        guard let captureSettingsUpdatedAt = camera.telemetry?.captureSettingsUpdatedAt else {
            return false
        }
        return captureSettingsUpdatedAt != captureSettingsTimestampBeforeModeChange
    }

    private struct CaptureSummaryItem {
        let value: String
        let systemImage: String?
        let accessibilityText: String

        init(
            _ value: String,
            systemImage: String? = nil,
            accessibilityText: String? = nil
        ) {
            self.value = value
            self.systemImage = systemImage
            self.accessibilityText = accessibilityText ?? value
        }
    }

    private var captureSettingsSummaryView: some View {
        HStack(spacing: 5) {
            ForEach(Array(captureSettingsSummaryItems.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Text("·")
                        .accessibilityHidden(true)
                }

                HStack(spacing: 3) {
                    if let systemImage = item.systemImage {
                        Image(systemName: systemImage)
                            .font(.caption2.weight(.semibold))
                            .accessibilityHidden(true)
                    }

                    Text(item.value)
                }
            }
        }
        .font(.footnote)
        .foregroundStyle(Color.acrMutedText)
        .lineLimit(1)
        .minimumScaleFactor(0.78)
        .allowsTightening(true)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            captureSettingsSummaryItems
                .map(\.accessibilityText)
                .joined(separator: ", ")
        )
    }

    private var captureSettingsSummaryItems: [CaptureSummaryItem] {
        guard isReadyConnected, let telemetry else { return [] }

        let settings: [CaptureSummaryItem?]
        switch camera.currentMode {
        case .photo:
            settings = [
                telemetry.videoResolution.map { CaptureSummaryItem($0) },
                telemetry.photoAspectRatio.map { CaptureSummaryItem($0) },
                telemetry.photoBurstCount.flatMap {
                    $0 > 1 ? CaptureSummaryItem("\($0) photos") : nil
                },
                telemetry.photoCountdownMilliseconds.flatMap {
                    $0 > 0
                        ? CaptureSummaryItem(
                            CameraDetailFormat.milliseconds($0),
                            systemImage: "timer",
                            accessibilityText: "\(CameraDetailFormat.milliseconds($0)) timer"
                        )
                        : nil
                },
            ]
        case .slowMotion:
            settings = [
                telemetry.videoResolution.map { CaptureSummaryItem($0) },
                telemetry.frameRate.map { CaptureSummaryItem($0) },
                slowMotionRate(from: telemetry.modeParameters).map { CaptureSummaryItem($0) },
            ]
        case .timelapse:
            settings = [
                telemetry.videoResolution.map { CaptureSummaryItem($0) },
                telemetry.timelapseIntervalTenths.map {
                    let value = CameraDetailFormat.timelapseInterval(tenths: $0, isHyperlapse: false)
                    return CaptureSummaryItem(
                        value,
                        systemImage: "repeat",
                        accessibilityText: "Every \(value)"
                    )
                },
                telemetry.timelapseDurationSeconds.flatMap {
                    guard $0 > 0 else { return nil }
                    let value = CameraDetailFormat.duration(seconds: UInt32($0))
                    return CaptureSummaryItem(
                        value,
                        systemImage: "clock",
                        accessibilityText: "\(value) duration"
                    )
                },
            ]
        case .hyperlapse:
            settings = [
                telemetry.videoResolution.map { CaptureSummaryItem($0) },
                telemetry.timelapseIntervalTenths.map {
                    let value = CameraDetailFormat.timelapseInterval(tenths: $0, isHyperlapse: true)
                    return CaptureSummaryItem(
                        value,
                        systemImage: "speedometer",
                        accessibilityText: "\(value) rate"
                    )
                },
                telemetry.timelapseDurationSeconds.flatMap {
                    guard $0 > 0 else { return nil }
                    let value = CameraDetailFormat.duration(seconds: UInt32($0))
                    return CaptureSummaryItem(
                        value,
                        systemImage: "clock",
                        accessibilityText: "\(value) duration"
                    )
                },
            ]
        case .video, .superNight:
            settings = [
                telemetry.videoResolution.map { CaptureSummaryItem($0) },
                telemetry.frameRate.map { CaptureSummaryItem($0) },
                (telemetry.lens ?? telemetry.framing).map { CaptureSummaryItem($0) },
            ]
        case .selfie, .boostVideo, .vortex, .panoramicSuperNight, .singleLensSuperNight:
            settings = [
                telemetry.videoResolution.map { CaptureSummaryItem($0) },
                telemetry.frameRate.map { CaptureSummaryItem($0) },
                (telemetry.lens ?? telemetry.framing).map { CaptureSummaryItem($0) },
            ]
        case nil:
            settings = [
                telemetry.videoResolution.map { CaptureSummaryItem($0) },
                telemetry.frameRate.map { CaptureSummaryItem($0) },
                (telemetry.lens ?? telemetry.framing).map { CaptureSummaryItem($0) },
            ]
        }

        var seen = Set<String>()
        return settings
            .compactMap { $0 }
            .filter { !$0.value.isEmpty }
            .filter { seen.insert($0.value.lowercased()).inserted }
            .prefix(3)
            .map { $0 }
    }

    private var reservesCaptureSettingsSummarySpace: Bool {
        isReadyConnected
            && (pendingCaptureMode != nil
                || camera.availableCaptureModes.count > 1
                || !captureSettingsSummaryItems.isEmpty)
    }

    private func slowMotionRate(from modeParameters: String?) -> String? {
        guard let token = modeParameters?
            .split(whereSeparator: \.isWhitespace)
            .last(where: { part in
                let uppercased = part.uppercased()
                return uppercased.hasSuffix("X")
                    && uppercased.dropLast().allSatisfy(\.isNumber)
            }) else {
            return nil
        }
        return "\(token.dropLast())×"
    }

    private var showsCaptureBar: Bool {
        isReadyConnected
            && (camera.currentMode != nil
                || !captureSettingsSummaryItems.isEmpty
                || camera.availableCaptureModes.count > 1
                || (camera.isPaired && camera.supportsBatchRecord))
    }

    @ViewBuilder
    private var batteryStatus: some View {
        if let telemetry {
            if let percent = telemetry.batteryPercent {
                Label {
                    Text("\(percent)%")
                        .foregroundStyle(Color.acrInk)
                } icon: {
                    batteryIconView
                }
                    .accessibilityLabel(batteryAccessibilityLabel("Camera battery \(percent) percent"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            } else if let bars = telemetry.batteryBars {
                Label {
                    Text("\(bars)/4")
                        .foregroundStyle(Color.acrInk)
                } icon: {
                    batteryIconView
                }
                    .accessibilityLabel(batteryAccessibilityLabel("Camera battery \(bars) of 4 bars"))
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
        }
    }

    private var batteryIcon: String {
        if telemetry?.isExternalPowerConnected == true {
            return "battery.100percent.bolt"
        }

        guard let percent = telemetry?.batteryPercent else { return "battery.50percent" }
        switch percent {
        case ...12:
            return "battery.0percent"
        case ...37:
            return "battery.25percent"
        case ...62:
            return "battery.50percent"
        case ...87:
            return "battery.75percent"
        default:
            return "battery.100percent"
        }
    }

    @ViewBuilder
    private var batteryIconView: some View {
        if telemetry?.isExternalPowerConnected == true {
            Image(systemName: batteryIcon)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black, Color.green)
        } else {
            Image(systemName: batteryIcon)
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(Color.acrInk)
        }
    }

    private func batteryAccessibilityLabel(_ batteryLabel: String) -> String {
        telemetry?.isExternalPowerConnected == true
            ? "\(batteryLabel), external power connected"
            : batteryLabel
    }

    private var telemetry: CameraTelemetry? {
        guard isReadyConnected else { return nil }
        return camera.telemetry
    }

    private var isReadyConnected: Bool {
        store.isCameraReadyConnected(camera)
    }

    private var isConnectInProgress: Bool {
        store.isCameraConnectInProgress(camera)
    }

}

struct CameraProductThumbnail: View {
    enum Size {
        case small
        case card
        case detail

        var dimensions: CGSize {
            switch self {
            case .small:
                CGSize(width: 38, height: 32)
            case .card:
                CGSize(width: 46, height: 42)
            case .detail:
                CGSize(width: 70, height: 58)
            }
        }
    }

    var model: CameraModel
    var brand: CameraBrand
    var size: Size

    var body: some View {
        Group {
            if let assetName {
                Image(assetName)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(assetScale)
                    .offset(x: imageOffsetX)
            } else {
                Image(systemName: "camera")
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: fallbackIconSize, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size.dimensions.width, height: size.dimensions.height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var assetScale: CGFloat {
        switch model {
        case .djiOsmoAction5Pro:
            0.9
        case .djiOsmoAction6,
             .djiOsmoNano,
             .djiOsmoAction4,
             .djiOsmoAction3,
             .djiOsmoAction:
            1.22
        case .djiAction2:
            1.2
        case .goproHero13Black:
            1.02
        case .goproLitHero,
             .goproHero,
             .goproHero12Black,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black,
             .goproHero8Black:
            1.22
        case .goproHero11BlackMini:
            1.15
        case .goproMax2, .goproMax:
            1.05
        case .djiOsmo360:
            1.05
        case .insta360AcePro2:
            0.95
        case .insta360AcePro,
             .insta360Ace,
             .insta360OneRS,
             .insta360GoUltra,
             .insta360Go3S,
             .insta360Go3:
            1.1
        case .insta360X5,
             .insta360X4Air,
             .insta360X4,
             .insta360X3:
            1.05
        case .djiOsmoPocket3,
             .unknown:
            1
        }
    }

    private var imageOffsetX: CGFloat {
        switch model {
        case .djiOsmoAction6, .djiOsmoNano:
            -2
        case .goproHero13Black:
            -1
        case .goproLitHero,
             .goproMax2,
             .goproHero,
             .goproHero12Black,
             .goproHero11BlackMini,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black,
             .goproMax,
             .goproHero8Black,
             .djiOsmoAction5Pro,
             .djiOsmo360,
             .djiOsmoAction4,
             .djiOsmoAction3,
             .djiAction2,
             .djiOsmoAction,
             .djiOsmoPocket3,
             .insta360AcePro2,
             .insta360AcePro,
             .insta360Ace,
             .insta360X5,
             .insta360X4Air,
             .insta360X4,
             .insta360X3,
             .insta360OneRS,
             .insta360GoUltra,
             .insta360Go3S,
             .insta360Go3,
             .unknown:
            0
        }
    }

    private var assetName: String? {
        switch model {
        case .djiOsmoAction5Pro:
            "CameraOsmoAction5Pro"
        case .djiOsmoAction6:
            "CameraOsmoAction6"
        case .djiOsmoNano:
            "CameraOsmoNano"
        case .djiOsmoAction4, .djiOsmoAction3, .djiOsmoAction:
            "CameraOsmoActionClassic"
        case .djiAction2:
            "CameraDJIAction2"
        case .djiOsmo360:
            "CameraOsmo360"
        case .goproHero13Black:
            "CameraGoProHero13"
        case .goproLitHero:
            "CameraGoProLitHero"
        case .goproMax2:
            "CameraGoProMax2"
        case .goproHero:
            "CameraGoProHero"
        case .goproHero12Black,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black:
            "CameraGoProHeroBlackClassic"
        case .goproHero11BlackMini:
            "CameraGoProHero11Mini"
        case .goproMax:
            "CameraGoProMax"
        case .goproHero8Black:
            "CameraGoProHero8"
        case .insta360AcePro2:
            "CameraInsta360AcePro2"
        case .insta360AcePro:
            "CameraInsta360AcePro"
        case .insta360Ace:
            "CameraInsta360Ace"
        case .insta360X5:
            "CameraInsta360X5"
        case .insta360X4Air:
            "CameraInsta360X4Air"
        case .insta360X4:
            "CameraInsta360X4"
        case .insta360X3:
            "CameraInsta360X3"
        case .insta360OneRS:
            "CameraInsta360OneRS"
        case .insta360GoUltra:
            "CameraInsta360GoUltra"
        case .insta360Go3S:
            "CameraInsta360Go3S"
        case .insta360Go3:
            "CameraInsta360Go3"
        case .djiOsmoPocket3,
             .unknown:
            nil
        }
    }

    private var fallbackIconSize: CGFloat {
        switch size {
        case .small:
            18
        case .card:
            20
        case .detail:
            28
        }
    }
}

struct CameraDetailView: View {
    @Environment(CameraStore.self) private var store
    var cameraID: UUID

    var body: some View {
        if let camera = store.cameras.first(where: { $0.id == cameraID }) {
            CameraDetailContent(camera: camera)
        } else {
            ContentUnavailableView("Camera unavailable", systemImage: "camera.badge.ellipsis")
                .navigationTitle("Camera")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct CameraDetailContent: View {
    @Environment(CameraStore.self) private var store

    var camera: DiscoveredCamera
    @State private var isRenaming = false
    @State private var proposedName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CameraDetailHeader(camera: camera)

                CameraCaptureSettingsSection(camera: camera)

                CameraTelemetryDetailSection(telemetry: camera.telemetry)

                if FeatureAvailability.djiPhoneGPS, camera.supportsDJIPhoneGPS {
                    DJIPhoneGPSSection(camera: camera)
                }

                CameraStatusAndSignalDetailSection(camera: camera)
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.acrAppBackground)
        .navigationTitle("Camera Info")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    proposedName = camera.displayName
                    isRenaming = true
                } label: {
                    Image(systemName: "pencil")
                }
                .accessibilityLabel("Edit camera name")
            }
        }
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
}

private struct DJIPhoneGPSSection: View {
    @Environment(CameraStore.self) private var store

    var camera: DiscoveredCamera

    var body: some View {
        CameraDetailSection(title: "GPS", systemImage: "location.fill") {
            Toggle(
                "Use Phone GPS",
                isOn: Binding(
                    get: { store.isDJIPhoneGPSEnabled(for: camera) },
                    set: { store.setDJIPhoneGPSEnabled($0, for: camera) }
                )
            )
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.acrInk)
            .tint(Color.acrAccent)

            Text("Sends this iPhone’s GPS data to the camera for video recordings.")
                .font(.caption)
                .foregroundStyle(Color.acrMutedText)
        }
    }
}

private struct CameraDetailHeader: View {
    var camera: DiscoveredCamera

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            CameraProductThumbnail(model: camera.model, brand: camera.brand, size: .detail)

            VStack(alignment: .leading, spacing: 5) {
                Text(camera.displayName)
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.acrInk)
                    .lineLimit(2)

                Text("\(camera.brand.rawValue) · \(camera.model.rawValue)")
                    .font(.subheadline)
                    .foregroundStyle(Color.acrMutedText)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)
        }
        .padding(.leading, 10)
        .padding(.trailing, 14)
        .padding(.vertical, 16)
        .acrCard(fill: Color.acrSurface, stroke: Color.acrLine.opacity(0.85))
    }
}

private struct CameraDetailSection<Content: View>: View {
    var title: String
    var systemImage: String
    var content: () -> Content

    init(title: String, systemImage: String, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.acrInk)

            VStack(alignment: .leading, spacing: 9) {
                content()
            }
        }
        .padding(14)
        .acrCard(fill: Color.acrSurface, stroke: Color.acrLine.opacity(0.85))
    }
}

private struct CameraInfoRow: View {
    var label: String
    var value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(Color.acrMutedText)

            Spacer(minLength: 10)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.acrInk)
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct CameraCaptureSettingsSection: View {
    var camera: DiscoveredCamera

    @ViewBuilder
    var body: some View {
        CameraDetailSection(title: "Capture Settings", systemImage: "camera.metering.center.weighted") {
            CameraInfoRow(label: "Camera Mode", value: cameraModeName)
            if let videoResolution = camera.telemetry?.videoResolution {
                CameraInfoRow(label: "Resolution", value: videoResolution)
            }
            if showsFrameRate, let frameRate = camera.telemetry?.frameRate {
                CameraInfoRow(label: "Frame Rate", value: frameRate)
            }
            if let framing = camera.telemetry?.framing,
               camera.currentMode != .photo || camera.telemetry?.photoAspectRatio == nil {
                CameraInfoRow(label: "Framing", value: framing)
            }
            if let lens = camera.telemetry?.lens {
                CameraInfoRow(label: "Lens", value: lens)
            }
            if showsStabilization, let stabilization = camera.telemetry?.hypersmooth {
                CameraInfoRow(label: "Stabilization", value: stabilization)
            }
            if let photoAspectRatio = camera.telemetry?.photoAspectRatio,
               camera.currentMode == .photo {
                CameraInfoRow(label: "Aspect Ratio", value: photoAspectRatio)
            }
            if let photoBurstCount = camera.telemetry?.photoBurstCount,
               camera.currentMode == .photo {
                CameraInfoRow(label: "Burst", value: "\(photoBurstCount) photos")
            }
            if let photoCountdownMilliseconds = camera.telemetry?.photoCountdownMilliseconds,
               photoCountdownMilliseconds > 0,
               camera.currentMode == .photo {
                CameraInfoRow(
                    label: "Photo Timer",
                    value: CameraDetailFormat.milliseconds(photoCountdownMilliseconds)
                )
            }
            if let timelapseIntervalTenths = camera.telemetry?.timelapseIntervalTenths,
               camera.currentMode == .timelapse || camera.currentMode == .hyperlapse {
                CameraInfoRow(
                    label: camera.currentMode == .hyperlapse ? "Hyperlapse Rate" : "Interval",
                    value: CameraDetailFormat.timelapseInterval(
                        tenths: timelapseIntervalTenths,
                        isHyperlapse: camera.currentMode == .hyperlapse
                    )
                )
            }
            if let timelapseDurationSeconds = camera.telemetry?.timelapseDurationSeconds,
               timelapseDurationSeconds > 0,
               camera.currentMode == .timelapse || camera.currentMode == .hyperlapse {
                CameraInfoRow(
                    label: "Duration",
                    value: CameraDetailFormat.duration(seconds: UInt32(timelapseDurationSeconds))
                )
            }
            if let loopRecordingSeconds = camera.telemetry?.loopRecordingSeconds,
               loopRecordingSeconds > 0,
               camera.currentMode == .video {
                CameraInfoRow(
                    label: "Loop Recording",
                    value: CameraDetailFormat.loopRecording(seconds: loopRecordingSeconds)
                )
            }
        }
    }

    private var cameraModeName: String {
        if let currentMode = camera.currentMode {
            return currentMode.displayName(for: camera.model)
        }

        let reportedMode = camera.telemetry?.modeName?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let reportedMode, !reportedMode.isEmpty {
            let lowercaseMode = reportedMode.lowercased()
            return lowercaseMode.prefix(1).uppercased() + String(lowercaseMode.dropFirst())
        }
        return "Unknown"
    }

    private var showsFrameRate: Bool {
        switch camera.currentMode {
        case .photo, .timelapse, .hyperlapse:
            false
        default:
            true
        }
    }

    private var showsStabilization: Bool {
        switch camera.currentMode {
        case .photo, .timelapse, .hyperlapse:
            false
        default:
            true
        }
    }
}

private struct CameraStatusAndSignalDetailSection: View {
    var camera: DiscoveredCamera

    var body: some View {
        CameraDetailSection(title: "Status & Signal", systemImage: "waveform.path.ecg") {
            CameraInfoRow(label: "Device Name", value: camera.name)

            if let telemetry = camera.telemetry {
                if let cameraStatus = telemetry.cameraStatus {
                    CameraInfoRow(label: "Camera Status", value: cameraStatus)
                }
                if let recordingElapsedSeconds = telemetry.recordingElapsedSeconds,
                   recordingElapsedSeconds > 0,
                   camera.recordingState == .recording {
                    CameraInfoRow(
                        label: "Recording Time",
                        value: CameraDetailFormat.elapsed(seconds: recordingElapsedSeconds)
                    )
                }
                if let countdownRemainingSeconds = telemetry.countdownRemainingSeconds,
                   countdownRemainingSeconds > 0 {
                    CameraInfoRow(label: "Countdown", value: "\(countdownRemainingSeconds)s")
                }
                if let temperatureStatus = telemetry.temperatureStatus {
                    CameraInfoRow(label: "Temperature", value: temperatureStatus)
                }
                if let userMode = telemetry.userMode, userMode != "General" {
                    CameraInfoRow(label: "Custom Mode", value: userMode)
                }
            }

            CameraInfoRow(label: "Signal", value: camera.signalLabel)
            CameraInfoRow(label: "Signal Level", value: "\(camera.rssi) dBm")
        }
    }
}

private struct CameraTelemetryDetailSection: View {
    var telemetry: CameraTelemetry?

    @ViewBuilder
    var body: some View {
        if let telemetry, hasMediaOrBatteryInfo(telemetry) {
            CameraDetailSection(title: "Media & Battery", systemImage: "externaldrive.fill") {
                if let batteryPercent = telemetry.batteryPercent {
                    CameraInfoRow(label: "Camera Battery", value: "\(batteryPercent)%")
                } else if let batteryBars = telemetry.batteryBars {
                    CameraInfoRow(label: "Camera Battery", value: "\(batteryBars) of 4 bars")
                }

                if let externalPower = telemetry.isExternalPowerConnected {
                    CameraInfoRow(
                        label: "Power Source",
                        value: externalPower ? "External Power" : "Battery"
                    )
                }

                if let storageFreeMB = telemetry.storageFreeMB, let storageTotalMB = telemetry.storageTotalMB {
                    CameraInfoRow(
                        label: "Storage",
                        value: "\(CameraDetailFormat.storage(mb: storageFreeMB)) / \(CameraDetailFormat.storage(mb: storageTotalMB))"
                    )
                } else if let storageFreeMB = telemetry.storageFreeMB {
                    CameraInfoRow(label: "Available Storage", value: CameraDetailFormat.storage(mb: storageFreeMB))
                } else if let sdCardCapacityMB = telemetry.sdCardCapacityMB {
                    CameraInfoRow(label: "SD Card", value: CameraDetailFormat.storage(mb: sdCardCapacityMB))
                } else if let storageState = telemetry.storageState {
                    CameraInfoRow(label: "Storage", value: storageState)
                }

                if let remainingVideoSeconds = telemetry.remainingVideoSeconds {
                    CameraInfoRow(
                        label: "Video Left",
                        value: CameraDetailFormat.duration(seconds: remainingVideoSeconds)
                    )
                }

                if let remainingPhotos = telemetry.remainingPhotos {
                    CameraInfoRow(label: "Photos Left", value: "\(remainingPhotos)")
                }
            }
        }
    }

    private func hasMediaOrBatteryInfo(_ telemetry: CameraTelemetry) -> Bool {
        telemetry.batteryPercent != nil
            || telemetry.batteryBars != nil
            || telemetry.isExternalPowerConnected != nil
            || telemetry.storageState != nil
            || telemetry.remainingVideoSeconds != nil
            || telemetry.remainingPhotos != nil
            || telemetry.sdCardCapacityMB != nil
            || telemetry.storageFreeMB != nil
            || telemetry.storageTotalMB != nil
    }
}

private struct CameraRecordButton: View {
    @Environment(CameraStore.self) private var store
    var camera: DiscoveredCamera

    var body: some View {
        ACRPrimaryActionButton(
            title: title,
            systemImage: systemImage,
            tint: .acrRecord,
            isEnabled: camera.primaryRecordCommand != nil,
            isLoading: isConnectInProgress
                || camera.recordingState == .starting
                || (camera.isInPhotoMode && camera.recordingState == .recording),
            appearance: camera.recordingState == .recording && !camera.isInPhotoMode
                ? .filled
                : .outlined,
            action: performRecordAction
        )
    }

    private var title: String {
        if isConnectInProgress {
            return "Connecting"
        }
        return camera.primaryRecordTitle
    }

    private var systemImage: String {
        if camera.recordingState == .recording, !camera.isInPhotoMode {
            return "stop.fill"
        }
        return camera.isInPhotoMode ? "camera.fill" : "record.circle.fill"
    }

    private func performRecordAction() {
        switch camera.primaryRecordCommand {
        case .startRecording:
            store.startRecording(camera)
        case .capturePhoto:
            store.startRecording(camera)
        case .stopRecording:
            store.stopRecording(camera)
        case .addHighlight, .toggleRecording, .setMode, .cycleMode, .applySetting, .keepAlive, nil:
            break
        }
    }

    private var isConnectInProgress: Bool {
        store.isCameraConnectInProgress(camera)
    }

}

private enum CameraDetailFormat {
    static func duration(seconds: UInt32) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60

        if hours > 0, minutes > 0 {
            return "\(hours)h \(minutes)m"
        }

        if hours > 0 {
            return "\(hours)h"
        }

        return "\(max(1, minutes))m"
    }

    static func storage(mb: UInt32) -> String {
        if mb >= 1024 {
            let gb = Double(mb) / 1024.0
            return gb >= 100 ? "\(Int(gb.rounded())) GB" : String(format: "%.1f GB", gb)
        }

        return "\(mb) MB"
    }

    static func elapsed(seconds: UInt32) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, remainingSeconds)
        }
        return String(format: "%d:%02d", minutes, remainingSeconds)
    }

    static func milliseconds(_ value: UInt32) -> String {
        let seconds = Double(value) / 1_000
        return seconds.rounded() == seconds
            ? "\(Int(seconds))s"
            : String(format: "%.1fs", seconds)
    }

    static func timelapseInterval(tenths: UInt16, isHyperlapse: Bool) -> String {
        if isHyperlapse {
            return tenths == 0 ? "Auto" : "\(tenths)×"
        }

        let seconds = Double(tenths) / 10
        if seconds >= 60, seconds.rounded() == seconds {
            return duration(seconds: UInt32(seconds))
        }
        return seconds.rounded() == seconds
            ? "\(Int(seconds))s"
            : String(format: "%.1fs", seconds)
    }

    static func loopRecording(seconds: UInt16) -> String {
        if seconds == .max {
            return "Maximum"
        }
        return duration(seconds: UInt32(seconds))
    }
}

private extension CaptureMode {
    var cameraCardSystemImage: String {
        switch self {
        case .video:
            "video.fill"
        case .photo:
            "camera.fill"
        case .slowMotion:
            "slowmo"
        case .timelapse:
            "timer"
        case .hyperlapse:
            "forward.fill"
        case .superNight, .panoramicSuperNight:
            "moon.stars.fill"
        case .selfie:
            "person.crop.circle"
        case .boostVideo:
            "bolt.fill"
        case .vortex:
            "hurricane"
        case .singleLensSuperNight:
            "moon.fill"
        }
    }
}
