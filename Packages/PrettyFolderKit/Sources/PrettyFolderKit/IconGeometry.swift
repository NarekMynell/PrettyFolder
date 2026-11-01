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
        imageRect(imageSize: imageSize, in: target, mode: mode, alignment: .centered, flipped: false)
    }

    /// Where an image of `imageSize` lands when it fills or fits `target`, placed by
    /// `alignment` on an axis where it is bigger or smaller than `target`.
    /// - Parameter flipped: whether `target` has a top-left origin, as in `targetRect`.
    public static func imageRect(
        imageSize: CGSize, in target: CGRect, mode: FitMode, alignment: PictureAlignment, flipped: Bool
    ) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, target.width > 0, target.height > 0 else { return target }
        let scaleX = target.width / imageSize.width
        let scaleY = target.height / imageSize.height
        let scale = mode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        // Alignment counts from the top; a bottom-left origin counts from the bottom.
        let fromTop = flipped ? alignment.y : 1 - alignment.y
        return CGRect(
            x: target.minX + (target.width - width) * alignment.x,
            y: target.minY + (target.height - height) * fromTop,
            width: width, height: height
        )
    }

    /// The visible part of the picture: the whole rectangle for `.fill`, the image itself for `.fit`.
    public static func visibleRect(imageSize: CGSize, in target: CGRect, mode: FitMode) -> CGRect {
        visibleRect(imageSize: imageSize, in: target, mode: mode, alignment: .centered, flipped: false)
    }

    /// The visible part of the picture placed by `alignment`: the whole rectangle for `.fill`,
    /// the image itself for `.fit`.
    public static func visibleRect(
        imageSize: CGSize, in target: CGRect, mode: FitMode, alignment: PictureAlignment, flipped: Bool
    ) -> CGRect {
        mode == .fill ? target : imageRect(imageSize: imageSize, in: target, mode: .fit, alignment: alignment, flipped: flipped)
    }

    /// How far the picture can move inside `target` on each axis: how much of it sticks out
    /// with Fill, or how much room it leaves with Fit. Zero where the two have the same shape.
    public static func room(imageSize: CGSize, in target: CGRect, mode: FitMode) -> CGSize {
        let image = imageRect(imageSize: imageSize, in: target, mode: mode)
        return CGSize(width: abs(target.width - image.width), height: abs(target.height - image.height))
    }

    /// The alignment that puts the picture `offset` away from where `alignment` has it, as far
    /// as it can go. `offset` and `target` have a top-left origin, like `targetRect(flipped: true)`.
    public static func alignment(
        _ alignment: PictureAlignment, movedBy offset: CGSize, imageSize: CGSize, in target: CGRect, mode: FitMode
    ) -> PictureAlignment {
        let image = imageRect(imageSize: imageSize, in: target, mode: mode)
        // The picture's edge sits `slack × alignment` from the rectangle's edge on each axis.
        func moved(_ value: Double, by distance: CGFloat, slack: CGFloat) -> Double {
            abs(slack) < 1e-9 ? value : value + Double(distance / slack)
        }
        return PictureAlignment(
            x: moved(alignment.x, by: offset.width, slack: target.width - image.width),
            y: moved(alignment.y, by: offset.height, slack: target.height - image.height)
        )
    }

    /// Corner radius of the picture. Tied to the canvas, like the folder's own corners,
    /// and never more than half of the shorter side.
    public static func cornerRadius(for visible: CGRect, canvas side: CGFloat) -> CGFloat {
        max(0, min(side * 0.035, min(visible.width, visible.height) / 2))
    }
}
