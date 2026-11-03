import CoreGraphics

/// Where the folder's edges are, for taking a picture right up to them. Unit coordinates with
/// a top-left origin, like `IconStyle.rect`.
public struct FolderEdges: Sendable, Equatable {
    /// The folder's bounds as measured once: the lines frames snap to.
    public var bounds: CGRect
    /// How far the folder's own pixels go at the size being drawn. Some sizes are drawn by hand,
    /// and there they can go a pixel or so past `bounds`.
    public var extent: CGRect

    public init(bounds: CGRect, extent: CGRect? = nil) {
        self.bounds = bounds
        self.extent = extent ?? bounds
    }

    /// The folder this Mac draws, as measured.
    public static var standard: FolderEdges {
        FolderEdges(bounds: FolderArtwork.shape.bounds)
    }
}

/// How a picture is drawn on the icon: where its middle is, its size before it is turned, how
/// far it is turned, and the part of it that shows. Made by `IconGeometry.layout`.
public struct PictureLayout {
    /// The picture's middle.
    public let center: CGPoint
    /// The picture's size, upright.
    public let size: CGSize
    /// How far it is turned counterclockwise, as seen on screen, in radians.
    public let angle: CGFloat
    /// Whether the coordinates have a top-left origin.
    public let flipped: Bool
    /// The part of the picture that shows, before the folder's outline cuts it: its frame with
    /// Fill, the picture itself with Fit. Its corners are rounded, except where it reaches the
    /// folder's edge.
    public let visible: CGPath

    /// Takes the picture's upright rectangle (`uprightRect`) to where it is drawn.
    public var transform: CGAffineTransform {
        CGAffineTransform(translationX: center.x, y: center.y).rotated(by: flipped ? -angle : angle)
    }

    /// The picture's rectangle, upright and centered on the origin: draw it there after `transform`.
    public var uprightRect: CGRect {
        CGRect(x: -size.width / 2, y: -size.height / 2, width: size.width, height: size.height)
    }

    /// The smallest upright rectangle around the picture as it is drawn.
    public var bounds: CGRect {
        uprightRect.applying(transform)
    }
}

/// The arithmetic behind placing a picture on the icon. Shared by the renderer and
/// the editor preview so both always agree on what the result looks like.
public enum IconGeometry {
    /// The picture rectangle on a square canvas of `side` points or pixels.
    /// - Parameter flipped: `true` for top-left origin (SwiftUI, AppKit flipped views),
    ///   `false` for Core Graphics' bottom-left origin.
    public static func targetRect(for style: IconStyle, canvas side: CGFloat, flipped: Bool) -> CGRect {
        let y = flipped ? style.y : 1 - style.y - style.height
        return CGRect(x: style.x * side, y: y * side, width: style.width * side, height: style.height * side)
    }

    /// How close to the folder's edge an edge of the frame has to come to count as reaching it:
    /// a hundredth of the icon, three points in the window. Nobody leaves a sliver of the folder
    /// that thin on purpose; it only looks like the picture failed to cover it.
    static let reachTolerance = 0.01

