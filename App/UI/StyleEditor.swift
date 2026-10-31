import AppKit
import PrettyFolderKit
import SwiftUI

/// The folder icon, big, with the picture on it to place by hand: drag it to move it,
/// drag the handles to resize it, nudge it with the arrow keys, pinch to scale it.
///
/// While it moves it snaps to the folder's edges and center (hold Command to place it
/// freely), and it is previewed with the renderer's own drawing, outline mask and all,
/// so what it shows is exactly what the icon gets.
struct StyleEditor: View {
    @Binding var style: IconStyle
    /// The lines the picture is lined up with while it is being dragged.
    @Binding var guides: [SnapGuide]
    /// `true` while the picture is being moved or resized; the parts that get cut off
    /// show faintly meanwhile.
    @Binding var isAdjusting: Bool
    let picture: SourceImage?
    var isEnabled = true
    var side: CGFloat = 320
    /// A change is finished (a drag ended, a nudge settled); gets the style from before it.
    var onCommit: (_ previous: IconStyle) -> Void = { _ in }
    /// A double-click on the picture: back to where it started.
    var onReset: () -> Void = {}

    @State private var dragStart: IconStyle?
    @State private var nudgeStart: IconStyle?
    @State private var nudgeCommit: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    /// The plain folder, rendered once at full size so it stays sharp at any editor size.
    private static let renderer = IconRenderer()
    private static let folderImage: Image = {
        if let bitmap = renderer.render(nil, style: .standard, pixelSize: 1024) {
            return Image(decorative: bitmap, scale: 1)
        }
        return Image(nsImage: FolderArtwork.makeBaseIcon())
    }()
    private static let silhouette = renderer.silhouette(pixelSize: 1024)

