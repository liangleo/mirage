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

    func testFittedSizeStaysWithinLimitsAndAspectRatio() {
        let fitted = fittedCaptureSize(
            CaptureSize(width: 4112, height: 2658),
            maxWidth: 3840,
            maxHeight: 2160
        )

        XCTAssertLessThanOrEqual(fitted.width, 3840)
        XCTAssertLessThanOrEqual(fitted.height, 2160)
        XCTAssertEqual(Double(fitted.width) / Double(fitted.height), 4112.0 / 2658.0, accuracy: 0.01)
        XCTAssertEqual(fitted.width % 2, 0)
        XCTAssertEqual(fitted.height % 2, 0)
    }

    func testFittedSizeDoesNotUpscale() {
        let original = CaptureSize(width: 1280, height: 800)
        XCTAssertEqual(fittedCaptureSize(original, maxWidth: 3840, maxHeight: 2160), original)
    }
}