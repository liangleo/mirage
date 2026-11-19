import Foundation

public enum UdpFlags {
    public static let sof: UInt8 = 1 << 0
    public static let eof: UInt8 = 1 << 1
    public static let key: UInt8 = 1 << 2
    public static let nack: UInt8 = 1 << 3
    public static let hello: UInt8 = 1 << 4
    public static let parity: UInt8 = 1 << 5
}

public enum UdpCipher: UInt8, Equatable, Sendable {
    case aes256GCM = 1
    case chaCha20Poly1305 = 2
}

public enum UdpError: Error, Equatable {
    case malformed
    case payloadTooLarge
}

public struct UdpVideoHeader: Equatable, Sendable {
    public static let size = 24
    public static let maxPayload = 1200
    public static let maxDatagramPayload = maxPayload + 16

    public let seq: UInt32
    public let frameID: UInt32
    public let fragIndex: UInt16
    public let fragCount: UInt16
    public let flags: UInt8
    public let reserved: UInt8
    public let payloadLength: UInt16
    /// 采集时间戳（微秒）：UDP 帧没有 TCP 的 VIDEO 头，用它恢复 e2e/p95。
    public let captureTsMicros: UInt64

    public init(
        seq: UInt32,
        frameID: UInt32,
        fragIndex: UInt16,
        fragCount: UInt16,
        flags: UInt8,
        reserved: UInt8 = 0,
        payloadLength: UInt16,
        captureTsMicros: UInt64 = 0
    ) {
        self.seq = seq
        self.frameID = frameID
        self.fragIndex = fragIndex
        self.fragCount = fragCount
        self.flags = flags
        self.reserved = reserved
        self.payloadLength = payloadLength
        self.captureTsMicros = captureTsMicros
    }

    public var isNack: Bool { flags & UdpFlags.nack != 0 }
    public var isHello: Bool { flags & UdpFlags.hello != 0 }
    public var isKeyFrame: Bool { flags & UdpFlags.key != 0 }
    public var isSOF: Bool { flags & UdpFlags.sof != 0 }
    public var isEOF: Bool { flags & UdpFlags.eof != 0 }
}

public struct UdpDatagram: Equatable, Sendable {
    public let header: UdpVideoHeader
    public let payload: Data

    public init(header: UdpVideoHeader, payload: Data) {
        self.header = header
        self.payload = payload
    }
}

public func encodeUdpHeader(_ header: UdpVideoHeader) -> Data {
    var data = Data(capacity: UdpVideoHeader.size)
    data.appendUInt32BE(header.seq)
    data.appendUInt32BE(header.frameID)
    data.appendUInt16BE(header.fragIndex)
    data.appendUInt16BE(header.fragCount)
    data.append(header.flags)
    data.append(header.reserved)
    data.appendUInt16BE(header.payloadLength)
    data.appendUInt64BE(header.captureTsMicros)
    return data
}

public func encodeUdpDatagram(_ datagram: UdpDatagram) throws -> Data {
    let payload = datagram.payload
    guard payload.count <= UdpVideoHeader.maxDatagramPayload else { throw UdpError.payloadTooLarge }
    guard datagram.header.payloadLength == UInt16(payload.count) else { throw UdpError.malformed }

    var data = encodeUdpHeader(datagram.header)
    data.append(payload)
    return data
}

public func decodeUdpDatagram(_ data: Data) throws -> UdpDatagram {
    guard data.count >= UdpVideoHeader.size else { throw UdpError.malformed }
    let payloadLength = Int(data.readUInt16BE(14))
    guard payloadLength <= UdpVideoHeader.maxDatagramPayload else { throw UdpError.payloadTooLarge }
    guard data.count == UdpVideoHeader.size + payloadLength else { throw UdpError.malformed }

    let header = UdpVideoHeader(
        seq: data.readUInt32BE(0),
        frameID: data.readUInt32BE(4),
        fragIndex: data.readUInt16BE(8),
        fragCount: data.readUInt16BE(10),
        flags: data[12],
        reserved: data[13],
        payloadLength: UInt16(payloadLength),
        captureTsMicros: data.readUInt64BE(16)
    )
    guard header.fragCount > 0 else { throw UdpError.malformed }
    if header.isNack {
        guard payloadLength == Int(header.fragCount) else { throw UdpError.malformed }
    } else {
        guard header.fragIndex < header.fragCount else { throw UdpError.malformed }
    }
    return UdpDatagram(header: header, payload: data.subdata(in: UdpVideoHeader.size..<data.count))
}

