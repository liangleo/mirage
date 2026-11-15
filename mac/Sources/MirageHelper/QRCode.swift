import AppKit
import CoreImage
import MirageCore

public func makeQRCode(for payload: PairingPayload, scale: CGFloat = 8) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator"),
          let url = payload.encodeURL() else { return nil }
    filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}