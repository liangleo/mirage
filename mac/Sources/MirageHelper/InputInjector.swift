import Foundation
import CoreGraphics
import ApplicationServices
import Carbon.HIToolbox
import MirageCore

public enum InputControl {
    public static var pauseFileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Mirage/input_paused")
    }

    public static var isPaused: Bool {
        FileManager.default.fileExists(atPath: pauseFileURL.path)
    }

    public static func setPaused(_ paused: Bool) {
        if paused {
            let directory = pauseFileURL.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: pauseFileURL.path, contents: nil)
        } else {
            try? FileManager.default.removeItem(at: pauseFileURL)
        }
    }

    public static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    public static var secureInput: Bool { IsSecureEventInputEnabled() }
}

public final class InputInjector: @unchecked Sendable {
    private let displayID: CGDirectDisplayID
    private let post: (CGEvent) -> Void
    private let accessibilityGranted: () -> Bool
    private let secureInput: () -> Bool
    private let nowMicros: () -> UInt64
    private let lock = NSLock()

    private var pressedMouse: Set<UInt16> = []
    private var pressedKeys: [UInt16: KeyInput] = [:]
    private var pressedModifierFlags: UInt8 = 0
    private var lastPoint = CGPoint.zero
    private var lastClickMicros: UInt64 = 0
    private var lastClickState: Int64 = 1
    private let debug = ProcessInfo.processInfo.environment["MIRAGE_DEBUG"] == "1"

