import Foundation
import Network
import MirageCore

public enum ServerError: Error {
    case invalidPort(UInt16)
}

public final class MirageServer: @unchecked Sendable {
    public var onKeyframeRequest: (() -> Void)?
    public var onLog: ((String) -> Void)?

    private let port: UInt16
    private let session: Session
    private let sender = FrameSender()
    private let queue = DispatchQueue(label: "app.mirage.server")
    private var listener: NWListener?
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var keepalive: DispatchSourceTimer?

    public init(port: UInt16, config: SessionConfig) {
        self.port = port
        self.session = Session(config: config)
    }

    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true

        let listener = try NWListener(using: parameters, on: nwPort)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.onLog?("listener state=\(state)")
        }
        self.listener = listener
        listener.start(queue: queue)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.keepaliveTick()
        }
        timer.resume()
        keepalive = timer
    }

    public func broadcast(_ encoded: EncodedFrame) {
        let frame = makeVideoFrame(encoded.header, annexB: encoded.data)
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }

            let wasWaiting = self.sender.isWaitingForKeyframe
            guard self.sender.enqueue(encoded) else {
                if !wasWaiting && self.sender.isWaitingForKeyframe {
                    self.onKeyframeRequest?()
                }
                return
            }
            self.session.noteOutbound(nowMicros: monotonicMicros())
            self.send(frame, on: connection) { [weak self] in
                self?.sender.completeOne()
            }
        }
    }

    public func stop() {
        keepalive?.cancel()
        keepalive = nil
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.listener?.cancel()
            self?.listener = nil
        }
    }

    private func accept(_ newConnection: NWConnection) {
        if connection != nil {
            onLog?("rejecting extra connection")
            newConnection.cancel()
            return
        }
        connection = newConnection
        decoder = FrameDecoder()
        sender.awaitKeyframe()
        onKeyframeRequest?()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            switch state {
            case .ready:
                self.onLog?("client connected")
                self.receive(on: newConnection)
            case .failed, .cancelled:
                self.onLog?("client disconnected")
                if self.connection === newConnection {
                    self.connection = nil
                }
            default:
                break
            }
        }
        newConnection.start(queue: queue)
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak connection] data, _, isComplete, error in
            guard let self, let connection else { return }

            if let data, !data.isEmpty {
                self.decoder.append(data)
                do {
                    while let frame = try self.decoder.next() {
                        self.handle(frame, on: connection)
                    }
                } catch {
                    self.onLog?("protocol error: \(error)")
                    connection.cancel()
                    return
                }
            }

            if let error {
                self.onLog?("receive error: \(error)")
                connection.cancel()
                return
            }
            if isComplete {
                connection.cancel()
                return
            }
            self.receive(on: connection)
        }
    }

    private func handle(_ frame: Frame, on connection: NWConnection) {
        for action in session.handle(frame, nowMicros: monotonicMicros()) {
            switch action {
            case .send(let outbound):
                send(outbound, on: connection)
            case .close(let reason):
                onLog?("closing: \(reason)")
                connection.cancel()
            case .requestKeyframe:
                onKeyframeRequest?()
            }
        }
    }

    private func keepaliveTick() {
        guard let connection else { return }
        for action in session.tick(nowMicros: monotonicMicros()) {
            if case .send(let frame) = action {
                send(frame, on: connection)
            }
        }
    }

    private func send(_ frame: Frame, on connection: NWConnection, completion: (() -> Void)? = nil) {
        connection.send(
            content: encodeFrame(frame),
            contentContext: .defaultMessage,
            isComplete: false,
            completion: .contentProcessed { [weak self] error in
                if let error {
                    self?.onLog?("send error: \(error)")
                }
                completion?()
            }
        )
    }
}