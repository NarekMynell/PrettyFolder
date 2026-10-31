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
}
