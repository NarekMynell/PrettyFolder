import CoreGraphics

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

    /// Where an image of `imageSize` lands when it fills or fits `target`, centered.
    public static func imageRect(imageSize: CGSize, in target: CGRect, mode: FitMode) -> CGRect {
        imageRect(imageSize: imageSize, in: target, mode: mode, placement: .natural, flipped: false)
    }

    /// Where an image of `imageSize` lands in `target`: at the size `mode` gives it times the
    /// placement's zoom, and on an axis where it is bigger or smaller than `target`, where the
    /// placement puts it.
    /// - Parameter flipped: whether `target` has a top-left origin, as in `targetRect`.
    public static func imageRect(
        imageSize: CGSize, in target: CGRect, mode: FitMode, placement: PicturePlacement, flipped: Bool
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, target.width > 0, target.height > 0 else { return target }
        let size = scaledSize(of: imageSize, in: target.size, mode: mode, zoom: placement.zoom)
        // The placement counts from the top; a bottom-left origin counts from the bottom.
        let fromTop = flipped ? placement.y : 1 - placement.y
        return CGRect(
            x: target.minX + (target.width - size.width) * placement.x,
            y: target.minY + (target.height - size.height) * fromTop,
            width: size.width, height: size.height
        )
    }

    /// The part of the placed picture that shows: where it and `target` overlap. That is all
    /// of `target` for a picture that covers it, as Fill does, and the picture itself for one
    /// that stays inside, as Fit does.
    public static func visibleRect(
        imageSize: CGSize, in target: CGRect, mode: FitMode, placement: PicturePlacement, flipped: Bool
    ) -> CGRect {
        let image = imageRect(imageSize: imageSize, in: target, mode: mode, placement: placement, flipped: flipped)
        switch mode {
        case .fill where placement.zoom >= 1: return target
        case .fit where placement.zoom <= 1: return image
        default:
            let overlap = image.intersection(target)
            return overlap.isNull ? .zero : overlap
        }
    }

    /// How far the picture can move inside `target` on each axis: how much of it sticks out,
    /// or how much room it leaves. Zero where the two are the same size.
    public static func room(imageSize: CGSize, in target: CGRect, mode: FitMode, zoom: Double = 1) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let size = scaledSize(of: imageSize, in: target.size, mode: mode, zoom: PicturePlacement.clampedZoom(zoom))
        return CGSize(width: abs(target.width - size.width), height: abs(target.height - size.height))
    }

    /// The placement that puts the picture `offset` away from where `placement` has it, as far
    /// as it can go. `offset` and `target` have a top-left origin, like `targetRect(flipped: true)`.
    public static func placement(
        _ placement: PicturePlacement, movedBy offset: CGSize, imageSize: CGSize, in target: CGRect, mode: FitMode
    ) -> PicturePlacement {
        guard imageSize.width > 0, imageSize.height > 0 else { return placement }
        let size = scaledSize(of: imageSize, in: target.size, mode: mode, zoom: placement.zoom)
        // The picture's edge sits `slack × position` from the rectangle's edge on each axis.
        func moved(_ value: Double, by distance: CGFloat, slack: CGFloat) -> Double {
            abs(slack) < 1e-9 ? value : value + Double(distance / slack)
        }
        return PicturePlacement(
            x: moved(placement.x, by: offset.width, slack: target.width - size.width),
            y: moved(placement.y, by: offset.height, slack: target.height - size.height),
            zoom: placement.zoom
        )
    }

    /// The placement with the picture at `zoom`, the point of it under `anchor` staying under
    /// `anchor` as far as the picture can go. An anchor off the picture counts as its nearest
    /// point on it. `anchor` and `target` have a top-left origin, like `targetRect(flipped: true)`.
    public static func placement(
        _ placement: PicturePlacement, zoomedTo zoom: Double, around anchor: CGPoint,
        imageSize: CGSize, in target: CGRect, mode: FitMode
    ) -> PicturePlacement {
        let zoom = PicturePlacement.clampedZoom(zoom)
        guard imageSize.width > 0, imageSize.height > 0, target.width > 0, target.height > 0 else {
            return PicturePlacement(x: placement.x, y: placement.y, zoom: zoom)
        }
        let before = imageRect(imageSize: imageSize, in: target, mode: mode, placement: placement, flipped: true)
        let after = scaledSize(of: imageSize, in: target.size, mode: mode, zoom: zoom)
        // Which point of the picture is under the anchor, from 0 to 1 across it.
        let pinX = min(max(anchor.x, before.minX), before.maxX)
        let pinY = min(max(anchor.y, before.minY), before.maxY)
        let originX = pinX - (pinX - before.minX) / before.width * after.width
        let originY = pinY - (pinY - before.minY) / before.height * after.height
        // Where the slack is gone the position doesn't matter; keep it for when it comes back.
        func position(_ origin: CGFloat, from edge: CGFloat, slack: CGFloat, keeping value: Double) -> Double {
            abs(slack) < 1e-9 ? value : Double((origin - edge) / slack)
        }
        return PicturePlacement(
            x: position(originX, from: target.minX, slack: target.width - after.width, keeping: placement.x),
            y: position(originY, from: target.minY, slack: target.height - after.height, keeping: placement.y),
            zoom: zoom
        )
    }

    /// The zooms at which the picture exactly fills `target` one way or the other: 1, the size
    /// `mode` gives it, and the size the other mode would. The same with a picture of the
    /// rectangle's own shape.
    public static func fittingZooms(imageSize: CGSize, in target: CGRect, mode: FitMode) -> [Double] {
        guard imageSize.width > 0, imageSize.height > 0, target.width > 0, target.height > 0 else { return [1] }
        let scaleX = target.width / imageSize.width, scaleY = target.height / imageSize.height
        let fill = max(scaleX, scaleY), fit = min(scaleX, scaleY)
        let other = Double(mode == .fill ? fit / fill : fill / fit)
        return abs(other - 1) < 1e-9 ? [1] : [1, other]
    }

    /// Corner radius of the picture. Tied to the canvas, like the folder's own corners,
    /// and never more than half of the shorter side.
    public static func cornerRadius(for visible: CGRect, canvas side: CGFloat) -> CGFloat {
        max(0, min(side * 0.035, min(visible.width, visible.height) / 2))
    }

    /// The picture's size in `frame`: as `mode` scales it, times `zoom`.
    private static func scaledSize(of imageSize: CGSize, in frame: CGSize, mode: FitMode, zoom: Double) -> CGSize {
        let scaleX = frame.width / imageSize.width
        let scaleY = frame.height / imageSize.height
        let scale = (mode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)) * zoom
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
