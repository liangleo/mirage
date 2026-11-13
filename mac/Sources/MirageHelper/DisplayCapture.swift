import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import MirageCore

public enum CaptureError: Error {
    case displayNotFound(CGDirectDisplayID)
    case invalidDisplayMode(CGDirectDisplayID)
}

public final class DisplayCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    public typealias FrameHandler = (CVPixelBuffer, UInt64) -> Void

    private let displayID: CGDirectDisplayID
    private let fps: Int
    private let onFrame: FrameHandler
    private var stream: SCStream?

    public init(displayID: CGDirectDisplayID, fps: Int, onFrame: @escaping FrameHandler) {
        self.displayID = displayID
        self.fps = fps
        self.onFrame = onFrame
    }

    public func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayNotFound(displayID)
        }
        guard let size = captureSize(for: displayID) else {
            throw CaptureError.invalidDisplayMode(displayID)
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = size.width
        config.height = size.height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.queueDepth = 3
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
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

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid else { return }
        guard let list = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let attachments = list.first else { return }

        if let raw = attachments[SCStreamFrameInfo.status] as? Int,
           let status = SCFrameStatus(rawValue: raw),
           status != .complete {
            return
        }
        guard hasNonEmptyDirtyRect(attachments) else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame(pixelBuffer, monotonicMicros())
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