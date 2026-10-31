import AppKit

/// Draws a picture onto the folder icon.
///
/// Every size is rendered on its own instead of scaling one big bitmap down: the
/// system folder has hand-tuned small sizes and the picture is resampled once,
/// straight to the final pixel size.
public struct IconRenderer {
    /// The pixel sizes that end up in the icon file (16 pt through 512 pt @2x).
    public static let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]

    private let base: NSImage

    public init(base: NSImage = FolderArtwork.makeBaseIcon()) {
        self.base = base
    }

    /// A multi-resolution icon, ready for `NSWorkspace.setIcon(_:forFile:options:)`.
    public func makeIcon(with picture: SourceImage, style: IconStyle) -> NSImage? {
        let icon = NSImage(size: NSSize(width: 512, height: 512))
        for side in Self.pixelSizes {
            let rendered: Bool = autoreleasepool {
                guard let bitmap = render(picture, style: style, pixelSize: side) else { return false }
                let rep = NSBitmapImageRep(cgImage: bitmap)
                // All reps describe the same 512 pt image; NSImage picks by pixel density.
                rep.size = icon.size
                icon.addRepresentation(rep)
                return true
            }
            if !rendered { return nil }
        }
        return icon
    }

    /// One square bitmap of the folder with the picture on it.
    /// Passing `nil` draws the plain folder, which the editor uses as a backdrop.
    public func render(_ picture: SourceImage?, style: IconStyle, pixelSize side: Int) -> CGImage? {
        guard side > 0, let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        let canvas = CGFloat(side)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        base.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        if let picture {
            let target = IconGeometry.targetRect(for: style, canvas: canvas, flipped: false)
            let drawRect = IconGeometry.imageRect(imageSize: picture.size, in: target, mode: style.mode)
            let visible = IconGeometry.visibleRect(imageSize: picture.size, in: target, mode: style.mode)
            let radius = IconGeometry.cornerRadius(for: visible, canvas: canvas)

            context.saveGState()
            context.addPath(CGPath(roundedRect: visible, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            picture.draw(in: drawRect, context: context)
            context.restoreGState()
        }
        return context.makeImage()
    }
}
