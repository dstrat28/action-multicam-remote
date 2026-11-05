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
            && otherEvents.updates.last?.telemetry?.storageVolumes?.count == 2 }
        precondition(events.updates.last?.telemetry?.batteryPercent == 50)
        precondition(events.updates.last?.telemetry?.storageFreeMB == 10)
        precondition(otherEvents.updates.last?.telemetry?.storageVolumes?.map(\.location) == [.internalStorage, .sdCard])
        precondition(otherEvents.updates.last?.telemetry?.storageVolumes?.map(\.freeMB) == [10, 10])
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
        let before = commands.statusRequests
        CFRunLoopRunInMode(tracking, 1.65, false)
        precondition(commands.statusRequests > before)
        precondition(commands.heartbeats == 0, "Do not apply socket heartbeat instructions to Bluetooth")
        first.disconnectManagedConnection()
        second.disconnectManagedConnection()
        precondition(!INSCameraManager.usb().isSetup)
        let afterDisconnect = commands.statusRequests
        spin(0.6)
        precondition(commands.statusRequests == afterDisconnect)

        for scenario in ["both", "no-card", "full", "invalid-card", "invalid-capacity", "duplicate-card",
                         "partial", "sd-only", "battery-scale-zero", "battery-zero", "empty-list", "bad-internal"] {
            let (camera, collected) = make("X6 " + scenario, model: .insta360X6)
            camera.didConnect()
            let c = INSBluetoothManager.instances.last!.commands
            let inner = INSCameraStorageStatus(); inner.cardLocation = .inner
            let sd = INSCameraStorageStatus(); sd.cardLocation = .SD; sd.freeSpace = 5 * 1_048_576
            if scenario == "no-card" { sd.cardState = .noCard }
            if scenario == "full" { sd.cardState = .noSpace; sd.freeSpace = 0 }
            if scenario == "invalid-card" { sd.cardState = .invalidFormat }
            if scenario == "invalid-capacity" { sd.freeSpace = sd.totalSpace + 1 }
            if scenario == "bad-internal" { inner.cardState = .unknownError }
            var list = scenario == "empty-list" ? [] : [sd]
            if scenario == "duplicate-card" { list.append(sd) }
            c.options.cameraStorageStatus = inner
            c.options.storageStateList = NSMutableArray(array: list)
            if scenario == "battery-scale-zero" { c.options.batteryStatus?.batteryScale = 0 }
            if scenario == "battery-zero" { c.options.batteryStatus?.batteryLevel = 0 }
            if scenario == "partial" || scenario == "sd-only" {
                c.optionsError = NSError(domain: "SDKTest", code: 206)
                c.successTypesOverride = [NSNumber(value: INSCameraOptionsType.batteryStatus.rawValue),
                    NSNumber(value: (scenario == "partial" ? INSCameraOptionsType.storageState : .storageStateList).rawValue)]
            }
            waitUntil { collected.updates.last?.telemetry?.storageVolumes != nil }
            let t = collected.updates.last!.telemetry!
            let volumes = t.storageVolumes!
            let hasSD = !["partial", "duplicate-card", "empty-list"].contains(scenario)
            precondition(volumes.count == ((scenario == "sd-only" ? 0 : 1) + (hasSD ? 1 : 0)), scenario)
            if let value = volumes.first(where: { $0.location == .sdCard }) {
                precondition(value.state == (scenario == "no-card" ? .notInserted
                    : ["invalid-card", "invalid-capacity"].contains(scenario) ? .unavailable : .available), scenario)
                if scenario == "full" { precondition(value.freeMB == 0) }
                if scenario == "both" { precondition(value.freeMB == 5) }
            }
            precondition(t.batteryPercent == (scenario == "battery-scale-zero" ? nil : scenario == "battery-zero" ? 0 : 50), scenario)
            precondition(t.storageFreeMB == nil, "Do not aggregate X6 volumes or imply a primary destination")
            camera.disconnectManagedConnection()
        }

        let (singleVolume, singleEvents) = make("ONE X metadata", model: .insta360OneX)
        singleVolume.didConnect()
        let singleCommands = INSBluetoothManager.instances.last!.commands
        singleCommands.options.batteryStatus?.batteryLevel = 0
        singleCommands.options.storageStatus?.cardState = .noSpace
        singleCommands.options.storageStatus?.freeSpace = 0
        waitUntil { singleEvents.updates.last?.telemetry?.storageVolumes != nil }
        let singleTelemetry = singleEvents.updates.last!.telemetry!
        precondition(singleTelemetry.batteryPercent == 0)
        precondition(singleTelemetry.storageVolumes?.map(\.location) == [.sdCard])
        precondition(singleTelemetry.storageFreeMB == 0)
        singleVolume.disconnectManagedConnection()

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
        waitUntil { INSBluetoothManager.instances.last!.commands.statusRequests > 0 }
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

        // X3 takes the per-device SDK path, including explicit start/stop. This
        // exercises our adapter, not the vendor Bluetooth stack or X3 firmware.
        let (x3, x3Events) = make("X3 ABC123", model: .insta360X3)
        x3.didConnect()
        let x3Manager = INSBluetoothManager.instances.last!
        let x3Commands = x3Manager.commands
        waitUntil { x3Events.connections.last == .connected }
        precondition(x3Manager.connectedID == x3.cameraID)
        let x3Start = x3.send(.startRecording)
        precondition(x3Start.status == .queued && x3Commands.starts == 1)
        x3Commands.status.state = .normalCapture
        waitUntil { x3Events.results.contains { $0.id == x3Start.id && $0.status == .sent } }
        x3Commands.holdOptions = true
        waitUntil { !x3Commands.heldOptions.isEmpty }
        spin(5.6)
        precondition(x3Events.updates.last?.recordingState == .unknown)
        let x3Stop = x3.send(.stopRecording)
        precondition(x3Stop.status == .queued && x3Commands.stops == 1,
                     "Unknown capture state must still reach explicit SDK Stop")
        x3Commands.status.state = .notCapture
        x3Commands.holdOptions = false
        x3Commands.releaseOptions()
        waitUntil { x3Events.results.contains { $0.id == x3Stop.id && $0.status == .sent } }

        x3Commands.options.photoSubMode = 0
        x3Commands.options.videoSubMode = 100
        waitUntil { x3Events.updates.last?.currentMode == .photo }
        x3Commands.appliesModeChanges = false
        let x3Mode = x3.send(.setMode(.video))
        precondition(x3Mode.status == .queued && x3Commands.modeChanges == 1)
        spin(1.8)
        precondition(!x3Events.results.contains { $0.id == x3Mode.id }, "Mode acceptance alone cannot confirm Video")
        precondition(CameraRecordingStartPolicy.sdkModePreparation(result: x3Mode,
            currentMode: x3Events.updates.last?.currentMode, now: Date()) == .waiting)
        precondition(x3Commands.starts == 1 && x3Commands.modeChanges == 1)
        x3Commands.options.photoSubMode = 100
        x3Commands.options.videoSubMode = 0
        waitUntil { x3Events.results.contains { $0.id == x3Mode.id && $0.status == .sent } }
        let confirmedMode = x3Events.results.first { $0.id == x3Mode.id }!
        precondition(CameraRecordingStartPolicy.sdkModePreparation(result: confirmedMode,
            currentMode: x3Events.updates.last?.currentMode, now: Date()) == .ready)
        let x3SecondStart = x3.send(.startRecording)
        precondition(x3SecondStart.status == .queued && x3Commands.starts == 2 && x3Commands.modeChanges == 1)
        x3Commands.status.state = .normalCapture
        waitUntil { x3Events.results.contains { $0.id == x3SecondStart.id && $0.status == .sent } }
        x3.disconnectManagedConnection()
        let (optional, optionalEvents) = make("X3 metadata", model: .insta360X3)
        optional.didConnect()
        waitUntil { optionalEvents.connections.last == .connected }
        let optionalCommands = INSBluetoothManager.instances.last!.commands
        let batteryType = NSNumber(value: INSCameraOptionsType.batteryStatus.rawValue)
        optionalCommands.holdTelemetry = true
        waitUntil { optionalCommands.heldOptions.contains { $0.0.contains(batteryType) } }
        let statusBeforeDelay = optionalCommands.statusRequests
        spin(5.6)
        precondition(optionalCommands.statusRequests > statusBeforeDelay)
        precondition(optionalEvents.updates.last?.recordingState == .stopped,
            "Delayed optional metadata must not make capture status unknown")
        let metadataStart = optional.send(.startRecording)
        precondition(metadataStart.status == .queued)
        optionalCommands.status.state = .normalCapture
        waitUntil { optionalEvents.results.contains { $0.id == metadataStart.id && $0.status == .sent } }
        let metadataStop = optional.send(.stopRecording)
        optionalCommands.status.state = .notCapture
        waitUntil { optionalEvents.results.contains { $0.id == metadataStop.id && $0.status == .sent } }
        optionalCommands.options.batteryStatus?.batteryLevel = 17
        optionalCommands.releaseOptions()
        spin(0.1)
        precondition(optionalEvents.updates.last?.telemetry?.batteryPercent == nil,
            "Expired telemetry must not publish a late reading")
        precondition(optionalCommands.optionRequests.filter { $0.contains(batteryType) }.count == 1,
            "Only one optional request may be outstanding; retain the 30-second cadence")
        optional.disconnectManagedConnection()

        print("Insta360 SDK adapter regressions passed: initialization, per-camera routing, X3 capture, stale replies/delegates, capture supersession, status polling and cleanup (SDK double).")
    }
}
