import CoreGraphics
import Foundation
import Testing
@testable import PrettyFolderKit

@Suite struct IconStyleTests {
    @Test func clampsIntoTheCanvas() {
        let style = IconStyle(x: -0.5, y: 0.9, width: 2, height: 0.5, mode: .fit)
        #expect(style.x == 0)
        #expect(style.width == 1)
        #expect(style.height == 0.5)
        #expect(style.y == 0.5)
    }

    @Test func enforcesMinimumSize() {
        let style = IconStyle(x: 0.5, y: 0.5, width: 0, height: 0.001, mode: .fill)
        #expect(style.width == IconStyle.minimumSide)
        #expect(style.height == IconStyle.minimumSide)
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
    }
}

@Suite struct IconGeometryTests {
    let style = IconStyle(x: 0.25, y: 0.1, width: 0.5, height: 0.2, mode: .fill)

    @Test func targetRectFlipsTheYAxis() {
        let topLeft = IconGeometry.targetRect(for: style, canvas: 100, flipped: true)
        let bottomLeft = IconGeometry.targetRect(for: style, canvas: 100, flipped: false)
        #expect(topLeft == CGRect(x: 25, y: 10, width: 50, height: 20))
        #expect(bottomLeft == CGRect(x: 25, y: 70, width: 50, height: 20))
    }

    @Test func fillCoversTheTarget() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 50)
        let rect = IconGeometry.imageRect(imageSize: CGSize(width: 400, height: 400), in: target, mode: .fill)
        #expect(rect == CGRect(x: 0, y: -25, width: 100, height: 100))
        #expect(rect.contains(target))
    }

    @Test func fitStaysInside() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 50)
        let rect = IconGeometry.imageRect(imageSize: CGSize(width: 400, height: 400), in: target, mode: .fit)
        #expect(rect == CGRect(x: 25, y: 0, width: 50, height: 50))
        #expect(target.contains(rect))
    }

    @Test func fitTouchesTheLimitingSide() {
        let target = CGRect(x: 10, y: 10, width: 80, height: 80)
        let wide = IconGeometry.imageRect(imageSize: CGSize(width: 1600, height: 900), in: target, mode: .fit)
        #expect(wide.width == 80)
        #expect(abs(wide.height - 45) < 0.0001)
        #expect(wide.midX == target.midX && wide.midY == target.midY)
    }

    @Test func degenerateSizesDoNotCrash() {
        let target = CGRect(x: 0, y: 0, width: 10, height: 10)
        #expect(IconGeometry.imageRect(imageSize: .zero, in: target, mode: .fill) == target)
        #expect(IconGeometry.cornerRadius(for: .zero, canvas: 512) == 0)
    }

    @Test func cornerRadiusNeverExceedsHalfTheShortSide() {
        let thin = CGRect(x: 0, y: 0, width: 300, height: 6)
        #expect(IconGeometry.cornerRadius(for: thin, canvas: 1024) == 3)
    }

    @Test func alignmentPicksThePartOfAFilledPictureThatShows() {
        // A square picture fills a wide rectangle, so it sticks out at the top and bottom.
        let target = CGRect(x: 0, y: 0, width: 100, height: 50)
        let square = CGSize(width: 400, height: 400)
        let top = PictureAlignment(x: 0.5, y: 0)
        #expect(IconGeometry.imageRect(imageSize: square, in: target, mode: .fill, alignment: top, flipped: true)
                == CGRect(x: 0, y: 0, width: 100, height: 100))
        // With a bottom-left origin the picture's top is at the rectangle's top all the same.
        #expect(IconGeometry.imageRect(imageSize: square, in: target, mode: .fill, alignment: top, flipped: false)
                == CGRect(x: 0, y: -50, width: 100, height: 100))
        let bottom = PictureAlignment(x: 0.5, y: 1)
        #expect(IconGeometry.imageRect(imageSize: square, in: target, mode: .fill, alignment: bottom, flipped: true)
                == CGRect(x: 0, y: -50, width: 100, height: 100))
        #expect(IconGeometry.visibleRect(imageSize: square, in: target, mode: .fill, alignment: bottom, flipped: true) == target)
    }

    @Test func alignmentPlacesAFittedPicture() {
        let target = CGRect(x: 10, y: 0, width: 100, height: 50)
        let square = CGSize(width: 400, height: 400)
        let left = PictureAlignment(x: 0, y: 0.5)
        let right = PictureAlignment(x: 1, y: 0.5)
        #expect(IconGeometry.imageRect(imageSize: square, in: target, mode: .fit, alignment: left, flipped: true)
                == CGRect(x: 10, y: 0, width: 50, height: 50))
        #expect(IconGeometry.visibleRect(imageSize: square, in: target, mode: .fit, alignment: right, flipped: false)
                == CGRect(x: 60, y: 0, width: 50, height: 50))
    }

    @Test func roomIsWhatSticksOutOrIsLeftOver() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 50)
        let square = CGSize(width: 400, height: 400)
        #expect(IconGeometry.room(imageSize: square, in: target, mode: .fill) == CGSize(width: 0, height: 50))
        #expect(IconGeometry.room(imageSize: square, in: target, mode: .fit) == CGSize(width: 50, height: 0))
        #expect(IconGeometry.room(imageSize: CGSize(width: 200, height: 100), in: target, mode: .fill) == .zero)
    }

    @Test func draggingMovesThePictureAsFarAsItGoes() {
        let target = CGRect(x: 0, y: 0, width: 100, height: 50)
        let square = CGSize(width: 400, height: 400)
        // Filled: 50 points stick out. Dragging the picture down 10 shows 10 more of its top.
        let down = IconGeometry.alignment(.centered, movedBy: CGSize(width: 30, height: 10), imageSize: square, in: target, mode: .fill)
        #expect(down == PictureAlignment(x: 0.5, y: 0.3))
        let far = IconGeometry.alignment(.centered, movedBy: CGSize(width: 0, height: 500), imageSize: square, in: target, mode: .fill)
        #expect(far.y == 0)
        // Fitted: 50 points of room across. Dragging right moves it right.
        let right = IconGeometry.alignment(.centered, movedBy: CGSize(width: 10, height: 10), imageSize: square, in: target, mode: .fit)
        #expect(right == PictureAlignment(x: 0.7, y: 0.5))
        let rect = IconGeometry.imageRect(imageSize: square, in: target, mode: .fit, alignment: right, flipped: true)
        #expect(rect.minX == 35)
    }
}

