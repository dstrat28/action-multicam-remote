import SwiftUI
import WidgetKit

@main
struct MulticamWatchComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "MulticamWatchComplication", provider: LauncherProvider()) { _ in
            LauncherView()
        }
        .configurationDisplayName("Multicam")
        .description("Open the camera remote.")
        .supportedFamilies([.accessoryCircular, .accessoryCorner, .accessoryRectangular, .accessoryInline])
    }
}

private struct LauncherEntry: TimelineEntry {
    let date: Date
}

private struct LauncherProvider: TimelineProvider {
    func placeholder(in context: Context) -> LauncherEntry {
        LauncherEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (LauncherEntry) -> Void) {
        completion(LauncherEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LauncherEntry>) -> Void) {
        completion(Timeline(entries: [LauncherEntry(date: .now)], policy: .never))
    }
}

private struct LauncherView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                Image(systemName: "video.fill")
                    .font(.title2)
            case .accessoryCorner:
                Image(systemName: "video.fill")
                    .font(.title3)
            case .accessoryRectangular:
                Label("Multicam", systemImage: "video.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
            default:
                Label("Multicam", systemImage: "video.fill")
            }
        }
        .accessibilityLabel("Open Multicam")
        .containerBackground(for: .widget) {
            if family == .accessoryCircular {
                AccessoryWidgetBackground()
            }
        }
    }
}
