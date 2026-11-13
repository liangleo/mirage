import XCTest
import MirageCore
@testable import MirageHelper

final class FrameSenderTests: XCTestCase {
    private func frame(keyframe: Bool) -> EncodedFrame {
        EncodedFrame(
            header: VideoHeader(
                codec: 1,
                flags: keyframe ? 1 : 0,
                frameID: 1,
                captureTimestampMicros: 0,
                reserved: 0
            ),
            data: Data([0x00])
        )
    }

    func testRejectsFourthNonKeyframeAndWaits() {
        let sender = FrameSender(maxQueued: 3)

        XCTAssertTrue(sender.enqueue(frame(keyframe: false)))
        XCTAssertTrue(sender.enqueue(frame(keyframe: false)))
        XCTAssertTrue(sender.enqueue(frame(keyframe: false)))
        XCTAssertEqual(sender.queuedCount, 3)

        XCTAssertFalse(sender.enqueue(frame(keyframe: false)))
        XCTAssertTrue(sender.isWaitingForKeyframe)
        XCTAssertEqual(sender.queuedCount, 3)

        XCTAssertFalse(sender.enqueue(frame(keyframe: false)))
        XCTAssertTrue(sender.isWaitingForKeyframe)
    }

    func testKeyframeIsAcceptedWhileWaitingAndResetsState() {
        let sender = FrameSender(maxQueued: 3)
        for _ in 0..<3 {
            XCTAssertTrue(sender.enqueue(frame(keyframe: false)))
        }
        XCTAssertFalse(sender.enqueue(frame(keyframe: false)))
        XCTAssertTrue(sender.isWaitingForKeyframe)

        XCTAssertTrue(sender.enqueue(frame(keyframe: true)))
        XCTAssertFalse(sender.isWaitingForKeyframe)
        XCTAssertEqual(sender.queuedCount, 4)
    }

    func testCompleteOneDecrementsQueue() {
        let sender = FrameSender(maxQueued: 2)
        XCTAssertTrue(sender.enqueue(frame(keyframe: false)))
        XCTAssertTrue(sender.enqueue(frame(keyframe: false)))
        XCTAssertEqual(sender.queuedCount, 2)

        sender.completeOne()
        XCTAssertEqual(sender.queuedCount, 1)

        sender.completeOne()
        sender.completeOne()
        XCTAssertEqual(sender.queuedCount, 0)
    }

    func testAwaitKeyframeDropsNonKeyframesUntilKeyframeArrives() {
        let sender = FrameSender()
        sender.awaitKeyframe()

        XCTAssertFalse(sender.enqueue(frame(keyframe: false)))
        XCTAssertTrue(sender.isWaitingForKeyframe)

        XCTAssertTrue(sender.enqueue(frame(keyframe: true)))
        XCTAssertFalse(sender.isWaitingForKeyframe)
    }
}