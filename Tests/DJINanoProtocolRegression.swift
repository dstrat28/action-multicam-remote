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

        print("DJI Nano protocol regression checks passed.")
    }

    private static func commandSignature(_ command: DJINanoProtocol.Command) -> String {
        String(format: "%02x:%02x:%02x:%@", command.destination, command.commandSet, command.commandID, hex(command.payload))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
