import Foundation
import Darwin
import MirageCore

public final class UdpVideoSender: @unchecked Sendable {
    public typealias SendHook = (Data) -> Void

    public var onPeerReady: (() -> Void)?
    public var onLog: ((String) -> Void)?
    /// 重传频繁说明链路在丢包：让上层请求关键帧，缩短花屏时间。
    public var onRetransmitBurst: (() -> Void)?

    public private(set) var sentDatagrams = 0
    public private(set) var retransmits = 0
    public private(set) var droppedFrames = 0
    public private(set) var sendErrors = 0

    private let port: UInt16
    private let key: Data
    private let noncePrefix: Data
    private let sendHook: SendHook?
    private let queue = DispatchQueue(label: "app.mirage.udp.sender")
    private var running = false
    private var fd: Int32 = -1
    private var source: DispatchSourceRead?
    private var peer: sockaddr_in?
    private var nextSeq: UInt32 = 1
    private var cache: [UInt32: [Data]] = [:]
    private var cacheOrder: [UInt32] = []
    private var retransmitted: Set<UInt64> = []

    public init(
        port: UInt16,
        key: Data,
        noncePrefix: Data,
        send: SendHook? = nil
    ) {
        self.port = port
        self.key = key
        self.noncePrefix = noncePrefix
        self.sendHook = send
    }

    public func start() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw POSIXError(.EMFILE) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        // 非阻塞：receiveLoop 在同一个串行队列上排空，如果 fd 阻塞在这里，
        // 排队等待的 sendOnQueue 永远拿不到队列（表现为只有 HELLO ACK 能发出去）。
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        self.fd = fd
        self.running = true
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receiveLoop()
        }
        source.resume()
        self.source = source
    }

    public func stop() {
        running = false
        queue.sync {
            source?.cancel()
            source = nil
            if fd >= 0 {
                close(fd)
                fd = -1
            }
            cache.removeAll()
            cacheOrder.removeAll()
            retransmitted.removeAll()
        }
    }

    public func send(frame: EncodedFrame) {
        // cache/nextSeq/peer 都在 sender 队列上访问：编码线程与收包线程共用
        // 一份状态，之前直接在这里改 cache 会和 handleNack 撞字典直接崩溃。
        if sendHook != nil {
            // 测试注入的发送钩子不涉及 socket/收包线程，同步执行便于断言
            sendOnQueue(frame)
            return
        }
        queue.async { [weak self] in
            self?.sendOnQueue(frame)
        }
    }

    // 仅调试：MIRAGE_UDP_LOSS=0.03 时按概率丢包，用来验证客户端 NACK 重传。
    private let simulatedLoss: Double = {
        guard let raw = ProcessInfo.processInfo.environment["MIRAGE_UDP_LOSS"],
              let value = Double(raw) else { return 0 }
        return min(max(value, 0), 1)
    }()
    private var dropNotRunningLogged = false
    private var dropNoPeerLogged = false

    private func sendOnQueue(_ frame: EncodedFrame) {
        guard running || sendHook != nil else {
            if !dropNotRunningLogged {
                dropNotRunningLogged = true
                onLog?("udp drop: sender not running")
            }
            return
        }
        let payload = frame.data
        guard !payload.isEmpty else { return }
        let fragCount = (payload.count + UdpVideoHeader.maxPayload - 1) / UdpVideoHeader.maxPayload
        guard fragCount > 0, fragCount <= Int(UInt16.max) else { return }

        var datagrams: [Data] = []
        datagrams.reserveCapacity(fragCount)
        for index in 0..<fragCount {
            let start = index * UdpVideoHeader.maxPayload
            let end = min(start + UdpVideoHeader.maxPayload, payload.count)
            let chunk = payload.subdata(in: start..<end)
            var flags: UInt8 = 0
            if index == 0 { flags |= UdpFlags.sof }
            if index == fragCount - 1 { flags |= UdpFlags.eof }
            if frame.header.flags & 1 != 0 { flags |= UdpFlags.key }

            let sequence = nextSeq
            nextSeq &+= 1
            let header = UdpVideoHeader(
                seq: sequence,
                frameID: frame.header.frameID,
                fragIndex: UInt16(index),
                fragCount: UInt16(fragCount),
                flags: flags,
                payloadLength: UInt16(chunk.count + 16),
                captureTsMicros: frame.header.captureTimestampMicros
            )
            do {
                let sealed = try udpSeal(chunk, header: header, key: key, noncePrefix: noncePrefix)
                datagrams.append(encodeUdpHeader(header) + sealed)
            } catch {
                droppedFrames += 1
                onLog?("udp seal failed: \(error)")
                return
            }
        }

        cache[frame.header.frameID] = datagrams
        cacheOrder.append(frame.header.frameID)
        while cacheOrder.count > 8 {
            cache.removeValue(forKey: cacheOrder.removeFirst())
        }
        for datagram in datagrams {
            emit(datagram)
        }
    }

    public func handleNack(_ datagram: UdpDatagram) {
        guard datagram.header.isNack else { return }
        let bitmap = datagram.payload
        guard let fragments = cache[datagram.header.frameID] else { return }

        for byteIndex in 0..<bitmap.count {
            let byte = bitmap[bitmap.startIndex + byteIndex]
            guard byte != 0 else { continue }
            for bit in 0..<8 where byte & (1 << UInt8(bit)) != 0 {
                let fragIndex = Int(datagram.header.fragIndex) + byteIndex * 8 + bit
                guard fragIndex < fragments.count else { continue }
                let key = UInt64(datagram.header.frameID) << 32 | UInt64(fragIndex)
                guard !retransmitted.contains(key) else { continue }
                retransmitted.insert(key)
                retransmits += 1
                if retransmits % 40 == 0 {
                    onRetransmitBurst?()
                }
                emit(fragments[fragIndex])
            }
        }
    }

    private func emit(_ datagram: Data) {
        if simulatedLoss > 0, Double.random(in: 0..<1) < simulatedLoss {
            return
        }
        if let sendHook {
            sendHook(datagram)
            sentDatagrams += 1
            return
        }
        guard let peer else {
            droppedFrames += 1
            if !dropNoPeerLogged {
                dropNoPeerLogged = true
                onLog?("udp drop: peer unknown")
            }
            return
        }
        var address = peer
        let sent = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, (datagram as NSData).bytes, datagram.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if sent < 0 {
            sendErrors += 1
        } else {
            sentDatagrams += 1
        }
    }

    private func receiveLoop() {
        var buffer = [UInt8](repeating: 0, count: 2048)
        for _ in 0..<64 {
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { raw in
                withUnsafeMutablePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(fd, raw.baseAddress, raw.count, 0, $0, &length)
                    }
                }
            }
            guard count > 0 else { return }  // EAGAIN：本轮排空，交回队列
            let data = Data(buffer[0..<count])
            guard let datagram = try? decodeUdpDatagram(data) else { continue }

            if datagram.header.isHello {
                let knownPeer = peer != nil
                peer = address
                if !knownPeer {
                    let ip = String(cString: inet_ntoa(address.sin_addr))
                    onLog?("udp peer ready from \(ip):\(UInt16(bigEndian: address.sin_port))")
                }
                onPeerReady?()
                sendHelloAck()
            } else if datagram.header.isNack {
                handleNack(datagram)
            }
        }
    }

    private func sendHelloAck() {
        let header = UdpVideoHeader(
            seq: nextSeq,
            frameID: 0,
            fragIndex: 0,
            fragCount: 1,
            flags: UdpFlags.hello,
            payloadLength: 0
        )
        nextSeq &+= 1
        emit(encodeUdpHeader(header))
    }
}