import AppKit
import ImageIO
import UniformTypeIdentifiers

/// A scratch directory that disappears when the test is done.
final class TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrettyFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func folder(_ name: String) throws -> URL {
        let folder = url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func file(_ name: String) -> URL {
        url.appendingPathComponent(name, isDirectory: false)
    }
}

enum TestImages {
    /// A solid-color bitmap. With `alpha < 1` the image carries an alpha channel.
    static func solid(width: Int, height: Int, red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) -> CGImage {
        let info = alpha < 1 ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: info
        )!
        context.setFillColor(CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }

    /// Writes `image` with ImageIO. `properties` can carry an EXIF orientation, for example.
    @discardableResult
    static func write(_ image: CGImage, to url: URL, type: UTType, properties: [CFString: Any] = [:]) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        return CGImageDestinationFinalize(destination)
    }

    static func writeSVG(to url: URL, width: Int, height: Int) throws {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="\(width)" height="\(height)" viewBox="0 0 \(width) \(height)">
          <rect width="\(width)" height="\(height)" fill="#ff0000"/>
        </svg>
        """
        try Data(svg.utf8).write(to: url)
    }

    static func writePDF(to url: URL, width: CGFloat, height: CGFloat) {
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(box)
        context.endPDFPage()
        context.closePDF()
    }

    /// RGBA of one pixel; `y` counts from the top.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            // Shift the image so that the wanted pixel lands on the single-pixel canvas.
            context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        }
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]), Int(bytes[3]))
    }
}
