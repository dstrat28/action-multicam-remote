import Foundation

struct DJINanoProtocol {
    static let appAddress: UInt8 = 0x02
    static let cameraAddress: UInt8 = 0x01
    static let wifiAddress: UInt8 = 0x07
    static let systemAddress: UInt8 = 0x1C
    static let sessionAddress: UInt8 = 0xF0
    static let configAddress: UInt8 = 0x28
    static let sessionInfoAddress: UInt8 = 0x88

    static let pairingToken = "MCAM"
    static let pairingDisplayName = "Action Multicam"

    enum PairingStatus: Equatable {
        case alreadyPaired
        case approvalRequired
        case approved
        case unexpected(UInt8)
    }

    private static let pairingIdentifier = "5f8e0d34c1a749b6a2713e90d4c25f68"

    struct Command: Equatable {
        var label: String
        var destination: UInt8
        var commandSet: UInt8
        var commandID: UInt8
        var payload: Data
    }

    struct ConfigItem: Equatable {
        var name: String
        var value: Data
    }

    enum CaptureSettingUpdate: Equatable {
        case video(resolution: UInt8, frameRate: UInt8)
        case photo(size: UInt8, aspectRatio: UInt8)
        case fieldOfView(UInt8)
    }

    static let configSubscriptionNames = [
        "cam_video_param_v2",
        "cam_fov",
        "cam_photo_param_new",
    ]

    static func permitsAutomaticConnection(
        currentAdvertisementAwake: Bool?,
        passiveReconnectBlocked: Bool,
        hasUserInitiatedWakeIntent: Bool
    ) -> Bool {
        if hasUserInitiatedWakeIntent {
            return true
        }

        return currentAdvertisementAwake == true && !passiveReconnectBlocked
    }

    static func confirmsFreshPowerOn(
        previousAdvertisementAwake: Bool?,
        currentAdvertisementAwake: Bool?
    ) -> Bool {
        previousAdvertisementAwake == false && currentAdvertisementAwake == true
    }

    static func isAuthoritativeShootingModeReadback(
        commandSet: UInt8,
        commandID: UInt8,
        isResponse: Bool
    ) -> Bool {
        !isResponse && commandSet == 0x02 && commandID == 0x80
    }

    static func hasStableAwakeAdvertisement(
        isAwake: Bool?,
        observedSince: Date?,
        now: Date,
        minimumDuration: TimeInterval
    ) -> Bool {
        guard isAwake == true, let observedSince else { return false }
        return now.timeIntervalSince(observedSince) >= minimumDuration
    }

    static var wakeSequence: [Command] {
        [
            Command(
                label: "Nano session open",
                destination: sessionAddress,
                commandSet: 0x00,
                commandID: 0x2B,
                payload: Data([0x04, 0x00])
            ),
            Command(
                label: "Nano SetPairingPIN",
                destination: wifiAddress,
                commandSet: 0x07,
                commandID: 0x45,
                payload: pairingPayload
            ),
            Command(
                label: "Nano session keepalive",
                destination: sessionAddress,
                commandSet: 0x00,
                commandID: 0x2B,
                payload: Data([0x01, 0x01])
            ),
            Command(
                label: "Nano wake",
                destination: systemAddress,
                commandSet: 0x53,
                commandID: 0x10,
                payload: Data([0x00, 0x00, 0x00, 0x00])
            ),
        ]
    }

    static let keepAliveCommand = Command(
        label: "Nano session keepalive",
        destination: sessionAddress,
        commandSet: 0x00,
        commandID: 0x2B,
        payload: Data([0x01, 0x01])
    )

    static let sessionInfoCommand = Command(
        label: "Nano session info",
        destination: sessionInfoAddress,
        commandSet: 0x00,
        commandID: 0x32,
        payload: Data([0x31, 0x31, 0x00, 0x00, 0x00])
    )

    static func configSubscriptionCommands(startingAt firstSubscriptionID: UInt32) -> [Command] {
        configSubscriptionNames.enumerated().map { offset, name in
            Command(
                label: "Nano subscribe \(name)",
                destination: configAddress,
                commandSet: 0x00,
                commandID: 0x99,
                payload: configSubscriptionPayload(
                    name: name,
                    subscriptionID: firstSubscriptionID &+ UInt32(offset)
                )
            )
        }
    }

    static let appDeviceInfo = Data([
        0x00, 0x41, 0x50, 0x50,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0,
        0x02,
        0, 0, 0, 0, 0, 0, 0, 0,
        0x02, 0x08,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    ])

    static func frame(
        sequenceNumber: UInt16,
        source: UInt8 = appAddress,
        destination: UInt8,
        flags: UInt8 = 0x40,
        commandSet: UInt8,
        commandID: UInt8,
        payload: Data
    ) -> Data {
        let packetLength = UInt16(11 + payload.count + 2)
        let versionAndLength = packetLength | (1 << 10)
        var bytes = Data()

        bytes.append(0x55)
        bytes.append(UInt8(versionAndLength & 0xFF))
        bytes.append(UInt8((versionAndLength >> 8) & 0xFF))
        bytes.append(headerChecksum(for: bytes))
        bytes.append(source)
        bytes.append(destination)
        bytes.append(UInt8((sequenceNumber >> 8) & 0xFF))
        bytes.append(UInt8(sequenceNumber & 0xFF))
        bytes.append(flags)
        bytes.append(commandSet)
        bytes.append(commandID)
        bytes.append(payload)

        let checksum = packetChecksum(for: bytes)
        bytes.append(UInt8(checksum & 0xFF))
        bytes.append(UInt8((checksum >> 8) & 0xFF))
        return bytes
    }

