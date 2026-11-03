import CoreGraphics
import Foundation
import Testing
@testable import PrettyFolderKit

@Suite struct IconStyleTests {
    @Test func clampsToWhereAFrameCanBe() {
        // Twice as wide as the canvas: it covers it all across. As tall as half of it: on it.
        let style = IconStyle(x: 0.3, y: 0.9, width: 2, height: 0.5, mode: .fit)
        #expect(style.width == 2 && style.x == 0)
        #expect(style.height == 0.5 && style.y == 0.5)
        let left = IconStyle(x: -3, y: 0, width: 2, height: 0.5, mode: .fit)
        #expect(left.x == -1, "as far left as it goes while it covers the canvas")
    }

    @Test func aFrameBiggerThanTheCanvasAlwaysCoversIt() {
        for x in stride(from: -9.0, through: 9.0, by: 0.25) {
            let style = IconStyle(x: x, y: x, width: 1.5, height: 3, mode: .fill)
            #expect(style.rect.minX <= 0 && style.rect.maxX >= 1)
            #expect(style.rect.minY <= 0 && style.rect.maxY >= 1)
        }
    }

    @Test func enforcesTheSmallestAndTheLargestSize() {
        let tiny = IconStyle(x: 0.5, y: 0.5, width: 0, height: 0.001, mode: .fill)
        #expect(tiny.width == IconStyle.minimumSide)
        #expect(tiny.height == IconStyle.minimumSide)
        let huge = IconStyle(x: 0, y: 0, width: 100, height: 9, mode: .fill)
        #expect(huge.width == IconStyle.maximumSide && huge.height == IconStyle.maximumSide)
    }

    @Test func replacesNonFiniteValues() {
        let style = IconStyle(x: .nan, y: 0, width: .infinity, height: 1, mode: .fill)
        #expect(style.rect == IconStyle.standard.rect)
    }

    @Test func decodingAlsoClamps() throws {
        let json = #"{"x": 0.9, "y": -3, "width": 0.5, "height": 0.2, "mode": "fit"}"#
        let style = try JSONDecoder().decode(IconStyle.self, from: Data(json.utf8))
        #expect(style.x == 0.5)
        #expect(style.y == 0)
        #expect(style.mode == .fit)
    }

    @Test func unknownModeFallsBackToFill() throws {
        let json = #"{"x": 0.1, "y": 0.1, "width": 0.5, "height": 0.5, "mode": "stretch"}"#
        #expect(try JSONDecoder().decode(IconStyle.self, from: Data(json.utf8)).mode == .fill)
    }

    @Test func encodesAndDecodes() throws {
        let style = IconStyle(x: 0.2, y: 0.3, width: 0.4, height: 0.5, mode: .fit)
        let decoded = try JSONDecoder().decode(IconStyle.self, from: JSONEncoder().encode(style))
        #expect(decoded == style)
        let big = IconStyle(x: -1.2, y: -0.5, width: 3, height: 2, mode: .fill)
        #expect(try JSONDecoder().decode(IconStyle.self, from: JSONEncoder().encode(big)) == big)
    }

    @Test func tellsWhichRectanglesAFrameCanHave() {
        #expect(IconStyle.allows(CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5)))
        #expect(!IconStyle.allows(CGRect(x: 0.6, y: 0.1, width: 0.5, height: 0.5)), "sticks out of the canvas")
        #expect(IconStyle.allows(CGRect(x: -0.5, y: -0.2, width: 2, height: 1.5)))
        #expect(!IconStyle.allows(CGRect(x: 0.1, y: -0.2, width: 2, height: 1.5)), "bigger, but leaves the left of the canvas bare")
        #expect(!IconStyle.allows(CGRect(x: 0, y: 0, width: 0.05, height: 0.5)))
        #expect(!IconStyle.allows(CGRect(x: -4, y: 0, width: 9, height: 1)))
    }
}

@Suite struct IconGeometryTests {
    let style = IconStyle(x: 0.25, y: 0.1, width: 0.5, height: 0.2, mode: .fill)
    let square = CGSize(width: 400, height: 400)

    /// A layout on a canvas of 100, the folder's edges left out of it.
    func layout(_ style: IconStyle, _ imageSize: CGSize, _ placement: PicturePlacement = .natural, flipped: Bool = true) -> PictureLayout {
        IconGeometry.layout(imageSize: imageSize, style: style, placement: placement, canvas: 100, flipped: flipped, folder: nil)
    }

