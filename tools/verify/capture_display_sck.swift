import AppKit
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

guard CommandLine.arguments.count >= 3,
      let rawID = UInt32(CommandLine.arguments[1]) else {
    print("usage: capture_display_sck <displayID> <out.png>")
    exit(2)
}
let targetID = CGDirectDisplayID(rawID)
let outPath = CommandLine.arguments[2]

final class Sink: NSObject, SCStreamOutput {
    let semaphore = DispatchSemaphore(value: 0)

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixelBuffer = CMSampleBufferGetImageBuffer(sb) else { return }
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        if let data = rep.representation(using: .png, properties: [:]) {
            try? data.write(to: URL(fileURLWithPath: outPath))
            print("saved \(cgImage.width)x\(cgImage.height)")
        }
        semaphore.signal()
    }
}

let sink = Sink()
let semaphore = DispatchSemaphore(value: 0)

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == targetID }) else {
            print("display not found")
            semaphore.signal()
            return
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        if let mode = CGDisplayCopyDisplayMode(targetID) {
            config.width = mode.pixelWidth
            config.height = mode.pixelHeight
        } else {
            config.width = display.width
            config.height = display.height
        }
        config.showsCursor = true
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(sink, type: .screen, sampleHandlerQueue: DispatchQueue(label: "capture.one"))
        try await stream.startCapture()
        _ = sink.semaphore.wait(timeout: .now() + 3)
        try await stream.stopCapture()
    } catch {
        print("error: \(error)")
    }
    semaphore.signal()
}
semaphore.wait()