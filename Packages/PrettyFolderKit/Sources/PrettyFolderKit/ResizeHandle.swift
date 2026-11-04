import CoreGraphics

/// The eight resize handles and how each one moves the rectangle's edges.
public enum ResizeHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    public static let corners: [ResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

    public var isCorner: Bool { Self.corners.contains(self) }

    private var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    private var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    private var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    private var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

    public var edges: RectEdges {
        var edges: RectEdges = []
        if movesLeft { edges.insert(.left) }
        if movesRight { edges.insert(.right) }
        if movesTop { edges.insert(.top) }
        if movesBottom { edges.insert(.bottom) }
        return edges
    }

    /// Which way is away from the rectangle, from this handle: −1, 0 or 1 on each axis, with
    /// the y axis pointing down.
    public var outward: CGPoint {
        CGPoint(x: movesLeft ? -1 : movesRight ? 1 : 0, y: movesTop ? -1 : movesBottom ? 1 : 0)
    }

    public func position(in rect: CGRect) -> CGPoint {
        let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
        let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }

    /// Moves the edges this handle owns. Never lets the rectangle flip, go below the smallest
    /// size or above the largest, or go where a style can't be (see `IconStyle.origins`).
    /// `keepRatio` keeps its proportions (corners only); `fromCenter` moves the opposite edges
    /// too, so the middle stays put.
    public func resize(_ rect: CGRect, dx: Double, dy: Double, keepRatio: Bool, fromCenter: Bool) -> CGRect {
        let horizontal = movesLeft || movesRight
        let vertical = movesTop || movesBottom
        let factor: Double = fromCenter ? 2 : 1

        // The point that stays put on each axis, and the sizes the rectangle can have around it.
        let anchorX = fromCenter ? rect.midX : movesLeft ? rect.maxX : rect.minX
        let anchorY = fromCenter ? rect.midY : movesTop ? rect.maxY : rect.minY
        let widths = Self.lengths(around: anchorX, now: rect.width, fromCenter: fromCenter, growsTowardZero: movesLeft)
        let heights = Self.lengths(around: anchorY, now: rect.height, fromCenter: fromCenter, growsTowardZero: movesTop)

        var width: Double = horizontal ? rect.width + (movesRight ? dx : -dx) * factor : rect.width
        var height: Double = vertical ? rect.height + (movesBottom ? dy : -dy) * factor : rect.height

        if keepRatio, isCorner, rect.width > 0, rect.height > 0 {
            // Follow whichever side changed more and derive the other one, then keep both
            // within what they can be.
            let ratio = rect.width / rect.height
            if abs(width - rect.width) >= abs(height - rect.height) * ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let lowest = max(widths.lowerBound / rect.width, heights.lowerBound / rect.height)
            let highest = min(widths.upperBound / rect.width, heights.upperBound / rect.height)
            if lowest <= highest {
                let scale = min(max(width / rect.width, lowest), highest)
                width = rect.width * scale
                height = rect.height * scale
            } else {
                width = rect.width
                height = rect.height
            }
        }
        width = horizontal ? width.clamped(to: widths) : rect.width
        height = vertical ? height.clamped(to: heights) : rect.height

        let left = !horizontal ? rect.minX : fromCenter ? anchorX - width / 2 : movesLeft ? anchorX - width : anchorX
        let top = !vertical ? rect.minY : fromCenter ? anchorY - height / 2 : movesTop ? anchorY - height : anchorY
        return CGRect(x: left, y: top, width: width, height: height)
    }

    /// The lengths a side can have on one axis while `anchor` stays put: its middle with
    /// `fromCenter`, otherwise its far end, the moving end growing toward 0 or toward 1. No
    /// longer than the canvas it stays on it; longer, it covers it. Where both can't be had
    /// without a jump, the run the side is in `now`.
    private static func lengths(around anchor: Double, now: Double, fromCenter: Bool, growsTowardZero: Bool) -> ClosedRange<Double> {
        let smallest = IconStyle.minimumSide, largest = IconStyle.maximumSide
        func run(_ shortest: Double, _ longest: Double) -> ClosedRange<Double> {
            let lower = min(max(shortest, smallest), largest)
            return lower...min(max(longest, lower), largest)
        }
        if fromCenter {
            // The longest that stays on the canvas, and the shortest that covers it.
            let onCanvas = 2 * min(anchor, 1 - anchor), covering = 2 * max(anchor, 1 - anchor)
            if covering - onCanvas < 1e-9 { return run(smallest, largest) }
            return now <= onCanvas + 1e-9 ? run(smallest, onCanvas) : run(covering, largest)
        }
        // The length that takes the moving end to the canvas' edge: shorter than the canvas,
        // the side stays on it; longer, the anchor is past the other edge and it must cover.
        let toEdge = growsTowardZero ? anchor : 1 - anchor
        if abs(toEdge - 1) < 1e-9 { return run(smallest, largest) }
        return toEdge < 1 ? run(smallest, toEdge) : run(toEdge, largest)
    }
}