    /// The frame the picture is laid out in at a canvas of `side` pixels or points, in unit
    /// coordinates with a top-left origin like `IconStyle.rect`, and which of its edges reach the
    /// folder's edge (`nil` for `folder` leaves the frame as it is).
    ///
    /// An edge that reaches the folder's edge, or comes within `reachTolerance` of it, goes a
    /// pixel past the folder's pixels at this size: they sit a little differently at each icon
    /// size, and a picture taken up to the edge covers them at every size. Its corners there
    /// aren't rounded off either: the folder's outline is its edge.
    public static func frame(for style: IconStyle, canvas side: CGFloat, folder: FolderEdges?) -> (rect: CGRect, reaches: RectEdges) {
        let rect = style.rect
        guard let folder, side > 0 else { return (rect, []) }
        let pixel = 1 / Double(side)
        let bounds = folder.bounds, extent = folder.extent
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        var reaches: RectEdges = []
        if minX <= bounds.minX + reachTolerance {
            minX = min(minX, bounds.minX - pixel, extent.minX - pixel)
            reaches.insert(.left)
        }
        if maxX >= bounds.maxX - reachTolerance {
            maxX = max(maxX, bounds.maxX + pixel, extent.maxX + pixel)
            reaches.insert(.right)
        }
        if minY <= bounds.minY + reachTolerance {
            minY = min(minY, bounds.minY - pixel, extent.minY - pixel)
            reaches.insert(.top)
        }
        if maxY >= bounds.maxY - reachTolerance {
            maxY = max(maxY, bounds.maxY + pixel, extent.maxY + pixel)
            reaches.insert(.bottom)
        }
        return (CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY), reaches)
    }

    /// Where a picture of `imageSize` is drawn on a canvas of `side` points or pixels, placed and
    /// turned by `placement` in the frame of `style` (see `frame(for:canvas:folder:)`).
    ///
    /// With Fill, the picture, turned, covers its whole frame, and the frame shows. With Fit,
    /// the whole picture shows, turned, inside its frame. Where the picture can move, `placement`
    /// puts it: along the frame's sides, or with Fill, when the picture is turned by something
    /// other than quarter turns, along the sides of the picture turned by the nearest quarter
    /// turn, which keeps it covering the frame however far it goes.
    /// - Parameter flipped: `true` for a top-left origin, `false` for a bottom-left origin.
    public static func layout(
        imageSize: CGSize, style: IconStyle, placement: PicturePlacement,
        canvas side: CGFloat, flipped: Bool, folder: FolderEdges? = .standard
    ) -> PictureLayout {
        let (unit, frameReaches) = frame(for: style, canvas: side, folder: folder)
        let frame = scaled(unit, side)
        guard let travel = travel(imageSize: imageSize, in: frame, mode: style.mode, rotation: placement.rotation) else {
            let path = roundedRect(frame, radius: cornerRadius(for: frame, canvas: side), squareNextTo: frameReaches)
            return finished(center: CGPoint(x: frame.midX, y: frame.midY), size: frame.size, angle: 0, visible: path, side: side, flipped: flipped)
        }
        let center = travel.center(for: placement)
        let visible: CGPath
        switch style.mode {
        case .fill:
            visible = roundedRect(frame, radius: cornerRadius(for: frame, canvas: side), squareNextTo: frameReaches)
        case .fit where travel.leftover == 0:
            // Upright or turned by quarter turns: a rectangle along the canvas' sides.
            let quarterTurned = travel.sideways
            let width = quarterTurned ? travel.size.height : travel.size.width
            let height = quarterTurned ? travel.size.width : travel.size.height
            let rect = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            let reaches = folder.map { edges(of: scaled(rect, 1 / side), reaching: $0.bounds) } ?? []
            visible = roundedRect(rect, radius: cornerRadius(for: rect, canvas: side), squareNextTo: reaches)
        case .fit:
            let upright = CGRect(x: -travel.size.width / 2, y: -travel.size.height / 2, width: travel.size.width, height: travel.size.height)
            let radius = cornerRadius(for: upright, canvas: side)
            var turn = CGAffineTransform(translationX: center.x, y: center.y).rotated(by: -travel.angle)
            visible = CGPath(roundedRect: upright, cornerWidth: radius, cornerHeight: radius, transform: &turn)
        }
        return finished(center: center, size: travel.size, angle: travel.angle, visible: visible, side: side, flipped: flipped)
    }

    /// The middle of the picture in unit coordinates with a top-left origin, as `layout` puts it.
    public static func pictureCenter(
        imageSize: CGSize, style: IconStyle, placement: PicturePlacement,
        canvas side: CGFloat, folder: FolderEdges? = .standard
    ) -> CGPoint {
        let (unit, _) = frame(for: style, canvas: side, folder: folder)
        return travel(imageSize: imageSize, in: unit, mode: style.mode, rotation: placement.rotation)?.center(for: placement)
            ?? CGPoint(x: unit.midX, y: unit.midY)
    }

    /// The placement, turned `rotation` degrees, that puts the picture's middle as close as it
    /// can get to `point` (unit coordinates, top-left origin), its frame being that of `style`.
    /// Moving the picture, it goes as far as it can; turning it, it stays where it is as far as
    /// its new size lets it.
    public static func placement(
        near point: CGPoint, rotation: Double, imageSize: CGSize, style: IconStyle,
        canvas side: CGFloat, folder: FolderEdges? = .standard
    ) -> PicturePlacement {
        let (unit, _) = frame(for: style, canvas: side, folder: folder)
        guard let travel = travel(imageSize: imageSize, in: unit, mode: style.mode, rotation: rotation) else {
            return PicturePlacement(x: 0.5, y: 0.5, rotation: rotation)
        }
        let (x, y) = travel.position(nearest: point)
        return PicturePlacement(x: x, y: y, rotation: rotation)
    }

    /// The placement that puts the picture `offset` away from where `placement` has it, as far
    /// as it can go. `offset` is in the canvas' units with a top-left origin.
    public static func placement(
        _ placement: PicturePlacement, movedBy offset: CGSize, imageSize: CGSize, style: IconStyle,
        canvas side: CGFloat, folder: FolderEdges? = .standard
    ) -> PicturePlacement {
        guard side > 0 else { return placement }
        let center = pictureCenter(imageSize: imageSize, style: style, placement: placement, canvas: side, folder: folder)
        let moved = CGPoint(x: center.x + offset.width / side, y: center.y + offset.height / side)
        return Self.placement(near: moved, rotation: placement.rotation, imageSize: imageSize, style: style, canvas: side, folder: folder)
    }

    /// The placement with the picture turned to `rotation` degrees, staying where it is as far
    /// as its new size lets it.
    public static func placement(
        _ placement: PicturePlacement, turnedTo rotation: Double, imageSize: CGSize, style: IconStyle,
        canvas side: CGFloat, folder: FolderEdges? = .standard
    ) -> PicturePlacement {
        let center = pictureCenter(imageSize: imageSize, style: style, placement: placement, canvas: side, folder: folder)
        return Self.placement(near: center, rotation: rotation, imageSize: imageSize, style: style, canvas: side, folder: folder)
    }

    /// The rectangle `rect`, in unit coordinates like `IconStyle.rect`, `factor` times as big
    /// around the middle of what of it is on the canvas: its own middle while it is smaller than
    /// the canvas, the canvas' middle on an axis it covers. It keeps its shape, so it stops
    /// growing once a side is the largest there is and shrinking at the smallest; where
    /// `IconStyle.origins` doesn't let it be, it is moved to the nearest place that does.
    public static func scaled(_ rect: CGRect, by factor: Double) -> CGRect {
        guard rect.width > 0, rect.height > 0, factor.isFinite, factor > 0 else { return rect }
        let smallest = max(IconStyle.minimumSide / rect.width, IconStyle.minimumSide / rect.height)
        let biggest = min(IconStyle.maximumSide / rect.width, IconStyle.maximumSide / rect.height)
        let factor = min(max(factor, min(smallest, 1)), max(biggest, 1))
        let width = rect.width * factor, height = rect.height * factor
        // The middle of the part on the canvas stays where it is.
        let anchorX = (max(rect.minX, 0) + min(rect.maxX, 1)) / 2
        let anchorY = (max(rect.minY, 0) + min(rect.maxY, 1)) / 2
        return CGRect(
            x: (anchorX - (anchorX - rect.minX) * factor).clamped(to: IconStyle.origins(forSide: width)),
            y: (anchorY - (anchorY - rect.minY) * factor).clamped(to: IconStyle.origins(forSide: height)),
            width: width, height: height
        )
    }

    /// Corner radius of the picture. Tied to the canvas, like the folder's own corners,
    /// and never more than half of the shorter side.
    public static func cornerRadius(for visible: CGRect, canvas side: CGFloat) -> CGFloat {
        max(0, min(side * 0.035, min(visible.width, visible.height) / 2))
    }

    // MARK: - Internals

    /// How a picture sits in its frame and where it can go: along two axes turned `tilt` from
    /// the canvas', by `slack` on each. Coordinates have a top-left origin.
    struct Travel {
        /// The frame's middle.
        var frameCenter: CGPoint
        /// How far the axes the picture moves along are turned, counterclockwise on screen:
        /// `leftover` with Fill, none with Fit, which moves the picture's bounds along the frame.
        var tilt: CGFloat
        /// How far the picture is turned past the nearest quarter turn, counterclockwise.
        var leftover: CGFloat
        /// On each axis, the frame's extent less the picture's: negative with Fill, where the
        /// picture is bigger.
        var slack: CGSize
        /// The picture's size, upright.
        var size: CGSize
        /// The picture's turn, counterclockwise on screen.
        var angle: CGFloat
        /// Turned by an odd number of quarter turns: lying on its side.
        var sideways: Bool

        /// The picture's middle for `placement`.
        func center(for placement: PicturePlacement) -> CGPoint {
            let along = (placement.x - 0.5) * slack.width, across = (placement.y - 0.5) * slack.height
            return CGPoint(
                x: frameCenter.x + along * cos(tilt) + across * sin(tilt),
                y: frameCenter.y - along * sin(tilt) + across * cos(tilt)
            )
        }

        /// The `x` and `y` of the placement whose middle is closest to `point`.
        func position(nearest point: CGPoint) -> (x: Double, y: Double) {
            let dx = point.x - frameCenter.x, dy = point.y - frameCenter.y
            let along = dx * cos(tilt) - dy * sin(tilt), across = dx * sin(tilt) + dy * cos(tilt)
            func position(_ distance: CGFloat, _ slack: CGFloat) -> Double {
                abs(slack) < 1e-12 ? 0.5 : Double(0.5 + distance / slack)
            }
            // PicturePlacement keeps them between 0 and 1, which is the nearest it can be: the
            // axes are square to each other.
            return (position(along, slack.width), position(across, slack.height))
        }
    }

    /// How a picture of `imageSize`, turned `rotation` degrees, sits in `frame`, scaled by
    /// `mode`; `nil` when either has no size.
    static func travel(imageSize: CGSize, in frame: CGRect, mode: FitMode, rotation: Double) -> Travel? {
        guard imageSize.width > 0, imageSize.height > 0, frame.width > 0, frame.height > 0,
              imageSize.width.isFinite, imageSize.height.isFinite
        else { return nil }
        // As a placement keeps it: halfway between two quarter turns, the nearest one is picked
        // the same way whichever way round the turn was asked for.
        let rotation = PicturePlacement.normalized(rotation)
        let angle = CGFloat(rotation * .pi / 180)
        // The nearest quarter turn, and what is left over.
        let quarters = (rotation / 90).rounded()
        let tilt = CGFloat((rotation - quarters * 90) * .pi / 180)
        let sideways = !Int(quarters).isMultiple(of: 2)
        let width = sideways ? imageSize.height : imageSize.width
        let height = sideways ? imageSize.width : imageSize.height
        let cosine = abs(cos(tilt)), sine = abs(sin(tilt))
        let center = CGPoint(x: frame.midX, y: frame.midY)
        switch mode {
        case .fill:
            // The frame as the picture sees it, turned back by the leftover: the picture covers
            // the frame when it covers that rectangle's bounds.
            let spanX = frame.width * cosine + frame.height * sine
            let spanY = frame.width * sine + frame.height * cosine
            let scale = max(spanX / width, spanY / height)
            return Travel(
                frameCenter: center, tilt: tilt, leftover: tilt,
                slack: CGSize(width: spanX - width * scale, height: spanY - height * scale),
                size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale),
                angle: angle, sideways: sideways
            )
        case .fit:
            // The picture's bounds, turned, fit in the frame.
            let boundsX = width * cosine + height * sine
            let boundsY = width * sine + height * cosine
            let scale = min(frame.width / boundsX, frame.height / boundsY)
            return Travel(
                frameCenter: center, tilt: 0, leftover: tilt,
                slack: CGSize(width: frame.width - boundsX * scale, height: frame.height - boundsY * scale),
                size: CGSize(width: imageSize.width * scale, height: imageSize.height * scale),
                angle: angle, sideways: sideways
            )
        }
    }

    /// The edges of `rect` that reach the folder's edges, `folder` being its bounds.
    static func edges(of rect: CGRect, reaching folder: CGRect) -> RectEdges {
        var edges: RectEdges = []
        if rect.minX <= folder.minX + reachTolerance { edges.insert(.left) }
        if rect.maxX >= folder.maxX - reachTolerance { edges.insert(.right) }
        if rect.minY <= folder.minY + reachTolerance { edges.insert(.top) }
        if rect.maxY >= folder.maxY - reachTolerance { edges.insert(.bottom) }
        return edges
    }

    private static func scaled(_ rect: CGRect, _ factor: CGFloat) -> CGRect {
        CGRect(x: rect.minX * factor, y: rect.minY * factor, width: rect.width * factor, height: rect.height * factor)
    }

    /// `rect` (top-left origin) with its corners rounded by `radius`, except the corners next to
    /// an edge in `square`.
    static func roundedRect(_ rect: CGRect, radius: CGFloat, squareNextTo square: RectEdges) -> CGPath {
        let path = CGMutablePath()
        let topLeft = square.isDisjoint(with: [.top, .left]) ? radius : 0
        let topRight = square.isDisjoint(with: [.top, .right]) ? radius : 0
        let bottomRight = square.isDisjoint(with: [.bottom, .right]) ? radius : 0
        let bottomLeft = square.isDisjoint(with: [.bottom, .left]) ? radius : 0
        func corner(_ point: CGPoint, toward next: CGPoint, radius: CGFloat) {
            if radius > 0 {
                path.addArc(tangent1End: point, tangent2End: next, radius: radius)
            } else {
                path.addLine(to: point)
            }
        }
        path.move(to: CGPoint(x: rect.minX + topLeft, y: rect.minY))
        corner(CGPoint(x: rect.maxX, y: rect.minY), toward: CGPoint(x: rect.maxX, y: rect.maxY), radius: topRight)
        corner(CGPoint(x: rect.maxX, y: rect.maxY), toward: CGPoint(x: rect.minX, y: rect.maxY), radius: bottomRight)
        corner(CGPoint(x: rect.minX, y: rect.maxY), toward: CGPoint(x: rect.minX, y: rect.minY), radius: bottomLeft)
        corner(CGPoint(x: rect.minX, y: rect.minY), toward: CGPoint(x: rect.maxX, y: rect.minY), radius: topLeft)
        path.closeSubpath()
        return path
    }

    /// A layout worked out with a top-left origin, in the coordinates asked for.
    private static func finished(
        center: CGPoint, size: CGSize, angle: CGFloat, visible: CGPath, side: CGFloat, flipped: Bool
    ) -> PictureLayout {
        guard !flipped else { return PictureLayout(center: center, size: size, angle: angle, flipped: true, visible: visible) }
        var flip = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: side)
        return PictureLayout(
            center: center.applying(flip), size: size, angle: angle, flipped: false,
            visible: visible.copy(using: &flip) ?? visible
        )
    }
}