    func close(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat = 1e-6) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }

    @Test func targetRectFlipsTheYAxis() {
        let topLeft = IconGeometry.targetRect(for: style, canvas: 100, flipped: true)
        let bottomLeft = IconGeometry.targetRect(for: style, canvas: 100, flipped: false)
        #expect(topLeft == CGRect(x: 25, y: 10, width: 50, height: 20))
        #expect(bottomLeft == CGRect(x: 25, y: 70, width: 50, height: 20))
    }

    @Test func fillCoversTheFrame() {
        let wide = IconStyle(x: 0, y: 0, width: 1, height: 0.5, mode: .fill)
        let result = layout(wide, square)
        #expect(close(result.bounds, CGRect(x: 0, y: -25, width: 100, height: 100)))
        #expect(close(result.visible.boundingBox, CGRect(x: 0, y: 0, width: 100, height: 50)), "the frame shows")
    }

    @Test func fitStaysInside() {
        let wide = IconStyle(x: 0, y: 0, width: 1, height: 0.5, mode: .fit)
        let result = layout(wide, square)
        #expect(close(result.bounds, CGRect(x: 25, y: 0, width: 50, height: 50)))
        #expect(close(result.visible.boundingBox, result.bounds), "the picture itself shows")
    }

    @Test func fitTouchesTheLimitingSide() {
        let frame = IconStyle(x: 0.1, y: 0.1, width: 0.8, height: 0.8, mode: .fit)
        let wide = layout(frame, CGSize(width: 1600, height: 900)).bounds
        #expect(abs(wide.width - 80) < 1e-9)
        #expect(abs(wide.height - 45) < 1e-9)
        #expect(abs(wide.midX - 50) < 1e-9 && abs(wide.midY - 50) < 1e-9)
    }

    @Test func degenerateSizesDoNotCrash() {
        let result = layout(style, .zero)
        #expect(close(result.bounds, CGRect(x: 25, y: 10, width: 50, height: 20)))
        #expect(IconGeometry.cornerRadius(for: .zero, canvas: 512) == 0)
        #expect(IconGeometry.placement(near: .zero, rotation: 30, imageSize: .zero, style: style, canvas: 100, folder: nil)
                == PicturePlacement(x: 0.5, y: 0.5, rotation: 30))
    }

    @Test func cornerRadiusNeverExceedsHalfTheShortSide() {
        let thin = CGRect(x: 0, y: 0, width: 300, height: 6)
        #expect(IconGeometry.cornerRadius(for: thin, canvas: 1024) == 3)
    }

    @Test func placementPicksThePartOfAFilledPictureThatShows() {
        // A square picture fills a wide frame, so it sticks out at the top and bottom.
        let wide = IconStyle(x: 0, y: 0, width: 1, height: 0.5, mode: .fill)
        let top = PicturePlacement(x: 0.5, y: 0)
        #expect(close(layout(wide, square, top).bounds, CGRect(x: 0, y: 0, width: 100, height: 100)))
        // With a bottom-left origin the picture's top is at the frame's top all the same.
        #expect(close(layout(wide, square, top, flipped: false).bounds, CGRect(x: 0, y: 0, width: 100, height: 100)))
        let bottom = PicturePlacement(x: 0.5, y: 1)
        #expect(close(layout(wide, square, bottom).bounds, CGRect(x: 0, y: -50, width: 100, height: 100)))
        #expect(close(layout(wide, square, bottom, flipped: false).bounds, CGRect(x: 0, y: 0, width: 100, height: 100)) == false)
        #expect(close(layout(wide, square, bottom, flipped: false).bounds, CGRect(x: 0, y: 50, width: 100, height: 100)))
    }

    @Test func placementPutsAFittedPicture() {
        // 90 across, 40 down: a square picture has 50 points of room across.
        let wide = IconStyle(x: 0.1, y: 0, width: 0.9, height: 0.4, mode: .fit)
        let left = layout(wide, square, PicturePlacement(x: 0, y: 0.5))
        #expect(close(left.bounds, CGRect(x: 10, y: 0, width: 40, height: 40)))
        let right = layout(wide, square, PicturePlacement(x: 1, y: 0.5), flipped: false)
        #expect(close(right.visible.boundingBox, CGRect(x: 60, y: 60, width: 40, height: 40)))
    }

    @Test func draggingMovesThePictureAsFarAsItGoes() {
        let wide = IconStyle(x: 0, y: 0, width: 1, height: 0.5, mode: .fill)
        func moved(_ style: IconStyle, by offset: CGSize) -> PicturePlacement {
            IconGeometry.placement(.natural, movedBy: offset, imageSize: square, style: style, canvas: 100, folder: nil)
        }
        // Filled: 50 points stick out. Dragging the picture down 10 shows 10 more of its top.
        let down = moved(wide, by: CGSize(width: 30, height: 10))
        #expect(down.x == 0.5 && abs(down.y - 0.3) < 1e-12)
        #expect(moved(wide, by: CGSize(width: 0, height: 500)).y == 0)
        // Fitted: 50 points of room across. Dragging right moves it right.
        var fitted = wide
        fitted.mode = .fit
        let right = moved(fitted, by: CGSize(width: 10, height: 10))
        #expect(abs(right.x - 0.7) < 1e-12 && right.y == 0.5)
        #expect(abs(layout(fitted, square, right).bounds.minX - 35) < 1e-9)
    }

    @Test func scalingKeepsTheShapeAndTheMiddle() {
        let rect = IconStyle.standard.rect
        let bigger = IconGeometry.scaled(rect, by: 1.1)
        #expect(abs(bigger.width - rect.width * 1.1) < 1e-9 && abs(bigger.height - rect.height * 1.1) < 1e-9)
        #expect(abs(bigger.midX - rect.midX) < 1e-9 && abs(bigger.midY - rect.midY) < 1e-9)
        let back = IconGeometry.scaled(bigger, by: 1 / 1.1)
        #expect(abs(back.width - rect.width) < 1e-9 && abs(back.minY - rect.minY) < 1e-9)
    }

    @Test func scalingGoesWellPastTheCanvas() {
        let rect = IconStyle.standard.rect
        // It grows until a side is the largest there is, and covers the canvas all the while.
        let biggest = IconGeometry.scaled(rect, by: 100)
        #expect(abs(max(biggest.width, biggest.height) - IconStyle.maximumSide) < 1e-9)
        #expect(abs(biggest.width / biggest.height - rect.width / rect.height) < 1e-9)
        #expect(biggest.minX <= 0 && biggest.maxX >= 1 && biggest.minY <= 0 && biggest.maxY >= 1)
        // A square in the middle of the canvas keeps its middle as it grows past it.
        let middle = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)
        let past = IconGeometry.scaled(middle, by: 3)
        #expect(abs(past.midX - 0.5) < 1e-9 && abs(past.midY - 0.5) < 1e-9 && abs(past.width - 1.2) < 1e-9)
        // It shrinks until its shorter side is the smallest there is.
        let smallest = IconGeometry.scaled(rect, by: 0.01)
        #expect(abs(smallest.height - IconStyle.minimumSide) < 1e-9)
        #expect(abs(smallest.width / smallest.height - rect.width / rect.height) < 1e-9)
        // Nothing to go by, nothing changes.
        #expect(IconGeometry.scaled(rect, by: .nan) == rect)
        #expect(IconGeometry.scaled(rect, by: 0) == rect)
    }

    @Test func aScaledRectangleStaysWhereAFrameCanBe() {
        // Against the right edge, it grows to the left while it is smaller than the canvas.
        let rect = CGRect(x: 0.6, y: 0.3, width: 0.4, height: 0.2)
        let bigger = IconGeometry.scaled(rect, by: 1.5)
        #expect(abs(bigger.maxX - 1) < 1e-9 && abs(bigger.width - 0.6) < 1e-9)
        #expect(abs(bigger.midY - rect.midY) < 1e-9)
        // Bigger than the canvas, it covers it.
        let past = IconGeometry.scaled(rect, by: 4)
        #expect(past.minX <= 0 && past.maxX >= 1)
        #expect(IconStyle.allows(past))
    }

    // MARK: - Turning

    /// Whether the picture, as `layout` draws it, covers the point.
    func covers(_ layout: PictureLayout, _ point: CGPoint, tolerance: CGFloat = 1e-6) -> Bool {
        let local = point.applying(layout.transform.inverted())
        return abs(local.x) <= layout.size.width / 2 + tolerance && abs(local.y) <= layout.size.height / 2 + tolerance
    }

    @Test func aQuarterTurnLaysThePictureOnItsSide() {
        let wide = IconStyle(x: 0, y: 0, width: 1, height: 0.5, mode: .fill)
        let picture = CGSize(width: 200, height: 100)
        // Upright the picture is as wide as the frame; turned, its short side is.
        let turned = layout(wide, picture, PicturePlacement(x: 0.5, y: 0.5, rotation: 90))
        #expect(abs(turned.size.width - 200) < 1e-9 && abs(turned.size.height - 100) < 1e-9)
        #expect(close(turned.bounds, CGRect(x: 0, y: -75, width: 100, height: 200)))
        // Fitted, it stands in the frame.
        var fitted = wide
        fitted.mode = .fit
        let standing = layout(fitted, picture, PicturePlacement(x: 0.5, y: 0.5, rotation: -90))
        #expect(close(standing.bounds, CGRect(x: 37.5, y: 0, width: 25, height: 50)))
        #expect(close(standing.visible.boundingBox, standing.bounds))
    }

    @Test func aTurnedPictureMovesAlongTheFrameWhenTurnedByQuarterTurns() {
        let wide = IconStyle(x: 0, y: 0, width: 1, height: 0.5, mode: .fill)
        let picture = CGSize(width: 200, height: 100)
        // On its side it sticks out at the top and bottom: y picks the part that shows, as upright.
        let top = layout(wide, picture, PicturePlacement(x: 0.5, y: 0, rotation: 90))
        #expect(close(top.bounds, CGRect(x: 0, y: 0, width: 100, height: 200)))
        let bottom = layout(wide, picture, PicturePlacement(x: 0.5, y: 1, rotation: 270))
        #expect(close(bottom.bounds, CGRect(x: 0, y: -150, width: 100, height: 200)))
    }

    @Test func aFilledPictureCoversItsFrameHoweverItIsTurned() {
        let frames = [
            IconStyle(x: 0.1, y: 0.3, width: 0.8, height: 0.47, mode: .fill),
            IconStyle(x: 0.2, y: 0.1, width: 0.3, height: 0.8, mode: .fill),
            IconStyle(x: -0.4, y: -0.2, width: 1.9, height: 1.4, mode: .fill),
        ]
        let pictures = [CGSize(width: 400, height: 300), CGSize(width: 300, height: 900), CGSize(width: 50, height: 50)]
        for style in frames {
            let frame = IconGeometry.targetRect(for: style, canvas: 100, flipped: true)
            let corners = [CGPoint(x: frame.minX, y: frame.minY), CGPoint(x: frame.maxX, y: frame.minY),
                           CGPoint(x: frame.minX, y: frame.maxY), CGPoint(x: frame.maxX, y: frame.maxY)]
            for picture in pictures {
                for rotation in stride(from: -180.0, through: 180, by: 7.5) {
                    for (x, y) in [(0.0, 0.0), (1, 1), (0, 1), (1, 0), (0.5, 0.5), (0.3, 0.8)] {
                        let result = layout(style, picture, PicturePlacement(x: x, y: y, rotation: rotation))
                        #expect(corners.allSatisfy { covers(result, $0) }, "\(style.rect) \(picture) \(rotation)° at \(x), \(y)")
                    }
                }
            }
        }
    }

    @Test func aFittedPictureStaysInItsFrameHoweverItIsTurned() {
        let style = IconStyle(x: 0.1, y: 0.3, width: 0.8, height: 0.47, mode: .fit)
        let frame = IconGeometry.targetRect(for: style, canvas: 100, flipped: true).insetBy(dx: -1e-6, dy: -1e-6)
        for picture in [CGSize(width: 400, height: 300), CGSize(width: 300, height: 900)] {
            for rotation in stride(from: -180.0, through: 180, by: 7.5) {
                var widest: CGFloat = 0
                for (x, y) in [(0.0, 0.0), (1, 1), (0, 1), (1, 0), (0.5, 0.5)] {
                    let result = layout(style, picture, PicturePlacement(x: x, y: y, rotation: rotation))
                    #expect(frame.contains(result.bounds), "\(picture) \(rotation)° at \(x), \(y)")
                    widest = max(widest, result.bounds.width, result.bounds.height)
                }
                // And it is as big as it can be: one of its sides touches the frame.
                let result = layout(style, picture, PicturePlacement(x: 0.5, y: 0.5, rotation: rotation))
                #expect(abs(result.bounds.width - 80) < 1e-6 || abs(result.bounds.height - 47) < 1e-6)
            }
        }
    }

    @Test func allOfAFittedPictureShowsHoweverItIsTurned() {
        // The part that shows is the turned picture itself: right inside its corners, it shows;
        // right outside its sides, it doesn't.
        let style = IconStyle(x: 0.2, y: 0.3, width: 0.6, height: 0.5, mode: .fit)
        for picture in [CGSize(width: 400, height: 300), CGSize(width: 200, height: 500)] {
            for rotation in stride(from: -180.0, through: 180, by: 7.5) {
                let result = layout(style, picture, PicturePlacement(x: 0.3, y: 0.6, rotation: rotation))
                let radius = IconGeometry.cornerRadius(for: result.uprightRect, canvas: 100)
                let inner = result.uprightRect.insetBy(dx: radius + 0.2, dy: radius + 0.2)
                let outer = result.uprightRect.insetBy(dx: -0.2, dy: -0.2)
                let insidePoints = [CGPoint(x: inner.minX, y: inner.minY), CGPoint(x: inner.maxX, y: inner.minY),
                                    CGPoint(x: inner.minX, y: inner.maxY), CGPoint(x: inner.maxX, y: inner.maxY),
                                    CGPoint(x: result.uprightRect.minX + 0.2, y: 0), CGPoint(x: 0, y: result.uprightRect.maxY - 0.2)]
                let outsidePoints = [CGPoint(x: outer.minX, y: 0), CGPoint(x: outer.maxX, y: 0), CGPoint(x: 0, y: outer.minY), CGPoint(x: 0, y: outer.maxY)]
                #expect(insidePoints.allSatisfy { result.visible.contains($0.applying(result.transform)) }, "\(picture) \(rotation)°")
                #expect(outsidePoints.allSatisfy { !result.visible.contains($0.applying(result.transform)) }, "\(picture) \(rotation)°")
            }
        }
    }

    @Test func aTurnHalfwayBetweenQuarterTurnsMeansTheSameWhicheverWayItIsWritten() {
        let style = IconStyle(x: 0.1, y: 0.3, width: 0.8, height: 0.47, mode: .fill)
        let picture = CGSize(width: 400, height: 300)
        let point = CGPoint(x: 0.45, y: 0.6)
        for (a, b) in [(225.0, -135.0), (315, -45), (-225, 135), (-315, 45), (405, 45)] {
            func center(_ rotation: Double) -> CGPoint {
                let placement = IconGeometry.placement(near: point, rotation: rotation, imageSize: picture, style: style, canvas: 100, folder: nil)
                return IconGeometry.pictureCenter(imageSize: picture, style: style, placement: placement, canvas: 100, folder: nil)
            }
            let first = center(a), second = center(b)
            #expect(abs(first.x - second.x) < 1e-9 && abs(first.y - second.y) < 1e-9, "\(a)° and \(b)°")
        }
    }

    @Test func turningKeepsThePictureWhereItIs() {
        let style = IconStyle(x: 0.1, y: 0.3, width: 0.8, height: 0.47, mode: .fill)
        let picture = CGSize(width: 400, height: 300)
        let placed = PicturePlacement(x: 0.5, y: 0.2)
        let start = IconGeometry.pictureCenter(imageSize: picture, style: style, placement: placed, canvas: 100, folder: nil)
        func center(_ placement: PicturePlacement) -> CGPoint {
            IconGeometry.pictureCenter(imageSize: picture, style: style, placement: placement, canvas: 100, folder: nil)
        }
        func distance(_ point: CGPoint, _ other: CGPoint) -> Double { hypot(point.x - other.x, point.y - other.y) }
        for rotation in [5.0, -30, 90, 180] {
            let turned = IconGeometry.placement(placed, turnedTo: rotation, imageSize: picture, style: style, canvas: 100, folder: nil)
            #expect(turned.rotation == rotation)
            // As close to where it was as it can be at its new size: no other placement is closer.
            let gap = distance(center(turned), start)
            for x in stride(from: 0.0, through: 1, by: 0.05) {
                for y in stride(from: 0.0, through: 1, by: 0.05) {
                    #expect(gap <= distance(center(PicturePlacement(x: x, y: y, rotation: rotation)), start) + 1e-9)
                }
            }
        }
        // Turned to where it started, from where it was then, it is where it was.
        let back = IconGeometry.placement(near: start, rotation: 0, imageSize: picture, style: style, canvas: 100, folder: nil)
        #expect(abs(back.x - placed.x) < 1e-9 && abs(back.y - placed.y) < 1e-9)
        // A quarter turn of a picture in the middle keeps it there.
        let middle = IconGeometry.placement(.natural, turnedTo: 90, imageSize: picture, style: style, canvas: 100, folder: nil)
        #expect(middle == PicturePlacement(x: 0.5, y: 0.5, rotation: 90))
    }

    @Test func aPlacementPutsThePictureWhereItWasAskedFor() {
        let style = IconStyle(x: 0.1, y: 0.3, width: 0.8, height: 0.47, mode: .fill)
        let picture = CGSize(width: 300, height: 400)
        for rotation in [0.0, 17, -60, 90, 135] {
            for mode in FitMode.allCases {
                var style = style
                style.mode = mode
                let placement = PicturePlacement(x: 0.3, y: 0.7, rotation: rotation)
                let center = IconGeometry.pictureCenter(imageSize: picture, style: style, placement: placement, canvas: 100, folder: nil)
                let again = IconGeometry.placement(near: center, rotation: rotation, imageSize: picture, style: style, canvas: 100, folder: nil)
                let there = IconGeometry.pictureCenter(imageSize: picture, style: style, placement: again, canvas: 100, folder: nil)
                #expect(hypot(there.x - center.x, there.y - center.y) < 1e-9, "\(rotation)° \(mode)")
            }
        }
    }

    // MARK: - The folder's edge

    @Test func anEdgeOnTheFoldersEdgeGoesAPixelPastIt() {
        let bounds = FolderArtwork.shape.bounds
        let folder = FolderEdges(bounds: bounds)
        let snapped = IconStyle(rect: bounds, mode: .fill)
        let (rect, reaches) = IconGeometry.frame(for: snapped, canvas: 256, folder: folder)
        #expect(reaches == [.left, .right, .top, .bottom])
        #expect(abs(rect.minX - (bounds.minX - 1.0 / 256)) < 1e-12 && abs(rect.maxY - (bounds.maxY + 1.0 / 256)) < 1e-12)
        // Where the folder's pixels go past its bounds at a size, a pixel past them.
        let further = FolderEdges(bounds: bounds, extent: bounds.insetBy(dx: 0, dy: -1.25 / 64))
        let past = IconGeometry.frame(for: snapped, canvas: 64, folder: further).rect
        #expect(abs(past.minY - (bounds.minY - 2.25 / 64)) < 1e-12 && abs(past.minX - (bounds.minX - 1.0 / 64)) < 1e-12)
        // Just inside, by less than a hundredth of the icon: the same.
        let nearly = IconStyle(rect: bounds.insetBy(dx: 0.5 / 256, dy: 0.009), mode: .fill)
        #expect(IconGeometry.frame(for: nearly, canvas: 256, folder: folder).reaches == [.left, .right, .top, .bottom])
        // A frame whose top ended up two pixels below the folder's (at 256), as snapping used to
        // leave it: it covers the folder's top.
        let hair = IconStyle(x: bounds.minX, y: bounds.minY + 2.0 / 256, width: bounds.width, height: 1 - bounds.minY - 2.0 / 256, mode: .fill)
        let covered = IconGeometry.frame(for: hair, canvas: 256, folder: folder)
        #expect(covered.reaches.contains(.top) && covered.rect.minY < bounds.minY)
        // Well inside: left as it is.
        let inside = IconStyle(rect: bounds.insetBy(dx: 0.02, dy: 0.02), mode: .fill)
        let kept = IconGeometry.frame(for: inside, canvas: 256, folder: folder)
        #expect(kept.reaches.isEmpty && kept.rect == inside.rect)
        // Past it already: left as it is too.
        let whole = IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill)
        #expect(IconGeometry.frame(for: whole, canvas: 256, folder: folder).rect == whole.rect)
    }

    @Test func cornersAreRoundedOnlyAwayFromTheFoldersEdge() {
        let folder = FolderEdges.standard
        // Across the folder's front, from side to side: its sides are the folder's.
        let band = IconStyle(x: folder.bounds.minX, y: 0.4, width: folder.bounds.width, height: 0.3, mode: .fill)
        let result = IconGeometry.layout(imageSize: square, style: band, placement: .natural, canvas: 100, flipped: true, folder: folder)
        let frame = IconGeometry.frame(for: band, canvas: 100, folder: folder).rect
        let corner = CGPoint(x: frame.minX * 100 + 0.01, y: frame.minY * 100 + 0.01)
        #expect(result.visible.contains(corner), "square at the folder's side")
        // On the front, away from the edges: rounded.
        let label = IconStyle(x: 0.3, y: 0.4, width: 0.4, height: 0.3, mode: .fill)
        let rounded = IconGeometry.layout(imageSize: square, style: label, placement: .natural, canvas: 100, flipped: true, folder: folder)
        #expect(!rounded.visible.contains(CGPoint(x: 30.01, y: 40.01)))
        #expect(rounded.visible.contains(CGPoint(x: 50, y: 55)))
    }
}

