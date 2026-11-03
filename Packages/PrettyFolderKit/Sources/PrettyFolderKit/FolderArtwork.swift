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

    /// What the folder in `icon` gives a picture drawn on it at `side` × `side` pixels: the
    /// folder itself apart from its shadow, and its light and shade. `shape` says where the
    /// folder's front is.
    public static func surface(of icon: NSImage, side: Int, shape: FolderShape) -> FolderSurface? {
        guard let pixels = pixels(of: icon, side: side) else { return nil }
        let coverage = coverage(of: pixels, side: side)
        var body = [UInt8](repeating: 0, count: side * side * 4)
        var shadow = [UInt8](repeating: 0, count: side * side * 2)
        for index in coverage.indices {
            let covered = coverage[index]
            // The folder keeps its colours; its shadow is black, so all colour is the folder's.
            body[index * 4] = pixels[index * 4]
            body[index * 4 + 1] = pixels[index * 4 + 1]
            body[index * 4 + 2] = pixels[index * 4 + 2]
            body[index * 4 + 3] = covered
            shadow[index * 2 + 1] = pixels[index * 4 + 3] - covered
        }
        guard let silhouette = image(from: coverage, side: side, bytesPerPixel: 1, alpha: .none),
              let bodyImage = image(from: body, side: side, bytesPerPixel: 4, alpha: .premultipliedLast),
              let shadowImage = image(from: shadow, side: side, bytesPerPixel: 2, alpha: .premultipliedLast)
        else { return nil }
        // How far the folder's pixels go.
        var left = side, right = -1, top = side, bottom = -1
        for row in 0..<side {
            for column in 0..<side where coverage[row * side + column] > 0 {
                left = min(left, column)
                right = max(right, column)
                top = min(top, row)
                bottom = max(bottom, row)
            }
        }
        let unit = CGFloat(side)
        let extent = right < 0 ? shape.bounds
            : CGRect(x: CGFloat(left) / unit, y: CGFloat(top) / unit, width: CGFloat(right - left + 1) / unit, height: CGFloat(bottom - top + 1) / unit)
        return FolderSurface(
            silhouette: silhouette, body: bodyImage, shadow: shadowImage,
            shading: shading(from: pixels, side: side, shape: shape),
            edges: FolderEdges(bounds: shape.bounds, extent: extent)
        )
    }

    /// How much of each pixel the folder itself covers, from 0 to 255, its shadow left out.
    ///
    /// The folder is opaque and its shadow is black. A pixel along the folder's outline, which
    /// the two share, is as much folder as it has the folder's colour: its colour over that of
    /// the folder right next to it. That is never less than its brightest channel (the shadow
    /// adds no colour) nor more than its alpha.
    static func coverage(of pixels: [UInt8], side: Int) -> [UInt8] {
        var coverage = [UInt8](repeating: 0, count: side * side)
        for row in 0..<side {
            for column in 0..<side {
                let index = row * side + column, pixel = index * 4
                let alpha = Int(pixels[pixel + 3])
                if alpha == 255 {
                    coverage[index] = 255
                    continue
                }
                let red = Int(pixels[pixel]), green = Int(pixels[pixel + 1]), blue = Int(pixels[pixel + 2])
                let brightest = max(red, green, blue)
                // Shadow alone, or nothing at all.
                guard brightest > 0 else { continue }
                // The brightest opaque pixel next to it, or a pixel further: the folder's colour here.
                var reference = 0
                for reach in 1...2 where reference == 0 {
                    for y in max(row - reach, 0)...min(row + reach, side - 1) {
                        for x in max(column - reach, 0)...min(column + reach, side - 1) {
                            let other = (y * side + x) * 4
                            guard pixels[other + 3] == 255 else { continue }
                            reference = max(reference, Int(pixels[other]) + Int(pixels[other + 1]) + Int(pixels[other + 2]))
                        }
                    }
                }
                // Without one, by how much denser it is than the shadow ever gets (about 110).
                let estimate = reference > 0 ? (red + green + blue) * 255 / reference : (alpha - 110) * 255 / 140
                coverage[index] = UInt8(min(max(estimate, brightest), alpha))
            }
        }
        return coverage
    }

    /// The folder's light and shade (see `FolderSurface.shading`) from the icon's pixels.
    ///
    /// The middle of the front is lit evenly, apart from a gentle fall-off from top to bottom:
    /// a plane through its brightness stands for that light everywhere on the folder, and each
    /// pixel of the folder is compared with it. The back comes out darker, the front's top edge
    /// lighter, and the middle of the front the same, give or take a level of noise.
    private static func shading(from pixels: [UInt8], side: Int, shape: FolderShape) -> CGImage? {
        let bytesPerRow = side * 4
        // Brightness on the 0–255 scale; nothing where the folder fades into its shadow.
        func brightness(_ index: Int) -> Double? {
            let alpha = Double(pixels[index + 3])
            guard alpha >= 128 else { return nil }
            let red = Double(pixels[index]), green = Double(pixels[index + 1]), blue = Double(pixels[index + 2])
            return (0.299 * red + 0.587 * green + 0.114 * blue) * 255 / alpha
        }

        // brightness ≈ a + b·row + c·column, by least squares over the middle of the front.
        let unit = Double(side)
        let top = Int((shape.front.minY + 0.08) * unit), bottom = Int((shape.bounds.maxY - 0.06) * unit)
        let left = Int((shape.bounds.minX + 0.06) * unit), right = Int((shape.bounds.maxX - 0.06) * unit)
        guard top >= 0, top < bottom, bottom < side, left >= 0, left < right, right < side else { return nil }
        let step = max(1, side / 128)
        var count = 0.0, r = 0.0, c = 0.0, rr = 0.0, rc = 0.0, cc = 0.0, v = 0.0, rv = 0.0, cv = 0.0
        for row in stride(from: top, through: bottom, by: step) {
            for column in stride(from: left, through: right, by: step) {
                guard let value = brightness(row * bytesPerRow + column * 4) else { continue }
                let y = Double(row), x = Double(column)
                count += 1; r += y; c += x; rr += y * y; rc += y * x; cc += x * x
                v += value; rv += y * value; cv += x * value
            }
        }
        guard let plane = solve([count, r, c, r, rr, rc, c, rc, cc], [v, rv, cv]) else { return nil }

        // Differences this small are noise in the artwork, not light.
        let noise = 1.5
        var shade = [UInt8](repeating: 0, count: side * side * 2)
        for row in 0..<side {
            for column in 0..<side {
                guard let value = brightness(row * bytesPerRow + column * 4) else { continue }
                let light = min(max(plane[0] + plane[1] * Double(row) + plane[2] * Double(column), 1), 254)
                let difference = value - light
                let index = (row * side + column) * 2
                if difference < -noise {
                    // Black: the picture darkens as much as the folder does here.
                    shade[index + 1] = UInt8(clamping: Int(((-difference - noise) / light * 255).rounded()))
                } else if difference > noise {
                    // White, premultiplied: the picture brightens toward white as the folder does.
                    let alpha = UInt8(clamping: Int(((difference - noise) / (255 - light) * 255).rounded()))
                    shade[index] = alpha
                    shade[index + 1] = alpha
                }
            }
        }
        return image(from: shade, side: side, bytesPerPixel: 2, alpha: .premultipliedLast)
    }

    /// Solves the 3 × 3 system `matrix · x = values`; `nil` when it has no single answer.
    private static func solve(_ matrix: [Double], _ values: [Double]) -> [Double]? {
        var a = matrix, b = values
        for column in 0..<3 {
            guard let pivot = (column..<3).max(by: { abs(a[$0 * 3 + column]) < abs(a[$1 * 3 + column]) }),
                  abs(a[pivot * 3 + column]) > 1e-9
            else { return nil }
            if pivot != column {
                for j in 0..<3 { a.swapAt(pivot * 3 + j, column * 3 + j) }
                b.swapAt(pivot, column)
            }
            for row in 0..<3 where row != column {
                let factor = a[row * 3 + column] / a[column * 3 + column]
                for j in 0..<3 { a[row * 3 + j] -= factor * a[column * 3 + j] }
                b[row] -= factor * b[column]
            }
        }
        return (0..<3).map { b[$0] / a[$0 * 3 + $0] }
    }

    /// An image from bytes with the top row first: gray (with alpha when `bytesPerPixel` is 2),
    /// or sRGB with alpha when it is 4, like the icon's own pixels.
    private static func image(from bytes: [UInt8], side: Int, bytesPerPixel: Int, alpha: CGImageAlphaInfo) -> CGImage? {
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let space = bytesPerPixel == 4 ? CGColorSpace(name: CGColorSpace.sRGB) : CGColorSpaceCreateDeviceGray()
        else { return nil }
        return CGImage(
            width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8 * bytesPerPixel, bytesPerRow: side * bytesPerPixel,
            space: space, bitmapInfo: CGBitmapInfo(rawValue: alpha.rawValue),
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

/// What the folder's artwork gives a picture drawn on it, at one pixel size. Every image has
/// the icon's size and its top row first, like the icon.
///
/// The icon is the folder over its soft shadow, and `body` and `shadow` are the two apart:
/// added together they make the icon again, pixel for pixel. A picture is painted on the body
/// alone, so along the folder's outline it takes the folder's place in each pixel instead of
/// being laid over it, and no rim of the folder shows around it.
public struct FolderSurface: @unchecked Sendable {
    /// The folder's outline: white where the folder is, black around it, and along its edge
    /// as much white as the folder covers of each pixel.
    public let silhouette: CGImage
    /// The folder itself, without its shadow: its own colours, as opaque as it covers each pixel.
    public let body: CGImage
    /// The folder's shadow alone: black, as dense as it shows in each pixel.
    public let shadow: CGImage
    /// The folder's light and shade, for a picture on it to catch the way the folder does:
    /// the back darker than the front, and the light along the front's top edge, so a
    /// picture across both shows the same depth. Black where the folder is darker than the
    /// evenly lit middle of its front, white where it is lighter, how much in alpha; clear on
    /// that middle, so a picture there keeps its colors. Draw it over the picture alone.
    /// `nil` when the artwork has no front to measure the light by.
    public let shading: CGImage?
    /// The folder's edges: as measured, and how far its pixels go at this size.
    public let edges: FolderEdges
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
