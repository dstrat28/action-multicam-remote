import SwiftUI
import WidgetKit

@main
struct MulticamLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        RecordingLiveActivityWidget()
        MulticamLauncherWidget()
    }
}
