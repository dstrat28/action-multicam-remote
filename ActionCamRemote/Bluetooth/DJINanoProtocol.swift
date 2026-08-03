import Foundation

struct DJINanoProtocol {
    static let appAddress: UInt8 = 0x02
    static let cameraAddress: UInt8 = 0x01
    static let wifiAddress: UInt8 = 0x07
    static let systemAddress: UInt8 = 0x1C
    static let sessionAddress: UInt8 = 0xF0

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
