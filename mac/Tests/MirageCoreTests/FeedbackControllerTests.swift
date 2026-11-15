import XCTest
@testable import MirageCore
@testable import MirageHelper

final class FeedbackControllerTests: XCTestCase {
    private func feedback(
        queueDepth: UInt16 = 0,
        lossPermille: UInt16 = 0,
        arrivalDelayMS: UInt32 = 0
    ) -> Feedback {
        Feedback(
            fpsX10: 600,
            decodeMS: 8,
            droppedFrames: 0,
            queueDepth: queueDepth,
            rttMS: 12,
            lossPermille: lossPermille,
            recvBitrateBps: 20_000_000,
            arrivalDelayMS: arrivalDelayMS,
            timestampMicros: 0
        )
    }

    func testDegradedFeedbackLowersBitrateWithoutCrossingMin() {
        let controller = FeedbackController(initialBitrate: 20_000_000, min: 5_000_000, max: 30_000_000)
        let bad = feedback(arrivalDelayMS: 300)

        var now: UInt64 = 1_000_000
        var previous = controller.bitrate
        var adjustments = 0
        while let next = controller.update(bad, nowMicros: now) {
            XCTAssertLessThan(next, previous)
            XCTAssertGreaterThanOrEqual(next, 5_000_000)
            previous = next
            now += 1_000_000
            adjustments += 1
        }
        XCTAssertGreaterThanOrEqual(adjustments, 3)
        XCTAssertEqual(controller.bitrate, 5_000_000)
    }

    func testHealthyFeedbackRaisesBitrateSlowlyUpToMax() {
        let controller = FeedbackController(initialBitrate: 10_000_000, min: 5_000_000, max: 30_000_000)
        let good = feedback()

        XCTAssertNil(controller.update(good, nowMicros: 100_000))
        XCTAssertEqual(controller.update(good, nowMicros: 2_200_000), 11_000_000)
        XCTAssertNil(controller.update(good, nowMicros: 2_300_000))
        XCTAssertEqual(controller.update(good, nowMicros: 4_400_000), 12_100_000)

        var now: UInt64 = 4_500_000
        XCTAssertNil(controller.update(good, nowMicros: now))
        now += 2_200_000
        var previous = controller.bitrate
        var adjustments = 2
        while true {
            guard let next = controller.update(good, nowMicros: now) else { break }
            XCTAssertGreaterThan(next, previous)
            XCTAssertLessThanOrEqual(next, 30_000_000)
            previous = next
            adjustments += 1
            now += 100_000
            XCTAssertNil(controller.update(good, nowMicros: now))
            now += 2_200_000
        }
        XCTAssertGreaterThanOrEqual(adjustments, 3)
        XCTAssertEqual(controller.bitrate, 30_000_000)
    }

    func testChangesAreThrottledAndMustExceedTenPercent() {
        let controller = FeedbackController(initialBitrate: 20_000_000, min: 5_000_000, max: 30_000_000)
        let bad = feedback(queueDepth: 4)

        XCTAssertNotNil(controller.update(bad, nowMicros: 1_000_000))
        XCTAssertNil(controller.update(bad, nowMicros: 1_300_000))
        XCTAssertNotNil(controller.update(bad, nowMicros: 1_600_000))

        let capped = FeedbackController(initialBitrate: 30_000_000, min: 5_000_000, max: 30_000_000)
        XCTAssertNil(capped.update(feedback(), nowMicros: 100_000))
        XCTAssertNil(capped.update(feedback(), nowMicros: 5_000_000))
        XCTAssertEqual(capped.bitrate, 30_000_000)
    }

    func testFeedbackTimeoutKeepsBitrate() {
        let controller = FeedbackController(initialBitrate: 12_000_000, min: 5_000_000, max: 30_000_000)
        XCTAssertNil(controller.tick(nowMicros: 10_000_000))
        XCTAssertEqual(controller.bitrate, 12_000_000)
    }
}