    /// Snapping kicks in within 6 points, whatever the editor's size.
    static func snapping(side: CGFloat) -> IconSnapping { IconSnapping(threshold: 6 / side) }
    private var snapping: IconSnapping { Self.snapping(side: side) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            guideLines
            if isEnabled {
                frameOverlay
            }
        }
        .frame(width: side, height: side)
        .coordinateSpace(name: "editor")
        .contentShape(Rectangle())
        .simultaneousGesture(pinchGesture, including: isEnabled ? .all : .none)
        .focusable(isEnabled)
        .focused($isFocused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow], phases: [.down, .repeat]) { nudge($0) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Picture position"))
        .accessibilityValue(Text(accessibilityDescription))
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let canvas = size.width
        context.draw(Self.folderImage, in: CGRect(origin: .zero, size: size))
        let showsCutOff = isAdjusting
        context.withCGContext { cg in
            // The renderer's drawing assumes a bottom-left origin.
            cg.translateBy(x: 0, y: canvas)
            cg.scaleBy(x: 1, y: -1)
            cg.interpolationQuality = .high
            let target = IconGeometry.targetRect(for: style, canvas: canvas, flipped: false)

            guard let picture else {
                // No picture yet: the area it will take, softly.
                let radius = IconGeometry.cornerRadius(for: target, canvas: canvas)
                cg.saveGState()
                if let silhouette = Self.silhouette {
                    cg.clip(to: CGRect(x: 0, y: 0, width: canvas, height: canvas), mask: silhouette)
                }
                cg.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
                cg.setFillColor(CGColor(gray: 1, alpha: 0.35))
                cg.fillPath()
                cg.restoreGState()
                return
            }
            if showsCutOff {
                // While it moves: faintly, the parts the rectangle or the folder's outline cut off.
                let drawn = IconGeometry.imageRect(imageSize: picture.size, in: target, mode: style.mode)
                cg.saveGState()
                cg.setAlpha(0.22)
                picture.draw(in: drawn, context: cg)
                cg.restoreGState()
            }
            IconRenderer.drawPicture(picture, style: style, canvas: canvas, clippedTo: Self.silhouette, in: cg)
        }
    }

    private var guideLines: some View {
        Path { path in
            for guide in guides {
                let position = guide.position * side
                switch guide.axis {
                case .vertical:
                    path.move(to: CGPoint(x: position, y: 0))
                    path.addLine(to: CGPoint(x: position, y: side))
                case .horizontal:
                    path.move(to: CGPoint(x: 0, y: position))
                    path.addLine(to: CGPoint(x: side, y: position))
                }
            }
        }
        .stroke(Color(nsColor: .systemPink), lineWidth: 1)
        .allowsHitTesting(false)
    }

    // MARK: - Handles

    private var frameOverlay: some View {
        let target = IconGeometry.targetRect(for: style, canvas: side, flipped: true)
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .strokeBorder(.white.opacity(0.95), lineWidth: 1.5)
                .shadow(color: .black.opacity(0.35), radius: 1.5)
                .background(Color.white.opacity(0.001)) // makes the inside draggable
                .frame(width: target.width, height: target.height)
                .offset(x: target.minX, y: target.minY)
                .onContinuousHover { phase in
                    if case .active = phase { (isAdjusting ? NSCursor.closedHand : NSCursor.openHand).set() }
                }
                .gesture(moveGesture)
                .onTapGesture(count: 2) {
                    isFocused = true
                    onReset()
                }
            ForEach(ResizeHandle.allCases, id: \.self) { handle in
                HandleKnob()
                    .position(handle.position(in: target))
                    .onContinuousHover { phase in
                        if case .active = phase { handle.cursor.set() }
                    }
                    .gesture(resizeGesture(handle))
            }
        }
        .frame(width: side, height: side, alignment: .topLeading)
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("editor"))
            .onChanged { value in
                let start = beginDrag()
                let moved = start.rect.offsetBy(dx: value.translation.width / side, dy: value.translation.height / side)
                if snapsNow {
                    let snapped = snapping.move(moved)
                    style.rect = snapped.rect
                    show(snapped.guides)
                } else {
                    style.rect = moved
                    show([])
                }
                NSCursor.closedHand.set()
            }
            .onEnded { _ in endDrag() }
    }

    private func resizeGesture(_ handle: ResizeHandle) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("editor"))
            .onChanged { value in
                let start = beginDrag()
                let modifiers = NSEvent.modifierFlags
                let keepRatio = modifiers.contains(.shift) && handle.isCorner
                let fromCenter = modifiers.contains(.option)
                let resized = handle.resize(
                    start.rect, dx: value.translation.width / side, dy: value.translation.height / side,
                    keepRatio: keepRatio, fromCenter: fromCenter
                )
                if snapsNow && !keepRatio {
                    let snapped = snapping.resize(resized, moving: handle.edges, symmetric: fromCenter)
                    style.rect = snapped.rect
                    show(snapped.guides)
                } else {
                    style.rect = resized
                    show([])
                }
            }
            .onEnded { _ in endDrag() }
    }

    private var pinchGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let start = beginDrag()
                let scale = max(value.magnification, 0.05)
                let width = min(max(start.width * scale, IconStyle.minimumSide), 1)
                let height = min(max(start.height * scale, IconStyle.minimumSide), 1)
                style.rect = CGRect(x: start.rect.midX - width / 2, y: start.rect.midY - height / 2, width: width, height: height)
            }
            .onEnded { _ in endDrag() }
    }

    /// Holding Command places the picture freely, as in most design apps.
    private var snapsNow: Bool { !NSEvent.modifierFlags.contains(.command) }

    private func beginDrag() -> IconStyle {
        if let dragStart { return dragStart }
        isFocused = true
        dragStart = style
        isAdjusting = true
        return style
    }

    private func endDrag() {
        show([])
        isAdjusting = false
        if let start = dragStart, start != style { onCommit(start) }
        dragStart = nil
    }

    /// Shows the guides, with a tap on a Force Touch trackpad as the picture lands on one.
    private func show(_ newGuides: [SnapGuide]) {
        guard newGuides != guides else { return }
        if !Set(newGuides).isSubset(of: guides) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        guides = newGuides
    }

    // MARK: - Keyboard

    /// Arrow keys move the picture by a point, ten with Shift. One undo step per burst.
    private func nudge(_ press: KeyPress) -> KeyPress.Result {
        guard isEnabled else { return .ignored }
        let step = (press.modifiers.contains(.shift) ? 10 : 1) / side
        var rect = style.rect
        switch press.key {
        case .leftArrow: rect.origin.x -= step
        case .rightArrow: rect.origin.x += step
        case .upArrow: rect.origin.y -= step
        case .downArrow: rect.origin.y += step
        default: return .ignored
        }
        if nudgeStart == nil { nudgeStart = style }
        style.rect = CGRect(
            x: min(max(rect.minX, 0), 1 - rect.width), y: min(max(rect.minY, 0), 1 - rect.height),
            width: rect.width, height: rect.height
        )
        nudgeCommit?.cancel()
        nudgeCommit = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let start = nudgeStart else { return }
            nudgeStart = nil
            if start != style { onCommit(start) }
        }
        return .handled
    }

    private var accessibilityDescription: String {
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        return "\(percent(style.width)) wide, \(percent(style.height)) tall, \(style.mode == .fill ? "fill" : "fit")"
    }
}

