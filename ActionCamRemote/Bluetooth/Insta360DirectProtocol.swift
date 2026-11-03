// Adapted from AndreySemjonov/X6-Watch-Remote (MIT), commit 4ea62293d706210236cef63fb0ce488549b7bbcb.
// UCD2 framing also derives from diamondfsd/luna-ai-cut (MIT).
// See THIRD_PARTY_NOTICES.md for copyright and license notices.

import Foundation

enum Insta360DirectProfile {
    case x5, x6

    var name: String { self == .x5 ? "X5" : "X6" }
    var maximumMessageID: UInt32 { self == .x5 ? 0xffffff : 0x3fffffff }

    func encode(_ command: Insta360DirectCommand, id: UInt32, sequence: UInt8) throws -> [UInt8] {
        switch self {
        case .x5: return try Insta360X5Protocol.encode(command, id: id)
        case .x6: return try Insta360X6Protocol.encode(command, id: id, sequence: sequence)
        }
    }
}

/// Original implementation of the X5 network framing documented with live
/// captures by soul667/insta360-x5-toolkit. X5 does not use X6's UCD2 envelope.
enum Insta360X5Protocol {
    static let sync: [UInt8] = [17, 0, 0, 0, 6, 0, 0] + Array("syNceNdinS".utf8)
    static let heartbeat: [UInt8] = [7, 0, 0, 0, 5, 0, 0]

    static func encode(_ command: Insta360DirectCommand, id: UInt32) throws -> [UInt8] {
        guard (1...0xffffff).contains(id), command != .telemetry else { throw Insta360DirectProtocolError.invalidIdentifier }
        return [16, 0, 0, 0, 4, 0, 0, UInt8(truncatingIfNeeded: command.rawValue),
            UInt8(command.rawValue >> 8), 2, UInt8(truncatingIfNeeded: id),
            UInt8(truncatingIfNeeded: id >> 8), UInt8(truncatingIfNeeded: id >> 16), 0x80, 0, 0]
    }
}

struct Insta360X5Decoder {
    private var buffer: [UInt8] = []
    mutating func reset() { buffer.removeAll(keepingCapacity: true) }

    mutating func feed(_ chunk: [UInt8]) throws -> [Insta360DirectMessage] {
        guard chunk.count <= 131_104 else { reset(); throw Insta360DirectProtocolError.invalidLength }
        buffer += chunk
        do {
            var messages: [Insta360DirectMessage] = []
            while buffer.count >= 4 {
                let count = Int(Insta360X6Protocol.uint32(buffer, 0))
                guard (7...65_552).contains(count) else { throw Insta360DirectProtocolError.invalidLength }
                guard buffer.count >= count else { break }
                let frame = Array(buffer.prefix(count))
                buffer.removeFirst(count)
                switch frame[4] {
                case 4:
                    guard count >= 16, frame[9] == 2, frame[13] & 0x80 != 0 else {
                        throw Insta360DirectProtocolError.invalidHeader
                    }
                    let id = UInt32(frame[10]) | UInt32(frame[11]) << 8 | UInt32(frame[12]) << 16
                    messages.append(Insta360DirectMessage(code: UInt16(frame[7]) | UInt16(frame[8]) << 8,
                        id: id, body: Array(frame.dropFirst(16)), type: 4))
                case 5:
                    guard frame == Insta360X5Protocol.heartbeat else { throw Insta360DirectProtocolError.invalidHeader }
                    messages.append(Insta360DirectMessage(code: 0, id: 0, body: [], type: 5))
                case 6:
                    guard frame == Insta360X5Protocol.sync else { throw Insta360DirectProtocolError.invalidHeader }
                    messages.append(Insta360DirectMessage(code: 0, id: 0, body: [], type: 6))
                default:
                    // The reference observes bounded type-9 events with unknown meaning.
                    continue
                }
            }
            return messages
        } catch { reset(); throw error }
    }
}

enum Insta360DirectProtocolError: Error, Equatable, LocalizedError {
    case invalidHeader, invalidLength, checksumMismatch, unsupportedFragment, malformedProtobuf
    case invalidIdentifier, missingStatus, cameraRejected(UInt16)
    var errorDescription: String? {
        switch self {
        case .cameraRejected(let code): return "Camera returned error \(code)."
        default: return "Unrecognized camera response (\(self))."
        }
    }
}

