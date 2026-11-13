import Foundation
import MirageCore

public enum SessionAction: Equatable {
    case send(Frame)
    case close(reason: String)
    case requestKeyframe
}

public final class Session: @unchecked Sendable {
    private let config: SessionConfig
    private var lastOutboundMicros: UInt64 = 0

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
                guard let configFrame = singleFrame(encodeSessionConfig(config)) else {
                    return [.close(reason: "failed to encode session config")]
                }
                return [.send(configFrame)]
            } catch {
                return [.close(reason: "malformed hello")]
            }

        case MessageType.ping.rawValue:
            guard (try? decodePing(frame.payload)) != nil else {
                return [.close(reason: "malformed ping")]
            }
            lastOutboundMicros = nowMicros
            return [.send(Frame(type: MessageType.ping.rawValue, payload: frame.payload))]

        case MessageType.ctrl.rawValue:
            return frame.payload.first == 1 ? [.requestKeyframe] : []

        case MessageType.bye.rawValue:
            return [.close(reason: "client bye")]

        default:
            return []
        }
    }

    public func tick(nowMicros: UInt64) -> [SessionAction] {
        guard nowMicros >= lastOutboundMicros + 1_000_000 else { return [] }
        lastOutboundMicros = nowMicros
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