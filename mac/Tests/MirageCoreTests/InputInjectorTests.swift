import XCTest
import CoreGraphics
import MirageCore
import MirageHelper

final class InputInjectorTests: XCTestCase {
    private final class Capture {
        var events: [CGEvent] = []
    }

    private var capture: Capture!
    private var displayID: CGDirectDisplayID!

    override func setUp() {
        super.setUp()
        capture = Capture()
        displayID = CGMainDisplayID()
    }

    private func makeInjector(
        accessibility: Bool = true,
        secure: Bool = false,
        now: @escaping () -> UInt64 = { 0 }
    ) -> InputInjector {
        let captured = capture!
        return InputInjector(
            displayID: displayID,
            post: { captured.events.append($0) },
            accessibilityGranted: { accessibility },
            secureInput: { secure },
            nowMicros: now
        )
    }

    private func pointer(_ kind: PointerKind, x: Float, y: Float, buttons: UInt16 = 1, id: UInt8 = 0) -> PointerSample {
        PointerSample(
            kind: kind,
            pointerID: id,
            buttons: buttons,
            x: x,
            y: y,
            pressure: 1,
            tiltX: 0,
            tiltY: 0,
            tsMicros: 1
        )
    }

    private func key(_ keycode: UInt16, modifiers: UInt8 = 0, unicode: UInt32 = 0, down: Bool = true) -> KeyInput {
        KeyInput(
            action: down ? .down : .up,
            modifiers: modifiers,
            flags: 0,
            keycode: keycode,
            unicode: unicode,
            tsMicros: 1
        )
    }

    func testNormalizedCoordinatesMapToDisplayBoundsAndClamp() {
        let injector = makeInjector()
        let bounds = CGDisplayBounds(displayID)

        injector.inject(.pointer([pointer(.down, x: 0, y: 0)]))
        injector.inject(.pointer([pointer(.move, x: 1, y: 1, buttons: 0)]))
        injector.inject(.pointer([pointer(.move, x: 2, y: -1, buttons: 0)]))

        let downs = capture.events.filter { $0.type == .leftMouseDown }
        XCTAssertEqual(downs.first?.location.x ?? -1, bounds.minX, accuracy: 0.5)
        XCTAssertEqual(downs.first?.location.y ?? -1, bounds.minY, accuracy: 0.5)

        let moves = capture.events.filter { $0.type == .mouseMoved }
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves[0].location.x, bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(moves[0].location.y, bounds.maxY, accuracy: 0.5)
        XCTAssertEqual(moves[1].location.x, bounds.maxX, accuracy: 0.5)
        XCTAssertEqual(moves[1].location.y, bounds.minY, accuracy: 0.5)
    }

    func testLeftAndRightButtonsUseMatchingEventTypes() {
        let injector = makeInjector()
        injector.inject(.pointer([pointer(.down, x: 0.5, y: 0.5)]))
        injector.inject(.pointer([pointer(.up, x: 0.5, y: 0.5)]))

        XCTAssertEqual(capture.events.map(\.type), [.leftMouseDown, .leftMouseUp])
        XCTAssertEqual(capture.events[0].getIntegerValueField(.mouseEventButtonNumber), 0)
        XCTAssertEqual(capture.events[0].getIntegerValueField(.mouseEventClickState), 1)

        capture.events.removeAll()
        injector.inject(.pointer([pointer(.down, x: 0.5, y: 0.5, buttons: 2)]))
        injector.inject(.pointer([pointer(.up, x: 0.5, y: 0.5, buttons: 2)]))

        XCTAssertEqual(capture.events.map(\.type), [.rightMouseDown, .rightMouseUp])
        XCTAssertEqual(capture.events[0].getIntegerValueField(.mouseEventButtonNumber), 1)
        XCTAssertTrue(capture.events.allSatisfy { $0.type != .leftMouseDown })
    }

    func testSecondClickWithinWindowSetsClickState() {
        var now: UInt64 = 0
        let injector = makeInjector(now: { now })
        injector.inject(.pointer([pointer(.down, x: 0.5, y: 0.5)]))
        now = 100_000
        injector.inject(.pointer([pointer(.down, x: 0.5, y: 0.5)]))

        let downs = capture.events.filter { $0.type == .leftMouseDown }
        XCTAssertEqual(downs.map { $0.getIntegerValueField(.mouseEventClickState) }, [1, 2])
    }

