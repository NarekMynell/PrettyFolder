import AppKit
import Testing
@testable import PrettyFolderKit

@Suite struct IconRendererTests {
    let renderer = IconRenderer()

    @Test func measuresTheFolder() throws {
        let shape = try #require(FolderArtwork.measureShape(in: FolderArtwork.makeBaseIcon()))
        #expect(shape == FolderArtwork.shape)
        // Every macOS folder since Big Sur: wide, a tab at the top left, the front below it.
        #expect(shape.bounds.minX < 0.1 && shape.bounds.maxX > 0.9)
        #expect(shape.bounds.minY > 0.05 && shape.bounds.maxY < 0.95)
        #expect(shape.tab.minX < 0.15 && shape.tab.width > 0.2 && shape.tab.width < 0.6)
        #expect(shape.front.minY > shape.tab.maxY && shape.front.minY < 0.4)
        #expect(abs(shape.front.maxY - shape.bounds.maxY) < 0.01)
    }

    @Test func silhouetteIsTheFolderWithoutItsShadow() throws {
        let mask = try #require(renderer.silhouette(pixelSize: 256))
        #expect(mask.width == 256 && mask.height == 256)
        let shape = FolderArtwork.shape
        let inside = TestImages.pixel(mask, x: 128, y: Int(shape.front.midY * 256))
        let corner = TestImages.pixel(mask, x: 2, y: 2)
        // Just below the folder, where its shadow is.
        let shadow = TestImages.pixel(mask, x: 128, y: Int(shape.bounds.maxY * 256) + 2)
        #expect(inside.r == 255)
        #expect(corner.r == 0)
        #expect(shadow.r == 0)
    }

    @Test func fillPaintsTheWholeRectangle() throws {
        let picture = SourceImage(bitmap: TestImages.solid(width: 300, height: 100, red: 1, green: 0, blue: 0))
        let style = IconStyle(x: 0.2, y: 0.4, width: 0.6, height: 0.4, mode: .fill)
        let icon = try #require(renderer.render(picture, style: style, pixelSize: 256))
        #expect(icon.width == 256 && icon.height == 256)

        // Inside the rectangle, near its top and bottom edges: red (the picture was cropped, not shrunk).
        #expect(isRed(TestImages.pixel(icon, x: 128, y: 110)))
        #expect(isRed(TestImages.pixel(icon, x: 128, y: 200)))
        // Outside the rectangle: the folder itself.
        #expect(!isRed(TestImages.pixel(icon, x: 128, y: 90)))
        #expect(!isRed(TestImages.pixel(icon, x: 40, y: 150)))
    }

    @Test func fitLeavesTheFolderVisibleAroundAWidePicture() throws {
        let picture = SourceImage(bitmap: TestImages.solid(width: 400, height: 100, red: 1, green: 0, blue: 0))
        let style = IconStyle(x: 0.2, y: 0.3, width: 0.6, height: 0.6, mode: .fit)
        let icon = try #require(renderer.render(picture, style: style, pixelSize: 256))
        // The picture is 4:1 inside a square, so only a band through the middle is red.
        #expect(isRed(TestImages.pixel(icon, x: 128, y: 154)))
        #expect(!isRed(TestImages.pixel(icon, x: 128, y: 90)))
        #expect(!isRed(TestImages.pixel(icon, x: 128, y: 220)))
    }

    @Test func picturesNeverLeaveTheFolder() throws {
        let picture = SourceImage(bitmap: TestImages.solid(width: 100, height: 100, red: 1, green: 0, blue: 0))
        let everywhere = IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill)
        let icon = try #require(renderer.render(picture, style: everywhere, pixelSize: 256))
        let plain = try #require(renderer.render(nil, style: .standard, pixelSize: 256))
        let shape = FolderArtwork.shape
        // Inside the folder: the picture.
        #expect(isRed(TestImages.pixel(icon, x: 128, y: Int(shape.front.midY * 256))))
        #expect(isRed(TestImages.pixel(icon, x: Int(shape.tab.midX * 256), y: Int(shape.tab.midY * 256))))
        // Outside the outline: exactly what the plain folder has there, shadow and all.
        for (x, y) in [(2, 2), (Int(shape.bounds.maxX * 256) - 20, Int(shape.tab.midY * 256)), (128, Int(shape.bounds.maxY * 256) + 3)] {
            #expect(TestImages.pixel(icon, x: x, y: y) == TestImages.pixel(plain, x: x, y: y), "pixel \(x),\(y)")
        }
    }

    @Test func plainRenderIsTheFolder() throws {
        let icon = try #require(renderer.render(nil, style: .standard, pixelSize: 64))
        // Transparent corners, opaque body.
        #expect(TestImages.pixel(icon, x: 0, y: 0).a == 0)
        #expect(TestImages.pixel(icon, x: 32, y: 40).a == 255)
    }

    @Test func makesEveryIconSize() throws {
        let picture = SourceImage(bitmap: TestImages.solid(width: 100, height: 100, red: 0, green: 1, blue: 0))
        let icon = try #require(renderer.makeIcon(with: picture, style: .standard))
        let sizes = icon.representations.map(\.pixelsWide).sorted()
        #expect(sizes == IconRenderer.pixelSizes)
    }

    @Test func vectorPicturesStaySharp() throws {
        let temp = try TemporaryDirectory()
        let url = temp.file("art.svg")
        try TestImages.writeSVG(to: url, width: 10, height: 10)
        let picture = try ImageLoader.load(contentsOf: url)
        let style = IconStyle(x: 0.2, y: 0.4, width: 0.6, height: 0.4, mode: .fill)
        let icon = try #require(renderer.render(picture, style: style, pixelSize: 1024))
        #expect(isRed(TestImages.pixel(icon, x: 512, y: 600)))
    }

    private func isRed(_ pixel: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        pixel.r > 200 && pixel.g < 60 && pixel.b < 60
    }
}
