import Foundation

// Open GoPro preset_status.proto and request_get_preset_status.proto:
// https://github.com/gopro/OpenGoPro/tree/main/protobuf
// Decode only the fields needed for selection; skip unknown protobuf fields.
enum GoProPresetProtocol {
    static let requestPayload = Data([0xF5, 0x72, 0x08, 0x01, 0x08, 0x02, 0x18, 0x01, 0x20, 0x00])

    static func loadPayload(id: UInt32) -> Data {
        Data([0x40, 0x04, UInt8((id >> 24) & 0xFF), UInt8((id >> 16) & 0xFF),
              UInt8((id >> 8) & 0xFF), UInt8(id & 0xFF)])
    }

    static func isNotification(_ payload: Data) -> Bool {
        payload.starts(with: [0xF5, 0xF3])
    }

    static func presets(from payload: Data) -> [GoProPreset]? {
        guard payload.starts(with: [0xF5, 0xF2]), payload.count <= 65_535,
              let message = Fields(Data(payload.dropFirst(2))) else { return nil }
        var presets: [GoProPreset] = []
        var seen: Set<UInt32> = []
        for groupData in message.messages(1) {
            guard let group = Fields(groupData), let groupID = group.uint32(1) else { return nil }
            for presetData in group.messages(2) {
                guard let fields = Fields(presetData), let id = fields.uint32(1),
                      id <= Int32.max else { return nil }
                // Older firmware omits visibility. Only exclude explicit hidden entries.
                guard fields.integer(11) != 0 else { continue }
                guard seen.insert(id).inserted else { continue }
                let title = fields.integer(3)
                let customName = fields.string(10)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let number = fields.uint32(4) ?? 0
                let base = title.flatMap { titles[$0] } ?? "Preset \(id)"
                let name: String
                if title == 94, let customName, !customName.isEmpty {
                    name = customName
                } else {
                    name = base + (number > 0 ? " \(number)" : "")
                }
                presets.append(GoProPreset(
                    id: id, name: name, groupID: groupID,
                    mode: captureMode(flatMode: fields.integer(2), groupID: groupID),
                    isCustom: fields.integer(5) == 1
                ))
                guard presets.count <= 256 else { return nil }
            }
        }
        return presets
    }

    static func captureMode(flatMode: UInt64?, groupID: UInt32? = nil) -> CaptureMode? {
        // Match the camera's menu grouping, even when a Time Lapse preset outputs video.
        switch groupID {
        case 1000: return .video
        case 1001: return .photo
        case 1002: return .timelapse
        default: break
        }

        switch flatMode {
        case 12, 15, 22, 27, 32: return .video
        case 16, 17, 18, 19, 25: return .photo
        case 13, 20, 21, 24, 26, 29, 30, 31: return .timelapse
        default: return nil
        }
    }

    private static let titles: [UInt64: String] = [
        0: "Activity",
        1: "Standard",
        2: "Cinematic",
        3: "Photo",
        4: "Live Burst",
        5: "Burst",
        6: "Night",
        7: "TimeWarp",
        8: "Time Lapse",
        9: "Night Lapse",
        10: "Video",
        11: "Slo-Mo",
        13: "Photo",
        14: "Panorama",
        16: "TimeWarp",
        18: "Custom",
        19: "Air",
        20: "Bike",
        21: "Epic",
        22: "Indoor",
        23: "Motor",
        24: "Mounted",
        25: "Outdoor",
        26: "POV",
        27: "Selfie",
        28: "Skate",
        29: "Snow",
        30: "Trail",
        31: "Travel",
        32: "Water",
        33: "Looping",
        34: "Stars",
        35: "Action",
        36: "Follow Cam",
        37: "Surf",
        38: "City",
        39: "Shaky",
        40: "Chesty",
        41: "Helmet",
        42: "Bite",
        43: "Cinematic",
        44: "Vlog",
        45: "FPV",
        46: "HDR",
        47: "Landscape",
        48: "Log",
        49: "Slo-Mo",
        50: "Tripod",
        58: "Basic",
        59: "Ultra Slo-Mo",
        60: "Standard Endurance",
        61: "Activity Endurance",
        62: "Cinematic Endurance",
        63: "Slomo Endurance",
        64: "Stationary 1",
        65: "Stationary 2",
        66: "Stationary 3",
        67: "Stationary 4",
        68: "Video",
        69: "TimeWarp",
        70: "SuperPhoto",
        71: "Night Photo",
        72: "Simple Video Endurance",
        73: "Highest Quality",
        74: "Extended Battery",
        75: "Longest Battery",
        76: "Star Trails",
        77: "Light Painting",
        78: "Vehicle Lights",
        79: "Full Frame",
        82: "Standard Quality Video",
        83: "Basic Quality Video",
        93: "Highest Quality Video",
        94: "Custom",
        99: "Easy Standard Profile",
        100: "Easy Hdr Profile",
        106: "Burst Slomo",
        125: "4 3 Video",
        126: "16 9 Video",
        127: "16 9 Slomo",
        131: "Time Lapse Video",
        132: "Time Lapse Photo",
        133: "Night Lapse Video",
        134: "Night Lapse Photo",
    ]

    private struct Fields {
        private var integers: [Int: UInt64] = [:]
        private var bytes: [Int: [Data]] = [:]

        init?(_ data: Data) {
            let data = Array(data)
            var offset = 0
            func varint() -> UInt64? {
                var value: UInt64 = 0
                for index in 0..<10 {
                    guard offset < data.count else { return nil }
                    let byte = data[offset]
                    offset += 1
                    guard index < 9 || byte <= 1 else { return nil }
                    value |= UInt64(byte & 0x7F) << (index * 7)
                    if byte & 0x80 == 0 { return value }
                }
                return nil
            }
            while offset < data.count {
                guard let tag = varint(), tag >> 3 > 0, tag >> 3 <= 0x1FFF_FFFF else { return nil }
                let field = Int(tag >> 3)
                switch tag & 7 {
                case 0:
                    guard let value = varint() else { return nil }
                    integers[field] = value
                case 1, 5:
                    let count = tag & 7 == 1 ? 8 : 4
                    guard count <= data.count - offset else { return nil }
                    offset += count
                case 2:
                    guard let length = varint(), length <= data.count - offset else { return nil }
                    let end = offset + Int(length)
                    bytes[field, default: []].append(Data(data[offset..<end]))
                    offset = end
                default: return nil
                }
            }
        }

        func integer(_ field: Int) -> UInt64? { integers[field] }
        func uint32(_ field: Int) -> UInt32? { integers[field].flatMap(UInt32.init(exactly:)) }
        func messages(_ field: Int) -> [Data] { bytes[field] ?? [] }
        func string(_ field: Int) -> String? {
            bytes[field]?.last.flatMap { String(data: $0, encoding: .utf8) }
        }
    }
}