private struct HandleKnob: View {
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: 10, height: 10)
            .shadow(color: .black.opacity(0.4), radius: 1.5, y: 0.5)
            .contentShape(Circle().inset(by: -6))
    }
}

/// The eight resize handles and how each one moves the rectangle's edges.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var isCorner: Bool { [.topLeft, .topRight, .bottomRight, .bottomLeft].contains(self) }

    private var movesLeft: Bool { [.topLeft, .left, .bottomLeft].contains(self) }
    private var movesRight: Bool { [.topRight, .right, .bottomRight].contains(self) }
    private var movesTop: Bool { [.topLeft, .top, .topRight].contains(self) }
    private var movesBottom: Bool { [.bottomLeft, .bottom, .bottomRight].contains(self) }

    var edges: RectEdges {
        var edges: RectEdges = []
        if movesLeft { edges.insert(.left) }
        if movesRight { edges.insert(.right) }
        if movesTop { edges.insert(.top) }
        if movesBottom { edges.insert(.bottom) }
        return edges
    }

    func position(in rect: CGRect) -> CGPoint {
        let x = movesLeft ? rect.minX : movesRight ? rect.maxX : rect.midX
        let y = movesTop ? rect.minY : movesBottom ? rect.maxY : rect.midY
        return CGPoint(x: x, y: y)
    }

    var cursor: NSCursor {
        if #available(macOS 15, *) {
            let position: NSCursor.FrameResizePosition = switch self {
            case .topLeft: .topLeft
            case .top: .top
            case .topRight: .topRight
            case .right: .right
            case .bottomRight: .bottomRight
            case .bottom: .bottom
            case .bottomLeft: .bottomLeft
            case .left: .left
            }
            return .frameResize(position: position, directions: .all)
        }
        switch self {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        default: return .crosshair
        }
    }

    /// Moves the edges this handle owns. Never lets the rectangle flip, shrink below the
    /// minimum or leave the canvas. `keepRatio` keeps its proportions (corners only);
    /// `fromCenter` moves the opposite edges too, so the middle stays put.
    func resize(_ rect: CGRect, dx: Double, dy: Double, keepRatio: Bool, fromCenter: Bool) -> CGRect {
        let minimum = IconStyle.minimumSide
        let horizontal = movesLeft || movesRight
        let vertical = movesTop || movesBottom
        let factor: Double = fromCenter ? 2 : 1

        // The point that stays put on each axis, and the most room there is around it.
        let anchorX = fromCenter ? rect.midX : movesLeft ? rect.maxX : rect.minX
        let anchorY = fromCenter ? rect.midY : movesTop ? rect.maxY : rect.minY
        let roomX = fromCenter ? 2 * min(anchorX, 1 - anchorX) : movesLeft ? anchorX : 1 - anchorX
        let roomY = fromCenter ? 2 * min(anchorY, 1 - anchorY) : movesTop ? anchorY : 1 - anchorY

        var width = horizontal ? rect.width + (movesRight ? dx : -dx) * factor : rect.width
        var height = vertical ? rect.height + (movesBottom ? dy : -dy) * factor : rect.height

        if keepRatio, isCorner, rect.width > 0, rect.height > 0 {
            // Follow whichever side changed more and derive the other one.
            let ratio = rect.width / rect.height
            if abs(width - rect.width) >= abs(height - rect.height) * ratio {
                height = width / ratio
            } else {
                width = height * ratio
            }
            let scale = min(1, roomX / max(width, .ulpOfOne), roomY / max(height, .ulpOfOne))
            width *= scale
            height *= scale
        }
        width = min(max(width, minimum), horizontal ? roomX : rect.width)
        height = min(max(height, minimum), vertical ? roomY : rect.height)

        let left = !horizontal ? rect.minX : fromCenter ? anchorX - width / 2 : movesLeft ? anchorX - width : anchorX
        let top = !vertical ? rect.minY : fromCenter ? anchorY - height / 2 : movesTop ? anchorY - height : anchorY
        return CGRect(x: left, y: top, width: width, height: height)
    }
}

