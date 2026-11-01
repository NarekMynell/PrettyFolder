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

    public init(_ axis: Axis, at position: Double, along extent: ClosedRange<Double>? = nil) {
        self.axis = axis
        self.position = position
        self.extent = extent
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
        // Inside the canvas, the way IconStyle keeps it.
        result.origin.x = min(max(result.origin.x, 0), 1 - result.width)
        result.origin.y = min(max(result.origin.y, 0), 1 - result.height)
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
        return (result, guides(for: result))
    }

    /// A picture moved inside its rectangle `rect`, snapped: on each axis it can move along,
    /// it sticks to the middle once its own middle comes close. The guides run across `rect`.
    public func pan(
        _ placement: PicturePlacement, imageSize: CGSize, in rect: CGRect, mode: FitMode
    ) -> (placement: PicturePlacement, guides: [SnapGuide]) {
        let room = IconGeometry.room(imageSize: imageSize, in: rect, mode: mode, zoom: placement.zoom)
        let movesX = room.width > 1e-9, movesY = room.height > 1e-9
        // The picture's middle is `room × (position − ½)` away from the rectangle's.
        let x = movesX && abs(room.width * (placement.x - 0.5)) <= threshold ? 0.5 : placement.x
        let y = movesY && abs(room.height * (placement.y - 0.5)) <= threshold ? 0.5 : placement.y
        var guides: [SnapGuide] = []
        if movesX, x == 0.5 { guides.append(SnapGuide(.vertical, at: rect.midX, along: rect.minY...rect.maxY)) }
        if movesY, y == 0.5 { guides.append(SnapGuide(.horizontal, at: rect.midY, along: rect.minX...rect.maxX)) }
        return (PicturePlacement(x: x, y: y, zoom: placement.zoom), guides)
    }

    /// How close a zoom has to come to a size where the picture fits its rectangle exactly,
    /// relatively, to stick to it.
    public static let zoomThreshold = 0.04

    /// A zoom of a picture in its rectangle `rect`, snapped: close to a size where the picture
    /// exactly fills the rectangle one way or the other (see `IconGeometry.fittingZooms`), it
    /// sticks to it. Returns whether it did.
    public func zoom(_ zoom: Double, imageSize: CGSize, in rect: CGRect, mode: FitMode) -> (zoom: Double, snapped: Bool) {
        let zoom = PicturePlacement.clampedZoom(zoom)
        let fitting = IconGeometry.fittingZooms(imageSize: imageSize, in: rect, mode: mode)
            .filter { PicturePlacement.zoomRange.contains($0) }
        guard let nearest = fitting.min(by: { abs(log($0 / zoom)) < abs(log($1 / zoom)) }),
              abs(log(nearest / zoom)) <= Self.zoomThreshold
        else { return (zoom, false) }
        return (nearest, true)
    }

    /// Every column and row that one of the rectangle's edges or centers lies on.
    public func guides(for rect: CGRect) -> [SnapGuide] {
        let onLine = { (line: Double, values: [Double]) in values.contains { abs($0 - line) < 1e-7 } }
        return columns.filter { onLine($0, [rect.minX, rect.midX, rect.maxX]) }.map { SnapGuide(.vertical, at: $0) }
            + rows.filter { onLine($0, [rect.minY, rect.midY, rect.maxY]) }.map { SnapGuide(.horizontal, at: $0) }
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
            guard let target = nearest(to: high, among: lines + [2 * center - low]),
                  target - low >= minimum, target <= 1
            else { return (low, high) }
            return (low, target)
        }
        guard let target = nearest(to: low, among: lines + [2 * center - high]),
              high - target >= minimum, target >= 0
        else { return (low, high) }
        return (target, high)
    }

    private func nearest(to value: Double, among targets: [Double]) -> Double? {
        targets
            .filter { abs($0 - value) <= threshold }
            .min { abs($0 - value) < abs($1 - value) }
    }
}
