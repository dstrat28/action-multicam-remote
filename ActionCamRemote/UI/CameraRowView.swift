import SwiftUI

struct CameraRowView: View {
    @Environment(CameraStore.self) private var store
    var camera: DiscoveredCamera
    var isShowingDiagnostics: Bool
    var matchesConnectedPeerHeight: Bool = false
    var onShowDetails: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: camera.isConnected ? 9 : 6) {
                identityRow
                connectionRow

                diagnosticContent
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard camera.isConnected else { return }
                onShowDetails()
            }
            .padding(.horizontal, 14)
            .padding(.top, camera.isConnected ? 14 : 8)
            .padding(.bottom, 14)

            if camera.isConnected, showsCaptureBar {
                Divider()
                    .padding(.horizontal, 14)

                HStack(spacing: 10) {
                    if let captureSummary {
                        Text(captureSummary)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.acrInk)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }

                    Spacer(minLength: 4)

                    if camera.isPaired, camera.supportsBatchRecord {
                        CameraRecordButton(camera: camera)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        }
        .frame(
            minHeight: matchesConnectedPeerHeight ? 168 : nil,
            alignment: .top
        )
        .background(Color.acrSurface, in: RoundedRectangle(cornerRadius: ACRDesign.cardCornerRadius, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: ACRDesign.cardCornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ACRDesign.cardCornerRadius, style: .continuous)
                .stroke(rowStroke, lineWidth: 1)
        }
    }

    private var selectionColor: Color {
        if camera.isSelected {
            return .acrAvailable
        }
        return camera.canSelectForBatch ? .secondary : Color.secondary.opacity(0.35)
    }

    private var rowAccent: Color {
        return camera.connectionState.statusColor
    }

    private var rowStroke: Color {
        if camera.recordingState == .recording {
            return Color.acrRecord.opacity(0.55)
        }
        if camera.isSelected {
            return Color.acrAvailable.opacity(0.42)
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
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!camera.canSelectForBatch && !camera.isSelected)
        .accessibilityLabel(camera.isSelected ? "Deselect \(camera.name)" : "Select \(camera.name)")
    }

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 4) {
            CameraProductThumbnail(model: camera.model, brand: camera.brand, size: .card)

            Text(camera.name)
                .font(.headline.weight(.bold))
                .foregroundStyle(Color.acrInk)
                .lineLimit(2)
                .minimumScaleFactor(0.82)

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

            if camera.isConnected {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.acrMutedText.opacity(0.7))
                    .frame(width: 18, height: 30)
            }
        }
        .padding(.leading, 6)
    }

    private var connectionIndicatorColor: Color {
        connectionText == CameraConnectionState.disconnected.label
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

        #if DEBUG
        if isShowingDiagnostics {
            if camera.unsupportedReason == nil,
               let detail = camera.connectionState.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.acrMutedText)
                    .lineLimit(2)
            }

            if let diagnosticDetail = store.cameraDiagnosticDetail(for: camera),
               shouldShowDiagnosticDetail {
                Text(diagnosticDetail)
                    .font(.caption)
                    .foregroundStyle(Color.acrMutedText)
                    .lineLimit(2)
            }
        }
        #endif
    }

    private var connectionText: String {
        if camera.recordingState == .recording {
            return "Recording"
        }
        return camera.displayConnectionLabel
    }

    private var captureSummary: String? {
        guard camera.isConnected else { return nil }
        guard let telemetry else { return camera.currentMode?.rawValue }

        let settings: [String] = [telemetry.videoResolution, telemetry.frameRate, telemetry.framing]
            .compactMap { $0 }
            .filter { !$0.isEmpty }

        if !settings.isEmpty {
            return settings.joined(separator: " · ")
        }

        return camera.currentMode?.rawValue
    }

    private var showsCaptureBar: Bool {
        captureSummary != nil || (camera.isPaired && camera.supportsBatchRecord)
    }

    @ViewBuilder
    private var batteryStatus: some View {
        if let telemetry {
            if let percent = telemetry.batteryPercent {
                Label("\(percent)%", systemImage: batteryIcon)
                    .accessibilityLabel("Camera battery \(percent) percent")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.acrInk)
                    .lineLimit(1)
            } else if let bars = telemetry.batteryBars {
                Label("\(bars)/4", systemImage: batteryIcon)
                    .accessibilityLabel("Camera battery \(bars) of 4 bars")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.acrInk)
                    .lineLimit(1)
            }
        }
    }

    private var batteryIcon: String {
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

    private var telemetry: CameraTelemetry? {
        guard camera.isConnected else { return nil }
        return camera.telemetry
    }

    private var shouldShowDiagnosticDetail: Bool {
        camera.isKnownAction6 || camera.connectionState != .connected
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
                CGSize(width: 38, height: 36)
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
                Image(systemName: "camera.fill")
                    .font(.system(size: fallbackIconSize, weight: .semibold))
                    .foregroundStyle(brand.badgeColor)
            }
        }
        .frame(width: size.dimensions.width, height: size.dimensions.height)
        .clipped()
        .accessibilityHidden(true)
    }

    private var assetScale: CGFloat {
        switch model {
        case .djiOsmoAction6, .djiOsmoNano:
            1.22
        case .goproHero13Black:
            1.02
        case .goproLitHero,
             .goproMax2,
             .goproHero12Black,
             .goproHero11BlackMini,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black,
             .djiOsmoPocket3,
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
             .goproHero12Black,
             .goproHero11BlackMini,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black,
             .djiOsmoPocket3,
             .unknown:
            0
        }
    }

    private var assetName: String? {
        switch model {
        case .djiOsmoAction6:
            "CameraOsmoAction6"
        case .djiOsmoNano:
            "CameraOsmoNano"
        case .goproHero13Black:
            "CameraGoProHero13"
        case .goproLitHero,
             .goproMax2,
             .goproHero12Black,
             .goproHero11BlackMini,
             .goproHero11Black,
             .goproHero10Black,
             .goproHero9Black,
             .djiOsmoPocket3,
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
    var camera: DiscoveredCamera

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                CameraDetailHeader(camera: camera)

                CameraTelemetryDetailSection(telemetry: camera.telemetry)

                CameraCaptureSettingsSection(camera: camera)

                CameraDetailSection(title: "Signal", systemImage: "antenna.radiowaves.left.and.right") {
                    CameraInfoRow(label: "Strength", value: camera.signalLabel)
                    CameraInfoRow(label: "Signal Level", value: "\(camera.rssi) dBm")
                }
            }
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.acrAppBackground)
        .navigationTitle("Camera Info")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct CameraDetailHeader: View {
    var camera: DiscoveredCamera

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            CameraProductThumbnail(model: camera.model, brand: camera.brand, size: .detail)

            VStack(alignment: .leading, spacing: 5) {
                Text(camera.name)
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
        .padding(16)
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
        if hasCaptureSettings {
            CameraDetailSection(title: "Capture Settings", systemImage: "camera.metering.center.weighted") {
                if let currentMode = camera.currentMode {
                    CameraInfoRow(label: "Mode", value: currentMode.rawValue)
                }
                if let videoResolution = camera.telemetry?.videoResolution {
                    CameraInfoRow(label: "Resolution", value: videoResolution)
                }
                if let frameRate = camera.telemetry?.frameRate {
                    CameraInfoRow(label: "Frame Rate", value: frameRate)
                }
                if let framing = camera.telemetry?.framing {
                    CameraInfoRow(label: "Framing", value: framing)
                }
                if let lens = camera.telemetry?.lens {
                    CameraInfoRow(label: "Lens", value: lens)
                }
                if let stabilization = camera.telemetry?.hypersmooth {
                    CameraInfoRow(label: "Stabilization", value: stabilization)
                }
            }
        }
    }

    private var hasCaptureSettings: Bool {
        camera.currentMode != nil
            || camera.telemetry?.videoResolution != nil
            || camera.telemetry?.frameRate != nil
            || camera.telemetry?.framing != nil
            || camera.telemetry?.lens != nil
            || camera.telemetry?.hypersmooth != nil
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

                if let storageFreeMB = telemetry.storageFreeMB, let storageTotalMB = telemetry.storageTotalMB {
                    CameraInfoRow(
                        label: "Storage",
                        value: "\(CameraDetailFormat.storage(mb: storageFreeMB)) / \(CameraDetailFormat.storage(mb: storageTotalMB))"
                    )
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
        Button {
            performRecordAction()
        } label: {
            Text(camera.primaryRecordTitle)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(recordButtonForeground)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 13)
                .frame(minWidth: 96)
                .frame(height: 44)
                .background(
                    recordButtonFill,
                    in: RoundedRectangle(cornerRadius: ACRDesign.buttonCornerRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ACRDesign.buttonCornerRadius, style: .continuous)
                        .stroke(recordButtonStroke, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(camera.primaryRecordCommand == nil)
        .accessibilityLabel(camera.primaryRecordTitle)
    }

    private var recordButtonFill: Color {
        guard camera.primaryRecordCommand != nil else { return Color.secondary.opacity(0.08) }
        return camera.recordingState == .recording ? .acrRecord : .clear
    }

    private var recordButtonForeground: Color {
        guard camera.primaryRecordCommand != nil else { return .acrMutedText }
        return camera.recordingState == .recording ? .white : .acrRecord
    }

    private var recordButtonStroke: Color {
        camera.primaryRecordCommand == nil ? Color.acrLine : Color.acrRecord
    }

    private func performRecordAction() {
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
}
