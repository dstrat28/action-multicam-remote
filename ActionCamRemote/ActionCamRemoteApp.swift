import SwiftUI

@main
struct ActionCamRemoteApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var store: CameraStore

    init() {
        _store = State(initialValue: MulticamAppServices.shared.store)
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--demo-watch-metadata") {
                    WatchMetadataPreview()
                } else {
                    CameraDashboardView()
                }
#else
                CameraDashboardView()
#endif
            }
                .environment(store)
                .onChange(of: scenePhase) { _, phase in
                    switch phase {
                    case .active:
                        store.resumeCameraConnections()
                    case .background:
                        store.saveDiagnosticsBeforeBackgrounding()
                    case .inactive:
                        break
                    @unknown default:
                        break
                    }
                }
        }
    }
}

#if DEBUG
/// Renders the real Watch detail view when a watchOS simulator is unavailable.
private struct WatchMetadataPreview: View {
    private var camera: WatchCamera {
        let arguments = ProcessInfo.processInfo.arguments
        var row: [String: Any] = ["id": "watch-ui-fixture", "name": "Insta360 X6", "model": "X6",
                                  "modeName": "Video", "batteryPercent": 84]
        var volumes = [CameraStorageVolume(location: .internalStorage, freeMB: 32_768, totalMB: 65_536),
                       CameraStorageVolume(location: .sdCard, freeMB: 51_200, totalMB: 131_072)]
        if arguments.contains("--demo-watch-nano") {
            row["name"] = "Osmo Nano"; row["model"] = "Osmo Nano"
            row["isExternalPowerConnected"] = true
            volumes.removeLast()
        } else if arguments.contains("--demo-watch-gopro") {
            row["name"] = "GoPro HERO13"; row["model"] = "HERO13 Black"
            row["storageFreeMB"] = 51_200; row["storageTotalMB"] = 131_072
            return WatchCamera(snapshot: row)!
        } else if arguments.contains("--demo-watch-no-sd") {
            volumes[1] = CameraStorageVolume(location: .sdCard, state: .notInserted)
        } else if arguments.contains("--demo-watch-empty") {
            row.removeValue(forKey: "batteryPercent")
            volumes = []
        }
        row["storageVolumes"] = try? JSONEncoder().encode(volumes)
        return WatchCamera(snapshot: row)!
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("Watch detail view · iPhone debug preview")
                .font(.caption)
                .foregroundStyle(.secondary)
            NavigationStack {
                WatchCameraDetailView(camera: camera)
                    .padding(.horizontal, 8)
                    .background(.black)
            }
            .frame(width: 208, height: 348)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .scaleEffect(1.5)
            .frame(width: 312, height: 522)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .preferredColorScheme(.dark)
    }
}
#endif
