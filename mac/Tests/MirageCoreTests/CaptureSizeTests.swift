import XCTest
import CoreGraphics
@testable import MirageCore

final class CaptureSizeTests: XCTestCase {
    func testMainDisplayPixelSizeMatchesDisplayMode() throws {
        let displayID = CGMainDisplayID()
        let size = try XCTUnwrap(captureSize(for: displayID))
        let mode = try XCTUnwrap(CGDisplayCopyDisplayMode(displayID))

        XCTAssertEqual(size.width, mode.pixelWidth)
        XCTAssertEqual(size.height, mode.pixelHeight)
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }
}