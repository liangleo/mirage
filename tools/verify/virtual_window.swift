// Puts a red floating window on the first non-main display, for verifying
// that Mirage's extend mode captures the virtual display.
import AppKit
import CoreGraphics

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let screens = NSScreen.screens

func displayID(of screen: NSScreen) -> CGDirectDisplayID {
    let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    return number.map { CGDirectDisplayID($0.uint32Value) } ?? 0
}

let requested = CommandLine.arguments.count > 1 ? CGDirectDisplayID(UInt32(CommandLine.arguments[1]) ?? 0) : 0
let screen = requested != 0
    ? screens.first(where: { displayID(of: $0) == requested })
    : screens.first(where: { displayID(of: $0) != CGMainDisplayID() })

guard let screen else {
    print("no screen")
    exit(1)
}

let rect = NSRect(
    x: screen.frame.midX - 200,
    y: screen.frame.midY - 120,
    width: 400,
    height: 240
)
let window = NSWindow(
    contentRect: rect,
    styleMask: [.titled, .closable],
    backing: .buffered,
    defer: false,
    screen: screen
)
window.title = "Mirage Test Window"
window.backgroundColor = .systemRed
window.level = .floating
window.makeKeyAndOrderFront(nil)

var tick = 0
let timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
    tick += 1
    let hue = CGFloat(tick % 100) / 100.0
    window.backgroundColor = NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1)
}
_ = timer

print("window screen=\(screen.frame) main=\(CGMainDisplayID())")
fflush(stdout)
RunLoop.current.run(until: Date(timeIntervalSinceNow: 10))