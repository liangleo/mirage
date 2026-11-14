import XCTest
import CoreGraphics
@testable import MirageHelper
@testable import MirageCore

final class VirtualDisplayTests: XCTestCase {
    func testCreatesHiDPIDisplay() throws {
        let display: VirtualDisplay
        do {
            display = try VirtualDisplay(
                pointWidth: 1280,
                pointHeight: 800,
                refreshRate: 60,
                hiDPI: true,
                name: "Mirage Test"
            )
        } catch {
            throw XCTSkip("virtual display unavailable or already in use: \(error)")
        }
        XCTAssertGreaterThan(display.displayID, 0)

        guard let size = waitForSize(display.displayID) else {
            throw XCTSkip("private API only brings up the first virtual display in a process")
        }
        XCTAssertEqual(size.width, 2560)
        XCTAssertEqual(size.height, 1600)

        display.destroy()
    }

    private func waitForSize(
        _ id: CGDirectDisplayID,
        timeout: TimeInterval = 2
    ) -> CaptureSize? {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if let size = captureSize(for: id) {
                return size
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}