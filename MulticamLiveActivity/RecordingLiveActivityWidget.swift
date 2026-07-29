import ActivityKit
import SwiftUI
import WidgetKit

struct RecordingLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            RecordingLockScreenView(context: context)
                .activityBackgroundTint(.black)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.trailing) {
                    elapsedTime(
                        startedAt: context.attributes.startedAt,
                        font: .headline
                    )
                    .frame(width: 54, alignment: .trailing)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: context.isStale ? "exclamationmark.circle.fill" : "record.circle.fill")
                                .foregroundStyle(context.isStale ? .orange : .red)

                            Text(cameraCountText(context.state.recordingCameraCount))
                                .foregroundStyle(.white)
                        }
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Spacer(minLength: 4)

                        RecordingActionButtons(
                            canAddHighlight: context.state.canAddHighlight,
                            isStopping: context.state.isStopping,
                            dimension: 38
                        )
                        .padding(.bottom, 4)
                    }
                }
            } compactLeading: {
                compactStatus(
                    isStale: context.isStale,
                    recordingCameraCount: context.state.recordingCameraCount
                )
            } compactTrailing: {
                elapsedTime(
                    startedAt: context.attributes.startedAt,
                    font: .caption2.weight(.semibold),
                    compact: true
                )
            } minimal: {
                compactStatusIcon(isStale: context.isStale)
            }
            .keylineTint(context.isStale ? .orange : .red)
        }
    }

    private func compactStatusIcon(isStale: Bool) -> some View {
        Image(systemName: isStale ? "exclamationmark.circle.fill" : "record.circle.fill")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isStale ? .orange : .red)
    }

    private func compactStatus(
        isStale: Bool,
        recordingCameraCount: Int
    ) -> some View {
        HStack(spacing: 3) {
            compactStatusIcon(isStale: isStale)

            Text("\(recordingCameraCount)")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(.white)
        }
    }

    private func elapsedTime(
        startedAt: Date,
        font: Font,
        compact: Bool = false
    ) -> some View {
        Text(startedAt, style: .timer)
            .font(font.monospacedDigit())
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: compact ? 42 : nil, alignment: .trailing)
    }

    private func cameraCountText(_ count: Int) -> String {
        count == 1 ? "1 camera" : "\(count) cameras"
    }
}

private struct RecordingActionButtons: View {
    let canAddHighlight: Bool
    let isStopping: Bool
    let dimension: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            if canAddHighlight {
                Button(intent: AddHighlightIntent()) {
                    Image(systemName: "bookmark.fill")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .frame(width: dimension, height: dimension)
                        .background(.yellow.opacity(0.16), in: buttonShape)
                        .overlay {
                            buttonShape.stroke(.yellow.opacity(0.8), lineWidth: 1.25)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add Highlight")
                .accessibilityHint("Adds a highlight tag to supported recording cameras")
            }

            Button(intent: StopRecordingIntent()) {
                HStack(spacing: 6) {
                    if isStopping {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "stop.fill")
                    }

                    Text("Stop")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(height: dimension)
                .padding(.horizontal, 12)
                .background(.red, in: buttonShape)
            }
            .buttonStyle(.plain)
            .disabled(isStopping)
            .accessibilityLabel(isStopping ? "Stopping recording" : "Stop recording")
            .accessibilityHint("Stops all recording cameras")
        }
    }

    private var buttonShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: dimension / 3, style: .continuous)
    }
}

private struct RecordingLockScreenView: View {
    let context: ActivityViewContext<RecordingActivityAttributes>

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: context.isStale ? "exclamationmark.circle.fill" : "record.circle.fill")
                        .foregroundStyle(context.isStale ? .orange : .red)
                    Text(context.isStale ? "Status may be out of date" : cameraCountText)
                        .font(.headline)
                        .foregroundStyle(.white)
                }

                Text(context.attributes.startedAt, style: .timer)
                    .font(.title2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.white)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            RecordingActionButtons(
                canAddHighlight: context.state.canAddHighlight,
                isStopping: context.state.isStopping,
                dimension: 48
            )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var cameraCountText: String {
        let count = context.state.recordingCameraCount
        return count == 1 ? "1 camera" : "\(count) cameras"
    }
}