    public init(
        displayID: CGDirectDisplayID,
        post: @escaping (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        accessibilityGranted: @escaping () -> Bool = { AXIsProcessTrusted() },
        secureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        nowMicros: @escaping () -> UInt64 = monotonicMicros
    ) {
        self.displayID = displayID
        self.post = post
        self.accessibilityGranted = accessibilityGranted
        self.secureInput = secureInput
        self.nowMicros = nowMicros
    }

    public var isPaused: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return paused
        }
        set {
            lock.lock()
            let wasPaused = paused
            paused = newValue
            lock.unlock()
            if newValue && !wasPaused {
                releaseAll()
            }
        }
    }

    private var paused = false

    private var keyboardAllowed: Bool {
        accessibilityGranted() && !secureInput()
    }

    public func inject(_ event: InputEvent) {
        guard !isPaused else { return }
        switch event {
        case .pointer(let samples):
            for sample in samples {
                injectPointer(sample)
            }
        case .key(let key):
            injectKey(key)
        case .text(let text):
            injectText(text)
        case .scroll(let scroll):
            injectScroll(scroll)
        case .releaseAll:
            releaseAll()
        }
    }

    public func releaseAll() {
        let pending: ([UInt16], [KeyInput])
        lock.lock()
        pending = (Array(pressedMouse), Array(pressedKeys.values))
        var remainingFlags = pressedModifierFlags
        pressedMouse.removeAll()
        pressedKeys.removeAll()
        pressedModifierFlags = 0
        lock.unlock()

        for button in pending.0 {
            guard let event = mouseEvent(type: type(for: button, down: false), at: lastPoint, button: button) else { continue }
            event.setIntegerValueField(.mouseEventClickState, value: lastClickState)
            post(event)
        }
        for key in pending.1 {
            guard let event = keyUpEvent(for: key, flags: keyFlags(for: key, remaining: &remainingFlags)) else {
                continue
            }
            post(event)
        }
        if debug {
            print(String(format: "input release_all mouse=%d keys=%d", pending.0.count, pending.1.count))
        }
    }

    public static func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    private func injectPointer(_ sample: PointerSample) {
        let point = mapPoint(sample.x, sample.y)
        let button = primaryButton(sample.buttons)

        switch sample.kind {
        case .hover:
            guard !isAnyButtonPressedLocked(sample.buttons) else { return }
            lastPoint = point
            postMouse(.mouseMoved, at: point, button: .left, clickState: 1)
        case .down:
            lock.lock()
            pressedMouse.insert(sample.buttons)
            let clickState = nextClickState(at: point)
            lastClickState = clickState
            lastPoint = point
            lock.unlock()
            if debug {
                print(String(format: "input down button=%u x=%.3f y=%.3f", sample.buttons, sample.x, sample.y))
            }
            postMouse(type(for: button, down: true, dragging: false), at: point, button: button, clickState: clickState)
        case .move:
            let dragging = isAnyButtonPressedLocked(sample.buttons)
            lastPoint = point
            if dragging {
                postMouse(type(for: button, down: true, dragging: true), at: point, button: button, clickState: lastClickState)
            } else {
                postMouse(.mouseMoved, at: point, button: .left, clickState: 1)
            }
        case .up:
            lock.lock()
            pressedMouse.remove(sample.buttons)
            let clickState = lastClickState
            lastPoint = point
            lock.unlock()
            postMouse(type(for: button, down: false), at: point, button: button, clickState: clickState)
        case .cancel:
            releaseAll()
        }
    }

    private func injectKey(_ key: KeyInput) {
        let flags = modifierFlags(key.modifiers)
        guard isModifierKey(key.keycode) else {
            guard keyboardAllowed else { return }
            let macCode = Self.keycodeMap[key.keycode] ?? 0
            let event = CGEvent(keyboardEventSource: nil, virtualKey: macCode, keyDown: key.action == .down)
            event?.flags = flags
            if key.action == .down, key.unicode != 0, let scalar = UnicodeScalar(key.unicode) {
                var utf16 = Array(String(scalar).utf16)
                event?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            }
            if let event {
                post(event)
            }
            if debug {
                print(String(format: "input key action=%u code=%u unicode=%u", key.action.rawValue, key.keycode, key.unicode))
            }
            return
        }

        guard keyboardAllowed else { return }
        let macCode = Self.keycodeMap[key.keycode] ?? 0
        lock.lock()
        if key.action == .down {
            pressedKeys[key.keycode] = key
            pressedModifierFlags |= modifierBit(for: key.keycode)
        } else {
            pressedKeys.removeValue(forKey: key.keycode)
            pressedModifierFlags &= ~modifierBit(for: key.keycode)
        }
        let activeFlags = flags.union(modifierFlags(pressedModifierFlags))
        lock.unlock()

        let event = CGEvent(keyboardEventSource: nil, virtualKey: macCode, keyDown: key.action == .down)
        event?.flags = activeFlags
        event?.type = .flagsChanged
        if let event {
            post(event)
        }
    }

    private func injectText(_ text: TextInput) {
        guard keyboardAllowed else { return }
        let units = Array(text.text.utf16)
        var index = 0
        while index < units.count {
            let end = min(index + 20, units.count)
            var chunk = Array(units[index..<end])
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true) else { return }
            event.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            post(event)
            index = end
        }
        if debug {
            print(String(format: "input text utf16=%d", units.count))
        }
    }

    private func injectScroll(_ scroll: ScrollInput) {
        let units: CGScrollEventUnit = scroll.flags & ScrollFlags.precise != 0 ? .pixel : .line
        let dy = Int32((scroll.dy * (units == .pixel ? 1 : 10)).rounded())
        let dx = Int32((scroll.dx * (units == .pixel ? 1 : 10)).rounded())
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: units,
            wheelCount: 2,
            wheel1: dy,
            wheel2: dx,
            wheel3: 0
        ) else { return }
        event.flags = scroll.flags & ScrollFlags.command != 0 ? .maskCommand : []
        event.location = lastPoint
        post(event)
    }

    private func postMouse(_ type: CGEventType, at point: CGPoint, button: CGMouseButton, clickState: Int64) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: type,
            mouseCursorPosition: point,
            mouseButton: button
        ) else { return }
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        post(event)
    }

    private func mouseEvent(type: CGEventType, at point: CGPoint, button: UInt16) -> CGEvent? {
        let cgButton = cgButton(button)
        return CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: cgButton)
    }

    private func mapPoint(_ x: Float, _ y: Float) -> CGPoint {
        let bounds = CGDisplayBounds(displayID)
        let clampedX = CGFloat(min(max(x, 0), 1))
        let clampedY = CGFloat(min(max(y, 0), 1))
        return CGPoint(
            x: bounds.minX + clampedX * bounds.width,
            y: bounds.minY + clampedY * bounds.height
        )
    }

    private func nextClickState(at point: CGPoint) -> Int64 {
        let now = nowMicros()
        let near = hypot(point.x - lastPoint.x, point.y - lastPoint.y) <= 5
        defer { lastClickMicros = now }
        guard near, now - lastClickMicros <= 500_000 else { return 1 }
        return lastClickState == 2 ? 1 : 2
    }

    private func isAnyButtonPressedLocked(_ buttons: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pressedMouse.contains(buttons) && buttons != 0
    }

    private func primaryButton(_ buttons: UInt16) -> CGMouseButton {
        if buttons & 2 != 0 { return .right }
        if buttons & 4 != 0 { return .center }
        return .left
    }

    private func cgButton(_ buttons: UInt16) -> CGMouseButton {
        primaryButton(buttons)
    }

    private func type(for button: CGMouseButton, down: Bool, dragging: Bool = false) -> CGEventType {
        if dragging && down {
            switch button {
            case .left: return .leftMouseDragged
            case .right: return .rightMouseDragged
            default: return .otherMouseDragged
            }
        }
        switch button {
        case .left: return down ? .leftMouseDown : .leftMouseUp
        case .right: return down ? .rightMouseDown : .rightMouseUp
        default: return down ? .otherMouseDown : .otherMouseUp
        }
    }

    private func type(for buttons: UInt16, down: Bool) -> CGEventType {
        type(for: primaryButton(buttons), down: down)
    }

    private func keyFlags(for key: KeyInput, remaining: inout UInt8) -> CGEventFlags {
        guard isModifierKey(key.keycode) else { return [] }
        remaining &= ~modifierBit(for: key.keycode)
        return modifierFlags(remaining)
    }

    private func keyUpEvent(for key: KeyInput, flags: CGEventFlags) -> CGEvent? {
        let macCode = Self.keycodeMap[key.keycode] ?? 0
        let event = CGEvent(keyboardEventSource: nil, virtualKey: macCode, keyDown: false)
        event?.flags = flags
        if isModifierKey(key.keycode) {
            event?.type = .flagsChanged
        }
        return event
    }

    private func modifierFlags(_ bits: UInt8) -> CGEventFlags {
        var flags: CGEventFlags = []
        if bits & InputModifiers.shift != 0 { flags.insert(.maskShift) }
        if bits & InputModifiers.control != 0 { flags.insert(.maskControl) }
        if bits & InputModifiers.option != 0 { flags.insert(.maskAlternate) }
        if bits & InputModifiers.command != 0 { flags.insert(.maskCommand) }
        if bits & InputModifiers.capsLock != 0 { flags.insert(.maskAlphaShift) }
        if bits & InputModifiers.fn != 0 { flags.insert(.maskSecondaryFn) }
        return flags
    }

    private func modifierBit(for keycode: UInt16) -> UInt8 {
        switch keycode {
        case 57, 58: return InputModifiers.option
        case 59, 60: return InputModifiers.shift
        case 113, 114: return InputModifiers.control
        case 117, 118: return InputModifiers.command
        case 115: return InputModifiers.capsLock
        case 119: return InputModifiers.fn
        default: return 0
        }
    }

    private func isModifierKey(_ keycode: UInt16) -> Bool {
        modifierBit(for: keycode) != 0
    }

    private static let keycodeMap: [UInt16: CGKeyCode] = [
        29: 0, 30: 11, 31: 8, 32: 2, 33: 14, 34: 3, 35: 5, 36: 4,
        37: 34, 38: 38, 39: 40, 40: 37, 41: 46, 42: 45, 43: 31, 44: 35,
        45: 12, 46: 15, 47: 1, 48: 17, 49: 32, 50: 9, 51: 13, 52: 7,
        53: 16, 54: 6,
        7: 29, 8: 18, 9: 19, 10: 20, 11: 21, 12: 23, 13: 22, 14: 26,
        15: 28, 16: 25,
        55: 43, 56: 47, 68: 50, 69: 27, 70: 24, 71: 33, 72: 30,
        73: 42, 74: 41, 75: 39, 76: 44,
        61: 48, 62: 49, 66: 36, 67: 51, 112: 117, 111: 53,
        19: 126, 20: 125, 21: 123, 22: 124,
        122: 115, 123: 119, 92: 116, 93: 121, 124: 114,
        57: 58, 58: 61, 59: 56, 60: 60,
        113: 59, 114: 62, 117: 55, 118: 54, 115: 57, 119: 63,
        131: 122, 132: 120, 133: 99, 134: 118, 135: 96, 136: 97,
        137: 98, 138: 100, 139: 101, 140: 109, 141: 103, 142: 111,
    ]
}