/// Pictures for the editor: small enough to stay quick, sharp enough for its size.
enum PreviewPicture {
    /// Always a bitmap: vectors are rasterized at full size, so tiny SVGs stay sharp too.
    static func load(_ url: URL) -> SourceImage? {
        guard let picture = try? ImageLoader.load(contentsOf: url),
              let bitmap = picture.bitmap(maxSide: 1024)
        else { return nil }
        return SourceImage(bitmap: bitmap)
    }

    /// A made-up landscape for previewing the default look before any picture is chosen.
    static let sample: SourceImage = {
        let width = 900, height = 600
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return SourceImage(bitmap: blank) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSGradient(colors: [
            NSColor(srgbRed: 0.98, green: 0.62, blue: 0.45, alpha: 1),
            NSColor(srgbRed: 0.96, green: 0.80, blue: 0.62, alpha: 1),
            NSColor(srgbRed: 0.55, green: 0.73, blue: 0.95, alpha: 1),
        ])?.draw(in: rect, angle: 90)
        NSColor(srgbRed: 1, green: 0.93, blue: 0.7, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 560, y: 300, width: 150, height: 150)).fill()
        let far = NSBezierPath()
        far.move(to: NSPoint(x: 0, y: 160))
        far.line(to: NSPoint(x: 230, y: 380))
        far.line(to: NSPoint(x: 420, y: 230))
        far.line(to: NSPoint(x: 640, y: 420))
        far.line(to: NSPoint(x: 900, y: 200))
        far.line(to: NSPoint(x: 900, y: 0))
        far.line(to: NSPoint(x: 0, y: 0))
        NSColor(srgbRed: 0.36, green: 0.42, blue: 0.62, alpha: 1).setFill()
        far.fill()
        let near = NSBezierPath()
        near.move(to: NSPoint(x: 0, y: 90))
        near.curve(to: NSPoint(x: 900, y: 120), controlPoint1: NSPoint(x: 300, y: 260), controlPoint2: NSPoint(x: 600, y: 20))
        near.line(to: NSPoint(x: 900, y: 0))
        near.line(to: NSPoint(x: 0, y: 0))
        NSColor(srgbRed: 0.2, green: 0.45, blue: 0.4, alpha: 1).setFill()
        near.fill()
        NSGraphicsContext.restoreGraphicsState()
        return SourceImage(bitmap: context.makeImage() ?? blank)
    }()

    private static let blank: CGImage = {
        let context = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }()
}
