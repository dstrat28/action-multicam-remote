import Foundation

@main
enum DJINanoProtocolRegression {
    static func main() {
        let sequence = DJINanoProtocol.wakeSequence
        precondition(sequence.count == 4)
        precondition(commandSignature(sequence[0]) == "f0:00:2b:0400")
        precondition(sequence[1].destination == 0x07)
        precondition(sequence[1].commandSet == 0x07)
        precondition(sequence[1].commandID == 0x45)
        precondition(sequence[1].payload.first == 32)
        precondition(sequence[1].payload.suffix(5) == Data([4, 0x4D, 0x43, 0x41, 0x4D]))
        precondition(DJINanoProtocol.pairingDisplayName == "Action Multicam")
        precondition(DJINanoProtocol.pairingStatus(fromSetPairingResponse: Data([0x00, 0x01])) == .alreadyPaired)
        precondition(DJINanoProtocol.pairingStatus(fromSetPairingResponse: Data([0x00, 0x02])) == .approvalRequired)
        precondition(DJINanoProtocol.pairingStatus(fromSetPairingResponse: Data([0x00, 0x7F])) == .unexpected(0x7F))
        precondition(DJINanoProtocol.pairingStatus(fromSetPairingResponse: Data([0x00])) == nil)
        precondition(commandSignature(sequence[2]) == "f0:00:2b:0101")
        precondition(commandSignature(sequence[3]) == "1c:53:10:00000000")

        precondition(DJIPocket3Protocol.notifyPrimePayload == Data([0x01, 0x00]))
        precondition(commandSignature(DJIPocket3Protocol.sessionOpenCommand) == "f0:00:2b:0400")
        precondition(DJIPocket3Protocol.pairingCommand.destination == 0x07)
        precondition(DJIPocket3Protocol.pairingCommand.commandSet == 0x07)
        precondition(DJIPocket3Protocol.pairingCommand.commandID == 0x45)
        precondition(DJIPocket3Protocol.pairingCommand.payload.first == 32)
        precondition(DJIPocket3Protocol.pairingCommand.payload.suffix(5) == Data([4, 0x6F, 0x73, 0x6D, 0x6F]))
        precondition(commandSignature(DJIPocket3Protocol.keepAliveCommand) == "f0:00:2b:0101")
        precondition(commandSignature(DJIPocket3Protocol.wakeCommand) == "1c:53:10:00000000")

        let pocketRecordFrame = DJINanoProtocol.frame(
            sequenceNumber: 0x1234,
            destination: 0x01,
            commandSet: 0x02,
            commandID: 0x02,
            payload: Data([0x01])
        )
        precondition(pocketRecordFrame[4] == 0x02 && pocketRecordFrame[5] == 0x01)
        precondition(pocketRecordFrame[8] == 0x40)
        precondition(pocketRecordFrame[9] == 0x02 && pocketRecordFrame[10] == 0x02)
        precondition(pocketRecordFrame[11] == 0x01)

        let wakeFrame = DJINanoProtocol.frame(
            sequenceNumber: 0x1234,
            destination: sequence[3].destination,
            commandSet: sequence[3].commandSet,
            commandID: sequence[3].commandID,
            payload: sequence[3].payload
        )
        precondition(wakeFrame.count == 17)
        precondition(wakeFrame.prefix(4) == Data([0x55, 0x11, 0x04, 0x92]))
        precondition(wakeFrame[4] == 0x02)
        precondition(wakeFrame[5] == 0x1C)
        precondition(wakeFrame[6] == 0x12 && wakeFrame[7] == 0x34)
        precondition(wakeFrame[8] == 0x40)
        precondition(wakeFrame[9] == 0x53 && wakeFrame[10] == 0x10)

        var status = Data(repeating: 0, count: 60)
        status[57] = 0x28
        precondition(DJINanoProtocol.shootingModeByte(from: status) == 0x28)
        precondition(CaptureMode.djiNanoMode(for: status[57]) == .superNight)
        precondition(DJINanoProtocol.shootingModeByte(from: Data(repeating: 0, count: 57)) == nil)

        precondition(commandSignature(DJINanoProtocol.sessionInfoCommand) == "88:00:32:3131000000")
        let subscriptions = DJINanoProtocol.configSubscriptionCommands(startingAt: 0xCBD6)
        precondition(subscriptions.count == 3)
        precondition(subscriptions.map(\.destination).allSatisfy { $0 == 0x28 })
        precondition(subscriptions.map(\.commandSet).allSatisfy { $0 == 0x00 })
        precondition(subscriptions.map(\.commandID).allSatisfy { $0 == 0x99 })
        precondition(subscriptions[0].payload.prefix(8) == Data([0x02, 0x02, 0x00, 0x00, 0xD6, 0xCB, 0x00, 0x00]))

        let videoItem = DJINanoProtocol.configItem(
            from: configItemPayload(name: "cam_video_param_v2", value: Data([0x10, 0x06]))
        )
        precondition(videoItem?.name == "cam_video_param_v2")
        precondition(videoItem?.value == Data([0x10, 0x06]))
        precondition(videoItem.flatMap(DJINanoProtocol.captureSettingUpdate) == .video(resolution: 0x10, frameRate: 0x06))

        let photoItem = DJINanoProtocol.configItem(
            from: configItemPayload(name: "cam_photo_param_new", value: Data([0x02, 0x15, 0x00, 0x04, 0x01]))
        )
        precondition(photoItem.flatMap(DJINanoProtocol.captureSettingUpdate) == .photo(size: 0x04, aspectRatio: 0x01))

        let fovItem = DJINanoProtocol.configItem(
            from: configItemPayload(name: "cam_fov", value: Data([0x05]))
        )
        precondition(fovItem.flatMap(DJINanoProtocol.captureSettingUpdate) == .fieldOfView(0x05))
        precondition(DJINanoProtocol.configItem(from: Data([0x02, 0x06])) == nil)

        precondition(
            DJINanoProtocol.permitsAutomaticConnection(
                currentAdvertisementAwake: true,
                passiveReconnectBlocked: false,
                hasUserInitiatedWakeIntent: false
            )
        )
        precondition(
            !DJINanoProtocol.permitsAutomaticConnection(
                currentAdvertisementAwake: nil,
                passiveReconnectBlocked: false,
                hasUserInitiatedWakeIntent: false
            )
        )
        precondition(
            !DJINanoProtocol.permitsAutomaticConnection(
                currentAdvertisementAwake: true,
                passiveReconnectBlocked: true,
                hasUserInitiatedWakeIntent: false
            )
        )
        precondition(
            DJINanoProtocol.permitsAutomaticConnection(
                currentAdvertisementAwake: false,
                passiveReconnectBlocked: true,
                hasUserInitiatedWakeIntent: true
            )
        )
        precondition(
            DJINanoProtocol.confirmsFreshPowerOn(
                previousAdvertisementAwake: false,
                currentAdvertisementAwake: true
            )
        )
        precondition(
            !DJINanoProtocol.confirmsFreshPowerOn(
                previousAdvertisementAwake: nil,
                currentAdvertisementAwake: true
            )
        )
        precondition(
            DJINanoProtocol.isAuthoritativeShootingModeReadback(
                commandSet: 0x02,
                commandID: 0x80,
                isResponse: false
            )
        )
        precondition(
            !DJINanoProtocol.isAuthoritativeShootingModeReadback(
                commandSet: 0x02,
                commandID: 0x80,
                isResponse: true
            )
        )
        precondition(
            !DJINanoProtocol.isAuthoritativeShootingModeReadback(
                commandSet: 0x02,
                commandID: 0x11,
                isResponse: true
            )
        )
        precondition(
            !DJINanoProtocol.isAuthoritativeShootingModeReadback(
                commandSet: 0x02,
                commandID: 0x70,
                isResponse: true
            )
        )

        let awakeObservedAt = Date(timeIntervalSince1970: 100)
        precondition(
            !DJINanoProtocol.hasStableAwakeAdvertisement(
                isAwake: true,
                observedSince: awakeObservedAt,
                now: awakeObservedAt.addingTimeInterval(0.5),
                minimumDuration: 1
            )
        )
        precondition(
            DJINanoProtocol.hasStableAwakeAdvertisement(
                isAwake: true,
                observedSince: awakeObservedAt,
                now: awakeObservedAt.addingTimeInterval(1),
                minimumDuration: 1
            )
        )
        precondition(
            !DJINanoProtocol.hasStableAwakeAdvertisement(
                isAwake: false,
                observedSince: awakeObservedAt,
                now: awakeObservedAt.addingTimeInterval(2),
                minimumDuration: 1
            )
        )
        precondition(
            !DJINanoProtocol.hasStableAwakeAdvertisement(
                isAwake: true,
                observedSince: nil,
                now: awakeObservedAt.addingTimeInterval(2),
                minimumDuration: 1
            )
        )

        print("DJI Nano protocol regression checks passed.")
    }

    private static func commandSignature(_ command: DJINanoProtocol.Command) -> String {
        String(format: "%02x:%02x:%02x:%@", command.destination, command.commandSet, command.commandID, hex(command.payload))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func configItemPayload(name: String, value: Data) -> Data {
        let nameBytes = Data(name.utf8)
        var payload = Data([0x02, 0x06, 0x00, 0x00])
        payload.append(contentsOf: [0xD6, 0xCB, 0x00, 0x00])
        payload.append(contentsOf: [0x00, 0x00, 0x00])
        appendLittleEndian(UInt16(nameBytes.count + 6), to: &payload)
        appendLittleEndian(UInt16(nameBytes.count), to: &payload)
        payload.append(nameBytes)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
        appendLittleEndian(UInt16(value.count), to: &payload)
        payload.append(value)
        return payload
    }

    private static func appendLittleEndian(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }
}
