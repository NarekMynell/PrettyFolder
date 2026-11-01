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
    private let surfaces: SurfaceCache

    public init(base: NSImage = FolderArtwork.makeBaseIcon()) {
        self.base = base
        surfaces = SurfaceCache(base: base)
    }

    /// A multi-resolution icon, ready for `NSWorkspace.setIcon(_:forFile:options:)`.
    public func makeIcon(with picture: SourceImage, style: IconStyle, placement: PicturePlacement = .centered) -> NSImage? {
        let icon = NSImage(size: NSSize(width: 512, height: 512))
        for side in Self.pixelSizes {
            let rendered: Bool = autoreleasepool {
                guard let bitmap = render(picture, style: style, placement: placement, pixelSize: side) else { return false }
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
    public func render(
        _ picture: SourceImage?, style: IconStyle, placement: PicturePlacement = .centered, pixelSize side: Int
    ) -> CGImage? {
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
            Self.drawPicture(picture, style: style, placement: placement, canvas: canvas, on: surface(pixelSize: side), in: context)
        }
        return context.makeImage()
    }

    /// The folder's outline and its light and shade at a pixel size (see `FolderSurface`).
    public func surface(pixelSize side: Int) -> FolderSurface? {
        surfaces.surface(side)
    }

    /// Draws `picture` over a folder already on a `canvas` × `canvas` context with a
    /// bottom-left origin: rounded, never outside the folder's outline, and in the folder's
    /// light and shade. The editor previews with this too, so what it shows is what the
    /// icon gets.
    public static func drawPicture(
        _ picture: SourceImage,
        style: IconStyle,
        placement: PicturePlacement = .centered,
        canvas: CGFloat,
        on surface: FolderSurface?,
        in context: CGContext
    ) {
        let target = IconGeometry.targetRect(for: style, canvas: canvas, flipped: false)
        let drawRect = IconGeometry.imageRect(imageSize: picture.size, in: target, mode: style.mode, placement: placement, flipped: false)
        let visible = IconGeometry.visibleRect(imageSize: picture.size, in: target, mode: style.mode, placement: placement, flipped: false)
        let radius = IconGeometry.cornerRadius(for: visible, canvas: canvas)
        let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)

        context.saveGState()
        if let surface {
            context.clip(to: bounds, mask: surface.silhouette)
        }
        context.addPath(CGPath(roundedRect: visible, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
        if let shading = surface?.shading {
            // The light and shade go on the picture alone, in a layer of its own: where the
            // picture is see-through, the folder below already has them.
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            picture.draw(in: drawRect, context: context)
            context.setBlendMode(.sourceAtop)
            context.draw(shading, in: bounds)
            context.endTransparencyLayer()
        } else {
            picture.draw(in: drawRect, context: context)
        }
        context.restoreGState()
    }
}

/// The outline and the light are the same for every picture, so each size is worked out once.
private final class SurfaceCache: @unchecked Sendable {
    private let lock = NSLock()
    private let base: NSImage
    private var shape: FolderShape?
    private var surfaces: [Int: FolderSurface] = [:]

    init(base: NSImage) {
        self.base = base
    }

    func surface(_ side: Int) -> FolderSurface? {
        lock.withLock {
            if let surface = surfaces[side] { return surface }
            let shape = self.shape ?? FolderArtwork.measureShape(in: base) ?? .fallback
            self.shape = shape
            let surface = FolderArtwork.surface(of: base, side: side, shape: shape)
            surfaces[side] = surface
            return surface
        }
    }
}
