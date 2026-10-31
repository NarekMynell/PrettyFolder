import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import PrettyFolderKit

@Suite struct ImageLoaderTests {
    let temp: TemporaryDirectory

    init() throws {
        temp = try TemporaryDirectory()
    }

    @Test(arguments: [
        ("png", UTType.png), ("jpg", UTType.jpeg), ("heic", UTType.heic), ("tiff", UTType.tiff),
        ("gif", UTType.gif), ("bmp", UTType.bmp), ("jp2", UTType(filenameExtension: "jp2")!),
    ])
    func loadsBitmapFormats(_ fileExtension: String, _ type: UTType) throws {
        let url = temp.file("picture.\(fileExtension)")
        let image = TestImages.solid(width: 300, height: 200, red: 1, green: 0, blue: 0)
        try #require(TestImages.write(image, to: url, type: type), "ImageIO can't write \(fileExtension) here")
        let loaded = try ImageLoader.load(contentsOf: url)
        #expect(loaded.size == CGSize(width: 300, height: 200))
        guard case .bitmap = loaded.content else { Issue.record("expected a bitmap"); return }
    }

    @Test func appliesExifOrientation() throws {
        let url = temp.file("rotated.jpg")
        let image = TestImages.solid(width: 400, height: 100, red: 0, green: 1, blue: 0)
        // Orientation 6: the camera was turned, the picture must come out standing up.
        TestImages.write(image, to: url, type: .jpeg, properties: [kCGImagePropertyOrientation: 6])
        let loaded = try ImageLoader.load(contentsOf: url)
        #expect(loaded.size == CGSize(width: 100, height: 400))
    }

    @Test func downsamplesHugePictures() throws {
        let url = temp.file("huge.png")
        TestImages.write(TestImages.solid(width: 6000, height: 4000, red: 0, green: 0, blue: 1), to: url, type: .png)
        let loaded = try ImageLoader.load(contentsOf: url)
        #expect(min(loaded.size.width, loaded.size.height) <= CGFloat(ImageLoader.maxShortSide))
        #expect(abs(loaded.size.width / loaded.size.height - 1.5) < 0.01)
    }

    @Test func capsPanoramas() throws {
        let url = temp.file("panorama.png")
        TestImages.write(TestImages.solid(width: 12000, height: 600, red: 0, green: 0, blue: 1), to: url, type: .png)
        let loaded = try ImageLoader.load(contentsOf: url)
        #expect(max(loaded.size.width, loaded.size.height) <= CGFloat(ImageLoader.maxLongSide))
    }

    @Test func neverUpscales() throws {
        let url = temp.file("tiny.png")
        TestImages.write(TestImages.solid(width: 12, height: 8, red: 1, green: 1, blue: 0), to: url, type: .png)
        #expect(try ImageLoader.load(contentsOf: url).size == CGSize(width: 12, height: 8))
    }

    @Test func keepsAlpha() throws {
        let url = temp.file("alpha.png")
        TestImages.write(TestImages.solid(width: 20, height: 20, red: 1, green: 0, blue: 0, alpha: 0.5), to: url, type: .png)
        #expect(try ImageLoader.load(contentsOf: url).hasAlpha)
    }

    @Test func loadsSVGAsVector() throws {
        let url = temp.file("drawing.svg")
        try TestImages.writeSVG(to: url, width: 120, height: 60)
        let loaded = try ImageLoader.load(contentsOf: url)
        guard case .vector = loaded.content else { Issue.record("expected a vector image"); return }
        #expect(loaded.size == CGSize(width: 120, height: 60))
        let bitmap = try #require(loaded.bitmap(maxSide: 240))
        #expect(bitmap.width == 240 && bitmap.height == 120)
        #expect(TestImages.pixel(bitmap, x: 120, y: 60).r > 200)
    }

    @Test func loadsPDFAsVector() throws {
        let url = temp.file("page.pdf")
        TestImages.writePDF(to: url, width: 200, height: 100)
        let loaded = try ImageLoader.load(contentsOf: url)
        guard case .vector = loaded.content else { Issue.record("expected a vector image"); return }
        #expect(loaded.size == CGSize(width: 200, height: 100))
    }

    @Test func loadsData() throws {
        let url = temp.file("data.png")
        TestImages.write(TestImages.solid(width: 50, height: 40, red: 0, green: 1, blue: 0), to: url, type: .png)
        let loaded = try ImageLoader.load(data: Data(contentsOf: url))
        #expect(loaded.size == CGSize(width: 50, height: 40))
    }

    @Test func rejectsGarbage() throws {
        let text = temp.file("notes.txt")
        try Data("hello".utf8).write(to: text)
        #expect(throws: ImageLoaderError.self) { try ImageLoader.load(contentsOf: text) }
        #expect(throws: ImageLoaderError.self) { try ImageLoader.load(data: Data([0, 1, 2, 3])) }

        let broken = temp.file("broken.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0x00, 0x01]).write(to: broken)
        #expect(throws: ImageLoaderError.self) { try ImageLoader.load(contentsOf: broken) }
    }

    @Test func recognizesImageFiles() {
        #expect(ImageLoader.isImageFile(URL(fileURLWithPath: "/x/a.JPG")))
        #expect(ImageLoader.isImageFile(URL(fileURLWithPath: "/x/a.svg")))
        #expect(ImageLoader.isImageFile(URL(fileURLWithPath: "/x/a.pdf")))
        #expect(ImageLoader.isImageFile(URL(fileURLWithPath: "/x/a.webp")))
        #expect(!ImageLoader.isImageFile(URL(fileURLWithPath: "/x/a.txt")))
        #expect(!ImageLoader.isImageFile(URL(fileURLWithPath: "/x/folder")))
    }
}