public func encodeUdpNack(seq: UInt32, frameID: UInt32, bitmapStart: UInt16, bitmap: Data) throws -> Data {
    guard !bitmap.isEmpty else { throw UdpError.malformed }
    let header = UdpVideoHeader(
        seq: seq,
        frameID: frameID,
        fragIndex: bitmapStart,
        fragCount: UInt16(bitmap.count),
        flags: UdpFlags.nack,
        payloadLength: UInt16(bitmap.count)
    )
    return try encodeUdpDatagram(UdpDatagram(header: header, payload: bitmap))
}

public struct Feedback: Equatable, Sendable {
    public static let size = 28

    public let fpsX10: UInt16
    public let decodeMS: UInt16
    public let droppedFrames: UInt16
    public let queueDepth: UInt16
    public let rttMS: UInt16
    public let lossPermille: UInt16
    public let recvBitrateBps: UInt32
    public let arrivalDelayMS: UInt32
    public let timestampMicros: UInt64

    public init(
        fpsX10: UInt16,
        decodeMS: UInt16,
        droppedFrames: UInt16,
        queueDepth: UInt16,
        rttMS: UInt16,
        lossPermille: UInt16,
        recvBitrateBps: UInt32,
        arrivalDelayMS: UInt32,
        timestampMicros: UInt64
    ) {
        self.fpsX10 = fpsX10
        self.decodeMS = decodeMS
        self.droppedFrames = droppedFrames
        self.queueDepth = queueDepth
        self.rttMS = rttMS
        self.lossPermille = lossPermille
        self.recvBitrateBps = recvBitrateBps
        self.arrivalDelayMS = arrivalDelayMS
        self.timestampMicros = timestampMicros
    }
}

public func encodeFeedback(_ feedback: Feedback) -> Frame {
    var payload = Data(capacity: Feedback.size)
    payload.appendUInt16BE(feedback.fpsX10)
    payload.appendUInt16BE(feedback.decodeMS)
    payload.appendUInt16BE(feedback.droppedFrames)
    payload.appendUInt16BE(feedback.queueDepth)
    payload.appendUInt16BE(feedback.rttMS)
    payload.appendUInt16BE(feedback.lossPermille)
    payload.appendUInt32BE(feedback.recvBitrateBps)
    payload.appendUInt32BE(feedback.arrivalDelayMS)
    payload.appendUInt64BE(feedback.timestampMicros)
    return Frame(type: MessageType.feedback.rawValue, payload: payload)
}

public func decodeFeedback(_ payload: Data) throws -> Feedback {
    guard payload.count >= Feedback.size else { throw UdpError.malformed }
    return Feedback(
        fpsX10: payload.readUInt16BE(0),
        decodeMS: payload.readUInt16BE(2),
        droppedFrames: payload.readUInt16BE(4),
        queueDepth: payload.readUInt16BE(6),
        rttMS: payload.readUInt16BE(8),
        lossPermille: payload.readUInt16BE(10),
        recvBitrateBps: payload.readUInt32BE(12),
        arrivalDelayMS: payload.readUInt32BE(16),
        timestampMicros: payload.readUInt64BE(20)
    )
}

public struct UdpConfig: Equatable, Sendable {
    public let port: UInt16
    public let cipher: UdpCipher
    public let key: Data
    public let noncePrefix: Data
    public let flags: UInt8

    public init(port: UInt16, cipher: UdpCipher, key: Data, noncePrefix: Data, flags: UInt8) {
        self.port = port
        self.cipher = cipher
        self.key = key
        self.noncePrefix = noncePrefix
        self.flags = flags
    }

    public var isEnabled: Bool { flags & 1 != 0 }
}

public func encodeUdpConfig(_ config: UdpConfig) -> Frame {
    precondition(config.key.count == 32, "UDP key must be 32 bytes")
    precondition(config.noncePrefix.count == 4, "nonce prefix must be 4 bytes")

    var payload = Data(capacity: 40)
    payload.appendUInt16BE(config.port)
    payload.append(config.cipher.rawValue)
    payload.append(config.key)
    payload.append(config.noncePrefix)
    payload.append(config.flags)
    return Frame(type: MessageType.udpConfig.rawValue, payload: payload)
}

public func decodeUdpConfig(_ payload: Data) throws -> UdpConfig {
    guard payload.count >= 40 else { throw UdpError.malformed }
    guard let cipher = UdpCipher(rawValue: payload[2]) else { throw UdpError.malformed }
    return UdpConfig(
        port: payload.readUInt16BE(0),
        cipher: cipher,
        key: payload.subdata(in: 3..<35),
        noncePrefix: payload.subdata(in: 35..<39),
        flags: payload[39]
    )
}