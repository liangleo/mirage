import XCTest
import MirageCore
@testable import MirageHelper

final class SessionTests: XCTestCase {
    private let config = SessionConfig(
        width: 2560,
        height: 1600,
        fps: 60,
        codec: 1,
        bitrate: 20_000_000,
        rotation: 0
    )

    private func hello(protoVersion: UInt8 = 1) -> Hello {
        Hello(
            protoVersion: protoVersion,
            clientVersion: 1,
            deviceID: Data(0..<16),
            screenWidth: 2560,
            screenHeight: 1600,
            xdpi: 240,
            ydpi: 240,
            maxFPS: 60,
            codecs: 1,
            features: 0,
            rotation: 0,
            name: "Test"
        )
    }

    private func frame(from encoded: Data) throws -> Frame {
        var decoder = FrameDecoder()
        decoder.append(encoded)
        return try XCTUnwrap(try decoder.next())
    }

    func testHelloRespondsWithSessionConfig() throws {
        let session = Session(config: config)
        let actions = session.handle(try frame(from: encodeHello(hello())), nowMicros: 0)

        XCTAssertEqual(actions.count, 1)
        guard case .send(let frame) = actions[0] else {
            return XCTFail("expected send, got \(actions)")
        }
        XCTAssertEqual(frame.type, MessageType.sessionConfig.rawValue)
        XCTAssertEqual(try decodeSessionConfig(frame.payload), config)
    }

    func testUnsupportedProtocolVersionCloses() throws {
        let session = Session(config: config)
        let actions = session.handle(try frame(from: encodeHello(hello(protoVersion: 2))), nowMicros: 0)

        XCTAssertEqual(actions.count, 1)
        guard case .close = actions[0] else {
            return XCTFail("expected close, got \(actions)")
        }
    }

    func testPingEchoesTimestamp() throws {
        let session = Session(config: config)
        let actions = session.handle(try frame(from: encodePing(timestamp: 42)), nowMicros: 7_000_000)

        XCTAssertEqual(actions.count, 1)
        guard case .send(let frame) = actions[0] else {
            return XCTFail("expected send, got \(actions)")
        }
        XCTAssertEqual(frame.type, MessageType.ping.rawValue)
        XCTAssertEqual(try decodePing(frame.payload), 42)
        XCTAssertEqual(
            Array(frame.payload.dropFirst(8)),
            [0x00, 0x00, 0x00, 0x00, 0x00, 0x6A, 0xCF, 0xC0]
        )
    }

    func testPongMatchingOwnPingIsNotEchoed() throws {
        let session = Session(config: config)

        let sent = session.tick(nowMicros: 1_000_000)
        XCTAssertEqual(sent.count, 1)

        let pongPayload = try frame(from: encodePing(timestamp: 1_000_000)).payload
        XCTAssertEqual(
            session.handle(Frame(type: MessageType.ping.rawValue, payload: pongPayload), nowMicros: 1_000_100),
            []
        )
    }

    func testCtrlRequestsKeyframe() {
        let session = Session(config: config)
        XCTAssertEqual(
            session.handle(Frame(type: MessageType.ctrl.rawValue, payload: Data([1])), nowMicros: 0),
            [.requestKeyframe]
        )
    }

    func testByeCloses() {
        let session = Session(config: config)
        let actions = session.handle(Frame(type: MessageType.bye.rawValue, payload: Data()), nowMicros: 0)
        XCTAssertEqual(actions.count, 1)
        guard case .close = actions[0] else {
            return XCTFail("expected close, got \(actions)")
        }
    }

    func testUnknownTypeIsIgnored() {
        let session = Session(config: config)
        XCTAssertEqual(
            session.handle(Frame(type: MessageType.feedback.rawValue, payload: Data()), nowMicros: 0),
            []
        )
    }

    func testMalformedHelloCloses() {
        let session = Session(config: config)
        let actions = session.handle(Frame(type: MessageType.hello.rawValue, payload: Data([0])), nowMicros: 0)
        XCTAssertEqual(actions.count, 1)
        guard case .close = actions[0] else {
            return XCTFail("expected close, got \(actions)")
        }
    }

    func testTickSendsKeepaliveAfterOneSecond() throws {
        let session = Session(config: config)

        XCTAssertEqual(session.tick(nowMicros: 999_999), [])

        let actions = session.tick(nowMicros: 1_000_000)
        XCTAssertEqual(actions.count, 1)
        guard case .send(let frame) = actions[0] else {
            return XCTFail("expected send, got \(actions)")
        }
        XCTAssertEqual(frame.type, MessageType.ping.rawValue)
        XCTAssertEqual(try decodePing(frame.payload), 1_000_000)

        XCTAssertEqual(session.tick(nowMicros: 1_500_000), [])
    }
}