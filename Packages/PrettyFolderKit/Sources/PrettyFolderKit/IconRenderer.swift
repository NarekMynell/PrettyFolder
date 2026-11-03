import AppKit

/// Draws a picture onto the folder icon.
///
/// Every size is rendered on its own instead of scaling one big bitmap down: the
/// system folder has hand-tuned small sizes and the picture is resampled once,
/// straight to the final pixel size.
public struct IconRenderer {
    /// The pixel sizes that end up in the icon file (16 pt through 512 pt @2x).
    public static let pixelSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// Goes up whenever the same look comes out differently, so icons drawn before can be
    /// drawn again. 2: the picture is painted on the folder rather than over it, and taken
    /// right up to its edges.
    public static let revision = 2

    private let base: NSImage
    private let surfaces: SurfaceCache

    public init(base: NSImage = FolderArtwork.makeBaseIcon()) {
        self.base = base
        surfaces = SurfaceCache(base: base)
    }

    /// A multi-resolution icon, ready for `NSWorkspace.setIcon(_:forFile:options:)`.
    public func makeIcon(with picture: SourceImage, style: IconStyle, placement: PicturePlacement = .natural) -> NSImage? {
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
        _ picture: SourceImage?, style: IconStyle, placement: PicturePlacement = .natural, pixelSize side: Int
    ) -> CGImage? {
        guard side > 0, let context = CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        let canvas = CGFloat(side)

        if let picture, let surface = surface(pixelSize: side) {
            Self.draw(picture, style: style, placement: placement, canvas: canvas, on: surface, in: context)
        } else {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            base.draw(in: NSRect(x: 0, y: 0, width: canvas, height: canvas), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            // Artwork that couldn't be measured: the picture goes over it, unshaped.
            if let picture {
                let layout = IconGeometry.layout(imageSize: picture.size, style: style, placement: placement, canvas: canvas, flipped: false)
                context.saveGState()
                context.addPath(layout.visible)
                context.clip()
                Self.drawPicture(picture, in: layout, context: context)
                context.restoreGState()
            }
        }
        return context.makeImage()
    }

    /// The folder's outline and its light and shade at a pixel size (see `FolderSurface`).
    public func surface(pixelSize side: Int) -> FolderSurface? {
        surfaces.surface(side)
    }

    /// Draws the folder with `picture` on it onto a `canvas` × `canvas` context with a
    /// bottom-left origin, in a layer of its own: the picture rounded, never outside the
    /// folder's outline, painted on the folder rather than over it, and in the folder's light
    /// and shade. The editor previews with this too, so what it shows is what the icon gets.
    public static func draw(
        _ picture: SourceImage,
        style: IconStyle,
        placement: PicturePlacement = .natural,
        canvas: CGFloat,
        on surface: FolderSurface,
        in context: CGContext
    ) {
        let layout = IconGeometry.layout(
            imageSize: picture.size, style: style, placement: placement, canvas: canvas, flipped: false, folder: surface.edges
        )
        let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.draw(surface.shadow, in: bounds)
        // The folder with the picture on it, added to its shadow: the two make the plain folder
        // again wherever the picture isn't.
        context.setBlendMode(.plusLighter)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.draw(surface.body, in: bounds)
        // The picture takes the folder's place as far as the folder covers each pixel, and
        // where it is see-through, the folder shows.
        context.setBlendMode(.sourceAtop)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.saveGState()
        context.addPath(layout.visible)
        context.clip()
        drawPicture(picture, in: layout, context: context)
        if let shading = surface.shading {
            // The light and shade go on the picture alone: where it is see-through, the folder
            // below already has them.
            context.setBlendMode(.sourceAtop)
            context.draw(shading, in: bounds)
        }
        context.restoreGState()
        context.endTransparencyLayer()
        context.endTransparencyLayer()
        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// Draws `picture` where `layout` puts it, turned as it says.
    public static func drawPicture(_ picture: SourceImage, in layout: PictureLayout, context: CGContext) {
        context.saveGState()
        context.concatenate(layout.transform)
        picture.draw(in: layout.uprightRect, context: context)
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
