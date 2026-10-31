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

    /// The folder's tab (the raised strip in the top-left corner), in unit coordinates
    /// with a top-left origin. Measured from the real artwork once per launch.
    public static let tabRegion: CGRect = measureTabRegion(in: makeBaseIcon()) ?? fallbackTabRegion

    static let fallbackTabRegion = CGRect(x: 0.04, y: 0.13, width: 0.36, height: 0.08)

    /// Finds the tab by scanning the icon's alpha channel: the rows at the top whose
    /// opaque span stops well short of the body's right edge.
    static func measureTabRegion(in icon: NSImage, side: Int = 256) -> CGRect? {
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
            icon.draw(in: NSRect(x: 0, y: 0, width: side, height: side), from: .zero, operation: .copy, fraction: 1)
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        guard drawn else { return nil }

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
              let bodyRight = spans.compactMap({ $0?.right }).max()
        else { return nil }

        // The tab ends where a row first reaches (almost) all the way to the right.
        let reachesRight = { (row: Int) in (spans[row]?.right ?? 0) >= bodyRight - side / 20 }
        guard let bodyTop = (top..<side).first(where: reachesRight), bodyTop - top >= 2 else { return nil }

        let tabRows = spans[top..<bodyTop].compactMap { $0 }
        guard let left = tabRows.map(\.left).min() else { return nil }
        // The tab's right edge slopes down into the body; its middle row is a fair width.
        guard let middle = spans[(top + bodyTop) / 2] else { return nil }

        let unit = CGFloat(side)
        let rect = CGRect(
            x: CGFloat(left) / unit,
            y: CGFloat(top) / unit,
            width: CGFloat(middle.right - left + 1) / unit,
            height: CGFloat(bodyTop - top) / unit
        )
        // Sanity check: a tab is a short strip in the upper-left part of the icon.
        guard rect.width > 0.1, rect.width < 0.7, rect.height > 0.02, rect.height < 0.3, rect.minY < 0.4 else { return nil }
        return rect
    }
}
