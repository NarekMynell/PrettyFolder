import CoreGraphics

/// A line on the icon that the picture lines up with, in unit coordinates.
public struct SnapGuide: Hashable, Sendable {
    public enum Axis: Hashable, Sendable {
        /// The line x = `position`.
        case vertical
        /// The line y = `position`.
        case horizontal
    }

    public let axis: Axis
    public let position: Double
    /// Where the line runs along its axis; `nil` for all the way across the icon.
    public let extent: ClosedRange<Double>?
    /// How far the line is turned counterclockwise, in radians, around the middle of its
    /// extent: the middle of a picture turned by something other than quarter turns moves
    /// along turned lines.
    public let tilt: Double

    public init(_ axis: Axis, at position: Double, along extent: ClosedRange<Double>? = nil, tilt: Double = 0) {
        self.axis = axis
        self.position = position
        self.extent = extent
        self.tilt = tilt
    }
}

/// The edges of the picture's rectangle that a resize moves.
public struct RectEdges: OptionSet, Hashable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let left = RectEdges(rawValue: 1 << 0)
    public static let right = RectEdges(rawValue: 1 << 1)
    public static let top = RectEdges(rawValue: 1 << 2)
    public static let bottom = RectEdges(rawValue: 1 << 3)
}

/// Makes precise placement easy: while the picture is moved or resized, its edges and
/// its center stick to the folder's edges and centers once they come close.
public struct IconSnapping: Sendable {
    /// The folder's left edge, its middle and its right edge.
    public let columns: [Double]
    /// The top of the folder, the top and the middle of its front, and its bottom.
    public let rows: [Double]
    /// How close an edge or center has to come to a line to stick to it.
    public var threshold: Double

    /// What centered means: the middle of the folder from left to right, and the middle
    /// of its front from top to bottom, which is where pictures look centered.
    private let centerX: Double
    private let centerY: Double

    public init(shape: FolderShape = FolderArtwork.shape, threshold: Double = 0.02) {
        centerX = shape.bounds.midX
        centerY = shape.front.midY
        columns = [shape.bounds.minX, centerX, shape.bounds.maxX]
        rows = [shape.bounds.minY, shape.front.minY, centerY, shape.bounds.maxY]
        self.threshold = threshold
    }

    /// A moved rectangle, snapped: its left, center or right to the closest column, its
    /// top, middle or bottom to the closest row. Its size stays the same.
    public func move(_ rect: CGRect) -> (rect: CGRect, guides: [SnapGuide]) {
        var result = rect
        result.origin.x += offset(of: [rect.minX, rect.midX, rect.maxX], to: columns) ?? 0
        result.origin.y += offset(of: [rect.minY, rect.midY, rect.maxY], to: rows) ?? 0
        // Where IconStyle lets it be.
        result.origin.x = result.origin.x.clamped(to: IconStyle.origins(forSide: result.width))
        result.origin.y = result.origin.y.clamped(to: IconStyle.origins(forSide: result.height))
        return (result, guides(for: result))
    }

    /// A resized rectangle, snapped: the edges being dragged stick to columns and rows, and
    /// to wherever they leave the rectangle centered. With `symmetric` both opposite edges
    /// move together around the rectangle's middle.
    public func resize(_ rect: CGRect, moving edges: RectEdges, symmetric: Bool) -> (rect: CGRect, guides: [SnapGuide]) {
        let (minX, maxX) = snap(rect.minX, rect.maxX, movingLow: edges.contains(.left), movingHigh: edges.contains(.right),
                                symmetric: symmetric, lines: columns, center: centerX)
        let (minY, maxY) = snap(rect.minY, rect.maxY, movingLow: edges.contains(.top), movingHigh: edges.contains(.bottom),
                                symmetric: symmetric, lines: rows, center: centerY)
        let result = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        // Sticking would take it where a style can't be (bigger than the canvas without
        // covering it, say): it stays as it is.
        guard IconStyle.allows(result) || !IconStyle.allows(rect) else { return (rect, guides(for: rect)) }
        return (result, guides(for: result))
    }

