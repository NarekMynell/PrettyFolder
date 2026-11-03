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
        let mask = try #require(renderer.surface(pixelSize: 256)?.silhouette)
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

    @Test func noRimOfTheFolderShowsAroundAPictureThatCoversIt() throws {
        // A pure red picture over a black shadow leaves no green or blue anywhere: whatever
        // there is of either comes from the folder showing through. Light and shade left out.
        let red = SourceImage(bitmap: TestImages.solid(width: 300, height: 200, red: 1, green: 0, blue: 0))
        let bounds = FolderArtwork.shape.bounds
        let covering = [
            IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill),
            IconStyle(rect: bounds, mode: .fill),
            IconStyle(x: -0.6, y: -0.4, width: 2.3, height: 1.9, mode: .fill),
        ]
        // Fitted in a frame on the folder's edges, a wide picture spans the folder from side to
        // side, its top and bottom inside: the rows it covers show no folder either.
        let fitted = IconStyle(rect: bounds, mode: .fit)
        for side in IconRenderer.pixelSizes {
            let surface = try #require(renderer.surface(pixelSize: side))
            let unshaded = FolderSurface(silhouette: surface.silhouette, body: surface.body, shadow: surface.shadow, shading: nil, edges: surface.edges)
            for style in covering + [fitted] {
                let icon = TestImages.bytes(try draw(red, style: style, placement: .natural, side: side, on: unshaded))
                var rows = 0..<side
                if style.mode == .fit {
                    let band = IconGeometry.layout(
                        imageSize: red.size, style: style, placement: .natural, canvas: CGFloat(side), flipped: true, folder: surface.edges
                    ).bounds
                    rows = Int(band.minY.rounded(.up))..<Int(band.maxY.rounded(.down))
                }
                var showing = 0
                for y in rows {
                    for x in 0..<side where icon[(y * side + x) * 4 + 1] > 0 || icon[(y * side + x) * 4 + 2] > 0 {
                        showing += 1
                    }
                }
                #expect(showing == 0, "\(style.rect) \(style.mode) at \(side) px: \(showing) pixels show the folder")
            }
        }
    }

    private func draw(_ picture: SourceImage, style: IconStyle, placement: PicturePlacement, side: Int, on surface: FolderSurface) throws -> CGImage {
        let context = try #require(CGContext(
            data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .high
        IconRenderer.draw(picture, style: style, placement: placement, canvas: CGFloat(side), on: surface, in: context)
        return try #require(context.makeImage())
    }

    @Test func theFolderAndItsShadowMakeTheIconAgain() throws {
        // A see-through picture over all of it changes nothing, at any size, anywhere.
        let clear = SourceImage(bitmap: TestImages.solid(width: 40, height: 40, red: 1, green: 1, blue: 1, alpha: 0))
        let everywhere = IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill)
        for side in IconRenderer.pixelSizes {
            let icon = try #require(renderer.render(clear, style: everywhere, pixelSize: side))
            let plain = try #require(renderer.render(nil, style: .standard, pixelSize: side))
            #expect(TestImages.bytes(icon) == TestImages.bytes(plain), "size \(side)")
        }
    }

    @Test func outsideTheFolderNothingChanges() throws {
        let red = SourceImage(bitmap: TestImages.solid(width: 100, height: 100, red: 1, green: 0, blue: 0))
        let everywhere = IconStyle(x: -1, y: -1, width: 3, height: 3, mode: .fill)
        for side in [32, 128, 512] {
            let icon = TestImages.bytes(try #require(renderer.render(red, style: everywhere, pixelSize: side)))
            let plain = TestImages.bytes(try #require(renderer.render(nil, style: .standard, pixelSize: side)))
            let outline = TestImages.bytes(try #require(renderer.surface(pixelSize: side)?.silhouette))
            var changed = 0
            for index in 0..<(side * side) {
                // Every pixel keeps its alpha: the icon's shape and shadow stay the folder's.
                if icon[index * 4 + 3] != plain[index * 4 + 3] { changed += 1 }
                // Where none of the folder is, nothing else changes either.
                if outline[index * 4] == 0, icon[index * 4..<index * 4 + 4] != plain[index * 4..<index * 4 + 4] { changed += 1 }
            }
            #expect(changed == 0, "size \(side)")
        }
    }

    @Test func aTurnedPictureIsDrawnTurned() throws {
        // Red on the left half, blue on the right; a quarter turn counterclockwise puts red at
        // the bottom and blue at the top.
        let picture = try halves()
        let style = IconStyle(x: 0.3, y: 0.4, width: 0.4, height: 0.4, mode: .fit)
        let turned = try #require(renderer.render(picture, style: style, placement: PicturePlacement(x: 0.5, y: 0.5, rotation: 90), pixelSize: 256))
        // The frame runs from 77 to 179 across and 102 to 205 down; turned, the picture is a
        // band 51 wide down the middle.
        #expect(isBlue(TestImages.pixel(turned, x: 128, y: 120)))
        #expect(isRed(TestImages.pixel(turned, x: 128, y: 185)))
        #expect(!isRed(TestImages.pixel(turned, x: 85, y: 185)) && !isBlue(TestImages.pixel(turned, x: 170, y: 120)))
        let clockwise = try #require(renderer.render(picture, style: style, placement: PicturePlacement(x: 0.5, y: 0.5, rotation: -90), pixelSize: 256))
        #expect(isRed(TestImages.pixel(clockwise, x: 128, y: 120)) && isBlue(TestImages.pixel(clockwise, x: 128, y: 185)))
    }

    @Test func aTiltedFittedPictureKeepsItsCorners() throws {
        let red = SourceImage(bitmap: TestImages.solid(width: 400, height: 300, red: 1, green: 0, blue: 0))
        let style = IconStyle(x: 0.2, y: 0.3, width: 0.6, height: 0.5, mode: .fit)
        for rotation in [15.0, 30, 45, 60, -20] {
            let placement = PicturePlacement(x: 0.5, y: 0.5, rotation: rotation)
            let icon = try #require(renderer.render(red, style: style, placement: placement, pixelSize: 256))
            let edges = try #require(renderer.surface(pixelSize: 256)).edges
            let layout = IconGeometry.layout(imageSize: red.size, style: style, placement: placement, canvas: 256, flipped: true, folder: edges)
            let inner = layout.uprightRect.insetBy(dx: 12, dy: 12)
            for corner in [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                           CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY)] {
                let point = corner.applying(layout.transform)
                #expect(isRed(TestImages.pixel(icon, x: Int(point.x), y: Int(point.y))), "\(rotation)° at \(point)")
            }
        }
    }

    @Test func aTiltedFilledPictureLeavesNoCornerBare() throws {
        let red = SourceImage(bitmap: TestImages.solid(width: 300, height: 200, red: 1, green: 0, blue: 0))
        let style = IconStyle(x: 0.2, y: 0.35, width: 0.6, height: 0.4, mode: .fill)
        for rotation in [10.0, -33, 45, 120] {
            let icon = try #require(renderer.render(red, style: style, placement: PicturePlacement(x: 0, y: 1, rotation: rotation), pixelSize: 256))
            // Just inside the frame's corners, past their rounding.
            for (x, y) in [(55, 93), (200, 93), (55, 188), (200, 188), (128, 140)] {
                #expect(isRed(TestImages.pixel(icon, x: x, y: y)), "\(rotation)° at \(x), \(y)")
            }
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

    @Test func shadingLeavesTheMiddleOfTheFrontAlone() throws {
        let shape = FolderArtwork.shape
        for side in IconRenderer.pixelSizes {
            let shading = try #require(renderer.surface(pixelSize: side)?.shading, "size \(side)")
            let unit = Double(side)
            for (x, y) in [(0.5, shape.front.midY), (0.25, shape.front.minY + 0.15), (0.75, shape.bounds.maxY - 0.12)] {
                // The small sizes are drawn by hand, a level or so off a smooth light: below 1%.
                let strength = TestImages.pixel(shading, x: Int(x * unit), y: Int(y * unit)).a
                #expect(side >= 128 ? strength == 0 : strength <= 2, "size \(side) at \(x), \(y)")
            }
        }
    }

    @Test func aPictureAcrossTheFolderShowsItsDepth() throws {
        // A plain gray picture over the whole folder, like a sheet laid on both its parts.
        let gray = SourceImage(bitmap: TestImages.solid(width: 100, height: 100, red: 0.6, green: 0.6, blue: 0.6))
        let everywhere = IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill)
        let icon = try #require(renderer.render(gray, style: everywhere, pixelSize: 512))
        let plain = try #require(renderer.render(nil, style: .standard, pixelSize: 512))
        let shape = FolderArtwork.shape
        let frontTop = Int(shape.front.minY * 512)
        let back = (x: 256, y: frontTop - 4), edge = (x: 256, y: frontTop + 1)
        let front = (x: 256, y: frontTop + 30), middle = (x: 256, y: Int(shape.front.midY * 512))
        func brightness(_ image: CGImage, _ point: (x: Int, y: Int)) -> Double {
            let pixel = TestImages.pixel(image, x: point.x, y: point.y)
            return 0.299 * Double(pixel.r) + 0.587 * Double(pixel.g) + 0.114 * Double(pixel.b)
        }
        // Darker on the back and lighter along the front's top edge, as on the folder itself.
        #expect(brightness(icon, middle) > 150 && brightness(icon, middle) < 156, "the front's middle keeps the picture's color")
        #expect(brightness(icon, front) > 150 && brightness(icon, front) < 156)
        let folderBack = brightness(plain, back) / brightness(plain, front)
        let pictureBack = brightness(icon, back) / brightness(icon, front)
        #expect(pictureBack < 0.85 && abs(pictureBack - folderBack) < 0.03, "\(pictureBack) vs \(folderBack)")
        #expect(brightness(icon, edge) > brightness(icon, front) + 5)
    }

    @Test func seeThroughPicturesLeaveTheFolderAsItIs() throws {
        let clear = SourceImage(bitmap: TestImages.solid(width: 100, height: 100, red: 1, green: 1, blue: 1, alpha: 0))
        let everywhere = IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill)
        let icon = try #require(renderer.render(clear, style: everywhere, pixelSize: 128))
        let plain = try #require(renderer.render(nil, style: .standard, pixelSize: 128))
        for (x, y) in [(64, 30), (64, 40), (64, 90), (20, 60)] {
            #expect(TestImages.pixel(icon, x: x, y: y) == TestImages.pixel(plain, x: x, y: y), "pixel \(x),\(y)")
        }
    }

    @Test func placementPicksThePartThatShows() throws {
        // Red on the left half, blue on the right, filling a square: only one half fits.
        let picture = try halves()
        let style = IconStyle(x: 0.3, y: 0.4, width: 0.4, height: 0.4, mode: .fill)

        let left = try #require(renderer.render(picture, style: style, placement: PicturePlacement(x: 0, y: 0.5), pixelSize: 256))
        let right = try #require(renderer.render(picture, style: style, placement: PicturePlacement(x: 1, y: 0.5), pixelSize: 256))
        #expect(isRed(TestImages.pixel(left, x: 128, y: 150)))
        #expect(isBlue(TestImages.pixel(right, x: 128, y: 150)))
    }

    @Test func aFittedPictureSitsWhereItIsPut() throws {
        // Fitted in a square, the red and blue halves sit side by side in a band.
        let picture = try halves()
        let style = IconStyle(x: 0.25, y: 0.35, width: 0.5, height: 0.5, mode: .fit)
        // 256 px: the rectangle runs from 64 to 192 across and 90 to 218 down; the band is
        // 64 tall, in the middle from 122 to 186.
        let middle = try #require(renderer.render(picture, style: style, pixelSize: 256))
        #expect(isRed(TestImages.pixel(middle, x: 80, y: 154)) && isBlue(TestImages.pixel(middle, x: 176, y: 154)))
        #expect(!isRed(TestImages.pixel(middle, x: 80, y: 100)), "above the band, the folder shows")

        // Put at the top, from 90 to 154, it leaves the bottom of its rectangle to the folder.
        let top = try #require(renderer.render(picture, style: style, placement: PicturePlacement(x: 0.5, y: 0), pixelSize: 256))
        let plain = try #require(renderer.render(nil, style: style, pixelSize: 256))
        #expect(isRed(TestImages.pixel(top, x: 80, y: 100)) && isBlue(TestImages.pixel(top, x: 176, y: 100)))
        for x in [80, 176] {
            #expect(TestImages.pixel(top, x: x, y: 200) == TestImages.pixel(plain, x: x, y: 200), "pixel \(x),200")
        }
    }

    /// 200 × 100: red on the left half, blue on the right.
    private func halves() throws -> SourceImage {
        let context = try #require(CGContext(
            data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 100, y: 0, width: 100, height: 100))
        return SourceImage(bitmap: try #require(context.makeImage()))
    }

    private func isRed(_ pixel: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        pixel.r > 200 && pixel.g < 60 && pixel.b < 60
    }

    private func isBlue(_ pixel: (r: Int, g: Int, b: Int, a: Int)) -> Bool {
        pixel.b > 200 && pixel.r < 60
    }
}
