import SwiftUI
import UIKit

extension Color {
    static let acrInk = Color.adaptive(
        light: UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    )
    static let acrAppBackground = Color.adaptive(
        light: UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1),
        dark: UIColor(red: 0.04, green: 0.05, blue: 0.06, alpha: 1)
    )
    static let acrSurface = Color.adaptive(
        light: UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        dark: UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)
    )
    static let acrInsetSurface = Color.adaptive(
        light: UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1),
        dark: UIColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
    )
    static let acrLine = Color.adaptive(
        light: UIColor(red: 0.84, green: 0.86, blue: 0.89, alpha: 1),
        dark: UIColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1)
    )
    static let acrMutedText = Color.adaptive(
        light: UIColor(red: 0.38, green: 0.41, blue: 0.46, alpha: 1),
        dark: UIColor(red: 0.64, green: 0.67, blue: 0.72, alpha: 1)
    )
    static let acrRecord = Color(red: 0.92, green: 0.13, blue: 0.18)
    static let acrReady = Color(red: 0.00, green: 0.57, blue: 0.38)
    static let acrAvailable = Color(red: 0.11, green: 0.42, blue: 0.88)
    static let acrWarning = Color(red: 0.93, green: 0.52, blue: 0.08)
    static let acrAccent = Color(red: 0.14, green: 0.34, blue: 0.82)
    static let acrDJI = Color(red: 0.15, green: 0.40, blue: 0.91)
    static let acrGoPro = Color(red: 0.00, green: 0.50, blue: 0.58)
    static let acrCommandTop = Color.adaptive(
        light: UIColor(red: 0.09, green: 0.14, blue: 0.21, alpha: 1),
        dark: UIColor(red: 0.13, green: 0.18, blue: 0.26, alpha: 1)
    )
    static let acrCommandBottom = Color.adaptive(
        light: UIColor(red: 0.06, green: 0.28, blue: 0.38, alpha: 1),
        dark: UIColor(red: 0.06, green: 0.21, blue: 0.30, alpha: 1)
    )

    private static func adaptive(light: UIColor, dark: UIColor) -> Color {
        Color(
            UIColor { traits in
                traits.userInterfaceStyle == .dark ? dark : light
            }
        )
    }
}

enum ACRDesign {
    static let cardCornerRadius: CGFloat = 10
    static let buttonCornerRadius: CGFloat = 12
    static let controlBarCornerRadius: CGFloat = 16
    static let insetCornerRadius: CGFloat = 6
}

extension View {
    func acrCard(
        fill: Color = .acrSurface,
        stroke: Color = .acrLine,
        lineWidth: CGFloat = 1
    ) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: ACRDesign.cardCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ACRDesign.cardCornerRadius, style: .continuous)
                    .stroke(stroke, lineWidth: lineWidth)
            }
    }

    func acrInsetPanel(fill: Color = .acrInsetSurface) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: ACRDesign.insetCornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ACRDesign.insetCornerRadius, style: .continuous)
                    .stroke(Color.acrLine.opacity(0.55), lineWidth: 1)
            }
    }
}

extension CameraBrand {
    var badgeColor: Color {
        switch self {
        case .gopro:
            .acrGoPro
        case .dji:
            .acrDJI
        case .unknown:
            .secondary
        }
    }
}

extension CameraConnectionState {
    var statusColor: Color {
        switch self {
        case .connected:
            .acrReady
        case .discovered:
            .acrAvailable
        case .connecting, .reconnecting:
            .acrWarning
        case .unsupported, .failed, .disconnected:
            .secondary
        }
    }
}

extension CameraRecordingState {
    var statusColor: Color {
        switch self {
        case .recording:
            .acrRecord
        case .starting:
            .acrWarning
        case .ready, .stopped:
            .acrReady
        case .unknown, .unavailable:
            .secondary
        }
    }
}
