import CoreFoundation
import Foundation
import INSCameraServiceSDK

private final class Events {
    var connections: [CameraConnectionState] = []
    var updates: [CameraStatusUpdate] = []
    var results: [CameraCommandResult] = []
}

@main
enum Insta360SDKAdapterRegression {
    static func spin(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: min(end, Date().addingTimeInterval(0.01))) }
    }

    static func waitUntil(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline { spin(0.01) }
        precondition(condition(), "SDK adapter did not reach the expected state")
    }

    private static func make(_ name: String, model: CameraModel = .insta360X5) -> (Insta360SDKClient, Events) {
        let events = Events()
        let client = Insta360SDKClient(cameraID: UUID(), cameraName: name, cameraModel: model,
            onStatus: { _, state, _ in events.connections.append(state) },
            onCameraStatus: { _, update in events.updates.append(update) }, onLog: { _ in },
            onCommandCompleted: { events.results.append($0) })
        return (client, events)
    }

    static func main() {
        let (first, events) = make("X5")
        let (second, otherEvents) = make("X6", model: .insta360X6)
        first.didConnect()
        second.didConnect()
        waitUntil { events.connections.last == .connected && otherEvents.connections.last == .connected }
        let managers = INSBluetoothManager.instances
        precondition(managers.count == 2 && INSCameraManager.usb().setupCount == 1)
        precondition(events.connections.last == .connected && otherEvents.connections.last == .connected)
        precondition(events.updates.last?.recordingState == .stopped && events.updates.last?.currentMode == .video)
        let commands = managers[0].commands
        let internalStorage = INSCameraStorageStatus()
        internalStorage.cardLocation = .inner
        let sdStorage = INSCameraStorageStatus()
        sdStorage.cardLocation = .SD
        managers[1].commands.options.storageStatus = nil
        managers[1].commands.options.cameraStorageStatus = internalStorage
        managers[1].commands.options.storageStateList = NSMutableArray(array: [sdStorage])
        precondition(commands !== managers[1].commands)
        waitUntil { events.updates.last?.telemetry?.batteryPercent == 50
            && otherEvents.updates.last?.telemetry?.storageState?.contains("SD card:") == true }
        precondition(events.updates.last?.telemetry?.batteryPercent == 50)
        precondition(events.updates.last?.telemetry?.storageFreeMB == 10)
        precondition(otherEvents.updates.last?.telemetry?.storageState?.contains("Internal:") == true)
        precondition(otherEvents.updates.last?.telemetry?.storageState?.contains("SD card:") == true)
        precondition(otherEvents.updates.last?.telemetry?.storageFreeMB == nil)
        precondition(managers[1].commands.optionRequests.contains { $0.contains(NSNumber(value: INSCameraOptionsType.storageStateList.rawValue)) })

        // A status response issued before Stop must not confirm that Stop.
        commands.holdOptions = true
        waitUntil { !commands.heldOptions.isEmpty }
        let stop = first.send(.stopRecording)
        precondition(stop.status == .queued && commands.stops == 1)
        commands.releaseOptions()
        spin(0.05)
        precondition(!events.results.contains { $0.id == stop.id && $0.status == .sent })
        commands.holdOptions = false
        waitUntil { events.results.contains { $0.id == stop.id && $0.status == .sent } }

        commands.acceptCapture = false
        let start = first.send(.startRecording)
        precondition(start.status == .queued && commands.starts == 1)
        precondition(first.send(.startRecording).status == .skipped && commands.starts == 1)
        precondition(managers[1].commands.starts == 0)
        let pendingStartCallback = commands.startCompletion
        let replacingStop = first.send(.stopRecording)
        precondition(replacingStop.status == .queued)
        precondition(events.results.contains { $0.id == start.id && $0.status == .failed })
        pendingStartCallback?(nil)
        waitUntil { events.results.contains { $0.id == replacingStop.id && $0.status == .sent } }
        precondition(commands.starts == 1 && managers[1].commands.stops == 0)

        // The real adapter's timer must continue while UI tracking uses a common mode.
        let tracking = CFRunLoopMode(rawValue: "Insta360SDKTrackingRegression" as CFString)
        CFRunLoopAddCommonMode(CFRunLoopGetMain(), tracking)
        let before = commands.heartbeats
        CFRunLoopRunInMode(tracking, 0.65, false)
        precondition(commands.heartbeats > before)
        first.disconnectManagedConnection()
        second.disconnectManagedConnection()
        precondition(!INSCameraManager.usb().isSetup)
        let afterDisconnect = commands.heartbeats
        spin(0.6)
        precondition(commands.heartbeats == afterDisconnect)

        // A canceled connection and its delegate belong to their original generation.
        INSBluetoothManager.autoConnect = false
        first.didConnect()
        let canceled = INSBluetoothManager.instances.last!
        let lateConnection = canceled.connectionCompletion
        let lateDelegate = canceled.delegate
        first.disconnectManagedConnection()
        precondition(canceled.cancellations == 1)
        INSBluetoothManager.autoConnect = true
        first.didConnect()
        waitUntil { INSBluetoothManager.instances.last!.commands.heartbeats > 0 }
        let current = INSBluetoothManager.instances.last!
        let failuresBefore = events.connections.filter { if case .failed = $0 { true } else { false } }.count
        lateConnection?(nil, INSBluetoothDevice(id: first.cameraID))
        lateDelegate?.device(INSBluetoothDevice(id: first.cameraID), didDisconnectWithError: nil)
        spin(0.1)
        precondition(events.connections.last == .connected)
        precondition(events.connections.filter { if case .failed = $0 { true } else { false } }.count == failuresBefore)
        precondition(current.disconnections == 0)
        current.state = .bluetoothDisable
        waitUntil { events.connections.contains { if case .failed = $0 { true } else { false } } }
        precondition(current.disconnections == 1 && !INSCameraManager.usb().isSetup)

        let (partial, partialEvents) = make("X4", model: .insta360X4)
        partial.didConnect()
        let partialCommands = INSBluetoothManager.instances.last!.commands
        partialCommands.optionsError = NSError(domain: "SDKTest", code: 206)
        partialCommands.successTypesOverride = [NSNumber(value: INSCameraOptionsType.photoSubMode.rawValue)]
        waitUntil { partialEvents.connections.last == .connected }
        precondition(partialEvents.updates.last?.currentMode == nil)
        precondition(partial.send(.startRecording).status == .skipped)
        partialCommands.optionsError = nil
        partialCommands.successTypesOverride = nil
        let mode = partial.send(.setMode(.video))
        precondition(mode.status == .queued)
        waitUntil { partialEvents.results.contains { $0.id == mode.id && $0.status == .sent } }
        partial.disconnectManagedConnection()
        print("Insta360 SDK adapter regressions passed: initialization, per-camera routing, stale replies/delegates, capture supersession, heartbeat and cleanup (SDK double).")
    }
}
