import AppKit
import UniformTypeIdentifiers

/// The system's own folder icon, which every custom icon is drawn on.
///
/// Nothing is bundled: the artwork comes from the running macOS, so icons made on
/// Sonoma look like Sonoma folders and icons made on Tahoe look like Tahoe folders.
public enum FolderArtwork {
    /// A fresh copy of the generic folder icon. `NSImage` is not meant to be drawn from
    /// several threads at once, so every renderer keeps its own instance.
    public static func makeBaseIcon() -> NSImage {
        NSWorkspace.shared.icon(for: .folder)
    }

    /// Where the folder's parts sit on the icon. Measured from the real artwork once per launch.
    public static let shape: FolderShape = measureShape(in: makeBaseIcon()) ?? .fallback

    /// The folder's tab, the raised strip in the top-left corner.
    public static var tabRegion: CGRect { shape.tab }

    /// Finds the folder's parts in the icon's pixels: the outline from the alpha channel,
    /// the tab from the rows at the top that stop well short of the right edge, and the
    /// front from the step in brightness where it starts, down the middle of the folder.
    static func measureShape(in icon: NSImage, side: Int = 256) -> FolderShape? {
        guard let pixels = pixels(of: icon, side: side) else { return nil }
        let bytesPerRow = side * 4

        // Row 0 of the buffer is the top of the image.
        func span(_ row: Int) -> (left: Int, right: Int)? {
            var left = -1, right = -1
            for column in 0..<side where pixels[row * bytesPerRow + column * 4 + 3] > 127 {
                if left < 0 { left = column }
                right = column
            }
            return left < 0 ? nil : (left, right)
        }

        let spans = (0..<side).map(span)
        guard let top = spans.firstIndex(where: { $0 != nil }),
              let bottom = spans.lastIndex(where: { $0 != nil }),
              let left = spans.compactMap({ $0?.left }).min(),
              let right = spans.compactMap({ $0?.right }).max()
        else { return nil }

        // The tab ends where a row first reaches (almost) all the way to the right.
        let reachesRight = { (row: Int) in (spans[row]?.right ?? 0) >= right - side / 20 }
        guard let bodyTop = (top..<side).first(where: reachesRight), bodyTop - top >= 2,
              let tabLeft = spans[top..<bodyTop].compactMap({ $0?.left }).min(),
              // The tab's right edge slopes down into the body; its middle row is a fair width.
              let tabMiddle = spans[(top + bodyTop) / 2]
        else { return nil }

        // The front is lighter than the back behind it.
        let column = (left + right) / 2
        func brightness(_ row: Int) -> Int {
            let index = row * bytesPerRow + column * 4
            return (Int(pixels[index]) * 299 + Int(pixels[index + 1]) * 587 + Int(pixels[index + 2]) * 114) / 1000
        }
        let middle = (top + bottom) / 2
        guard bodyTop + 2 < middle,
              let frontTop = (bodyTop + 2...middle).max(by: { brightness($0) - brightness($0 - 1) < brightness($1) - brightness($1 - 1) }),
              brightness(frontTop) - brightness(frontTop - 1) >= 6
        else { return nil }

        let unit = CGFloat(side)
        let shape = FolderShape(
            bounds: CGRect(x: CGFloat(left) / unit, y: CGFloat(top) / unit,
                           width: CGFloat(right - left + 1) / unit, height: CGFloat(bottom - top + 1) / unit),
            front: CGRect(x: CGFloat(left) / unit, y: CGFloat(frontTop) / unit,
                          width: CGFloat(right - left + 1) / unit, height: CGFloat(bottom - frontTop + 1) / unit),
            tab: CGRect(x: CGFloat(tabLeft) / unit, y: CGFloat(top) / unit,
                        width: CGFloat(tabMiddle.right - tabLeft + 1) / unit, height: CGFloat(bodyTop - top) / unit)
        )
        return shape.isPlausible ? shape : nil
    }

    /// The folder's outline at `side` × `side` pixels, for clipping: white where the folder
    /// is and black around it. The soft shadow around the artwork is left out, so whatever
    /// is clipped to it ends exactly where the folder does.
    public static func silhouette(of icon: NSImage, side: Int) -> CGImage? {
        guard let pixels = pixels(of: icon, side: side) else { return nil }
        var mask = [UInt8](repeating: 0, count: side * side)
        for index in mask.indices {
            // The shadow never gets denser than about 100; the folder itself is opaque.
            let alpha = Int(pixels[index * 4 + 3])
            mask[index] = UInt8(clamping: (alpha - 110) * 255 / 140)
        }
        guard let provider = CGDataProvider(data: Data(mask) as CFData) else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        )
    }

    /// The icon drawn at `side` pixels exactly as the renderer draws it, as RGBA bytes
    /// with the top row first.
    private static func pixels(of icon: NSImage, side: Int) -> [UInt8]? {
        guard side > 0 else { return nil }
        let bytesPerRow = side * 4
        var pixels = [UInt8](repeating: 0, count: side * bytesPerRow)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: bytesPerRow, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        return drawn ? pixels : nil
    }
}

/// Where the parts of the folder sit on the icon, in unit coordinates with a top-left
/// origin, like `IconStyle`.
public struct FolderShape: Sendable, Equatable {
    /// The whole folder: the back with its tab, and the front.
    public var bounds: CGRect
    /// The front of the folder, where a picture usually goes.
    public var front: CGRect
    /// The raised tab in the top-left corner.
    public var tab: CGRect

    /// The folder every macOS since Big Sur draws.
    static let fallback = FolderShape(
        bounds: CGRect(x: 0.041, y: 0.131, width: 0.918, height: 0.737),
        front: CGRect(x: 0.041, y: 0.262, width: 0.918, height: 0.606),
        tab: CGRect(x: 0.041, y: 0.131, width: 0.36, height: 0.066)
    )

    /// A folder is wider than tall, its tab is a short strip at the top left, and its front
    /// covers most of it.
    var isPlausible: Bool {
        bounds.width > 0.6 && bounds.height > 0.4
            && tab.width > 0.1 && tab.width < 0.7 && tab.height > 0.02 && tab.height < 0.3 && tab.minY < 0.4
            && front.minY > tab.maxY && front.minY < bounds.midY && front.height > 0.3
    }
}