@Suite struct PicturePlacementTests {
    @Test func staysBetweenTheEdges() {
        #expect(PicturePlacement(x: -1, y: 2) == PicturePlacement(x: 0, y: 1))
        #expect(PicturePlacement(x: .nan, y: .infinity) == .natural)
    }

    @Test func turnsAreKeptWithinAWholeTurn() {
        #expect(PicturePlacement(x: 0.5, y: 0.5, rotation: 270).rotation == -90)
        #expect(PicturePlacement(x: 0.5, y: 0.5, rotation: -180).rotation == 180)
        #expect(PicturePlacement(x: 0.5, y: 0.5, rotation: 540).rotation == 180)
        #expect(PicturePlacement(x: 0.5, y: 0.5, rotation: -450).rotation == -90)
        #expect(PicturePlacement(x: 0.5, y: 0.5, rotation: 360).rotation == 0)
        #expect(PicturePlacement(x: 0.5, y: 0.5, rotation: .nan).rotation == 0)
        #expect(PicturePlacement(x: 0.5, y: 0.5, rotation: 90 - 1e-12).rotation == 90)
        #expect(PicturePlacement(x: 0.5, y: 0.5, rotation: 12.5).rotation == 12.5)
        // Four quarter turns come back to upright.
        var placement = PicturePlacement.natural
        for _ in 0..<4 { placement = placement.turned(to: placement.rotation + 90) }
        #expect(placement == .natural)
    }

