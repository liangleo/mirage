import Foundation
import Network
import Security
import CryptoKit
import Darwin
import MirageCore

public enum ServerError: Error {
    case invalidPort(UInt16)
    case notReady
    case failed(Error)
    case tlsUnavailable
}

private final class StartResult: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?

    func set(_ error: Error) {
        lock.lock()
        self.error = error
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return error
    }
}

public final class MirageServer: @unchecked Sendable {
    public var onKeyframeRequest: (() -> Void)?
    public var onLog: ((String) -> Void)?
    public var onHello: ((Hello) -> Void)?
    public var onUsbRequest: (() -> Void)?
    public var onSecureClientActive: ((Bool) -> Void)?
    public var onFeedback: ((Feedback) -> Void)?
    public var onInput: (@Sendable (InputEvent) -> Void)?
    public var inputAllowed: (@Sendable (Data) -> Bool)?
    public var inputPaused: @Sendable () -> Bool = { false }
    public var inputCaps: UInt8 = 0b111111

    private let port: UInt16
    private let session: Session
    private let sender = FrameSender()
    private let bindAddress: NWEndpoint.Host?
    private let serviceName: String?
    private let tlsIdentity: SecIdentity?
    private let queue = DispatchQueue(label: "app.mirage.server")
    private var listener: NWListener?
    private var tlsListener: NWListener?
    private var connection: NWConnection?
    private var decoder = FrameDecoder()
    private var keepalive: DispatchSourceTimer?
    private var udpSender: UdpVideoSender?
    private var udpPeerReady = false
    private var udpClientReady = false
    private var lastRetransmitKeyframeMicros: UInt64 = 0
    private let wifiToggleLock = NSLock()
    private var lastFeedbackMicros: UInt64 = 0
    private var clientDeviceID: Data?
    private var inputDisabledSent = false
    private var inputEventLogged = false
    private var connectionSecure = false
    private var inputRate = InputRateLimiter()
    private var inputWasPaused = false
    public private(set) var udpConfig: UdpConfig?
    private var wifiOn = false

    public var tlsPort: UInt16 { port + 1 }

    public init(
        port: UInt16,
        config: SessionConfig,
        bindAddress: NWEndpoint.Host? = .ipv4(.loopback),
        serviceName: String? = nil,
        tlsIdentity: SecIdentity? = nil
    ) {
        self.port = port
        self.session = Session(config: config)
        self.bindAddress = bindAddress
        self.serviceName = serviceName
        self.tlsIdentity = tlsIdentity
    }

