#!/usr/bin/env swift
// Draws the PrettyFolder app icon at every size the asset catalog needs.
// Usage: swift Scripts/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".", isDirectory: true)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Everything is drawn on a 1024 canvas (y up) and scaled down.
func drawIcon(in ctx: CGContext) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!

    // Rounded-square plate, inset to the standard macOS icon grid (824 pt body).
    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 186, cornerHeight: 186, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.28))
    ctx.addPath(platePath)
    ctx.setFillColor(color(0x2A3170))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(platePath)
    ctx.clip()
    let background = CGGradient(colorsSpace: space, colors: [color(0x6C7BFF), color(0x8B5CF6), color(0xD9467A)] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(background, start: CGPoint(x: 160, y: 924), end: CGPoint(x: 864, y: 100), options: [])
    // Soft light from the top.
    let glow = CGGradient(colorsSpace: space, colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 980), startRadius: 0, endCenter: CGPoint(x: 512, y: 980), endRadius: 620, options: [])
    ctx.restoreGState()

    // Folder back with its tab.
    let back = CGMutablePath()
    back.move(to: CGPoint(x: 232, y: 300))
    back.addLine(to: CGPoint(x: 232, y: 686))
    back.addQuadCurve(to: CGPoint(x: 268, y: 722), control: CGPoint(x: 232, y: 722))
    back.addLine(to: CGPoint(x: 418, y: 722))
    back.addQuadCurve(to: CGPoint(x: 452, y: 704), control: CGPoint(x: 438, y: 722))
    back.addLine(to: CGPoint(x: 478, y: 672))
    back.addQuadCurve(to: CGPoint(x: 508, y: 660), control: CGPoint(x: 488, y: 660))
    back.addLine(to: CGPoint(x: 756, y: 660))
    back.addQuadCurve(to: CGPoint(x: 792, y: 624), control: CGPoint(x: 792, y: 660))
    back.addLine(to: CGPoint(x: 792, y: 300))
    back.closeSubpath()
    ctx.addPath(back)
    ctx.setFillColor(color(0xFFFFFF, 0.55))
    ctx.fillPath()

    // Folder front.
    let front = CGRect(x: 216, y: 236, width: 592, height: 392)
    let frontPath = CGPath(roundedRect: front, cornerWidth: 44, cornerHeight: 44, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 22, color: color(0x1E1250, 0.35))
    ctx.addPath(frontPath)
    ctx.setFillColor(color(0xFFFFFF))
    ctx.fillPath()
    ctx.restoreGState()

    // The picture on the folder: a little landscape.
    let photo = front.insetBy(dx: 44, dy: 44)
    let photoPath = CGPath(roundedRect: photo, cornerWidth: 26, cornerHeight: 26, transform: nil)
    ctx.saveGState()
    ctx.addPath(photoPath)
    ctx.clip()
    let sky = CGGradient(colorsSpace: space, colors: [color(0xFFB36B), color(0xFF7A8A), color(0x7C83FF)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: photo.minY), end: CGPoint(x: 0, y: photo.maxY), options: [])
    ctx.setFillColor(color(0xFFF1B8))
    ctx.fillEllipse(in: CGRect(x: photo.minX + 300, y: photo.minY + 150, width: 104, height: 104))
    let far = CGMutablePath()
    far.move(to: CGPoint(x: photo.minX, y: photo.minY + 90))
    far.addLine(to: CGPoint(x: photo.minX + 150, y: photo.minY + 205))
    far.addLine(to: CGPoint(x: photo.minX + 255, y: photo.minY + 120))
    far.addLine(to: CGPoint(x: photo.minX + 380, y: photo.minY + 230))
    far.addLine(to: CGPoint(x: photo.maxX, y: photo.minY + 100))
    far.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
    far.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
    far.closeSubpath()
    ctx.addPath(far)
    ctx.setFillColor(color(0x4B3F9E))
    ctx.fillPath()
    let near = CGMutablePath()
    near.move(to: CGPoint(x: photo.minX, y: photo.minY + 50))
    near.addCurve(to: CGPoint(x: photo.maxX, y: photo.minY + 70), control1: CGPoint(x: photo.minX + 170, y: photo.minY + 150), control2: CGPoint(x: photo.minX + 330, y: photo.minY + 10))
    near.addLine(to: CGPoint(x: photo.maxX, y: photo.minY))
    near.addLine(to: CGPoint(x: photo.minX, y: photo.minY))
    near.closeSubpath()
    ctx.addPath(near)
    ctx.setFillColor(color(0x2B2A6B))
    ctx.fillPath()
    ctx.restoreGState()
}

let sizes: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in sizes {
    let ctx = CGContext(data: nil, width: size.pixels, height: size.pixels, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.scaleBy(x: CGFloat(size.pixels) / 1024, y: CGFloat(size.pixels) / 1024)
    drawIcon(in: ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(size.name + ".png"))
}

let images = sizes.map { size -> String in
    let parts = size.name.replacingOccurrences(of: "icon_", with: "").split(separator: "@")
    let scale = parts.count > 1 ? String(parts[1]) : "1x"
    return """
        { "filename" : "\(size.name).png", "idiom" : "mac", "scale" : "\(scale)", "size" : "\(parts[0])" }
    """
}
let contents = """
{
  "images" : [
\(images.joined(separator: ",\n"))
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}

"""
try contents.write(to: output.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Wrote \(sizes.count) icons to \(output.path)")
