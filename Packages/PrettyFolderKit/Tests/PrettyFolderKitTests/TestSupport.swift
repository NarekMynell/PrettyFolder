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
    static func nsImage(red: CGFloat, green: CGFloat, blue: CGFloat) -> NSImage {
        NSImage(cgImage: solid(width: 64, height: 64, red: red, green: green, blue: blue), size: NSSize(width: 64, height: 64))
    }

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

    /// Every pixel's RGBA, premultiplied, the top row first.
    static func bytes(_ image: CGImage) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return bytes
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

/// Everything about a folder that PrettyFolder could leave behind: its extended attributes
/// (Finder info included), what is inside it (the hidden icon file included), and its date.
struct FolderSnapshot: Equatable {
    var attributes: [String: Data] = [:]
    var contents: [String] = []
    var modified: timespec?

    init(_ folder: URL) {
        folder.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
            if size > 0 {
                var names = [CChar](repeating: 0, count: size)
                let read = listxattr(path, &names, size, XATTR_NOFOLLOW)
                for name in names[0..<max(read, 0)].split(separator: 0).map({ String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }) {
                    let length = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
                    var value = [UInt8](repeating: 0, count: max(length, 0))
                    _ = getxattr(path, name, &value, value.count, 0, XATTR_NOFOLLOW)
                    attributes[name] = Data(value)
                }
            }
            var info = stat()
            if lstat(path, &info) == 0 { modified = info.st_mtimespec }
        }
        contents = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    static func == (a: FolderSnapshot, b: FolderSnapshot) -> Bool {
        a.attributes == b.attributes && a.contents == b.contents
            && a.modified?.tv_sec == b.modified?.tv_sec && a.modified?.tv_nsec == b.modified?.tv_nsec
    }
}