    public func start() throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw ServerError.invalidPort(port)
        }

        let plainParameters = NWParameters.tcp
        plainParameters.allowLocalEndpointReuse = true
        let plainHost: NWEndpoint.Host = bindAddress ?? .ipv4(.loopback)
        plainParameters.requiredLocalEndpoint = .hostPort(host: plainHost, port: 0)
        listener = try startListener(parameters: plainParameters, on: nwPort, serviceName: nil, txtRecord: Data())

        if let tlsIdentity {
            try enableWifi(identity: tlsIdentity, serviceName: serviceName ?? "Mirage")
        } else if serviceName != nil {
            onLog?("warning: mDNS advertised without TLS")
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0)
        timer.setEventHandler { [weak self] in
            self?.keepaliveTick()
        }
        timer.resume()
        keepalive = timer
    }

    public var wifiEnabled: Bool {
        queue.sync { wifiOn }
    }

    /// Start the TLS listener, mDNS advertisement and UDP sender on demand.
    /// Driven by the control channel so toggling Wi-Fi never restarts capture,
    /// the virtual display, or an active AOA session.
    public func enableWifi(identity: SecIdentity, serviceName: String) throws {
        wifiToggleLock.lock()
        defer { wifiToggleLock.unlock() }
        if wifiEnabled {
            return
        }
        guard let tlsPortValue = NWEndpoint.Port(rawValue: tlsPort),
              let secIdentity = sec_identity_create(identity) else {
            throw ServerError.tlsUnavailable
        }
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_local_identity(tlsOptions.securityProtocolOptions, secIdentity)
        sec_protocol_options_set_min_tls_protocol_version(tlsOptions.securityProtocolOptions, .TLSv12)
        let tlsParameters = NWParameters(tls: tlsOptions, tcp: NWProtocolTCP.Options())
        tlsParameters.allowLocalEndpointReuse = true
        let listener = try startListener(
            parameters: tlsParameters,
            on: tlsPortValue,
            serviceName: serviceName,
            txtRecord: pairingTXTRecord(identity: identity),
            secure: true
        )

        let key = randomData(count: 32)
        let noncePrefix = randomData(count: 4)
        let config = UdpConfig(
            port: tlsPort,
            cipher: .aes256GCM,
            key: key,
            noncePrefix: noncePrefix,
            flags: 1
        )
        let sender = UdpVideoSender(port: tlsPort, key: key, noncePrefix: noncePrefix)
        sender.onLog = onLog
        sender.onRetransmitBurst = { [weak self] in
            guard let server = self else { return }
            server.queue.async {
                let now = monotonicMicros()
                // 最多每 500ms 要一次，避免重传风暴里连续重建 IDR
                if now - server.lastRetransmitKeyframeMicros < 500_000 {
                    return
                }
                server.lastRetransmitKeyframeMicros = now
                server.onKeyframeRequest?()
            }
        }
        sender.onPeerReady = { [weak self] in
            guard let server = self else { return }
            server.queue.async {
                server.udpPeerReady = true
                server.onLog?("udp ready set")
                // 静态画面时编码器可能长时间不出帧，UDP 会一直拿不到首帧；
                // 这里主动要一个关键帧，让客户端尽快确认 UDP 通路。
                server.onKeyframeRequest?()
            }
        }
        do {
            try sender.start()
        } catch {
            listener.cancel()
            throw error
        }

        queue.sync {
            tlsListener = listener
            udpSender = sender
            udpConfig = config
            udpPeerReady = false
            wifiOn = true
        }
        onLog?("wifi enabled port=\(tlsPort)")
    }

    public func disableWifi() {
        wifiToggleLock.lock()
        defer { wifiToggleLock.unlock() }
        var listener: NWListener?
        var sender: UdpVideoSender?
        var secure: NWConnection?
        queue.sync {
            guard wifiOn else { return }
            listener = tlsListener
            tlsListener = nil
            sender = udpSender
            udpSender = nil
            udpConfig = nil
            udpPeerReady = false
            wifiOn = false
            if connectionSecure {
                secure = connection
                connection = nil
                connectionSecure = false
            }
        }
        listener?.cancel()
        sender?.stop()
        secure?.cancel()
        if listener != nil {
            onLog?("wifi disabled")
        }
    }

    private func startListener(
        parameters: NWParameters,
        on port: NWEndpoint.Port,
        serviceName: String?,
        txtRecord: Data,
        secure: Bool = false
    ) throws -> NWListener {
        let listener = try NWListener(using: parameters, on: port)
        if let serviceName {
            listener.service = NWListener.Service(
                name: serviceName,
                type: "_mirage._tcp",
                txtRecord: txtRecord
            )
        }
        let ready = DispatchSemaphore(value: 0)
        let startResult = StartResult()
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, secure: secure)
        }
        listener.stateUpdateHandler = { [weak self] state in
            self?.onLog?("listener state=\(state)")
            switch state {
            case .ready:
                ready.signal()
            case .failed(let error):
                startResult.set(error)
                ready.signal()
            case .cancelled:
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
        if let error = startResult.get() {
            listener.cancel()
            throw ServerError.failed(error)
        }
        return listener
    }

    private var broadcastDebugLogged = false
    private var broadcastUdpLogged = false

    public func broadcast(_ encoded: EncodedFrame) {
        let frame = makeVideoFrame(encoded.header, annexB: encoded.data)
        queue.async { [weak self] in
            guard let self, let connection = self.connection else { return }
            if !self.broadcastDebugLogged {
                self.broadcastDebugLogged = true
                self.onLog?("broadcast udpReady=\(self.udpPeerReady) sender=\(self.udpSender != nil)")
            }

            if self.udpPeerReady, let udpSender = self.udpSender {
                if !self.broadcastUdpLogged {
                    self.broadcastUdpLogged = true
                    self.onLog?("broadcast udp path")
                }
                self.session.noteOutbound(nowMicros: monotonicMicros())
                udpSender.send(frame: encoded)
                // 客户端还没确认收到 UDP 帧前，TCP 也继续发：静态画面时编码器
                // 可能长时间不出帧，客户端等首帧期间不至于完全没数据。
                if self.udpClientReady {
                    return
                }
            }

            let wasWaiting = self.sender.isWaitingForKeyframe
            let accepted = self.sender.enqueue(encoded)
            guard accepted else {
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
        onInput?(.releaseAll)
        queue.async { [weak self] in
            self?.connection?.cancel()
            self?.connection = nil
            self?.listener?.cancel()
            self?.listener = nil
            self?.tlsListener?.cancel()
            self?.tlsListener = nil
            self?.udpSender?.stop()
            self?.udpSender = nil
            self?.udpPeerReady = false
        }
    }

    private func pairingTXTRecord(identity: SecIdentity?) -> Data {
        guard let identity else { return Data() }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
              let certificate else {
            return Data()
        }
        let der = SecCertificateCopyData(certificate) as Data
        let fingerprint = Data(SHA256.hash(data: der))

        var record = Data()
        let pairs = [
            ("v", "1"),
            ("fp", fingerprint.map { String(format: "%02x", $0) }.joined()),
            ("name", Host.current().localizedName ?? "Mac"),
        ]
        for (key, value) in pairs {
            let entry = Data("\(key)=\(value)".utf8)
            guard entry.count <= 255 else { continue }
            record.append(UInt8(entry.count))
            record.append(entry)
        }
        return record
    }

    private func accept(_ newConnection: NWConnection, secure: Bool) {
        onLog?("accept remote=\(String(describing: newConnection.endpoint)) secure=\(secure)")
        if connection != nil {
            onLog?("rejecting extra connection")
            newConnection.cancel()
            return
        }
        connection = newConnection
        decoder = FrameDecoder()
        lastFeedbackMicros = 0
        clientDeviceID = nil
        inputDisabledSent = false
        connectionSecure = secure
        sender.awaitKeyframe()
        onKeyframeRequest?()

        newConnection.stateUpdateHandler = { [weak self, weak newConnection] state in
            guard let self, let newConnection else { return }
            self.onLog?("connection state=\(state)")
            switch state {
            case .ready:
                self.onLog?("client connected")
                if secure {
                    self.onSecureClientActive?(true)
                }
                if let udpConfig = self.udpConfig {
                    self.send(encodeUdpConfig(udpConfig), on: newConnection)
                }
                // accept 时的第一帧可能在 socket ready 之前就被广播掉，这里再要一次。
                self.onKeyframeRequest?()
                self.receive(on: newConnection)
            case .failed, .cancelled:
                self.onLog?("client disconnected")
                if secure {
                    self.onSecureClientActive?(false)
                }
                if self.udpPeerReady {
                    self.onLog?("udp ready reset by new connection")
                }
                self.udpPeerReady = false
                self.udpClientReady = false
                self.onInput?(.releaseAll)
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
        if frame.type == MessageType.ctrl.rawValue, let code = frame.payload.first {
            if code == CtrlCode.udpFailed {
                udpPeerReady = false
                udpClientReady = false
                onLog?("udp failed; falling back to TCP video")
            } else if code == CtrlCode.udpReady {
                udpClientReady = true
                onLog?("udp ready")
            } else if code == CtrlCode.usbRequest {
                onLog?("usb requested")
                onUsbRequest?()
            }
        }

        if frame.type == MessageType.hello.rawValue,
           let hello = try? decodeHello(frame.payload) {
            clientDeviceID = hello.deviceID
            session.inputCaps = advertisedInputCaps
            inputDisabledSent = false
            inputEventLogged = false
            onLog?("hello screen=\(hello.screenWidth)x\(hello.screenHeight) caps=\(session.inputCaps)")
            onHello?(hello)
        }

        if frame.type == MessageType.feedback.rawValue,
           let feedback = try? decodeFeedback(frame.payload) {
            let now = monotonicMicros()
            if now - lastFeedbackMicros >= 100_000 {
                lastFeedbackMicros = now
                onFeedback?(feedback)
            }
        }

        for action in session.handle(frame, nowMicros: monotonicMicros()) {
            switch action {
            case .send(let outbound):
                send(outbound, on: connection)
            case .close(let reason):
                onLog?("closing: \(reason)")
                onInput?(.releaseAll)
                connection.cancel()
            case .requestKeyframe:
                onKeyframeRequest?()
            case .inject(let event):
                deliverInput(event, on: connection)
            }
        }
    }

    private var advertisedInputCaps: UInt8 {
        // AOA 桥通过 127.0.0.1 明文连接；helper 同时开 Wi-Fi 时 bindAddress 为 nil，
        // 不能因此把 USB 会话误判成不安全链路而禁用输入。
        if connectionSecure || isLoopbackConnection || bindAddress == .ipv4(.loopback) {
            return inputCaps
        }
        return 0
    }

    private var isLoopbackConnection: Bool {
        guard let endpoint = connection?.currentPath?.remoteEndpoint else { return false }
        if case let .hostPort(host, _) = endpoint {
            let text = "\(host)"
            return text == "127.0.0.1" || text == "::1" || text == "localhost"
        }
        return false
    }

    private func deliverInput(_ event: InputEvent, on connection: NWConnection) {
        if case .releaseAll = event {
            onInput?(event)
            return
        }
        let allowed = clientDeviceID.map { inputAllowed?($0) ?? true } ?? true
        let paused = inputPaused()
        if paused && !inputWasPaused {
            onInput?(.releaseAll)
        }
        inputWasPaused = paused
        if let reason = InputGate.disabledReason(
            caps: session.inputCaps,
            paused: paused,
            allowed: allowed
        ) {
            sendInputDisabled(reason: reason, on: connection)
            return
        }
        guard allowInputRate() else { return }
        if !inputEventLogged {
            inputEventLogged = true
            onLog?("input events flowing")
        }
        onInput?(event)
    }

    private func allowInputRate() -> Bool {
        inputRate.allow(now: monotonicMicros())
    }

    private func sendInputDisabled(reason: UInt8, on connection: NWConnection) {
        guard !inputDisabledSent else { return }
        inputDisabledSent = true
        let messages: [UInt8: String] = [
            1: "此设备未授权控制 Mac",
            2: "输入已暂停",
            3: "当前链路不允许输入",
        ]
        let text = Data((messages[reason] ?? "输入不可用").utf8)
        onLog?("input disabled reason=\(reason)")
        var payload = Data([CtrlCode.inputDisabled, UInt8(text.count)])
        payload.append(text)
        send(Frame(type: MessageType.ctrl.rawValue, payload: payload), on: connection)
    }

    private func keepaliveTick() {
        guard let connection else { return }
        syncInputGate(on: connection)
        for action in session.tick(nowMicros: monotonicMicros()) {
            if case .send(let frame) = action {
                send(frame, on: connection)
            }
        }
    }

    // The client stops sending input frames entirely while the server has
    // reported input disabled, so state changes must be pushed proactively
    // rather than piggybacked on the next input event.
    private func syncInputGate(on connection: NWConnection) {
        let allowed = clientDeviceID.map { inputAllowed?($0) ?? true } ?? true
        let paused = inputPaused()
        if paused && !inputWasPaused {
            onInput?(.releaseAll)
        }
        inputWasPaused = paused
        let reason = InputGate.disabledReason(
            caps: session.inputCaps,
            paused: paused,
            allowed: allowed
        )
        if let reason {
            sendInputDisabled(reason: reason, on: connection)
        } else if inputDisabledSent {
            inputDisabledSent = false
            onLog?("input enabled")
            send(Frame(type: MessageType.ctrl.rawValue, payload: Data([CtrlCode.inputEnabled])), on: connection)
        }
    }

    private func send(_ frame: Frame, on connection: NWConnection, completion: (@Sendable () -> Void)? = nil) {
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

struct InputRateLimiter {
    private var windowStart: UInt64 = 0
    private var count = 0

    mutating func allow(now: UInt64, limit: Int = 500) -> Bool {
        if now < windowStart || now - windowStart >= 1_000_000 {
            windowStart = now
            count = 0
        }
        count += 1
        return count <= limit
    }
}

enum InputGate {
    static func disabledReason(caps: UInt8, paused: Bool, allowed: Bool) -> UInt8? {
        if caps == 0 { return 3 }
        if paused { return 2 }
        if !allowed { return 1 }
        return nil
    }
}

private func randomData(count: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: count)
    let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
    precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
    return Data(bytes)
}