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