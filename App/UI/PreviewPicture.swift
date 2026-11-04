import AppKit
import PrettyFolderKit

/// Pictures for the editor: small enough to stay quick, sharp enough for its size.
enum PreviewPicture {
    /// The longer side of a picture in the editor: as big as the ones icons are made from, so a
    /// picture made several times as big as the folder stays sharp there too.
    nonisolated static let maxSide = 2048

    /// Always a bitmap: vectors are rasterized at full size, so tiny SVGs stay sharp too.
    /// Reads and decodes the file, so better not on the main thread.
    nonisolated static func load(_ url: URL) -> SourceImage? {
        guard let picture = try? ImageLoader.load(contentsOf: url),
              let bitmap = picture.bitmap(maxSide: maxSide)
        else { return nil }
        return SourceImage(bitmap: bitmap, keepingSmallerCopies: true)
    }

    /// A made-up landscape for previewing the default look before any picture is chosen.
    static let sample: SourceImage = {
        let width = 900, height = 600
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SourceImage(bitmap: blank) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.62, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.80, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.73, blue: 0.95, alpha: 1),
        ])?.draw(in: rect, angle: 90)
        NSColor(srgbRed: 1, green: 0.93, blue: 0.7, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 560, y: 300, width: 150, height: 150)).fill()
        let far = NSBezierPath()
        far.move(to: NSPoint(x: 0, y: 160))
        far.line(to: NSPoint(x: 230, y: 380))
        far.line(to: NSPoint(x: 420, y: 230))
        far.line(to: NSPoint(x: 640, y: 420))
        far.line(to: NSPoint(x: 900, y: 200))
        far.line(to: NSPoint(x: 900, y: 0))
        far.line(to: NSPoint(x: 0, y: 0))
        NSColor(srgbRed: 0.36, green: 0.42, blue: 0.62, alpha: 1).setFill()
        far.fill()
        let near = NSBezierPath()
        near.move(to: NSPoint(x: 0, y: 90))
        near.curve(to: NSPoint(x: 900, y: 120), controlPoint1: NSPoint(x: 300, y: 260), controlPoint2: NSPoint(x: 600, y: 20))
        near.line(to: NSPoint(x: 900, y: 0))
        near.line(to: NSPoint(x: 0, y: 0))
        NSColor(srgbRed: 0.2, green: 0.45, blue: 0.4, alpha: 1).setFill()
        near.fill()
        NSGraphicsContext.restoreGraphicsState()
        return SourceImage(bitmap: context.makeImage() ?? blank)
    }()

    private static let blank: CGImage = {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()
}
