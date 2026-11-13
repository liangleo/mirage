// 验证 §15-3：ScreenCaptureKit 捕获固定显示器时的帧回调与 idle 行为。
// 编译：swiftc -O tools/verify/sck_probe.swift -o tools/verify/build/sck_probe
import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import QuartzCore

final class Counter: NSObject, SCStreamOutput {
    private let lock = NSLock()
    private var frames = 0
    private var idleAndBlank = 0
    private var withDirty = 0
    private var withoutDirty = 0
    private var dirtyRectsTotal = 0
    private var last: CFTimeInterval = 0
    private var maxGap: CFTimeInterval = 0
    private var first: CFTimeInterval = 0
    private var statusCounts: [String: Int] = [:]

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen else { return }
        if frames == 0, let pb = CMSampleBufferGetImageBuffer(sb) {
            print("first frame buffer: \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))")
        }
        let now = CACurrentMediaTime()
        var statusName = "none"
        var rectCount = 0
        let typed = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let stringy = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]]
        let dict: [String: Any]? = typed?.first?.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value } ?? stringy?.first
        if let dict {
            if frames == 0 {
                print("sample attachments keys: \(Array(dict.keys))")
                for (k, v) in dict { print("  \(k) -> \(Swift.type(of: v)) = \(v)") }
            }
            if let raw = dict[SCStreamFrameInfo.status.rawValue] as? Int, let st = SCFrameStatus(rawValue: raw) {
                statusName = String(describing: st)
                if st == .idle || st == .blank { idleAndBlank += 1 }
            }
            if let rects = dict[SCStreamFrameInfo.dirtyRects.rawValue] as? [[String: Any]] {
                for r in rects {
                    let w = (r["Width"] as? NSNumber)?.doubleValue ?? 0
                    let h = (r["Height"] as? NSNumber)?.doubleValue ?? 0
                    if w > 0 && h > 0 { rectCount += 1 }
                }
            }
        } else if frames == 0 {
            print("sample attachments: nil")
        }
        lock.lock()
        frames += 1
        statusCounts[statusName, default: 0] += 1
        if rectCount > 0 { withDirty += 1; dirtyRectsTotal += rectCount } else { withoutDirty += 1 }
        if first == 0 { first = now } else if last > 0 {
            maxGap = max(maxGap, now - last)
        }
        last = now
        lock.unlock()
    }

    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        let span = last > first ? last - first : 0
        return """
        frames=\(frames) span=\(String(format: "%.2f", span))s max_gap=\(String(format: "%.3f", maxGap))s \
        idle_or_blank=\(idleAndBlank) with_dirty=\(withDirty) without_dirty=\(withoutDirty) \
        dirty_rects_total=\(dirtyRectsTotal) status=\(statusCounts)
        """
    }
}

let counter = Counter()
let sem = DispatchSemaphore(value: 0)

Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let target = CommandLine.arguments.count > 1 ? UInt32(CommandLine.arguments[1]) : nil
        let display = target.flatMap { id in content.displays.first { $0.displayID == id } } ?? content.displays.first
        guard let display else { print("NO_DISPLAY"); sem.signal(); return }
        print("display=\(display.displayID) \(display.width)x\(display.height) target=\(target.map(String.init) ?? "first")")
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let cfg = SCStreamConfiguration()
        var cfgW = display.width
        var cfgH = display.height
        if let mode = CGDisplayCopyDisplayMode(display.displayID) {
            let pw = mode.pixelWidth
            let ph = mode.pixelHeight
            if pw > 0 && ph > 0 { cfgW = pw; cfgH = ph }
        }
        print("capture config: \(cfgW)x\(cfgH) (SCDisplay reports \(display.width)x\(display.height))")
        cfg.width = cfgW
        cfg.height = cfgH
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.queueDepth = 3
        cfg.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        cfg.showsCursor = false
        let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
        try stream.addStreamOutput(counter, type: .screen, sampleHandlerQueue: DispatchQueue(label: "mirage.sck"))
        try await stream.startCapture()
        // 静置 8 秒，期间不输出任何内容，避免自己的终端刷新制造帧
        try await Task.sleep(nanoseconds: 8_000_000_000)
        try await stream.stopCapture()
        print(counter.report())
        print("RESULT=\(counter.report().contains("frames=0") ? "NO_FRAMES" : "CAPTURED")")
    } catch {
        print("ERROR=\(error)")
        print("RESULT=FAIL_OR_NO_PERMISSION")
    }
    sem.signal()
}
sem.wait()