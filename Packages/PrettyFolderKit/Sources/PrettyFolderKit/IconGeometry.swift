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
        guard imageSize.width > 0, imageSize.height > 0, target.width > 0, target.height > 0 else { return target }
        let scaleX = target.width / imageSize.width
        let scaleY = target.height / imageSize.height
        let scale = mode == .fill ? max(scaleX, scaleY) : min(scaleX, scaleY)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: target.midX - width / 2, y: target.midY - height / 2, width: width, height: height)
    }

    /// The visible part of the picture: the whole rectangle for `.fill`, the image itself for `.fit`.
    public static func visibleRect(imageSize: CGSize, in target: CGRect, mode: FitMode) -> CGRect {
        mode == .fill ? target : imageRect(imageSize: imageSize, in: target, mode: .fit)
    }

    /// Corner radius of the picture. Tied to the canvas, like the folder's own corners,
    /// and never more than half of the shorter side.
    public static func cornerRadius(for visible: CGRect, canvas side: CGFloat) -> CGFloat {
        max(0, min(side * 0.035, min(visible.width, visible.height) / 2))
    }
}
