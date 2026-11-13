import Foundation
import Darwin
import CoreGraphics
import CoreMedia
import CoreVideo
import MirageCore
import MirageHelper

let arguments = CommandLine.arguments

if arguments.contains("--list-displays") {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    for id in ids {
        if let size = captureSize(for: id) {
            print("id=\(id) pixel=\(size.width)x\(size.height)")
        } else {
            print("id=\(id) pixel=unknown")
        }
    }
} else if arguments.contains("--encode-selftest") {
    let counter = FrameCounter()
    do {
        let encoder = try VideoEncoder(width: 1280, height: 800, fps: 60, bitrate: 20_000_000)
        encoder.onFrame = { counter.record($0) }
        guard let pixelBuffer = makeTestPixelBuffer(width: 1280, height: 800) else {
            print("pixel_buffer=failed")
            exit(2)
        }
        for index in 0..<30 {
            let pts = CMTime(value: Int64(monotonicMicros()), timescale: 1_000_000)
            try encoder.encode(pixelBuffer, pts: pts, forceKeyframe: index == 0)
        }
        encoder.finish()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        let (frames, keyframes) = counter.snapshot()
        print("create_status=0 frames=\(frames) keyframes=\(keyframes)")
        exit(frames == 30 && keyframes == 1 ? 0 : 1)
    } catch {
        print("encoder_error=\(error)")
        exit(1)
    }
} else {
    print("usage: mirage-helper --list-displays | --encode-selftest")
}

final class FrameCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var keyframes = 0

    func record(_ frame: EncodedFrame) {
        lock.lock()
        frames += 1
        if frame.header.flags & 1 == 1 { keyframes += 1 }
        lock.unlock()
    }

    func snapshot() -> (Int, Int) {
        lock.lock()
        defer { lock.unlock() }
        return (frames, keyframes)
    }
}

func makeTestPixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
    var pixelBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        attributes as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else { return nil }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    if let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) {
        memset(luma, 0x10, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 0))
    }
    if let chroma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
        memset(chroma, 0x80, CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1) * CVPixelBufferGetHeightOfPlane(pixelBuffer, 1))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    return pixelBuffer
}