    static func shootingModeByte(from statusPayload: Data) -> UInt8? {
        statusPayload.count > 57 ? statusPayload[statusPayload.index(statusPayload.startIndex, offsetBy: 57)] : nil
    }

    static func configItem(from payload: Data) -> ConfigItem? {
        guard payload.count >= 17,
              payload.byte(at: 0) == 0x02,
              payload.byte(at: 1) == 0x06,
              let nameLength = payload.littleEndianUInt16(at: 13) else {
            return nil
        }

        let nameStart = 15
        let nameEnd = nameStart + Int(nameLength)
        let valueLengthOffset = nameEnd + 6
        guard nameEnd <= payload.count,
              valueLengthOffset + 2 <= payload.count,
              let name = String(data: payload[nameStart ..< nameEnd], encoding: .utf8),
              let valueLength = payload.littleEndianUInt16(at: valueLengthOffset) else {
            return nil
        }

        let valueStart = valueLengthOffset + 2
        let valueEnd = valueStart + Int(valueLength)
        guard valueEnd <= payload.count else { return nil }
        return ConfigItem(name: name, value: Data(payload[valueStart ..< valueEnd]))
    }

    static func captureSettingUpdate(from item: ConfigItem) -> CaptureSettingUpdate? {
        switch item.name {
        case "cam_video_param_v2":
            guard let resolution = item.value.byte(at: 0),
                  let frameRate = item.value.byte(at: 1) else {
                return nil
            }
            return .video(resolution: resolution, frameRate: frameRate)
        case "cam_photo_param_new":
            guard let size = item.value.byte(at: 3),
                  let aspectRatio = item.value.byte(at: 4) else {
                return nil
            }
            return .photo(size: size, aspectRatio: aspectRatio)
        case "cam_fov":
            guard let fieldOfView = item.value.first else { return nil }
            return .fieldOfView(fieldOfView)
        default:
            return nil
        }
    }

    static func pairingStatus(fromSetPairingResponse payload: Data) -> PairingStatus? {
        guard payload.count >= 2 else { return nil }
        switch payload[payload.index(payload.startIndex, offsetBy: 1)] {
        case 0x01:
            return .alreadyPaired
        case 0x02:
            return .approvalRequired
        case let value:
            return .unexpected(value)
        }
    }

    private static var pairingPayload: Data {
        var payload = Data()
        appendPackedString(pairingIdentifier, to: &payload)
        appendPackedString(pairingToken, to: &payload)
        return payload
    }

    private static func appendPackedString(_ value: String, to data: inout Data) {
        let bytes = Data(value.utf8)
        precondition(bytes.count <= UInt8.max)
        data.append(UInt8(bytes.count))
        data.append(bytes)
    }

    private static func configSubscriptionPayload(name: String, subscriptionID: UInt32) -> Data {
        let nameBytes = Data(name.utf8)
        precondition(!nameBytes.isEmpty && nameBytes.count <= UInt8.max)

        var payload = Data([0x02, 0x02, 0x00, 0x00])
        payload.appendLittleEndian(subscriptionID)
        payload.append(contentsOf: [0x00, 0x00, 0x00])
        payload.appendLittleEndian(UInt16(nameBytes.count + 6))
        payload.appendLittleEndian(UInt16(nameBytes.count))
        payload.append(nameBytes)
        payload.append(contentsOf: [0x00, 0x00, 0x00, 0x00])
        return payload
    }

    private static func headerChecksum(for bytes: Data) -> UInt8 {
        bytes.reduce(UInt8(0x77)) { checksum, byte in
            crc8Maxim(checksum ^ byte)
        }
    }

    private static func packetChecksum(for bytes: Data) -> UInt16 {
        bytes.reduce(UInt16(0x3692)) { checksum, byte in
            crc16X25Step(checksum, byte: byte)
        }
    }

    private static func crc8Maxim(_ value: UInt8) -> UInt8 {
        var checksum = value
        for _ in 0 ..< 8 {
            if checksum & 0x01 == 0x01 {
                checksum = (checksum >> 1) ^ 0x8C
            } else {
                checksum >>= 1
            }
        }
        return checksum
    }

    private static func crc16X25Step(_ checksum: UInt16, byte: UInt8) -> UInt16 {
        var value = checksum ^ UInt16(byte)
        for _ in 0 ..< 8 {
            if value & 0x0001 == 0x0001 {
                value = (value >> 1) ^ 0x8408
            } else {
                value >>= 1
            }
        }
        return value
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8? {
        guard offset >= 0, offset < count else { return nil }
        return self[index(startIndex, offsetBy: offset)]
    }

    func littleEndianUInt16(at offset: Int) -> UInt16? {
        guard let low = byte(at: offset), let high = byte(at: offset + 1) else { return nil }
        return UInt16(low) | (UInt16(high) << 8)
    }

    mutating func appendLittleEndian(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendLittleEndian(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