    /// A picture moved inside the frame of `style`, snapped: on each axis it can move along,
    /// it sticks to the middle once its own middle comes close. The guides run across the
    /// frame, turned with the axes the picture moves along (see `IconGeometry.layout`).
    /// `side` is the canvas the picture is laid out on, as in `IconGeometry.layout`.
    public func pan(
        _ placement: PicturePlacement, imageSize: CGSize, style: IconStyle,
        canvas side: CGFloat, folder: FolderEdges? = .standard
    ) -> (placement: PicturePlacement, guides: [SnapGuide]) {
        let (frame, _) = IconGeometry.frame(for: style, canvas: side, folder: folder)
        guard let travel = IconGeometry.travel(imageSize: imageSize, in: frame, mode: style.mode, rotation: placement.rotation) else {
            return (placement, [])
        }
        let movesX = abs(travel.slack.width) > 1e-9, movesY = abs(travel.slack.height) > 1e-9
        // The picture's middle is `slack × (position − ½)` away from the frame's along each axis.
        let x = movesX && abs(travel.slack.width * (placement.x - 0.5)) <= threshold ? 0.5 : placement.x
        let y = movesY && abs(travel.slack.height * (placement.y - 0.5)) <= threshold ? 0.5 : placement.y
        let rect = style.rect, tilt = Double(travel.tilt)
        var guides: [SnapGuide] = []
        if movesX, x == 0.5 {
            guides.append(SnapGuide(.vertical, at: travel.frameCenter.x, along: rect.minY...rect.maxY, tilt: tilt))
        }
        if movesY, y == 0.5 {
            guides.append(SnapGuide(.horizontal, at: travel.frameCenter.y, along: rect.minX...rect.maxX, tilt: tilt))
        }
        return (PicturePlacement(x: x, y: y, rotation: placement.rotation), guides)
    }

    /// How close, in degrees, a picture being turned has to come to upright or a quarter turn
    /// to stick to it.
    public static let turnThreshold = 4.0

    /// A turn of `degrees`, snapped: within `turnThreshold` of upright or a quarter turn, it is
    /// that. Also says whether it stuck.
    public static func turn(_ degrees: Double) -> (degrees: Double, snapped: Bool) {
        let quarter = (degrees / 90).rounded() * 90
        guard abs(degrees - quarter) <= turnThreshold else { return (degrees, false) }
        return (quarter, true)
    }

