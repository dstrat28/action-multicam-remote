import CoreBluetooth
import Foundation

// The app's scanner owns this UUID. The clients and callback session below
// are production sources; the host check does not create a central manager.
enum Insta360BLEUUID {
    static let directControl = CBUUID(string: "BE80")
}

@MainActor
private final class EventProbe {
    let events = CameraClientEventSession()
    var statuses: [CameraConnectionState] = []
    var disconnects = 0
    var discardedDisconnects = 0

    nonisolated func receive(_ state: CameraConnectionState) {
        events.deliverStatus(state, apply: { [self] in
            statuses.append(state)
            if case .failed = state { events.invalidate() }
        }, onFailure: { [self] in disconnects += 1 })
    }

    nonisolated func requestDisconnect() {
        events.deliver({ [self] in disconnects += 1 },
            onDiscard: { [self] in discardedDisconnects += 1 })
    }
}

@main
@MainActor
enum CameraClientLifecycleRegression {
    static func main() async {
        for current in [CameraConnectionState.discovered, .disconnected, .connecting, .reconnecting] {
            precondition(current.applyingLinkUpdate(.connected) == .connecting,
                "Opening a Bluetooth link must not enable controls before the client's protocol-ready status")
        }
        precondition(CameraConnectionState.connected.applyingLinkUpdate(.connected) == .connected,
            "A late link-open notification must not demote an already ready connection")
        for linkState in [CameraConnectionState.connecting, .reconnecting, .disconnected, .failed("Link failed")] {
            precondition(CameraConnectionState.connected.applyingLinkUpdate(linkState) == linkState,
                "A lost or restarted link must clear application readiness")
        }
        for brand in [CameraBrand.gopro, .insta360] {
            let active = EventProbe()
            let (client, peripheral) = failClient(brand: brand, probe: active)
            await waitUntil { active.discardedDisconnects == 1 }
            precondition(active.statuses.count == 1 && active.disconnects == 1,
                "A current client's terminal failure must disconnect even when applying its status retires the session")
            client.didDisconnect(error: nil)
            _ = peripheral

            let retired = EventProbe()
            let (oldClient, oldPeripheral) = failClient(brand: brand, probe: retired)
            retired.events.invalidate() // Replacement precedes queued failure delivery.
            let replacement = EventProbe()
            replacement.receive(.connected)
            await waitUntil { retired.discardedDisconnects == 1 && replacement.statuses.count == 1 }
            precondition(retired.statuses.isEmpty && retired.disconnects == 0,
                "A retired client's failure must neither change state nor request teardown")
            precondition(replacement.statuses == [.connected] && replacement.disconnects == 0,
                "A late failure must not close the replacement connection")
            oldClient.didDisconnect(error: nil)
            _ = oldPeripheral
        }
        print("Client lifecycle checks passed: actual GoPro and direct Insta360 failures preserve current teardown and discard replaced callbacks.")
    }

    private static func failClient(brand: CameraBrand, probe: EventProbe) -> (any BLECameraDeviceClient, CBPeripheral) {
        let peripheral = CBPeripheral()
        if brand == .gopro {
            let writer = CBCharacteristic(uuid: GoProBLEUUID.command, properties: [.write])
            let response = CBCharacteristic(uuid: GoProBLEUUID.commandResponse, properties: [.notify])
            let service = CBService(uuid: GoProBLEUUID.serviceControlAndQuery, characteristics: [writer, response])
            peripheral.services = [service]
            let client = GoProBLEClient(cameraID: UUID(), cameraName: "Test GoPro", peripheral: peripheral,
                onStatus: { _, state, _ in probe.receive(state) }, onCameraStatus: { _, _ in }, onLog: { _ in },
                onDisconnectRequested: { _ in probe.requestDisconnect() })
            client.didConnect()
            client.peripheral(peripheral, didDiscoverCharacteristicsFor: service, error: nil)
            precondition(!peripheral.writes.isEmpty)
            client.peripheral(peripheral, didWriteValueFor: peripheral.writes[0].characteristic,
                error: NSError(domain: "Test", code: 1))
            return (client, peripheral)
        }
        let client = Insta360DirectBLEClient(cameraID: UUID(), cameraName: "Test X6", cameraModel: .insta360X6,
            peripheral: peripheral, onStatus: { _, state, _ in probe.receive(state) },
            onCameraStatus: { _, _ in }, onProtocolActivity: { _ in }, onLog: { _ in },
            onCommandCompleted: { _ in }, onDisconnectRequested: { _ in probe.requestDisconnect() })
        client.didConnect()
        client.peripheral(peripheral, didDiscoverServices: NSError(domain: "Test", code: 1))
        return (client, peripheral)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        precondition(condition(), "Expected queued client callbacks to finish")
    }
}