struct Insta360DirectMessage: Equatable, Sendable {
    let code: UInt16
    let id: UInt32
    let body: [UInt8]
    let type: UInt8
}

enum Insta360DirectCommand: UInt16, Sendable {
    case start = 4, stop = 5, telemetry = 8, status = 15
    /// GET_OPTIONS: repeated option_types, BATTERY_STATUS=11, STORAGE_STATE=20.
    /// GET_OPTIONS: BATTERY_STATUS=11, STORAGE_STATE=20 (the storage the camera
    /// records to) and 176, the X6's list of all storages (internal and SD).
    var requestBody: [UInt8] { self == .telemetry ? [0x08, 11, 0x08, 20, 0x08, 0xb0, 0x01] : [] }
}

enum Insta360X6Protocol {
    static let maximumPayload = 65_536
    static func checksum(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<32 {
                let high = crc & 0x80000000 != 0
                crc = (crc &<< 1) ^ (high ? 0x04c11db7 : 0)
            }
        }
        return crc
    }

    static func encode(_ command: Insta360DirectCommand, id: UInt32, sequence: UInt8) throws -> [UInt8] {
        guard id > 0 && id <= 0x3fffffff else { throw Insta360DirectProtocolError.invalidIdentifier }
        var bytes: [UInt8] = [0x55, 0x43, 0x44, 0x32, 1, 12, 4, sequence]
        bytes += little(UInt32(9 + command.requestBody.count))
        bytes += little(UInt32(command.rawValue), count: 2) + [2]
        bytes += little(id | 0x80000000) + [0, 0]
        bytes += command.requestBody
        bytes += little(checksum(bytes))
        return bytes
    }

    static func little(_ value: UInt32, count: Int = 4) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) }
    }
    static func uint32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | (UInt32(bytes[offset + $1]) << ($1 * 8)) }
    }
}

struct Insta360X6Decoder: Sendable {
    private var buffer: [UInt8] = []
    init() {}
    mutating func reset() { buffer.removeAll(keepingCapacity: true) }
    mutating func feed(_ chunk: [UInt8]) throws -> [Insta360DirectMessage] {
        // Bound a single input too, before allocation. Typical ATT input <= 514 bytes.
        guard chunk.count <= (Insta360X6Protocol.maximumPayload + 16) * 2 else {
            reset(); throw Insta360DirectProtocolError.invalidLength
        }
        buffer += chunk
        do {
            var messages: [Insta360DirectMessage] = []
            while buffer.count >= 12 {
                guard Array(buffer[0..<4]) == [0x55, 0x43, 0x44, 0x32], buffer[4] == 1,
                      buffer[5] == 12, [4, 5].contains(buffer[6]) else { throw Insta360DirectProtocolError.invalidHeader }
                let length = Int(Insta360X6Protocol.uint32(buffer, 8))
                guard (9...Insta360X6Protocol.maximumPayload).contains(length) else { throw Insta360DirectProtocolError.invalidLength }
                let total = 12 + length + 4
                guard buffer.count >= total else { break }
                let packet = Array(buffer.prefix(total))
                buffer.removeFirst(total)
                guard Insta360X6Protocol.checksum(Array(packet.dropLast(4))) == Insta360X6Protocol.uint32(packet, total - 4) else {
                    throw Insta360DirectProtocolError.checksumMismatch
                }
                let flags = Insta360X6Protocol.uint32(packet, 15)
                guard packet[14] == 2, flags & 0x80000000 != 0 else { throw Insta360DirectProtocolError.unsupportedFragment }
                messages.append(Insta360DirectMessage(code: UInt16(packet[12]) | UInt16(packet[13]) << 8,
                    id: flags & 0x3fffffff, body: Array(packet[21..<(total - 4)]), type: packet[6]))
            }
            return messages
        } catch {
            reset()
            throw error
        }
    }
}


enum Insta360DirectProtobufValue: Equatable, Sendable { case integer(UInt64), bytes([UInt8]), fixed([UInt8]) }

