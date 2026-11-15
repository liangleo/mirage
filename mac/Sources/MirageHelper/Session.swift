import Foundation
import MirageCore

public enum SessionAction: Equatable {
    case send(Frame)
    case close(reason: String)
    case requestKeyframe
    case inject(InputEvent)
}

public final class Session: @unchecked Sendable {
    private var config: SessionConfig
    private var lastOutboundMicros: UInt64 = 0
    private var lastPingTimestamp: UInt64?
    public var inputCaps: UInt8 = 0

    public init(config: SessionConfig) {
        self.config = config
    }

    public func handle(_ frame: Frame, nowMicros: UInt64) -> [SessionAction] {
        switch frame.type {
        case MessageType.hello.rawValue:
            do {
                let hello = try decodeHello(frame.payload)
                guard hello.protoVersion == 1 else {
                    return [.close(reason: "unsupported protocol version \(hello.protoVersion)")]
                }
                lastOutboundMicros = nowMicros
                config.inputCaps = inputCaps
                guard let configFrame = singleFrame(encodeSessionConfig(config)) else {
                    return [.close(reason: "failed to encode session config")]
                }
                return [.send(configFrame)]
            } catch {
                return [.close(reason: "malformed hello")]
            }

        case MessageType.ping.rawValue:
            guard let timestamp = try? decodePing(frame.payload) else {
                return [.close(reason: "malformed ping")]
            }
            if timestamp == lastPingTimestamp {
                lastPingTimestamp = nil
                return []
            }
            lastOutboundMicros = nowMicros
            var payload = frame.payload
            for shift in stride(from: 56, through: 0, by: -8) {
                payload.append(UInt8((nowMicros >> UInt64(shift)) & 0xff))
            }
            return [.send(Frame(type: MessageType.ping.rawValue, payload: payload))]

        case MessageType.ctrl.rawValue:
            switch frame.payload.first {
            case CtrlCode.requestKeyframe:
                return [.requestKeyframe]
            case CtrlCode.releaseAll:
                return [.inject(.releaseAll)]
            default:
                return []
            }

        case MessageType.input.rawValue:
            guard let samples = try? decodeInput(frame.payload) else { return [] }
            return [.inject(.pointer(samples))]

        case MessageType.key.rawValue:
            guard let key = try? decodeKey(frame.payload) else { return [] }
            return [.inject(.key(key))]

        case MessageType.text.rawValue:
            guard let text = try? decodeText(frame.payload) else { return [] }
            return [.inject(.text(text))]

        case MessageType.scroll.rawValue:
            guard let scroll = try? decodeScroll(frame.payload) else { return [] }
            return [.inject(.scroll(scroll))]

        case MessageType.bye.rawValue:
            return [.close(reason: "client bye")]

        default:
            return []
        }
    }

    public func tick(nowMicros: UInt64) -> [SessionAction] {
        guard nowMicros >= lastOutboundMicros + 1_000_000 else { return [] }
        lastOutboundMicros = nowMicros
        lastPingTimestamp = nowMicros
        guard let frame = singleFrame(encodePing(timestamp: nowMicros)) else { return [] }
        return [.send(frame)]
    }

    public func noteOutbound(nowMicros: UInt64) {
        lastOutboundMicros = nowMicros
    }

    private func singleFrame(_ encoded: Data) -> Frame? {
        var decoder = FrameDecoder()
        decoder.append(encoded)
        return try? decoder.next()
    }
}