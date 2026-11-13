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

    private let keyframeLock = NSLock()
    private var pendingKeyframe = true
    private var encoder: VideoEncoder?
    private var capture: DisplayCapture?
    private var server: MirageServer?

    public init(displayID: CGDirectDisplayID, port: UInt16, fps: Int, bitrate: Int) {
        self.displayID = displayID
        self.port = port
        self.fps = fps
        self.bitrate = bitrate
    }

    public func run() async throws {
        guard let capturedSize = captureSize(for: displayID) else {
            throw HelperAppError.invalidDisplay(displayID)
        }
        let size = fittedCaptureSize(capturedSize, maxWidth: 3840, maxHeight: 2160)
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

        encoder.onFrame = { [weak server] frame in
            server?.broadcast(frame)
        }

        let capture = DisplayCapture(displayID: displayID, fps: fps, size: size) { [weak self] pixelBuffer, micros in
            guard let self, let encoder = self.encoder else { return }
            let forceKeyframe = self.consumeKeyframeRequest()
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
        keyframeLock.lock()
        pendingKeyframe = true
        keyframeLock.unlock()
    }

    private func consumeKeyframeRequest() -> Bool {
        keyframeLock.lock()
        defer { keyframeLock.unlock() }
        let value = pendingKeyframe
        pendingKeyframe = false
        return value
    }
}

public enum HelperAppError: Error {
    case invalidDisplay(CGDirectDisplayID)
}