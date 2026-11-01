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
        imageRect(imageSize: imageSize, in: target, mode: mode, placement: .centered, flipped: false)
    }

    /// Where an image of `imageSize` lands when it fills or fits `target`, put by `placement`
    /// on an axis where it is bigger or smaller than `target`.
    /// - Parameter flipped: whether `target` has a top-left origin, as in `targetRect`.
    public static func imageRect(
        imageSize: CGSize, in target: CGRect, mode: FitMode, placement: PicturePlacement, flipped: Bool
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, target.width > 0, target.height > 0 else { return target }
        let size = scaledSize(of: imageSize, in: target.size, mode: mode)
        // The placement counts from the top; a bottom-left origin counts from the bottom.
        let fromTop = flipped ? placement.y : 1 - placement.y
        return CGRect(
            x: target.minX + (target.width - size.width) * placement.x,
            y: target.minY + (target.height - size.height) * fromTop,
            width: size.width, height: size.height
        )
    }

    /// The part of the placed picture that shows: all of `target` with Fill, which covers it,
    /// and the picture itself with Fit, which stays inside it.
    public static func visibleRect(
        imageSize: CGSize, in target: CGRect, mode: FitMode, placement: PicturePlacement, flipped: Bool
    ) -> CGRect {
        mode == .fill ? target : imageRect(imageSize: imageSize, in: target, mode: .fit, placement: placement, flipped: flipped)
    }

    /// How far the picture can move inside `target` on each axis: how much of it sticks out
    /// with Fill, or how much room it leaves with Fit. Zero where the two have the same shape.
    public static func room(imageSize: CGSize, in target: CGRect, mode: FitMode) -> CGSize {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let size = scaledSize(of: imageSize, in: target.size, mode: mode)
        return CGSize(width: abs(target.width - size.width), height: abs(target.height - size.height))
    }

    /// The placement that puts the picture `offset` away from where `placement` has it, as far
    /// as it can go. `offset` and `target` have a top-left origin, like `targetRect(flipped: true)`.
    public static func placement(
        _ placement: PicturePlacement, movedBy offset: CGSize, imageSize: CGSize, in target: CGRect, mode: FitMode
    ) -> PicturePlacement {
        guard imageSize.width > 0, imageSize.height > 0 else { return placement }
        let size = scaledSize(of: imageSize, in: target.size, mode: mode)
        // The picture's edge sits `slack × position` from the rectangle's edge on each axis.
        func moved(_ value: Double, by distance: CGFloat, slack: CGFloat) -> Double {
            abs(slack) < 1e-9 ? value : value + Double(distance / slack)
        }
        return PicturePlacement(
            x: moved(placement.x, by: offset.width, slack: target.width - size.width),
            y: moved(placement.y, by: offset.height, slack: target.height - size.height)
        )
    }

    /// The rectangle `rect`, in unit coordinates like `IconStyle.rect`, `factor` times as big
    /// around its middle. It keeps its shape, so it stops growing once a side spans the whole
    /// canvas and shrinking at the smallest side; where it would stick out of the canvas, it is
    /// moved back in.
    public static func scaled(_ rect: CGRect, by factor: Double) -> CGRect {
        guard rect.width > 0, rect.height > 0, factor.isFinite, factor > 0 else { return rect }
        let smallest = max(IconStyle.minimumSide / rect.width, IconStyle.minimumSide / rect.height)
        let biggest = min(1 / rect.width, 1 / rect.height)
        let factor = min(max(factor, min(smallest, 1)), max(biggest, 1))
        let width = rect.width * factor, height = rect.height * factor
        return CGRect(
            x: min(max(rect.midX - width / 2, 0), 1 - width),
            y: min(max(rect.midY - height / 2, 0), 1 - height),
            width: width, height: height
        )
    }

    /// Corner radius of the picture. Tied to the canvas, like the folder's own corners,
    /// and never more than half of the shorter side.
    public static func cornerRadius(for visible: CGRect, canvas side: CGFloat) -> CGFloat {
        max(0, min(side * 0.035, min(visible.width, visible.height) / 2))
    }

    /// The picture's size in `frame`, as `mode` scales it.
    private static func scaledSize(of imageSize: CGSize, in frame: CGSize, mode: FitMode) -> CGSize {
        let scaleX = frame.width / imageSize.width
        let scaleY = frame.height / imageSize.height
        let scale = mode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }
}