enum Insta360DirectProtobuf {
    static func fields(_ bytes: [UInt8]) throws -> [Int: [Insta360DirectProtobufValue]] {
        var offset = 0
        func varint() throws -> UInt64 {
            var value: UInt64 = 0
            for index in 0..<10 {
                guard offset < bytes.count else { throw Insta360DirectProtocolError.malformedProtobuf }
                let byte = bytes[offset]; offset += 1
                if index == 9 && byte > 1 { throw Insta360DirectProtocolError.malformedProtobuf }
                value |= UInt64(byte & 127) << (index * 7)
                if byte < 128 { return value }
            }
            throw Insta360DirectProtocolError.malformedProtobuf
        }
        var result: [Int: [Insta360DirectProtobufValue]] = [:]
        while offset < bytes.count {
            let tag = try varint()
            guard tag >> 3 > 0, tag >> 3 <= 0x1fffffff else { throw Insta360DirectProtocolError.malformedProtobuf }
            let number = Int(tag >> 3), wire = tag & 7
            let value: Insta360DirectProtobufValue
            if wire == 0 { value = .integer(try varint()) }
            else if [1, 2, 5].contains(wire) {
                let length: UInt64 = wire == 2 ? try varint() : (wire == 1 ? 8 : 4)
                guard length <= UInt64(bytes.count - offset) else { throw Insta360DirectProtocolError.malformedProtobuf }
                let data = Array(bytes[offset..<(offset + Int(length))])
                value = wire == 2 ? .bytes(data) : .fixed(data)
                offset += Int(length)
            } else { throw Insta360DirectProtocolError.malformedProtobuf }
            result[number, default: []].append(value)
        }
        return result
    }
}

enum Insta360DirectRecordingState: String, Sendable, Codable { case stopped, recording, unknown }

struct Insta360DirectCaptureStatus: Equatable, Sendable {
    let rawState: UInt64?
    let elapsed: UInt64?
    var recording: Insta360DirectRecordingState {
        switch rawState { case 0: return .stopped; case 1: return .recording; default: return .unknown }
    }
    init(rawState: UInt64?, elapsed: UInt64?) { self.rawState = rawState; self.elapsed = elapsed }
    static func decodeResponse(_ bytes: [UInt8]) throws -> Insta360DirectCaptureStatus {
        let outer = try Insta360DirectProtobuf.fields(bytes)
        guard outer[1]?.count == 1, case .bytes(let nested) = outer[1]?.first else { throw Insta360DirectProtocolError.missingStatus }
        return try decodeFields(nested)
    }
    static func decodeNotification(_ bytes: [UInt8]) throws -> Insta360DirectCaptureStatus { try decodeFields(bytes) }
    private static func decodeFields(_ bytes: [UInt8]) throws -> Insta360DirectCaptureStatus {
        let fields = try Insta360DirectProtobuf.fields(bytes)
        func integer(_ key: Int) throws -> UInt64? {
            guard let values = fields[key] else { return nil }
            guard values.count == 1, case .integer(let value) = values[0] else { throw Insta360DirectProtocolError.malformedProtobuf }
            return value
        }
        return try Insta360DirectCaptureStatus(rawState: integer(1), elapsed: integer(2))
    }
}


/// Read-only schema from the Insta360 protobuf descriptors. X6 values still
/// require comparison with the physical camera; never infer a missing reading.
struct Insta360X6Telemetry: Equatable, Sendable {
    /// One storage from the X6's storage list (option 176). Locations observed on
    /// the X6 (fw 1.1.7): 2 = internal, 3 = SD card; 1 (card reader) is ignored.
    struct Storage: Equatable, Sendable {
        let location: UInt64
        let state: UInt64
        let freeBytes: UInt64?
        let totalBytes: UInt64?
        init(location: UInt64, state: UInt64, freeBytes: UInt64?, totalBytes: UInt64?) {
            self.location = location; self.state = state
            self.freeBytes = freeBytes; self.totalBytes = totalBytes
        }
        var name: String {
            switch location {
            case 2: return "Internal"
            case 3: return "SD card"
            default: return "Storage"
            }
        }
    }

    let batteryPercent: Int?
    /// The storage the camera records to (option 20 follows the camera setting).
    let freeBytes: UInt64?
    let totalBytes: UInt64?
    let cardState: UInt64?
    let storageLocation: UInt64?
    let storages: [Storage]
    init(batteryPercent: Int? = nil, freeBytes: UInt64? = nil,
                totalBytes: UInt64? = nil, cardState: UInt64? = nil,
                storageLocation: UInt64? = nil, storages: [Storage] = []) {
        self.batteryPercent = batteryPercent; self.freeBytes = freeBytes
        self.totalBytes = totalBytes; self.cardState = cardState
        self.storageLocation = storageLocation; self.storages = storages
    }

