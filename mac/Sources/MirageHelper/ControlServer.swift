import Foundation
import Network

/// Loopback-only admin endpoint for the menu app: one command line in, one
/// reply line out. Kept separate from the streaming protocol so toggling Wi-Fi
/// never touches an active client or the capture pipeline.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (String) -> String

    private let port: UInt16
    private let handler: Handler
    private let queue = DispatchQueue(label: "app.mirage.control")
    private var listener: NWListener?

    public init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort(port)
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: 0)
        let listener = try NWListener(using: parameters, on: nwPort)

        let ready = DispatchSemaphore(value: 0)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw ServerError.notReady
        }
        self.listener = listener
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, _, _ in
            guard let self else {
                connection.cancel()
                return
            }
            let line = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let reply = self.handler(line)
            connection.send(content: Data((reply + "\n").utf8), completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}