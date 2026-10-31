import AppKit
import Testing
@testable import PrettyFolderKit

@Suite struct IconRendererTests {
    let renderer = IconRenderer()

    @Test func findsTheFolderTab() {
        let tab = FolderArtwork.tabRegion
        // The tab sits in the upper-left part of every macOS folder since Big Sur.
        #expect(tab.minX < 0.15)
        #expect(tab.minY > 0.05 && tab.minY < 0.25)
        #expect(tab.width > 0.2 && tab.width < 0.6)
        #expect(tab.height > 0.03 && tab.height < 0.2)
        #expect(FolderArtwork.measureTabRegion(in: FolderArtwork.makeBaseIcon()) != nil)
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
