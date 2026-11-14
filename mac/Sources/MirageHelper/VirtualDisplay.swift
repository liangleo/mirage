import Foundation
import CoreGraphics
import CGVirtualDisplayBridge

public enum VirtualDisplayError: Error {
    case creationFailed
}

public final class VirtualDisplay {
    public let displayID: CGDirectDisplayID

    private var ref: UnsafeMutableRawPointer?

    public init(
        pointWidth: Int,
        pointHeight: Int,
        refreshRate: Double = 60,
        hiDPI: Bool = true,
        name: String = "Mirage"
    ) throws {
        guard pointWidth > 0, pointHeight > 0 else {
            throw VirtualDisplayError.creationFailed
        }

        let created = name.withCString { cName in
            mira_virtual_display_create(
                UInt32(pointWidth),
                UInt32(pointHeight),
                refreshRate,
                hiDPI ? 1 : 0,
                cName
            )
        }
        guard let created else {
            throw VirtualDisplayError.creationFailed
        }

        let id = mira_virtual_display_display_id(created)
        guard id != 0 else {
            mira_virtual_display_destroy(created)
            throw VirtualDisplayError.creationFailed
        }

        self.ref = created
        self.displayID = id
    }

    public func destroy() {
        if let ref {
            mira_virtual_display_destroy(ref)
            self.ref = nil
        }
    }

    deinit {
        destroy()
    }
}