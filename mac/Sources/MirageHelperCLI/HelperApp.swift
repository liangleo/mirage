import Foundation
import Darwin
import CoreGraphics
import CoreMedia
import CoreVideo
import CoreImage
import ImageIO
import MirageCore
import MirageHelper

public enum DisplayMode: String {
    case mirror
    case extend
}

public enum DisplayPosition: String {
    case right
    case left
}

public final class HelperApp: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let port: UInt16
    private let fps: Int
    private let bitrate: Int
    private let maxWidth: Int
    private let maxHeight: Int
    private let mode: DisplayMode
    private let pointWidth: Int
    private let pointHeight: Int
    private let autoSize: Bool
    private let position: DisplayPosition
    private let wifi: Bool
    private let controlPort: UInt16?
    private let dumpFramePath: String?
    private var dumpedFrame = false
    private let recordPath: String?
    private var recordHandle: FileHandle?
    private var virtualDisplay: VirtualDisplay?

    private let keyframes = KeyframeController()
    private let statsLock = NSLock()
    private var encodedFrames = 0
    private var encodeLatencySum: UInt64 = 0
    private var encoder: VideoEncoder?
    private var capture: DisplayCapture?
    private var server: MirageServer?
    private var controlServer: ControlServer?
    private var injector: InputInjector?

    public init(
        displayID: CGDirectDisplayID,
        port: UInt16,
        fps: Int,
        bitrate: Int,
        maxWidth: Int = 3840,
        maxHeight: Int = 2160,
        mode: DisplayMode = .mirror,
        pointWidth: Int = 1280,
        pointHeight: Int = 800,
        autoSize: Bool = false,
        position: DisplayPosition = .right,
        wifi: Bool = false,
        controlPort: UInt16? = nil,
        dumpFramePath: String? = nil,
        recordPath: String? = nil
    ) {
        self.displayID = displayID
        self.port = port
        self.fps = fps
        self.bitrate = bitrate
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
        self.mode = mode
        self.pointWidth = pointWidth
        self.pointHeight = pointHeight
        self.autoSize = autoSize
        self.position = position
        self.wifi = wifi
        self.controlPort = controlPort
        self.dumpFramePath = dumpFramePath
        self.recordPath = recordPath
    }

    public func run() async throws {
        var targetDisplayID = displayID

        if mode == .extend {
            targetDisplayID = try makeVirtualDisplay()
        }

        if let recordPath {
            FileManager.default.createFile(atPath: recordPath, contents: nil)
            recordHandle = FileHandle(forWritingAtPath: recordPath)
        }

        guard let capturedSize = captureSize(for: targetDisplayID) else {
            throw HelperAppError.invalidDisplay(targetDisplayID)
        }
        let effectiveMaxWidth = autoSize ? max(maxWidth, 4096) : maxWidth
        let effectiveMaxHeight = autoSize ? max(maxHeight, 4096) : maxHeight
        let size = fittedCaptureSize(capturedSize, maxWidth: effectiveMaxWidth, maxHeight: effectiveMaxHeight)
        print("display=\(targetDisplayID) capture=\(size.width)x\(size.height) source=\(capturedSize.width)x\(capturedSize.height) mode=\(mode.rawValue)")
        fflush(stdout)

        let encoder = try VideoEncoder(width: size.width, height: size.height, fps: fps, bitrate: bitrate)
        self.encoder = encoder

        let config = SessionConfig(
            width: UInt16(clamping: size.width),
            height: UInt16(clamping: size.height),
            fps: UInt8(clamping: fps),
            codec: 1,
            bitrate: UInt32(clamping: bitrate),
            rotation: 0
        )
        let tls = wifi ? try TLSIdentity.loadOrCreate() : nil
        let server = MirageServer(
            port: port,
            config: config,
            bindAddress: wifi ? nil : .ipv4(.loopback),
            serviceName: wifi ? "Mirage" : nil,
            tlsIdentity: tls?.identity
        )
        server.onKeyframeRequest = { [weak self] in
            self?.requestKeyframe()
        }
        server.onHello = { [weak self] hello in
            self?.handleAutoSize(hello)
        }
        server.onLog = { message in
            print(message)
            fflush(stdout)
        }
        let injector = InputInjector(displayID: targetDisplayID)
        self.injector = injector
        server.onInput = { event in
            injector.inject(event)
        }
        server.inputAllowed = { _ in InputControl.accessibilityGranted }
        server.inputPaused = { InputControl.isPaused }
        let feedbackController = FeedbackController(initialBitrate: bitrate)
        server.onFeedback = { [weak self] feedback in
            guard let self else { return }
            // A missing UDP fragment leaves the decoder predicting from a
            // frame it never saw, so the picture stays corrupt until the next
            // IDR; ask for one promptly instead of waiting for the periodic
            // keyframe.
            if feedback.lossPermille > 20,
               self.keyframes.requestIfDue(nowMicros: monotonicMicros()) {
                self.requestKeyframe()
            }
            guard let newBitrate = feedbackController.update(feedback, nowMicros: monotonicMicros()) else {
                return
            }
            self.encoder?.setBitrate(newBitrate)
            print("bitrate=\(newBitrate) reason=feedback loss=\(feedback.lossPermille) rtt=\(feedback.rttMS)")
            fflush(stdout)
        }
        self.server = server

        encoder.onFrame = { [weak self, weak server] frame in
            if frame.header.flags & 1 == 1 {
                self?.keyframes.noteKeyframe(nowMicros: frame.header.captureTimestampMicros)
            }
            self?.recordStats(frame)
            self?.recordHandle?.write(frame.data)
            server?.broadcast(frame)
        }

        let capture = DisplayCapture(displayID: targetDisplayID, fps: fps, size: size) { [weak self] pixelBuffer, micros in
            guard let self, let encoder = self.encoder else { return }
            self.dumpFirstFrameIfNeeded(pixelBuffer)
            let forceKeyframe = self.keyframes.shouldForce(nowMicros: micros)
            let pts = CMTime(value: Int64(micros), timescale: 1_000_000)
            do {
                try encoder.encode(pixelBuffer, pts: pts, forceKeyframe: forceKeyframe)
            } catch {
                print("encode_error=\(error)")
            }
        }
        self.capture = capture
        // 系统停止共享（菜单栏「停止共享」等）后 helper 已无可服务的内容，自行退出，
        // 否则菜单一直显示运行中、录制指示灯也不会灭
        capture.onStop = { [weak self] in
            print("helper_stopped=capture")
            fflush(stdout)
            Task {
                await self?.stop()
                exit(0)
            }
        }

        try await capture.start()
        try server.start()
        print("listening=\(wifi ? "0.0.0.0" : "127.0.0.1"):\(port)\(wifi ? " tls_port=\(server.tlsPort) mdns=_mirage._tcp" : "")")
        if let tls {
            print("tls_fingerprint=\(tls.fingerprint.prefix(4).map { String(format: "%02x", $0) }.joined())")
        }
        if let controlPort {
            // 菜单总是同时要 USB + Wi-Fi；在 helper 就绪时直接开，避免控制通道
            // 在启动窗口期抢跑失败（捕获/虚拟显示器初始化可能超过几秒）
            do {
                let identity = try TLSIdentity.loadOrCreate()
                try server.enableWifi(identity: identity.identity, serviceName: "Mirage")
                print("wifi enabled at startup")
            } catch {
                print("wifi startup failed: \(error)")
            }
            let control = ControlServer(port: controlPort) { [weak server] line in
                guard let server else { return "err stopped" }
                switch ControlParser.parse(line) {
                case .wifiOn:
                    do {
                        let identity = try TLSIdentity.loadOrCreate()
                        try server.enableWifi(identity: identity.identity, serviceName: "Mirage")
                        return "ok"
                    } catch {
                        return "err \(error)"
                    }
                case .wifiOff:
                    server.disableWifi()
                    return "ok"
                case .wifiStatus:
                    return server.wifiEnabled ? "on" : "off"
                case nil:
                    return "err unknown"
                }
            }
            try control.start()
            self.controlServer = control
            print("control=127.0.0.1:\(controlPort)")
        }
        fflush(stdout)
    }

    public func stop() async {
        injector?.releaseAll()
        try? await capture?.stop()
        encoder?.finish()
        server?.stop()
        controlServer?.stop()
        controlServer = nil
        virtualDisplay?.destroy()
        virtualDisplay = nil
    }

    private func makeVirtualDisplay() throws -> CGDirectDisplayID {
        do {
            let created = try VirtualDisplay(
                pointWidth: pointWidth,
                pointHeight: pointHeight,
                name: "Mirage"
            )
            if waitForDisplay(created.displayID, timeout: 5.0) {
                virtualDisplay = created
                positionVirtualDisplay(created.displayID)
                print("extend display=\(created.displayID) points=\(pointWidth)x\(pointHeight)")
                fflush(stdout)
                return created.displayID
            }
            print("extend_fallback=not_online after 5s; streaming main display instead")
            fflush(stdout)
            created.destroy()
            return displayID
        } catch {
            print("extend_fallback=create_failed")
            fflush(stdout)
            return displayID
        }
    }

    private func positionVirtualDisplay(_ id: CGDirectDisplayID) {
        let main = CGDisplayBounds(CGMainDisplayID())
        let own = CGDisplayBounds(id)
        let x: CGFloat
        switch position {
        case .right:
            x = main.maxX
        case .left:
            x = main.minX - own.width
        }
        var config: CGDisplayConfigRef?
        let begin = CGBeginDisplayConfiguration(&config)
        guard begin == .success, let config else {
            print("extend_position=failed begin=\(begin.rawValue)")
            fflush(stdout)
            return
        }
        CGConfigureDisplayOrigin(config, id, Int32(x), Int32(main.minY))
        let complete = CGCompleteDisplayConfiguration(config, .permanently)
        print("extend_position=\(position.rawValue) x=\(Int(x)) result=\(complete.rawValue) bounds=\(CGDisplayBounds(id))")
        fflush(stdout)
    }

    private func waitForDisplay(_ id: CGDirectDisplayID, timeout: TimeInterval) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            var count: UInt32 = 0
            CGGetActiveDisplayList(0, nil, &count)
            var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
            CGGetActiveDisplayList(count, &ids, &count)
            if ids.contains(id), captureSize(for: id) != nil {
                return true
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private func requestKeyframe() {
        keyframes.request()
        capture?.requestFrame()
    }

    private func handleAutoSize(_ hello: Hello) {
        guard mode == .extend, autoSize else { return }

        let pixelWidth = Int(hello.screenWidth)
        let pixelHeight = Int(hello.screenHeight)
        guard pixelWidth > 1, pixelHeight > 1 else { return }

        let targetWidth = max(2, (pixelWidth / 2) & ~1)
        let targetHeight = max(2, (pixelHeight / 2) & ~1)
        if abs(targetWidth - pointWidth) <= 2 && abs(targetHeight - pointHeight) <= 2 {
            return
        }

        print("extend_resize device=\(pixelWidth)x\(pixelHeight) points=\(targetWidth)x\(targetHeight)")
        fflush(stdout)
        relaunch(width: targetWidth, height: targetHeight)
    }

    private func relaunch(width: Int, height: Int) -> Never {
        // execv keeps every open descriptor, so the inherited TCP/UDP sockets
        // would make the new image fail to bind 7777/7778. Mark them
        // close-on-exec first; the new image reopens what it needs.
        let maxFD = getdtablesize()
        for fd in 3..<maxFD {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let arguments = CommandLine.arguments
        var cleaned = [executable]
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--width", "--height":
                index += 2
            default:
                cleaned.append(arguments[index])
                index += 1
            }
        }
        cleaned += ["--width", "\(width)", "--height", "\(height)"]

        var cArguments = cleaned.map { strdup($0) }
        cArguments.append(nil)
        execv(executable, &cArguments)
        exit(1)
    }

    private func dumpFirstFrameIfNeeded(_ pixelBuffer: CVPixelBuffer) {
        guard let path = dumpFramePath else { return }

        statsLock.lock()
        if dumpedFrame {
            statsLock.unlock()
            return
        }
        dumpedFrame = true
        statsLock.unlock()

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            "public.png" as CFString,
            1,
            nil
        ) else { return }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        print("dumped_frame=\(path)")
        fflush(stdout)
    }

    private func recordStats(_ frame: EncodedFrame) {
        statsLock.lock()
        encodedFrames += 1
        encodeLatencySum += frame.encodeLatencyMicros
        let count = encodedFrames
        let average = encodeLatencySum / UInt64(max(1, count))
        let shouldLog = count % 60 == 0
        statsLock.unlock()

        if shouldLog {
            print(String(format: "stats encode_frames=%d avg_encode_ms=%.2f", count, Double(average) / 1000.0))
            fflush(stdout)
        }
    }
}

public enum HelperAppError: Error {
    case invalidDisplay(CGDirectDisplayID)
}