    /// A rectangle made bigger or smaller around its middle, snapped: once one of its edges
    /// comes close to a column or a row, it takes the size that puts that edge right on it.
    /// It keeps its middle and its shape; the guides are the lines its edges lie on.
    public func scale(_ rect: CGRect) -> (rect: CGRect, guides: [SnapGuide]) {
        guard rect.width > 0, rect.height > 0 else { return (rect, edgeGuides(for: rect)) }
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        var best: (distance: Double, factor: Double)?
        // An edge `half` away from `center`, put on `line` on the same side of it.
        func consider(_ edge: Double, _ line: Double, center: Double, half: Double) {
            let distance = abs(line - edge)
            guard distance <= threshold, distance < best?.distance ?? .infinity,
                  (edge < center) == (line < center), line != center
            else { return }
            let factor = abs(line - center) / half
            let width = rect.width * factor, height = rect.height * factor
            // A size a style can have, where it is.
            guard IconStyle.allows(CGRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height))
            else { return }
            best = (distance, factor)
        }
        for line in columns {
            consider(rect.minX, line, center: middle.x, half: rect.width / 2)
            consider(rect.maxX, line, center: middle.x, half: rect.width / 2)
        }
        for line in rows {
            consider(rect.minY, line, center: middle.y, half: rect.height / 2)
            consider(rect.maxY, line, center: middle.y, half: rect.height / 2)
        }
        guard let best else { return (rect, edgeGuides(for: rect)) }
        let width = rect.width * best.factor, height = rect.height * best.factor
        let result = CGRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height)
        return (result, edgeGuides(for: result))
    }

    /// Every column and row that one of the rectangle's edges or centers lies on.
    public func guides(for rect: CGRect) -> [SnapGuide] {
        let onLine = { (line: Double, values: [Double]) in values.contains { abs($0 - line) < 1e-7 } }
        return columns.filter { onLine($0, [rect.minX, rect.midX, rect.maxX]) }.map { SnapGuide(.vertical, at: $0) }
            + rows.filter { onLine($0, [rect.minY, rect.midY, rect.maxY]) }.map { SnapGuide(.horizontal, at: $0) }
    }

    /// The columns and rows that one of the rectangle's edges lies on: the lines that count
    /// while it grows or shrinks around its middle, which stays where it is.
    private func edgeGuides(for rect: CGRect) -> [SnapGuide] {
        let onLine = { (line: Double, values: [Double]) in values.contains { abs($0 - line) < 1e-7 } }
        return columns.filter { onLine($0, [rect.minX, rect.maxX]) }.map { SnapGuide(.vertical, at: $0) }
            + rows.filter { onLine($0, [rect.minY, rect.maxY]) }.map { SnapGuide(.horizontal, at: $0) }
    }

    // MARK: - Internals

    /// The smallest shift that puts one of `values` on one of `lines`, if any is close enough.
    private func offset(of values: [Double], to lines: [Double]) -> Double? {
        var best: Double?
        for value in values {
            for line in lines {
                let delta = line - value
                if abs(delta) <= threshold, abs(delta) < abs(best ?? .infinity) {
                    best = delta
                }
            }
        }
        return best
    }

    /// One axis of a resize: the span from `low` to `high`, with the moving edges snapped.
    private func snap(
        _ low: Double, _ high: Double,
        movingLow: Bool, movingHigh: Bool, symmetric: Bool,
        lines: [Double], center: Double
    ) -> (Double, Double) {
        let minimum = IconStyle.minimumSide
        guard movingLow || movingHigh else { return (low, high) }

        if symmetric {
            // Whichever edge is closer to a line decides; the other one mirrors it.
            let middle = (low + high) / 2
            var best: (distance: Double, half: Double)?
            for line in lines {
                for edge in [low, high] {
                    let distance = abs(line - edge)
                    let half = abs(line - middle)
                    guard distance <= threshold, distance < best?.distance ?? .infinity,
                          half * 2 >= minimum, middle - half >= 0, middle + half <= 1
                    else { continue }
                    best = (distance, half)
                }
            }
            guard let best else { return (low, high) }
            return (middle - best.half, middle + best.half)
        }

        if movingHigh {
            // The mirror of the fixed edge around the center leaves the span centered.
            guard let target = nearest(to: high, among: lines + mirror(of: low, around: center, apartFrom: lines)),
                  target - low >= minimum
            else { return (low, high) }
            return (low, target)
        }
        guard let target = nearest(to: low, among: lines + mirror(of: high, around: center, apartFrom: lines)),
              high - target >= minimum
        else { return (low, high) }
        return (target, high)
    }

    /// Where an edge leaves a span from `edge` centered on `center`, unless that is close to
    /// one of `lines`: an edge that ends up a hair from the folder's own edge, which it was
    /// surely meant to be on, leaves a sliver of the folder showing.
    private func mirror(of edge: Double, around center: Double, apartFrom lines: [Double]) -> [Double] {
        let mirror = 2 * center - edge
        return lines.contains { abs($0 - mirror) <= threshold } ? [] : [mirror]
    }

    private func nearest(to value: Double, among targets: [Double]) -> Double? {
        targets
            .filter { abs($0 - value) <= threshold }
            .min { abs($0 - value) < abs($1 - value) }
    }
}
