import Foundation
import CoreGraphics
import MirageCore

let arguments = CommandLine.arguments

if arguments.contains("--list-displays") {
    var count: UInt32 = 0
    CGGetActiveDisplayList(0, nil, &count)
    var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
    CGGetActiveDisplayList(count, &ids, &count)
    for id in ids {
        if let size = captureSize(for: id) {
            print("id=\(id) pixel=\(size.width)x\(size.height)")
        } else {
            print("id=\(id) pixel=unknown")
        }
    }
} else {
    print("usage: mirage-helper --list-displays")
}