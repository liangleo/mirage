import Foundation
import CoreGraphics

public struct CaptureSize: Equatable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public func captureSize(for displayID: CGDirectDisplayID) -> CaptureSize? {
    guard let mode = CGDisplayCopyDisplayMode(displayID) else { return nil }
    let width = mode.pixelWidth
    let height = mode.pixelHeight
    guard width > 0, height > 0 else { return nil }
    return CaptureSize(width: width, height: height)
}

public func fittedCaptureSize(_ size: CaptureSize, maxWidth: Int, maxHeight: Int) -> CaptureSize {
    guard size.width > 0, size.height > 0, maxWidth > 0, maxHeight > 0 else { return size }

    let scale = min(
        1.0,
        Double(maxWidth) / Double(size.width),
        Double(maxHeight) / Double(size.height)
    )
    guard scale < 1 else { return size }

    let width = max(2, Int((Double(size.width) * scale).rounded(.down)) & ~1)
    let height = max(2, Int((Double(size.height) * scale).rounded(.down)) & ~1)
    return CaptureSize(width: width, height: height)
}