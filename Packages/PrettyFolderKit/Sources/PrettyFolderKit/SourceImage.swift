import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// A decoded picture, ready to be drawn onto a folder icon.
///
/// Bitmaps are decoded once, already downsampled and rotated according to their EXIF
/// orientation. Vector files (PDF, SVG) stay vector so they are sharp at every icon size.
public final class SourceImage {
    public enum Content {
        case bitmap(CGImage)
        case vector(NSImage)
    }

    public let content: Content

    /// Natural size, used for the aspect ratio: pixels for bitmaps, points for vectors.
    public let size: CGSize

    public init(bitmap: CGImage) {
        content = .bitmap(bitmap)
        size = CGSize(width: bitmap.width, height: bitmap.height)
    }

    init(vector: NSImage) {
        content = .vector(vector)
        size = vector.size
    }

    public var hasAlpha: Bool {
        switch content {
        case .vector:
            return true
        case .bitmap(let image):
            switch image.alphaInfo {
            case .none, .noneSkipFirst, .noneSkipLast: return false
            default: return true
            }
        }
    }

    /// Draws the picture into `rect` of the current context.
    func draw(in rect: CGRect, context: CGContext) {
        switch content {
        case .bitmap(let image):
            context.draw(image, in: rect)
        case .vector(let image):
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    /// A bitmap copy with the longer side at most `maxSide` pixels (vectors are rasterized).
    public func bitmap(maxSide: Int) -> CGImage? {
        switch content {
        case .bitmap(let image) where max(image.width, image.height) <= maxSide:
            return image
        default:
            guard size.width > 0, size.height > 0 else { return nil }
            let scale = CGFloat(maxSide) / max(size.width, size.height)
            let width = max(1, Int((size.width * scale).rounded()))
            let height = max(1, Int((size.height * scale).rounded()))
            guard let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .high
            draw(in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
            return context.makeImage()
        }
    }
}

public enum ImageLoaderError: LocalizedError, Equatable {
    case unreadable(String)
    case notAnImage(String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let name): return "“\(name)” could not be read."
        case .notAnImage(let name): return "“\(name)” is not an image PrettyFolder can use."
        }
    }
}

/// Opens pictures in every format macOS understands: JPEG, PNG, HEIC, WebP, AVIF,
/// GIF, TIFF, BMP, ICNS, PSD, RAW, JPEG XL, PDF, SVG and anything Quick Look can preview.
public enum ImageLoader {
    /// Bitmaps are downsampled so their shorter side is at most this many pixels. The
    /// largest icon is 1024 px, so this keeps full quality even for a picture that
    /// fills the whole canvas, while a 100-megapixel photo never sits in memory.
    public static let maxShortSide = 1024
    /// Caps panoramas and other extreme aspect ratios.
    public static let maxLongSide = 4096

    /// Types worth offering in a file picker or accepting from a drag.
    public static let acceptedTypes: [UTType] = [.image, .pdf, .svg]

    public static func isImageType(_ type: UTType) -> Bool {
        acceptedTypes.contains { type.conforms(to: $0) }
    }

    public static func isImageFile(_ url: URL) -> Bool {
        if let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType {
            return isImageType(type)
        }
        return UTType(filenameExtension: url.pathExtension).map(isImageType) ?? false
    }

    static func isVectorType(_ type: UTType) -> Bool {
        type.conforms(to: .pdf) || type.conforms(to: .svg)
    }

    /// Loads an image file synchronously. Use `loadAllowingQuickLook` for the widest support.
    public static func load(contentsOf url: URL) throws -> SourceImage {
        let name = url.lastPathComponent
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: url.pathExtension)

        if let type, isVectorType(type) {
            if let image = NSImage(contentsOf: url), let vector = validVector(image) {
                return vector
            }
            throw ImageLoaderError.unreadable(name)
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = decode(source) {
            return SourceImage(bitmap: image)
        }

        // Some formats only NSImage knows about.
        if let image = NSImage(contentsOf: url), let vector = validVector(image) {
            return vector
        }
        throw ImageLoaderError.notAnImage(name)
    }

    /// Like `load(contentsOf:)`, but falls back to Quick Look for image formats
    /// ImageIO cannot decode on this macOS version.
    public static func loadAllowingQuickLook(contentsOf url: URL) async throws -> SourceImage {
        do {
            return try load(contentsOf: url)
        } catch {
            guard isImageFile(url), let image = await quickLookImage(for: url) else { throw error }
            return SourceImage(bitmap: image)
        }
    }

    /// Loads image data, for example from a drag or the clipboard.
    public static func load(data: Data, typeHint: UTType? = nil, name: String = "Image") throws -> SourceImage {
        if let typeHint, isVectorType(typeHint) {
            if let image = NSImage(data: data), let vector = validVector(image) { return vector }
            throw ImageLoaderError.unreadable(name)
        }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
           let image = decode(source) {
            return SourceImage(bitmap: image)
        }
        if let image = NSImage(data: data), let vector = validVector(image) { return vector }
        throw ImageLoaderError.notAnImage(name)
    }

    private static func validVector(_ image: NSImage) -> SourceImage? {
        guard image.isValid, image.size.width > 0, image.size.height > 0, !image.representations.isEmpty else { return nil }
        return SourceImage(vector: image)
    }

    /// Decodes the primary frame, downsampled and with the EXIF orientation applied.
    static func decode(_ source: CGImageSource) -> CGImage? {
        guard CGImageSourceGetCount(source) > 0 else { return nil }
        let index = CGImageSourceGetPrimaryImageIndex(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              pixelWidth > 0, pixelHeight > 0
        else { return nil }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let rotated = (5...8).contains(orientation)
        let width = Double(rotated ? pixelHeight : pixelWidth)
        let height = Double(rotated ? pixelWidth : pixelHeight)

        let scale = min(1, Double(maxShortSide) / min(width, height), Double(maxLongSide) / max(width, height))
        let maxPixelSize = max(1, Int((max(width, height) * scale).rounded(.up)))

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    static func quickLookImage(for url: URL) async -> CGImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: maxShortSide, height: maxShortSide),
            scale: 1,
            representationTypes: .thumbnail
        )
        return try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
    }
}
