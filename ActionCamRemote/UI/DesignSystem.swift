import SwiftUI
import UIKit

extension Color {
    static let acrInk = Color.adaptive(
        light: UIColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1),
        dark: UIColor(red: 0.94, green: 0.95, blue: 0.97, alpha: 1)
    )
    static let acrAppBackground = Color.adaptive(
        light: UIColor(red: 0.95, green: 0.97, blue: 0.99, alpha: 1),
        dark: UIColor(red: 0.02, green: 0.03, blue: 0.055, alpha: 1)
    )
    static let acrSurface = Color.adaptive(
        light: UIColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        dark: UIColor(red: 0.08, green: 0.10, blue: 0.15, alpha: 1)
    )
    static let acrInsetSurface = Color.adaptive(
        light: UIColor(red: 0.93, green: 0.94, blue: 0.95, alpha: 1),
        dark: UIColor(red: 0.055, green: 0.07, blue: 0.11, alpha: 1)
    )
    static let acrLine = Color.adaptive(
        light: UIColor(red: 0.79, green: 0.84, blue: 0.91, alpha: 1),
        dark: UIColor(red: 0.27, green: 0.32, blue: 0.42, alpha: 1)
    )
    static let acrMutedText = Color.adaptive(
        light: UIColor(red: 0.38, green: 0.41, blue: 0.46, alpha: 1),
        dark: UIColor(red: 0.65, green: 0.69, blue: 0.77, alpha: 1)
    )
    static let acrRecord = Color(red: 0.96, green: 0.12, blue: 0.20)
    static let acrReady = Color(red: 0.11, green: 0.72, blue: 0.47)
    static let acrAvailable = Color(red: 0.14, green: 0.45, blue: 0.96)
    static let acrWarning = Color(red: 0.93, green: 0.52, blue: 0.08)
    static let acrAccent = Color(red: 0.14, green: 0.34, blue: 0.82)
    static let acrDJI = Color(red: 0.15, green: 0.40, blue: 0.91)
    static let acrGoPro = Color(red: 0.00, green: 0.50, blue: 0.58)
    static let acrGlassTint = Color.adaptive(
        light: UIColor(red: 0.80, green: 0.88, blue: 1.00, alpha: 1),
        dark: UIColor(red: 0.16, green: 0.25, blue: 0.42, alpha: 1)
    )
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
    static let cardCornerRadius: CGFloat = 22
    static let buttonCornerRadius: CGFloat = 16
    static let controlBarCornerRadius: CGFloat = 24
    static let insetCornerRadius: CGFloat = 12
}

struct ACRGlassEffectContainer<Content: View>: View {
    var spacing: CGFloat
    private var content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content
            }
        } else {
            content
        }
    }
}

struct ACRAtmosphericBackground: View {
    var body: some View {
        ZStack {
            Color.acrAppBackground

            RadialGradient(
                colors: [
                    Color.acrAvailable.opacity(0.12),
                    Color.acrAvailable.opacity(0.025),
                    .clear,
                ],
                center: UnitPoint(x: 0.82, y: 0.10),
                startRadius: 0,
                endRadius: 330
            )

            RadialGradient(
                colors: [
                    Color.acrGoPro.opacity(0.08),
                    .clear,
                ],
                center: UnitPoint(x: 0.08, y: 0.76),
                startRadius: 0,
                endRadius: 290
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(0.018),
                    .clear,
                    Color.black.opacity(0.20),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }
}

extension View {
    @ViewBuilder
    func acrCard(
        fill: Color = .acrSurface,
        stroke: Color = .acrLine,
        lineWidth: CGFloat = 1,
        interactive: Bool = false
    ) -> some View {
        let shape = RoundedRectangle(cornerRadius: ACRDesign.cardCornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .background(fill.opacity(0.07), in: shape)
                .glassEffect(
                    interactive
                        ? .clear.tint(Color.acrGlassTint.opacity(0.15)).interactive()
                        : .clear.tint(Color.acrGlassTint.opacity(0.15)),
                    in: .rect(cornerRadius: ACRDesign.cardCornerRadius)
                )
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.20),
                                stroke.opacity(0.54),
                                Color.acrAvailable.opacity(0.10),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: lineWidth
                    )
                }
                .shadow(color: Color.acrAvailable.opacity(0.055), radius: 18, y: 8)
                .shadow(color: Color.black.opacity(0.26), radius: 14, y: 9)
        } else {
            self
                .background(fill, in: shape)
                .overlay {
                    shape.stroke(stroke, lineWidth: lineWidth)
                }
        }
    }

    @ViewBuilder
    func acrFloatingControlBar() -> some View {
        let shape = RoundedRectangle(cornerRadius: ACRDesign.controlBarCornerRadius, style: .continuous)

        if #available(iOS 26.0, *) {
            self
                .background(Color.acrSurface.opacity(0.07), in: shape)
                .glassEffect(
                    .clear.tint(Color.acrGlassTint.opacity(0.15)),
                    in: .rect(cornerRadius: ACRDesign.controlBarCornerRadius)
                )
                .overlay {
                    shape.stroke(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.22),
                                Color.acrLine.opacity(0.52),
                                Color.acrAvailable.opacity(0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
                .shadow(color: Color.acrAvailable.opacity(0.075), radius: 22, y: 8)
                .shadow(color: Color.black.opacity(0.34), radius: 20, y: 12)
        } else {
            self
                .background(.regularMaterial, in: shape)
                .overlay {
                    shape.stroke(Color.acrLine.opacity(0.7), lineWidth: 1)
                }
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