    func testModifierAndKeyFlags() {
        let injector = makeInjector()
        injector.inject(.key(key(29, modifiers: InputModifiers.command | InputModifiers.shift, unicode: 0)))

        let event = try! XCTUnwrap(capture.events.first)
        XCTAssertTrue(event.flags.contains(.maskCommand))
        XCTAssertTrue(event.flags.contains(.maskShift))
        XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
    }

    func testUnicodeTextIsChunked() {
        let injector = makeInjector()
        let text = "abcdefghijklmnopqrstuvwxyz0123456789中文"
        injector.inject(.text(TextInput(text: text, tsMicros: 1)))

        XCTAssertGreaterThanOrEqual(capture.events.count, 2)
        var rebuilt = ""
        for event in capture.events {
            var length = 0
            var buffer = [UniChar](repeating: 0, count: 64)
            event.keyboardGetUnicodeString(maxStringLength: 64, actualStringLength: &length, unicodeString: &buffer)
            XCTAssertLessThanOrEqual(length, 20)
            rebuilt += String(utf16CodeUnits: buffer, count: length)
        }
        XCTAssertEqual(rebuilt, text)
    }

    func testReleaseAllClearsMouseAndModifiersOnce() {
        let injector = makeInjector()
        injector.inject(.pointer([pointer(.down, x: 0.5, y: 0.5)]))
        injector.inject(.key(key(117, modifiers: InputModifiers.command)))

        injector.releaseAll()
        XCTAssertEqual(capture.events.map(\.type), [.leftMouseDown, .flagsChanged, .leftMouseUp, .flagsChanged])
        XCTAssertFalse(capture.events.last!.flags.contains(.maskCommand))

        let count = capture.events.count
        injector.releaseAll()
        XCTAssertEqual(capture.events.count, count)
    }

    func testKeyboardBlockedWithoutAccessibilityButPointerStillWorks() {
        let injector = makeInjector(accessibility: false)
        injector.inject(.key(key(29, unicode: 97)))
        injector.inject(.text(TextInput(text: "hi", tsMicros: 1)))
        XCTAssertTrue(capture.events.isEmpty)

        injector.inject(.pointer([pointer(.down, x: 0.5, y: 0.5)]))
        XCTAssertEqual(capture.events.map(\.type), [.leftMouseDown])
    }

    func testKeyboardBlockedDuringSecureInput() {
        let injector = makeInjector(accessibility: true, secure: true)
        injector.inject(.key(key(117, modifiers: InputModifiers.command)))
        injector.inject(.text(TextInput(text: "secret", tsMicros: 1)))
        XCTAssertTrue(capture.events.isEmpty)
    }

    func testPausedDropsEverything() {
        let injector = makeInjector()
        injector.isPaused = true
        injector.inject(.pointer([pointer(.down, x: 0.5, y: 0.5)]))
        injector.inject(.key(key(29, unicode: 97)))
        injector.inject(.scroll(ScrollInput(phase: .change, flags: 0, dx: 1, dy: 1, tsMicros: 1)))
        XCTAssertTrue(capture.events.isEmpty)

        injector.isPaused = false
        injector.inject(.pointer([pointer(.down, x: 0.5, y: 0.5)]))
        XCTAssertEqual(capture.events.count, 1)
    }

    func testScrollCarriesDeltaAndCommandFlag() {
        let injector = makeInjector()
        injector.inject(.scroll(ScrollInput(phase: .begin, flags: ScrollFlags.precise, dx: 0, dy: 12, tsMicros: 1)))
        injector.inject(.scroll(ScrollInput(phase: .change, flags: ScrollFlags.command | ScrollFlags.precise, dx: 0, dy: -4, tsMicros: 2)))

        XCTAssertEqual(capture.events.count, 2)
        XCTAssertEqual(capture.events[0].getIntegerValueField(.scrollWheelEventPointDeltaAxis1), 12)
        XCTAssertTrue(capture.events[1].flags.contains(.maskCommand))
    }
}