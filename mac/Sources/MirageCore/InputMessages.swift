import Foundation

public enum PointerKind: UInt8, Equatable, Sendable {
    case down = 1
    case move = 2
    case up = 3
    case cancel = 4
    case hover = 5
}

public enum InputModifiers {
    public static let shift: UInt8 = 1 << 0
    public static let control: UInt8 = 1 << 1
    public static let option: UInt8 = 1 << 2
    public static let command: UInt8 = 1 << 3
    public static let capsLock: UInt8 = 1 << 4
    public static let fn: UInt8 = 1 << 5
}

public enum KeyAction: UInt8, Equatable, Sendable {
    case down = 1
    case up = 2
}

public enum ScrollPhase: UInt8, Equatable, Sendable {
    case begin = 1
    case change = 2
    case end = 3
}

public enum ScrollFlags {
    public static let command: UInt8 = 1 << 0
    public static let precise: UInt8 = 1 << 1
}

public enum InputMessageError: Error, Equatable {
    case malformed
    case tooManySamples
    case textTooLong
}

public struct PointerSample: Equatable, Sendable {
    public static let size = 32

    public let kind: PointerKind
    public let pointerID: UInt8
    public let buttons: UInt16
    public let x: Float
    public let y: Float
    public let pressure: Float
    public let tiltX: Float
    public let tiltY: Float
    public let tsMicros: UInt64

    public init(
        kind: PointerKind,
        pointerID: UInt8,
        buttons: UInt16,
        x: Float,
        y: Float,
        pressure: Float,
        tiltX: Float,
        tiltY: Float,
        tsMicros: UInt64
    ) {
        self.kind = kind
        self.pointerID = pointerID
        self.buttons = buttons
        self.x = x
        self.y = y
        self.pressure = pressure
        self.tiltX = tiltX
        self.tiltY = tiltY
        self.tsMicros = tsMicros
    }
}

public struct KeyInput: Equatable, Sendable {
    public let action: KeyAction
    public let modifiers: UInt8
    public let flags: UInt8
    public let keycode: UInt16
    public let unicode: UInt32
    public let tsMicros: UInt64

    public init(
        action: KeyAction,
        modifiers: UInt8,
        flags: UInt8 = 0,
        keycode: UInt16,
        unicode: UInt32,
        tsMicros: UInt64
    ) {
        self.action = action
        self.modifiers = modifiers
        self.flags = flags
        self.keycode = keycode
        self.unicode = unicode
        self.tsMicros = tsMicros
    }
}

public struct TextInput: Equatable, Sendable {
    public let text: String
    public let tsMicros: UInt64

    public init(text: String, tsMicros: UInt64) {
        self.text = text
        self.tsMicros = tsMicros
    }
}

public struct ScrollInput: Equatable, Sendable {
    public let phase: ScrollPhase
    public let flags: UInt8
    public let dx: Float
    public let dy: Float
    public let tsMicros: UInt64

    public init(phase: ScrollPhase, flags: UInt8 = 0, dx: Float, dy: Float, tsMicros: UInt64) {
        self.phase = phase
        self.flags = flags
        self.dx = dx
        self.dy = dy
        self.tsMicros = tsMicros
    }
}

public enum InputEvent: Equatable, Sendable {
    case pointer([PointerSample])
    case key(KeyInput)
    case text(TextInput)
    case scroll(ScrollInput)
    case releaseAll
}

public func encodeInput(_ samples: [PointerSample]) throws -> Frame {
    guard !samples.isEmpty else { throw InputMessageError.malformed }
    guard samples.count <= 32 else { throw InputMessageError.tooManySamples }
    for sample in samples {
        guard sample.x.isFinite, sample.y.isFinite, sample.pressure.isFinite,
              sample.tiltX.isFinite, sample.tiltY.isFinite else {
            throw InputMessageError.malformed
        }
    }
    var payload = Data(capacity: 2 + samples.count * PointerSample.size)
    payload.appendUInt16BE(UInt16(samples.count))
    for sample in samples {
        payload.append(sample.kind.rawValue)
        payload.append(sample.pointerID)
        payload.appendUInt16BE(sample.buttons)
        payload.appendFloatBE(sample.x)
        payload.appendFloatBE(sample.y)
        payload.appendFloatBE(sample.pressure)
        payload.appendFloatBE(sample.tiltX)
        payload.appendFloatBE(sample.tiltY)
        payload.appendUInt64BE(sample.tsMicros)
    }
    return Frame(type: MessageType.input.rawValue, payload: payload)
}