    static func decodeResponse(_ body: [UInt8]) throws -> Self {
        let envelope = try Insta360DirectProtobuf.fields(body)
        guard let bytes = try nested(envelope, 2) else { throw Insta360DirectProtocolError.missingStatus }
        let options = try Insta360DirectProtobuf.fields(bytes)
        let battery = try nested(options, 11).map { try decodeBattery($0) } ?? nil
        var free: UInt64?, total: UInt64?, state: UInt64?, activeLocation: UInt64?
        if let storage = try nested(options, 20), let entry = try decodeStorage(storage) {
            state = entry.state == 0 && entry.totalBytes == nil ? nil : entry.state
            free = entry.freeBytes; total = entry.totalBytes
            activeLocation = entry.location
        }
        var storages: [Storage] = []
        for value in options[176] ?? [] {
            guard case .bytes(let bytes) = value else { throw Insta360DirectProtocolError.malformedProtobuf }
            if let entry = try decodeStorage(bytes) { storages.append(entry) }
        }
        return Self(batteryPercent: battery, freeBytes: free, totalBytes: total, cardState: state,
                    storageLocation: activeLocation, storages: storages)
    }

    /// Location 1 is a card reader (card not usable by the camera) and is ignored.
    /// The X6 (fw 1.1.7) reports internal storage as 2 and its SD card as 3, not 0
    /// (captured 2026-09-27), so every other location counts as camera storage.
    private static func decodeStorage(_ bytes: [UInt8]) throws -> Storage? {
        let fields = try Insta360DirectProtobuf.fields(bytes)
        // Proto3 omits zero-valued scalars. A positive capacity establishes
        // that omitted free_space really means zero, rather than no data.
        let location = try integer(fields, 4) ?? 0
        let rawState = try integer(fields, 1) ?? 0
        let capacity = try integer(fields, 3)
        let available = try integer(fields, 2) ?? 0
        guard location != 1, rawState <= 5 else { return nil }
        if rawState == 0, (capacity ?? 0) == 0 { return Storage(location: location, state: 0, freeBytes: nil, totalBytes: nil) }
        if [0, 2].contains(rawState), let capacity, capacity > 0, available <= capacity {
            return Storage(location: location, state: rawState, freeBytes: available, totalBytes: capacity)
        }
        return Storage(location: location, state: rawState, freeBytes: nil, totalBytes: nil)
    }

    static func decodeBatteryNotification(_ body: [UInt8]) throws -> Int? {
        guard let battery = try nested(Insta360DirectProtobuf.fields(body), 1) else { return nil }
        return try decodeBattery(battery)
    }

    private static func decodeBattery(_ body: [UInt8]) throws -> Int? {
        let fields = try Insta360DirectProtobuf.fields(body)
        guard try integer(fields, 4) != 100 else { return nil }
        let reportedLevel = try integer(fields, 2)
        // Captured X6 v1.1.7 battery event 0a0408001064 omits scale and reports
        // explicit level=100. Treat an explicit 0...100 as percent on this profile.
        guard let scale = try integer(fields, 3) else {
            guard let level = reportedLevel, level <= 100 else { return nil }
            return Int(level)
        }
        guard scale > 0, scale <= UInt32.max else { return nil }
        let level = reportedLevel ?? 0 // proto3 zero, only with explicit valid scale
        guard level <= scale else { return nil }
        return Int((level * 100 + scale / 2) / scale)
    }

    private static func integer(_ fields: [Int: [Insta360DirectProtobufValue]], _ key: Int) throws -> UInt64? {
        guard let values = fields[key] else { return nil }
        guard values.count == 1, case .integer(let number) = values[0] else { throw Insta360DirectProtocolError.malformedProtobuf }
        return number
    }
    private static func nested(_ fields: [Int: [Insta360DirectProtobufValue]], _ key: Int) throws -> [UInt8]? {
        guard let values = fields[key] else { return nil }
        guard values.count == 1, case .bytes(let bytes) = values[0] else { throw Insta360DirectProtocolError.malformedProtobuf }
        return bytes
    }
}
