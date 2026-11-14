import Foundation

public enum MessageType: UInt8 {
    case hello = 1
    case sessionConfig = 2
    case video = 3
    case input = 4
    case feedback = 5
    case ctrl = 6
    case ping = 7
    case bye = 8
}

public struct Frame: Equatable, Sendable {
    public let type: UInt8
    public let payload: Data

    public init(type: UInt8, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

public enum FrameError: Error, Equatable {
    case oversized
    case malformed
}

public func encodeFrame(_ frame: Frame) -> Data {
    var data = Data(capacity: 5 + frame.payload.count)
    data.appendUInt32BE(UInt32(frame.payload.count + 1))
    data.append(frame.type)
    data.append(frame.payload)
    return data
}

public struct FrameDecoder {
    public static let maxPayload = 8 * 1024 * 1024

    private var buffer = Data()

    public init() {}

    public mutating func append(_ data: Data) {
        buffer.append(data)
    }

    public mutating func next() throws -> Frame? {
        guard buffer.count >= 4 else { return nil }

        let length = buffer.readUInt32BE(0)
        guard length >= 1 else { throw FrameError.malformed }
        guard length <= UInt32(Self.maxPayload + 1) else { throw FrameError.oversized }

        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }

        let base = buffer.startIndex
        let type = buffer[base + 4]
        let payload = buffer.subdata(in: (base + 5)..<(base + total))
        buffer.removeFirst(total)
        return Frame(type: type, payload: payload)
    }
}

extension Data {
    mutating func appendUInt16BE(_ value: UInt16) {
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }

    mutating func appendUInt64BE(_ value: UInt64) {
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    func readUInt16BE(_ offset: Int) -> UInt16 {
        let base = startIndex + offset
        return (UInt16(self[base]) << 8) | UInt16(self[base + 1])
    }

    func readUInt32BE(_ offset: Int) -> UInt32 {
        let base = startIndex + offset
        return (UInt32(self[base]) << 24)
            | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8)
            | UInt32(self[base + 3])
    }

    func readUInt64BE(_ offset: Int) -> UInt64 {
        let base = startIndex + offset
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(self[base + index])
        }
        return value
    }
}