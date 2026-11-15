import Foundation
import Dispatch

public struct Hello: Equatable {
    public let protoVersion: UInt8
    public let clientVersion: UInt16
    public let deviceID: Data
    public let screenWidth: UInt16
    public let screenHeight: UInt16
    public let xdpi: UInt16
    public let ydpi: UInt16
    public let maxFPS: UInt8
    public let codecs: UInt8
    public let features: UInt8
    public let rotation: UInt8
    public let name: String

    public init(
        protoVersion: UInt8,
        clientVersion: UInt16,
        deviceID: Data,
        screenWidth: UInt16,
        screenHeight: UInt16,
        xdpi: UInt16,
        ydpi: UInt16,
        maxFPS: UInt8,
        codecs: UInt8,
        features: UInt8,
        rotation: UInt8,
        name: String
    ) {
        self.protoVersion = protoVersion
        self.clientVersion = clientVersion
        self.deviceID = deviceID
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.xdpi = xdpi
        self.ydpi = ydpi
        self.maxFPS = maxFPS
        self.codecs = codecs
        self.features = features
        self.rotation = rotation
        self.name = name
    }
}

public struct SessionConfig: Equatable {
    public let width: UInt16
    public let height: UInt16
    public let fps: UInt8
    public let codec: UInt8
    public let bitrate: UInt32
    public let rotation: UInt8
    public var inputCaps: UInt8

    public init(
        width: UInt16,
        height: UInt16,
        fps: UInt8,
        codec: UInt8,
        bitrate: UInt32,
        rotation: UInt8,
        inputCaps: UInt8 = 0
    ) {
        self.width = width
        self.height = height
        self.fps = fps
        self.codec = codec
        self.bitrate = bitrate
        self.rotation = rotation
        self.inputCaps = inputCaps
    }
}

public struct VideoHeader: Equatable, Sendable {
    public let codec: UInt8
    public let flags: UInt8
    public let frameID: UInt32
    public let captureTimestampMicros: UInt64
    public let reserved: UInt32

    public init(codec: UInt8, flags: UInt8, frameID: UInt32, captureTimestampMicros: UInt64, reserved: UInt32) {
        self.codec = codec
        self.flags = flags
        self.frameID = frameID
        self.captureTimestampMicros = captureTimestampMicros
        self.reserved = reserved
    }
}

public func encodeHello(_ hello: Hello) -> Data {
    precondition(hello.deviceID.count == 16, "deviceID must be 16 bytes")
    let nameBytes = Data(hello.name.utf8)
    precondition(nameBytes.count <= 255, "name must fit in 255 UTF-8 bytes")

    var payload = Data()
    payload.append(hello.protoVersion)
    payload.appendUInt16BE(hello.clientVersion)
    payload.append(hello.deviceID)
    payload.appendUInt16BE(hello.screenWidth)
    payload.appendUInt16BE(hello.screenHeight)
    payload.appendUInt16BE(hello.xdpi)
    payload.appendUInt16BE(hello.ydpi)
    payload.append(hello.maxFPS)
    payload.append(hello.codecs)
    payload.append(hello.features)
    payload.append(hello.rotation)
    payload.append(UInt8(nameBytes.count))
    payload.append(nameBytes)
    return encodeFrame(Frame(type: MessageType.hello.rawValue, payload: payload))
}

public func decodeHello(_ payload: Data) throws -> Hello {
    guard payload.count >= 32 else { throw FrameError.malformed }
    let nameLength = Int(payload[31])
    guard payload.count >= 32 + nameLength else { throw FrameError.malformed }
    let nameBytes = payload.subdata(in: 32..<(32 + nameLength))
    guard let name = String(data: nameBytes, encoding: .utf8) else { throw FrameError.malformed }

    return Hello(
        protoVersion: payload[0],
        clientVersion: payload.readUInt16BE(1),
        deviceID: payload.subdata(in: 3..<19),
        screenWidth: payload.readUInt16BE(19),
        screenHeight: payload.readUInt16BE(21),
        xdpi: payload.readUInt16BE(23),
        ydpi: payload.readUInt16BE(25),
        maxFPS: payload[27],
        codecs: payload[28],
        features: payload[29],
        rotation: payload[30],
        name: name
    )
}

public func encodeSessionConfig(_ config: SessionConfig) -> Data {
    var payload = Data()
    payload.appendUInt16BE(config.width)
    payload.appendUInt16BE(config.height)
    payload.append(config.fps)
    payload.append(config.codec)
    payload.appendUInt32BE(config.bitrate)
    payload.append(config.rotation)
    payload.append(config.inputCaps)
    return encodeFrame(Frame(type: MessageType.sessionConfig.rawValue, payload: payload))
}

public func decodeSessionConfig(_ payload: Data) throws -> SessionConfig {
    guard payload.count >= 11 else { throw FrameError.malformed }
    return SessionConfig(
        width: payload.readUInt16BE(0),
        height: payload.readUInt16BE(2),
        fps: payload[4],
        codec: payload[5],
        bitrate: payload.readUInt32BE(6),
        rotation: payload[10],
        inputCaps: payload.count >= 12 ? payload[11] : 0
    )
}

public func makeVideoFrame(_ header: VideoHeader, annexB: Data) -> Frame {
    var payload = Data(capacity: 18 + annexB.count)
    payload.append(header.codec)
    payload.append(header.flags)
    payload.appendUInt32BE(header.frameID)
    payload.appendUInt64BE(header.captureTimestampMicros)
    payload.appendUInt32BE(header.reserved)
    payload.append(annexB)
    return Frame(type: MessageType.video.rawValue, payload: payload)
}

public func encodeVideo(_ header: VideoHeader, annexB: Data) -> Data {
    encodeFrame(makeVideoFrame(header, annexB: annexB))
}

public func decodeVideo(_ payload: Data) throws -> (VideoHeader, Data) {
    guard payload.count >= 18 else { throw FrameError.malformed }
    let header = VideoHeader(
        codec: payload[0],
        flags: payload[1],
        frameID: payload.readUInt32BE(2),
        captureTimestampMicros: payload.readUInt64BE(6),
        reserved: payload.readUInt32BE(14)
    )
    return (header, payload.subdata(in: 18..<payload.count))
}

public func encodePing(timestamp: UInt64) -> Data {
    var payload = Data()
    payload.appendUInt64BE(timestamp)
    return encodeFrame(Frame(type: MessageType.ping.rawValue, payload: payload))
}

public func decodePing(_ payload: Data) throws -> UInt64 {
    guard payload.count >= 8 else { throw FrameError.malformed }
    return payload.readUInt64BE(0)
}

public func monotonicMicros() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds / 1000
}