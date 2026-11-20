import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import MirageCore

public enum CaptureError: Error {
    case displayNotFound(CGDirectDisplayID)
    case invalidDisplayMode(CGDirectDisplayID)
}

public final class DisplayCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public typealias FrameHandler = (CVPixelBuffer, UInt64) -> Void

    /// Fired when the system stops the stream (e.g. the menu bar's "stop
    /// sharing"); the helper has nothing left to serve and should exit.
    public var onStop: (@Sendable () -> Void)?
    /// 最近一次被系统停止时的错误码；helper 用它区分「用户停止共享」与「显示器消失」。
    public private(set) var lastStopCode: Int?

    private let displayID: CGDirectDisplayID
    private let fps: Int
    private let targetSize: CaptureSize?
    private let onFrame: FrameHandler
    private var stream: SCStream?
    private let debug = ProcessInfo.processInfo.environment["MIRAGE_DEBUG"] == "1"
    private var rawCallbacks = 0
    private var completeFrames = 0
    private var dirtyFrames = 0
    private var emittedFrames = 0
    private let forceLock = NSLock()
    private var forceNextFrame = false
    private var lastCompleteBuffer: CVPixelBuffer?

    public init(displayID: CGDirectDisplayID, fps: Int, size: CaptureSize? = nil, onFrame: @escaping FrameHandler) {
        self.displayID = displayID
        self.fps = fps
        self.targetSize = size
        self.onFrame = onFrame
    }

    public func requestFrame() {
        forceLock.lock()
        forceNextFrame = true
        forceLock.unlock()
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        guard let size = targetSize ?? captureSize(for: displayID) else {
            throw CaptureError.invalidDisplayMode(displayID)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        print("capture_selected displayID=\(display.displayID) size=\(display.width)x\(display.height)")
        fflush(stdout)
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "app.mirage.capture"))
        try await stream.startCapture()
        self.stream = stream
    }

    public func stop() async throws {
        if let stream {
            try await stream.stopCapture()
        }
        stream = nil
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        lastStopCode = (error as NSError).code
        print("capture stopped: \(error)")
        fflush(stdout)
        onStop?()
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        rawCallbacks += 1
        if debug && rawCallbacks % 60 == 0 {
            print("capture_callbacks=\(rawCallbacks)")
            fflush(stdout)
        }
        guard let list = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = list.first else { return }

        let forced = takeForcedFrame()
        let isComplete: Bool
        if let raw = attachments[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: raw) {
            isComplete = status == .complete
        } else {
            isComplete = true
        }
        if !forced && !isComplete { return }
        if isComplete { completeFrames += 1 }
        guard forced || hasNonEmptyDirtyRect(attachments) else { return }
        dirtyFrames += 1
        var pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        if isComplete, let buffer = pixelBuffer {
            lastCompleteBuffer = buffer
        } else if forced {
            // idle 帧可能没有有效画面；强制帧回退到最后一帧完整缓冲。
            pixelBuffer = lastCompleteBuffer ?? pixelBuffer
        }
        guard let pixelBuffer else { return }
        emittedFrames += 1
        if debug && rawCallbacks % 120 == 0 {
            print("capture raw=\(rawCallbacks) complete=\(completeFrames) dirty=\(dirtyFrames) emitted=\(emittedFrames)")
            fflush(stdout)
        }
        onFrame(pixelBuffer, monotonicMicros())
    }

    private func takeForcedFrame() -> Bool {
        forceLock.lock()
        defer { forceLock.unlock() }
        let forced = forceNextFrame
        forceNextFrame = false
        return forced
    }

    private func hasNonEmptyDirtyRect(_ attachments: [SCStreamFrameInfo: Any]) -> Bool {
        guard let rects = attachments[SCStreamFrameInfo.dirtyRects] as? [[String: Any]] else { return false }
        return rects.contains { rect in
            let width = (rect["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (rect["Height"] as? NSNumber)?.doubleValue ?? 0
            return width > 0 && height > 0
        }
    }
}