    @Test func decodingAlsoClamps() throws {
        let placement = try JSONDecoder().decode(PicturePlacement.self, from: Data(#"{"x": 1.5, "y": 0.25, "rotation": 450}"#.utf8))
        #expect(placement == PicturePlacement(x: 1, y: 0.25, rotation: 90))
    }

    @Test func anUprightPictureIsSavedAsBefore() throws {
        let upright = try #require(String(data: JSONEncoder().encode(PicturePlacement(x: 0.2, y: 0.8)), encoding: .utf8))
        #expect(!upright.contains("rotation"), "earlier versions read it as it is")
        let turned = PicturePlacement(x: 0.2, y: 0.8, rotation: -30)
        #expect(try JSONDecoder().decode(PicturePlacement.self, from: JSONEncoder().encode(turned)) == turned)
        // One saved before pictures could turn is upright.
        #expect(try JSONDecoder().decode(PicturePlacement.self, from: Data(#"{"x": 0.2, "y": 0.8}"#.utf8)).rotation == 0)
    }

    @Test func aZoomFromAnEarlierBuildIsLetGo() throws {
        let placement = try JSONDecoder().decode(PicturePlacement.self, from: Data(#"{"x": 0.2, "y": 0.8, "zoom": 3}"#.utf8))
        #expect(placement == PicturePlacement(x: 0.2, y: 0.8))
        let saved = try #require(String(data: JSONEncoder().encode(placement), encoding: .utf8))
        #expect(!saved.contains("zoom"))
    }

    @Test func recordsWithoutOneHaveThePictureInTheMiddle() throws {
        let json = #"{"id": "6F1D7E0A-6C49-4E1E-9C55-5B1B8E6C2B11", "bookmark": "", "lastKnownPath": "/tmp/a", "pictureName": "a.jpg", "iconDigest": "", "created": 0, "updated": 0}"#
        let record = try JSONDecoder().decode(FolderRecord.self, from: Data(json.utf8))
        #expect(record.placement == nil)
        #expect(record.style == nil)
    }

    @Test func recordsKeepWhereTheirPictureWasPutAsAnAlignment() throws {
        let json = #"{"id": "6F1D7E0A-6C49-4E1E-9C55-5B1B8E6C2B11", "bookmark": "", "lastKnownPath": "/tmp/a", "pictureName": "a.jpg", "alignment": {"x": 0.5, "y": 0.012}, "iconDigest": "", "created": 0, "updated": 0}"#
        let record = try JSONDecoder().decode(FolderRecord.self, from: Data(json.utf8))
        #expect(record.placement == PicturePlacement(x: 0.5, y: 0.012))
        // Saved again, it is a placement, and reads back the same.
        let again = try JSONDecoder().decode(FolderRecord.self, from: JSONEncoder().encode(record))
        #expect(again.placement == record.placement)
        let saved = try #require(String(data: JSONEncoder().encode(record), encoding: .utf8))
        #expect(saved.contains("\"placement\"") && !saved.contains("\"alignment\""))
    }
}

@Suite struct CanonicalPathTests {
    @Test func resolvesExistingAndMissingPaths() throws {
        let temp = try TemporaryDirectory()
        let real = FolderInspector.canonicalPath(temp.url.path)
        #expect(real.hasPrefix("/private/"), "the temporary directory lives under /private")
        #expect(FolderInspector.canonicalPath(temp.url.appendingPathComponent("gone/deeper").path) == real + "/gone/deeper")
        #expect(FolderInspector.canonicalPath("/") == "/")
    }
}

@Suite struct IconSnappingTests {
    let shape = FolderArtwork.shape
    let snapping = IconSnapping(threshold: 0.02)

    @Test func centersAMovedPicture() {
        let width = 0.4
        let nearlyCentered = CGRect(x: shape.bounds.midX - width / 2 + 0.012, y: 0.4, width: width, height: 0.3)
        let (rect, guides) = snapping.move(nearlyCentered)
        #expect(abs(rect.midX - shape.bounds.midX) < 1e-9)
        #expect(rect.size == nearlyCentered.size)
        #expect(guides.contains(SnapGuide(.vertical, at: shape.bounds.midX)))
    }

    @Test func linesUpWithTheFront() {
        let rect = CGRect(x: 0.3, y: shape.front.minY - 0.015, width: 0.3, height: 0.2)
        let (snapped, guides) = snapping.move(rect)
        #expect(abs(snapped.minY - shape.front.minY) < 1e-9)
        #expect(guides.contains(SnapGuide(.horizontal, at: shape.front.minY)))
    }

    @Test func leavesFarAwayPicturesAlone() {
        let rect = CGRect(x: 0.27, y: 0.42, width: 0.31, height: 0.2)
        let (snapped, guides) = snapping.move(rect)
        #expect(snapped == rect)
        #expect(guides.isEmpty)
    }

    @Test func resizingSnapsToWhereThePictureIsCentered() {
        let left = 0.2
        let mirrored = 2 * shape.bounds.midX - left
        let rect = CGRect(x: left, y: 0.4, width: mirrored - left - 0.01, height: 0.3)
        let (snapped, guides) = snapping.resize(rect, moving: .right, symmetric: false)
        #expect(abs(snapped.minX - left) < 1e-12)
        #expect(abs(snapped.maxX - mirrored) < 1e-9)
        #expect(guides.contains(SnapGuide(.vertical, at: shape.bounds.midX)))
    }

    @Test func resizingSnapsToTheFolderEdges() {
        let rect = CGRect(x: 0.3, y: 0.4, width: 0.3, height: shape.bounds.maxY - 0.4 - 0.01)
        let (snapped, guides) = snapping.resize(rect, moving: [.right, .bottom], symmetric: false)
        #expect(abs(snapped.maxY - shape.bounds.maxY) < 1e-9)
        #expect(guides.contains(SnapGuide(.horizontal, at: shape.bounds.maxY)))
    }

    @Test func symmetricResizingKeepsTheMiddle() {
        let rect = CGRect(x: shape.bounds.minX + 0.01, y: 0.4, width: 1 - 2 * (shape.bounds.minX + 0.01), height: 0.3)
        let (snapped, _) = snapping.resize(rect, moving: [.left, .right], symmetric: true)
        #expect(abs(snapped.midX - rect.midX) < 1e-9)
        #expect(abs(snapped.minX - shape.bounds.minX) < 1e-9)
    }

    @Test func aMovedPictureSticksToTheMiddle() {
        // A square picture filling a wide frame can move up and down only.
        let style = IconStyle(x: 0.2, y: 0.4, width: 0.4, height: 0.2, mode: .fill)
        let rect = style.rect
        let square = CGSize(width: 100, height: 100)
        func pan(_ placement: PicturePlacement, _ style: IconStyle) -> (placement: PicturePlacement, guides: [SnapGuide]) {
            snapping.pan(placement, imageSize: square, style: style, canvas: 100, folder: nil)
        }
        let (placement, guides) = pan(PicturePlacement(x: 0.9, y: 0.55), style)
        #expect(placement == PicturePlacement(x: 0.9, y: 0.5))
        #expect(guides == [SnapGuide(.horizontal, at: rect.midY, along: rect.minX...rect.maxX)])

        let (away, none) = pan(PicturePlacement(x: 0.5, y: 0.8), style)
        #expect(away.y == 0.8)
        #expect(none.isEmpty)

        // Fitted, it moves across instead, and sticks to the middle that way.
        var fitted = style
        fitted.mode = .fit
        let (across, line) = pan(PicturePlacement(x: 0.52, y: 0.1), fitted)
        #expect(across == PicturePlacement(x: 0.5, y: 0.1))
        #expect(line == [SnapGuide(.vertical, at: rect.midX, along: rect.minY...rect.maxY)])
    }

    @Test func aTurnedPictureSticksToTheMiddleAlongTurnedLines() {
        // Filling a wide frame, a square picture turned a little sticks out at the top and
        // bottom only, along its tilted sides.
        let style = IconStyle(x: 0.2, y: 0.4, width: 0.4, height: 0.2, mode: .fill)
        let (placement, guides) = snapping.pan(
            PicturePlacement(x: 0.51, y: 0.49, rotation: 20), imageSize: CGSize(width: 100, height: 100), style: style, canvas: 100, folder: nil
        )
        #expect(placement == PicturePlacement(x: 0.51, y: 0.5, rotation: 20))
        #expect(guides.count == 1 && guides.allSatisfy { $0.axis == .horizontal && abs($0.tilt - 20 * .pi / 180) < 1e-9 })
        // A quarter turn moves along the frame's own lines.
        let (_, straight) = snapping.pan(
            PicturePlacement(x: 0.5, y: 0.49, rotation: 90), imageSize: CGSize(width: 100, height: 100), style: style, canvas: 100, folder: nil
        )
        #expect(straight.allSatisfy { $0.tilt == 0 })
    }

    @Test func turningSticksToUprightAndQuarterTurns() {
        #expect(IconSnapping.turn(3) == (0, true))
        #expect(IconSnapping.turn(-3.9) == (0, true))
        #expect(IconSnapping.turn(87) == (90, true))
        #expect(IconSnapping.turn(-178) == (-180, true))
        #expect(IconSnapping.turn(10) == (10, false))
        #expect(IconSnapping.turn(45) == (45, false))
    }

    @Test func anEdgeDraggedToTheFoldersTopStaysOnIt() {
        // The frame reaches the bottom of the canvas, so the spot that centers it on the front
        // is a hair below the folder's top; the folder's own top wins.
        let rect = CGRect(x: shape.bounds.minX, y: shape.bounds.minY + 0.005, width: shape.bounds.width, height: 1 - shape.bounds.minY - 0.005)
        let (snapped, guides) = snapping.resize(rect, moving: .top, symmetric: false)
        #expect(abs(snapped.minY - shape.bounds.minY) < 1e-12)
        #expect(guides.contains(SnapGuide(.horizontal, at: shape.bounds.minY)))
    }

    @Test func aFrameBiggerThanTheCanvasMovesWhereItStillCoversIt() {
        let big = CGRect(x: -0.3, y: -0.2, width: 1.6, height: 1.4)
        let (moved, _) = snapping.move(big.offsetBy(dx: 0.5, dy: -0.5))
        #expect(moved.minX == 0 && abs(moved.minY - -0.4) < 1e-12)
        // Its middle still sticks to the folder's middle.
        let nearly = CGRect(x: shape.bounds.midX - 0.8 + 0.01, y: -0.2, width: 1.6, height: 1.4)
        #expect(abs(snapping.move(nearly).rect.midX - shape.bounds.midX) < 1e-9)
    }

    @Test func aScaledFrameSticksWhereItsEdgesMeetTheFolder() {
        // Centered on the folder, its sides just inside the folder's: growing a little more
        // puts them right on the folder's sides, both at once.
        let middle = CGPoint(x: shape.bounds.midX, y: shape.front.midY)
        let half = shape.bounds.width / 2 - 0.01
        let rect = CGRect(x: middle.x - half, y: middle.y - 0.1, width: 2 * half, height: 0.2)
        let (snapped, guides) = snapping.scale(rect)
        #expect(abs(snapped.minX - shape.bounds.minX) < 1e-9 && abs(snapped.maxX - shape.bounds.maxX) < 1e-9)
        #expect(abs(snapped.width / snapped.height - rect.width / rect.height) < 1e-9, "it keeps its shape")
        #expect(abs(snapped.midX - middle.x) < 1e-9 && abs(snapped.midY - middle.y) < 1e-9, "and its middle")
        #expect(Set(guides) == [SnapGuide(.vertical, at: shape.bounds.minX), SnapGuide(.vertical, at: shape.bounds.maxX)])
    }

    @Test func aScaledFrameAwayFromTheLinesIsLeftAlone() {
        // Its middle is on the folder's middle, but that doesn't change while it grows.
        let rect = CGRect(x: shape.bounds.midX - 0.25, y: shape.front.midY - 0.1, width: 0.5, height: 0.2)
        let (snapped, guides) = snapping.scale(rect)
        #expect(snapped == rect)
        #expect(guides.isEmpty)
        // Sticking would take it below the smallest size: it doesn't.
        let tiny = CGRect(x: shape.bounds.midX + 0.03 - IconStyle.minimumSide / 2, y: 0.36, width: IconStyle.minimumSide, height: IconStyle.minimumSide)
        #expect(snapping.scale(tiny).rect == tiny)
    }

    @Test func neverSnapsBelowTheMinimumSize() {
        let tiny = CGRect(x: 0.47, y: 0.5, width: IconStyle.minimumSide, height: IconStyle.minimumSide)
        let (snapped, _) = snapping.resize(tiny, moving: .left, symmetric: false)
        #expect(snapped.width >= IconStyle.minimumSide - 1e-9)
    }
}
