// 验证 §15-2：VideoToolbox 低延迟码控键可用、编码会话可创建、GOP 行为。
// 编译：swiftc -O tools/verify/vt_probe.swift -o tools/verify/build/vt_probe
import Foundation
import VideoToolbox
import CoreMedia
import CoreVideo

final class Collector {
    private let lock = NSLock()
    private(set) var frames = 0
    private(set) var keyframes = 0
    private(set) var bytes = 0

    func add(_ sb: CMSampleBuffer) {
        var isKey = true
        if let list = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[CFString: Any]],
           let notSync = list.first?[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }
        let size = CMSampleBufferGetTotalSampleSize(sb)
        lock.lock()
        frames += 1
        if isKey { keyframes += 1 }
        bytes += size
        lock.unlock()
    }

    func snapshot() -> (Int, Int, Int) {
        lock.lock(); defer { lock.unlock() }
        return (frames, keyframes, bytes)
    }
}

let collector = Collector()
let encoderSpec: [CFString: Any] = [
    kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true
]
var session: VTCompressionSession?
let cb: VTCompressionOutputCallback = { refcon, _, status, _, sb in
    guard status == noErr, let refcon, let sb else { return }
    Unmanaged<Collector>.fromOpaque(refcon).takeUnretainedValue().add(sb)
}
var status = VTCompressionSessionCreate(
    allocator: kCFAllocatorDefault,
    width: 1280, height: 800,
    codecType: kCMVideoCodecType_H264,
    encoderSpecification: encoderSpec as CFDictionary,
    imageBufferAttributes: nil,
    compressedDataAllocator: nil,
    outputCallback: cb,
    refcon: Unmanaged.passUnretained(collector).toOpaque(),
    compressionSessionOut: &session
)
print("create_status=\(status) session=\(session != nil)")
guard status == noErr, let s = session else { exit(2) }

func set(_ key: CFString, _ value: CFTypeRef) {
    let st = VTSessionSetProperty(s, key: key, value: value)
    print("set \(key)=\(value) -> \(st)")
}
set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
set(kVTCompressionPropertyKey_MaxFrameDelayCount, 0 as CFNumber)
set(kVTCompressionPropertyKey_AverageBitRate, 20_000_000 as CFNumber)
set(kVTCompressionPropertyKey_DataRateLimits, [2_500_000, 1] as CFArray)
status = VTCompressionSessionPrepareToEncodeFrames(s)
print("prepare_status=\(status)")

var pixelBuffer: CVPixelBuffer?
let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
CVPixelBufferCreate(kCFAllocatorDefault, 1280, 800,
                    kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                    attrs as CFDictionary, &pixelBuffer)
guard let pb = pixelBuffer else { print("no pixel buffer"); exit(3) }
CVPixelBufferLockBaseAddress(pb, [])
if let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0) {
    memset(y, 0x10, CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * CVPixelBufferGetHeightOfPlane(pb, 0))
}
if let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1) {
    memset(uv, 0x80, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * CVPixelBufferGetHeightOfPlane(pb, 1))
}
CVPixelBufferUnlockBaseAddress(pb, [])

let frameCount = 30
for i in 0..<frameCount {
    var flagsOut = VTEncodeInfoFlags()
    let st = VTCompressionSessionEncodeFrame(
        s, imageBuffer: pb,
        presentationTimeStamp: CMTime(value: Int64(i), timescale: 60),
        duration: CMTime(value: 1, timescale: 60),
        frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flagsOut)
    if st != noErr { print("encode[\(i)] status=\(st)") }
}
VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
let (frames, keyframes, bytes) = collector.snapshot()
print("frames=\(frames) keyframes=\(keyframes) bytes=\(bytes)")
print("RESULT=\(frames == frameCount && keyframes == 1 ? "PASS_INFINITE_GOP" : "CHECK")")
VTCompressionSessionInvalidate(s)