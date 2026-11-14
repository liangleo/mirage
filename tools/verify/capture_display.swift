import AppKit
import CoreGraphics
import Foundation

guard CommandLine.arguments.count >= 3,
      let rawID = UInt32(CommandLine.arguments[1]) else {
    print("usage: capture_display <displayID> <out.png>")
    exit(2)
}

let displayID = CGDirectDisplayID(rawID)
guard let image = CGDisplayCreateImage(displayID) else {
    print("capture failed")
    exit(3)
}

let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else {
    exit(4)
}
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
print("saved \(image.width)x\(image.height)")