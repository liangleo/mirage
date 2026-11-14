import Foundation
import CoreGraphics
import CoreMedia
import MirageCore
import MirageHelper

public final class HelperApp: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let port: UInt16
    private let fps: Int
    private let bitrate: Int
    private let maxWidth: Int
    private let maxHeight: Int

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
        maxHeight: Int = 2160
    ) {
        self.displayID = displayID
        self.port = port
        self.fps = fps
        self.bitrate = bitrate
        self.maxWidth = maxWidth
        self.maxHeight = maxHeight
    }

    public func run() async throws {
        guard let capturedSize = captureSize(for: displayID) else {
            throw HelperAppError.invalidDisplay(displayID)
        }
        let size = fittedCaptureSize(capturedSize, maxWidth: maxWidth, maxHeight: maxHeight)
        print("display=\(displayID) capture=\(size.width)x\(size.height) source=\(capturedSize.width)x\(capturedSize.height)")
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
            server?.broadcast(frame)
        }

        let capture = DisplayCapture(displayID: displayID, fps: fps, size: size) { [weak self] pixelBuffer, micros in
            guard let self, let encoder = self.encoder else { return }
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
    }

    private func requestKeyframe() {
        keyframes.request()
        capture?.requestFrame()
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