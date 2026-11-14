// Generates Mirage app icons:
//   assets/icon/mirage-1024.png
//   build/AppIcon.iconset/*.png  (for iconutil)
//   android/app/src/main/res/mipmap-*/ic_launcher.png
// Run from the repository root: swift tools/make_icon.swift
import AppKit
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

func color(_ value: Int, alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((value >> 16) & 0xff) / 255.0,
        green: CGFloat((value >> 8) & 0xff) / 255.0,
        blue: CGFloat(value & 0xff) / 255.0,
        alpha: alpha
    )
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("cannot create context")
    }
    context.setAllowsAntialiasing(true)

    let inset = s * 0.06
    let backgroundRect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    context.addPath(CGPath(
        roundedRect: backgroundRect,
        cornerWidth: s * 0.22,
        cornerHeight: s * 0.22,
        transform: nil
    ))
    context.clip()
    let background = CGGradient(
        colorsSpace: space,
        colors: [color(0x0B1220), color(0x1E293B)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        background,
        start: CGPoint(x: 0, y: s),
        end: CGPoint(x: s, y: 0),
        options: []
    )
    context.resetClip()

    let backRect = CGRect(x: s * 0.20, y: s * 0.30, width: s * 0.46, height: s * 0.34)
    context.setStrokeColor(color(0x38BDF8))
    context.setLineWidth(max(2, s * 0.024))
    context.addPath(CGPath(
        roundedRect: backRect,
        cornerWidth: s * 0.055,
        cornerHeight: s * 0.055,
        transform: nil
    ))
    context.strokePath()

    let frontRect = CGRect(x: s * 0.34, y: s * 0.38, width: s * 0.46, height: s * 0.34)
    context.saveGState()
    context.addPath(CGPath(
        roundedRect: frontRect,
        cornerWidth: s * 0.055,
        cornerHeight: s * 0.055,
        transform: nil
    ))
    context.clip()
    let screen = CGGradient(
        colorsSpace: space,
        colors: [color(0x22D3EE), color(0x8B5CF6)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        screen,
        start: CGPoint(x: frontRect.minX, y: frontRect.maxY),
        end: CGPoint(x: frontRect.maxX, y: frontRect.minY),
        options: []
    )
    context.restoreGState()

    context.setFillColor(CGColor(gray: 1, alpha: 0.85))
    let bar = CGRect(
        x: frontRect.minX + s * 0.05,
        y: frontRect.maxY - s * 0.10,
        width: s * 0.12,
        height: max(1.5, s * 0.022)
    )
    context.addPath(CGPath(
        roundedRect: bar,
        cornerWidth: bar.height / 2,
        cornerHeight: bar.height / 2,
        transform: nil
    ))
    context.fillPath()

    let spark = CGPoint(x: s * 0.79, y: s * 0.77)
    let radius = s * 0.045
    context.setFillColor(color(0xE0F2FE, alpha: 0.95))
    context.addEllipse(in: CGRect(
        x: spark.x - radius * 0.35,
        y: spark.y - radius,
        width: radius * 0.7,
        height: radius * 2
    ))
    context.fillPath()
    context.addEllipse(in: CGRect(
        x: spark.x - radius,
        y: spark.y - radius * 0.35,
        width: radius * 2,
        height: radius * 0.7
    ))
    context.fillPath()

    return context.makeImage()!
}

func write(_ image: CGImage, to relativePath: String) {
    let url = root.appendingPathComponent(relativePath)
    try? FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let representation = NSBitmapImageRep(cgImage: image)
    guard let data = representation.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: url)
    print("wrote \(relativePath)")
}

write(drawIcon(size: 1024), to: "assets/icon/mirage-1024.png")

let iconSet: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]
for (name, size) in iconSet {
    write(drawIcon(size: size), to: "build/AppIcon.iconset/\(name)")
}

let androidMipmaps: [(String, Int)] = [
    ("mdpi", 48),
    ("hdpi", 72),
    ("xhdpi", 96),
    ("xxhdpi", 144),
    ("xxxhdpi", 192),
]
for (density, size) in androidMipmaps {
    write(
        drawIcon(size: size),
        to: "android/app/src/main/res/mipmap-\(density)/ic_launcher.png"
    )
}