@Suite struct PictureAlignmentTests {
    @Test func staysBetweenTheEdges() {
        #expect(PictureAlignment(x: -1, y: 2) == PictureAlignment(x: 0, y: 1))
        #expect(PictureAlignment(x: .nan, y: .infinity) == .centered)
    }

    @Test func decodingAlsoClamps() throws {
        let alignment = try JSONDecoder().decode(PictureAlignment.self, from: Data(#"{"x": 1.5, "y": 0.25}"#.utf8))
        #expect(alignment == PictureAlignment(x: 1, y: 0.25))
    }

    @Test func recordsWithoutOneHaveThePictureInTheMiddle() throws {
        let json = #"{"id": "6F1D7E0A-6C49-4E1E-9C55-5B1B8E6C2B11", "bookmark": "", "lastKnownPath": "/tmp/a", "pictureName": "a.jpg", "iconDigest": "", "created": 0, "updated": 0}"#
        let record = try JSONDecoder().decode(FolderRecord.self, from: Data(json.utf8))
        #expect(record.alignment == nil)
        #expect(record.style == nil)
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
        // A square picture filling a wide rectangle can move up and down only.
        let rect = CGRect(x: 0.2, y: 0.4, width: 0.4, height: 0.2)
        let square = CGSize(width: 100, height: 100)
        let nearlyCentered = PictureAlignment(x: 0.9, y: 0.55)
        let (alignment, guides) = snapping.pan(nearlyCentered, imageSize: square, in: rect, mode: .fill)
        #expect(alignment == PictureAlignment(x: 0.9, y: 0.5))
        #expect(guides == [SnapGuide(.horizontal, at: rect.midY, along: rect.minX...rect.maxX)])

        let (away, none) = snapping.pan(PictureAlignment(x: 0.5, y: 0.8), imageSize: square, in: rect, mode: .fill)
        #expect(away.y == 0.8)
        #expect(none.isEmpty)
    }

    @Test func neverSnapsBelowTheMinimumSize() {
        let tiny = CGRect(x: 0.47, y: 0.5, width: IconStyle.minimumSide, height: IconStyle.minimumSide)
        let (snapped, _) = snapping.resize(tiny, moving: .left, symmetric: false)
        #expect(snapped.width >= IconStyle.minimumSide - 1e-9)
    }
}
