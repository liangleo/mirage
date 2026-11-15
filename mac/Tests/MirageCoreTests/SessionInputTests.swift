import XCTest
import MirageCore
@testable import MirageHelper

final class SessionInputTests: XCTestCase {
    private let config = SessionConfig(
        width: 2560,
        height: 1600,
        fps: 60,
        codec: 1,
        bitrate: 20_000_000,
        rotation: 0
    )

    private func frame(from encoded: Data) throws -> Frame {
        var decoder = FrameDecoder()
        decoder.append(encoded)
        return try XCTUnwrap(try decoder.next())
    }

    private func sessionFrame(_ frame: Frame) throws -> Frame {
        var decoder = FrameDecoder()
        decoder.append(encodeFrame(frame))
        return try XCTUnwrap(try decoder.next())
    }

    private var sample: PointerSample {
        PointerSample(kind: .down, pointerID: 0, buttons: 1, x: 0.5, y: 0.5, pressure: 1, tiltX: 0, tiltY: 0, tsMicros: 1)
    }

    func testPointerKeyTextScrollProduceInjectActions() throws {
        let session = Session(config: config)

        let pointer = try sessionFrame(try encodeInput([sample]))
        XCTAssertEqual(session.handle(pointer, nowMicros: 0), [.inject(.pointer([sample]))])

        let key = KeyInput(action: .down, modifiers: InputModifiers.command, flags: 0, keycode: 29, unicode: 97, tsMicros: 1)
        XCTAssertEqual(try session.handle(sessionFrame(encodeKey(key)), nowMicros: 0), [.inject(.key(key))])

        let text = TextInput(text: "hi", tsMicros: 1)
        XCTAssertEqual(try session.handle(sessionFrame(try encodeText(text)), nowMicros: 0), [.inject(.text(text))])

        let scroll = ScrollInput(phase: .begin, flags: 0, dx: 0, dy: 3, tsMicros: 1)
        XCTAssertEqual(try session.handle(sessionFrame(try encodeScroll(scroll)), nowMicros: 0), [.inject(.scroll(scroll))])
    }

    func testMalformedInputIsIgnoredWithoutClosing() {
        let session = Session(config: config)
        XCTAssertEqual(session.handle(Frame(type: MessageType.input.rawValue, payload: Data([0])), nowMicros: 0), [])
        XCTAssertEqual(session.handle(Frame(type: MessageType.key.rawValue, payload: Data([1, 0, 0, 0])), nowMicros: 0), [])
        XCTAssertEqual(session.handle(Frame(type: MessageType.text.rawValue, payload: Data([0, 9])), nowMicros: 0), [])
        XCTAssertEqual(session.handle(Frame(type: MessageType.scroll.rawValue, payload: Data(repeating: 0, count: 3)), nowMicros: 0), [])
        XCTAssertEqual(session.handle(Frame(type: 200, payload: Data()), nowMicros: 0), [])
    }

    func testCtrlReleaseAllMapsToInjectReleaseAll() {
        let session = Session(config: config)
        XCTAssertEqual(
            session.handle(Frame(type: MessageType.ctrl.rawValue, payload: Data([CtrlCode.releaseAll])), nowMicros: 0),
            [.inject(.releaseAll)]
        )
        XCTAssertEqual(
            session.handle(Frame(type: MessageType.ctrl.rawValue, payload: Data([CtrlCode.requestKeyframe])), nowMicros: 0),
            [.requestKeyframe]
        )
        XCTAssertEqual(session.handle(Frame(type: MessageType.ctrl.rawValue, payload: Data([99])), nowMicros: 0), [])
    }

    func testSessionConfigCarriesInputCaps() throws {
        let session = Session(config: config)
        session.inputCaps = 0b111111
        let hello = Hello(
            protoVersion: 1,
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
        let actions = try session.handle(sessionFrame(try frame(from: encodeHello(hello))), nowMicros: 0)
        guard case .send(let configFrame) = actions.first else {
            return XCTFail("expected session config, got \(actions)")
        }
        XCTAssertEqual(try decodeSessionConfig(configFrame.payload).inputCaps, 0b111111)
    }

    func testRateLimiterDropsBurstBeyondLimit() {
        var limiter = InputRateLimiter()
        for _ in 0..<500 { XCTAssertTrue(limiter.allow(now: 10)) }
        XCTAssertFalse(limiter.allow(now: 10))
        XCTAssertTrue(limiter.allow(now: 1_000_010))
    }

    func testNonFinitePointerIsDropped() {
        let session = Session(config: config)
        var payload = Data([0, 1, 1, 0, 0, 0])
        payload.append(Data([0x7f, 0xc0, 0, 0]))
        payload.append(Data(repeating: 0, count: 24))
        XCTAssertEqual(payload.count, 34)
        XCTAssertEqual(session.handle(Frame(type: MessageType.input.rawValue, payload: payload), nowMicros: 0), [])
    }

    func testInputGateReasons() {
        XCTAssertNil(InputGate.disabledReason(caps: 0b111111, paused: false, allowed: true))
        XCTAssertEqual(InputGate.disabledReason(caps: 0, paused: false, allowed: true), 3)
        XCTAssertEqual(InputGate.disabledReason(caps: 0b111111, paused: true, allowed: true), 2)
        XCTAssertEqual(InputGate.disabledReason(caps: 0b111111, paused: false, allowed: false), 1)
    }
}