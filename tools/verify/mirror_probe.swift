import CoreGraphics
import Foundation

var count: UInt32 = 0
CGGetActiveDisplayList(0, nil, &count)
var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
CGGetActiveDisplayList(count, &ids, &count)

for id in ids {
    let bounds = CGDisplayBounds(id)
    print("id=\(id) main=\(CGDisplayIsMain(id)) active=\(CGDisplayIsActive(id)) online=\(CGDisplayIsOnline(id)) mirrorSet=\(CGDisplayIsInMirrorSet(id)) mirrors=\(CGDisplayMirrorsDisplay(id)) bounds=\(Int(bounds.origin.x)),\(Int(bounds.origin.y)) \(Int(bounds.width))x\(Int(bounds.height))")
}
print("main=\(CGMainDisplayID()) null=\(kCGNullDirectDisplay)")