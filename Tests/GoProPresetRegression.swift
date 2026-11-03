import Foundation

@main
enum GoProPresetRegression {
    static func main() throws {
        // Field numbers and values from GoPro's preset_status.proto. IDs are
        // deliberately unrelated to mode so selection cannot infer IDs.
        let standard = field(1, 873) + field(2, 12) + field(3, 1)
        let helmet = field(1, 91_234) + field(2, 12) + field(3, 94)
            + field(5, 1) + message(10, Data("Helmet · Café".utf8))
        let custom = field(1, 99_876) + field(2, 27) + field(3, 18) + field(4, 3) + field(5, 1)
        let hidden = field(1, 432) + field(2, 12) + field(3, 2) + field(11, 0)
        let video = field(1, 1000) + message(2, standard) + message(2, helmet)
            + message(2, custom) + message(2, hidden)
        let photo = field(1, 1001) + message(2, field(1, 777) + field(2, 19) + field(3, 5))
        let general = field(1, 2000) + message(2, field(1, 888) + field(2, 24) + field(3, 7))
        let response = Data([0xF5, 0xF2]) + message(1, video) + message(1, photo) + message(1, general)
        let presets = GoProPresetProtocol.presets(from: response)!
        precondition(presets.map(\.id) == [873, 91_234, 99_876, 777, 888])
        precondition(presets.map(\.name) == ["Standard", "Helmet · Café", "Custom 3", "Burst", "TimeWarp"])
        precondition(presets.map(\.mode) == [.video, .video, .video, .photo, .timelapse])
        precondition(presets[1].isCustom && !presets[0].isCustom)
        precondition(GoProPresetProtocol.loadPayload(id: 91_234) == Data([0x40, 0x04, 0, 1, 0x64, 0x62]))
        precondition(GoProPresetProtocol.requestPayload == Data([0xF5, 0x72, 8, 1, 8, 2, 24, 1, 32, 0]))

        // Night Effects produce video files but belong to the camera's Time Lapse group.
        let nightEffects = [(29, 76, "Star Trails"), (30, 77, "Light Painting"), (31, 78, "Vehicle Lights")]
        let nightEffectPresets = nightEffects.map { flatMode, title, _ in
            message(2, field(1, UInt64(10_000 + flatMode)) + field(2, UInt64(flatMode))
                + field(3, UInt64(title)))
        }.reduce(Data(), +)
        let timeLapseResponse = Data([0xF5, 0xF2])
            + message(1, field(1, 1002) + nightEffectPresets)
        let parsedNightEffects = GoProPresetProtocol.presets(from: timeLapseResponse)!
        precondition(parsedNightEffects.map(\.name) == nightEffects.map { $0.2 })
        precondition(parsedNightEffects.allSatisfy { $0.mode == .timelapse && $0.groupID == 1002 },
                     "Night Effects must remain in the camera's Time Lapse group")

        // A recognized camera group takes precedence over a preset's flat mode.
        for (groupID, expectedMode) in [(1000, CaptureMode.video), (1001, .photo), (1002, .timelapse)] {
            let groupedResponse = Data([0xF5, 0xF2]) + message(1, field(1, UInt64(groupID))
                + message(2, field(1, 123) + field(2, 12) + field(3, 1))
                + message(2, field(1, 124) + field(2, 999) + field(3, 18))
                + message(2, field(1, 125) + field(3, 18)))
            precondition(GoProPresetProtocol.presets(from: groupedResponse)?.map(\.mode)
                         == Array(repeating: expectedMode, count: 3))
        }

        // General and unknown groups fall back to flat mode, including Night Effects.
        for groupID: UInt64 in [2000, 3000] {
            let flatResponse = Data([0xF5, 0xF2]) + message(1, field(1, groupID) + nightEffectPresets
                + message(2, field(1, 200) + field(2, 12) + field(3, 1))
                + message(2, field(1, 201) + field(2, 16) + field(3, 3))
                + message(2, field(1, 202) + field(2, 24) + field(3, 7))
                + message(2, field(1, 203) + field(2, 999) + field(3, 18)))
            precondition(GoProPresetProtocol.presets(from: flatResponse)?.map(\.mode)
                         == [.timelapse, .timelapse, .timelapse, .video, .photo, .timelapse, nil])
        }

        // A camera with one general group still exposes modes per preset.
        let unknown = Data([0xF5, 0xF2]) + message(1, field(1, 2000)
            + message(2, field(1, 42) + field(2, 12) + field(3, 999)))
        precondition(GoProPresetProtocol.presets(from: unknown)?.first?.name == "Preset 42")
        precondition(GoProPresetProtocol.presets(from: unknown)?.first?.mode == .video)
        precondition(GoProPresetProtocol.presets(from: Data([0xF5, 0xF2])) == [])
        precondition(GoProPresetProtocol.isNotification(Data([0xF5, 0xF3])))
        precondition(GoProPresetProtocol.presets(from: Data([0xF5, 0xF3])) == nil,
                     "A partial notification must trigger a full refresh, not replace the catalog")
        let unknownFields = field(100, 999) + message(101, Data([1, 2, 3]))
            + Data([0xB5, 0x06, 0, 0, 0, 0]) // unknown fixed32 field 102
        precondition(GoProPresetProtocol.presets(from: response + unknownFields) == presets)
        let singleGroup = Data([0xF5, 0xF2]) + message(1, video)
        for length in 3..<singleGroup.count {
            precondition(GoProPresetProtocol.presets(from: Data(singleGroup.prefix(length))) == nil)
        }
        for invalid in [
            Data([0xF5]), Data([0xF5, 0xF2, 0]), Data([0xF5, 0xF2, 0x0A, 0xFF]),
            Data([0xF5, 0xF2, 0x08] + Array(repeating: UInt8(0xFF), count: 11)),
            Data([0xF5, 0xF2, 0x0B])
        ] {
            precondition(GoProPresetProtocol.presets(from: invalid) == nil)
        }

        // Exercise the client's real BLE reassembler, including continuation
        // counter wrap and a response larger than a one-byte packet header.
        let largeResponse = response + message(100, Data(repeating: 0xA5, count: 600))
        let framed = GoProPacket.packetize(largeResponse)
        var reassembler = GoProPacketReassembler()
        precondition(reassembler.append(Data(framed.prefix(20))).isEmpty)
        var offset = 20
        var counter: UInt8 = 0
        var assembled: [Data] = []
        while offset < framed.count {
            let end = min(offset + 19, framed.count)
            assembled += reassembler.append(Data([0x80 | counter]) + framed[offset..<end])
            counter = (counter + 1) & 0x0F
            offset = end
        }
        precondition(assembled == [largeResponse])
        precondition(GoProPresetProtocol.presets(from: assembled[0]) == presets)
        _ = reassembler.append(Data(framed.prefix(20)))
        precondition(reassembler.append(Data([0x81, 0])).isEmpty)
        precondition(reassembler.append(Data([0x80, 0])).isEmpty,
                     "A missing fragment must discard the response")

        // Changing presets cancels stale unsent capture/mode intent, while
        // retaining status queries, Stop, and the latest chosen preset.
        var queue = GoProCommandQueue<String>()
        queue.deferUntilIdle(.setMode(.photo))
        queue.append("query")
        queue.append("start", command: .startRecording)
        queue.append("photo", command: .capturePhoto)
        queue.append("stop", command: .stopRecording)
        let load = CameraCommand.loadGoProPreset(id: 91_234, name: "Helmet · Café")
        queue.prepare(for: load)
        queue.append("old preset", command: load)
        queue.prepare(for: load)
        queue.append("latest preset", command: load)
        precondition(!queue.hasPendingStart && queue.takeDeferredCommand(isBusy: false) == nil)
        precondition(queue.removeFirst() == "query")
        precondition(queue.removeFirst() == "stop")
        precondition(queue.removeFirst() == "latest preset" && queue.isEmpty)
        let restoredCommand = try JSONDecoder().decode(CameraCommand.self, from: JSONEncoder().encode(load))
        precondition(restoredCommand == load)
        print("GoPro preset checks passed: dynamic IDs/names, camera groups, Night Effects, flat-mode fallback, hidden presets, unknown fields, malformed data, BLE fragmentation, and safe command ordering.")
    }

    private static func varint(_ value: UInt64) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            let byte = UInt8(value & 0x7F)
            value >>= 7
            bytes.append(byte | (value == 0 ? 0 : 0x80))
        } while value != 0
        return bytes
    }

    private static func field(_ number: UInt64, _ value: UInt64) -> Data {
        varint(number << 3) + varint(value)
    }

    private static func message(_ number: UInt64, _ value: Data) -> Data {
        varint(number << 3 | 2) + varint(UInt64(value.count)) + value
    }
}
