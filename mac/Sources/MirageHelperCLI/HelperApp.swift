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
    private let alreadySized: Bool
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
        alreadySized: Bool = false,
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
        self.alreadySized = alreadySized
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
        let size = fittedCaptureSize(capturedSize, maxWidth: maxWidth, maxHeight: maxHeight)
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
        let server = MirageServer(port: port, config: config)
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

        try await capture.start()
        try server.start()
        print("listening=127.0.0.1:\(port)")
        fflush(stdout)
    }

    public func stop() async {
        try? await capture?.stop()
        encoder?.finish()
        server?.stop()
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
        guard mode == .extend, autoSize, !alreadySized else { return }

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
        let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let arguments = CommandLine.arguments
        var cleaned = [executable]
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--width", "--height":
                index += 2
            case "--auto-size", "--sized":
                index += 1
            default:
                cleaned.append(arguments[index])
                index += 1
            }
        }
        cleaned += ["--width", "\(width)", "--height", "\(height)", "--sized"]

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