public func decodeInput(_ payload: Data) throws -> [PointerSample] {
    guard payload.count >= 2 else { throw InputMessageError.malformed }
    let count = Int(payload.readUInt16BE(0))
    guard count >= 1 else { throw InputMessageError.malformed }
    guard count <= 32 else { throw InputMessageError.tooManySamples }
    guard payload.count == 2 + count * PointerSample.size else { throw InputMessageError.malformed }

    var samples: [PointerSample] = []
    samples.reserveCapacity(count)
    for index in 0..<count {
        let base = 2 + index * PointerSample.size
        guard let kind = PointerKind(rawValue: payload[base]) else {
            throw InputMessageError.malformed
        }
        let sample = PointerSample(
            kind: kind,
            pointerID: payload[base + 1],
            buttons: payload.readUInt16BE(base + 2),
            x: payload.readFloatBE(base + 4),
            y: payload.readFloatBE(base + 8),
            pressure: payload.readFloatBE(base + 12),
            tiltX: payload.readFloatBE(base + 16),
            tiltY: payload.readFloatBE(base + 20),
            tsMicros: payload.readUInt64BE(base + 24)
        )
        guard sample.x.isFinite, sample.y.isFinite, sample.pressure.isFinite,
              sample.tiltX.isFinite, sample.tiltY.isFinite else {
            throw InputMessageError.malformed
        }
        samples.append(sample)
    }
    return samples
}

public func encodeKey(_ key: KeyInput) -> Frame {
    var payload = Data(capacity: 18)
    payload.append(key.action.rawValue)
    payload.append(key.modifiers)
    payload.append(key.flags)
    payload.append(0)
    payload.appendUInt16BE(key.keycode)
    payload.appendUInt32BE(key.unicode)
    payload.appendUInt64BE(key.tsMicros)
    return Frame(type: MessageType.key.rawValue, payload: payload)
}

public func decodeKey(_ payload: Data) throws -> KeyInput {
    guard payload.count >= 18, let action = KeyAction(rawValue: payload[0]) else {
        throw InputMessageError.malformed
    }
    return KeyInput(
        action: action,
        modifiers: payload[1],
        flags: payload[2],
        keycode: payload.readUInt16BE(4),
        unicode: payload.readUInt32BE(6),
        tsMicros: payload.readUInt64BE(10)
    )
}

public func encodeText(_ text: TextInput) throws -> Frame {
    let bytes = Data(text.text.utf8)
    guard !bytes.isEmpty, bytes.count <= 4096 else { throw InputMessageError.textTooLong }
    var payload = Data(capacity: 2 + bytes.count + 8)
    payload.appendUInt16BE(UInt16(bytes.count))
    payload.append(bytes)
    payload.appendUInt64BE(text.tsMicros)
    return Frame(type: MessageType.text.rawValue, payload: payload)
}

public func decodeText(_ payload: Data) throws -> TextInput {
    guard payload.count >= 10 else { throw InputMessageError.malformed }
    let length = Int(payload.readUInt16BE(0))
    guard (1...4096).contains(length), payload.count == 2 + length + 8 else {
        throw InputMessageError.malformed
    }
    guard let text = String(data: payload.subdata(in: 2..<(2 + length)), encoding: .utf8) else {
        throw InputMessageError.malformed
    }
    return TextInput(text: text, tsMicros: payload.readUInt64BE(2 + length))
}

public func encodeScroll(_ scroll: ScrollInput) throws -> Frame {
    guard scroll.dx.isFinite, scroll.dy.isFinite else { throw InputMessageError.malformed }
    var payload = Data(capacity: 20)
    payload.append(scroll.phase.rawValue)
    payload.append(scroll.flags)
    payload.appendUInt16BE(0)
    payload.appendFloatBE(scroll.dx)
    payload.appendFloatBE(scroll.dy)
    payload.appendUInt64BE(scroll.tsMicros)
    return Frame(type: MessageType.scroll.rawValue, payload: payload)
}

public func decodeScroll(_ payload: Data) throws -> ScrollInput {
    guard payload.count == 20, let phase = ScrollPhase(rawValue: payload[0]) else {
        throw InputMessageError.malformed
    }
    let dx = payload.readFloatBE(4)
    let dy = payload.readFloatBE(8)
    guard dx.isFinite, dy.isFinite else { throw InputMessageError.malformed }
    return ScrollInput(
        phase: phase,
        flags: payload[1],
        dx: dx,
        dy: dy,
        tsMicros: payload.readUInt64BE(12)
    )
}