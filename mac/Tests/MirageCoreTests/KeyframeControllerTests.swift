import XCTest
import MirageCore
@testable import MirageHelper

final class KeyframeControllerTests: XCTestCase {
    func testFirstFrameIsForced() {
        let controller = KeyframeController()
        XCTAssertTrue(controller.shouldForce(nowMicros: 1_000))
    }

    func testNoForceWithinFiveSecondsOfLastKeyframe() {
        let controller = KeyframeController()
        XCTAssertTrue(controller.shouldForce(nowMicros: 1_000_000))
        controller.noteKeyframe(nowMicros: 1_000_000)

        XCTAssertFalse(controller.shouldForce(nowMicros: 2_000_000))
        XCTAssertFalse(controller.shouldForce(nowMicros: 5_999_999))
        XCTAssertTrue(controller.shouldForce(nowMicros: 6_000_000))
    }

    func testRequestForcesImmediately() {
        let controller = KeyframeController()
        XCTAssertTrue(controller.shouldForce(nowMicros: 1_000_000))
        controller.noteKeyframe(nowMicros: 1_000_000)
        XCTAssertFalse(controller.shouldForce(nowMicros: 1_500_000))

        controller.request()
        XCTAssertTrue(controller.shouldForce(nowMicros: 1_600_000))
        XCTAssertFalse(controller.shouldForce(nowMicros: 1_700_000))
    }

    func testRequestIfDueRespectsInterval() {
        let controller = KeyframeController()
        XCTAssertTrue(controller.shouldForce(nowMicros: 1_000_000))
        controller.noteKeyframe(nowMicros: 1_000_000)

        XCTAssertFalse(controller.requestIfDue(nowMicros: 1_500_000))
        XCTAssertFalse(controller.shouldForce(nowMicros: 1_500_000))

        XCTAssertTrue(controller.requestIfDue(nowMicros: 3_000_000))
        XCTAssertTrue(controller.shouldForce(nowMicros: 3_000_000))
    }
}