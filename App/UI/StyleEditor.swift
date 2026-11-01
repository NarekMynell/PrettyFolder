import AppKit
import PrettyFolderKit
import SwiftUI

/// The folder icon, big, with the picture on it to place by hand: drag the rectangle's edge
/// to move it and its handles to resize it, drag the picture to move it inside, nudge the
/// rectangle with the arrow keys (the picture with ⌥), pinch to scale the rectangle.
///
/// While something moves it snaps to the folder's edges and center, the picture to the
/// middle of its rectangle (hold Command to place it freely). It is drawn with the
/// renderer's own drawing, outline, light and all, so what it shows is exactly what the
/// icon gets.
struct StyleEditor: NSViewRepresentable {
    @Binding var style: IconStyle
    @Binding var alignment: PictureAlignment
    /// The lines the picture is lined up with while it is being dragged.
    @Binding var guides: [SnapGuide]
    /// `true` while the picture is being moved or resized; the parts that get cut off
    /// show faintly meanwhile.
    @Binding var isAdjusting: Bool
    let picture: SourceImage?
    var isEnabled = true
    /// Whether the picture can move inside its rectangle. A folder's own can; the default
    /// look always has it in the middle.
    var movesPicture = false
    var side: CGFloat = 320
    /// A change begins: a drag, a pinch, the first of a burst of arrow keys.
    var onBegin: () -> Void = {}
    /// The change is finished: a drag ended, a nudge settled.
    var onCommit: () -> Void = {}

    /// Snapping kicks in within 6 points, whatever the editor's size.
    static func snapping(side: CGFloat) -> IconSnapping { IconSnapping(threshold: 6 / side) }

    func makeNSView(context: Context) -> StyleEditorView {
        StyleEditorView()
    }

    func updateNSView(_ view: StyleEditorView, context: Context) {
        view.actions = StyleEditorView.Actions(
            change: { style = $0; alignment = $1 },
            showGuides: { guides = $0 },
            adjust: { isAdjusting = $0 },
            begin: onBegin,
            commit: onCommit
        )
        view.update(
            style: style, alignment: alignment, guides: guides, isAdjusting: isAdjusting,
            picture: picture, isEnabled: isEnabled, movesPicture: movesPicture, side: side
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StyleEditorView, context: Context) -> CGSize? {
        CGSize(width: side + 2 * StyleEditorView.margin, height: side + 2 * StyleEditorView.margin)
    }
}

/// What the editor draws and how it takes the mouse, the trackpad and the keyboard. The
/// pointer always shows what pressing there would do: a resize arrow on a handle, a hand
/// over a picture that can move, the arrow on the rectangle's edge, which moves it.
final class StyleEditorView: NSView, NSViewToolTipOwner {
    /// Room around the folder, so the handles of a rectangle at its edges show and can be
    /// grabbed whole. The folder's top-left corner is the origin all the same.
    static let margin: CGFloat = 12

    struct Actions {
        var change: (IconStyle, PictureAlignment) -> Void = { _, _ in }
        var showGuides: ([SnapGuide]) -> Void = { _ in }
        var adjust: (Bool) -> Void = { _ in }
        var begin: () -> Void = {}
        var commit: () -> Void = {}
    }

    /// A part of the editor, by what pressing on it does.
    enum Part: Equatable {
        /// Resizes the rectangle.
        case handle(ResizeHandle)
        /// Moves the rectangle: its edge, and its inside when the picture can't move.
        case frame
        /// Moves the picture inside the rectangle.
        case picture
        /// Nothing.
        case none
    }

    var actions = Actions()

    private var style = IconStyle.standard
    private var alignment = PictureAlignment.centered
    private var guides: [SnapGuide] = []
    private var isAdjusting = false
    private var picture: SourceImage?
    private var isEnabled = true
    private var movesPicture = false
    private var side: CGFloat = 320

    /// The part under the pointer; its edge lights up when it's the rectangle's.
    private var hovered = Part.none
    /// The part being dragged.
    private var dragged: Part?
    /// A pinch going on, and how far it has gone.
    private var pinch: (start: IconStyle, magnification: CGFloat)?
    /// Arrow keys pressed in a row make one change, finished once they stop for a moment.
    private var nudgeEnd: Task<Void, Never>?
    private var tracking: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var cursorUpdateIsQueued = false

    /// The plain folder, rendered once at full size so it stays sharp at any editor size.
    private static let renderer = IconRenderer()
    private static let folderImage = renderer.render(nil, style: .standard, pixelSize: 1024)
    private static let surface = renderer.surface(pixelSize: 1024)

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        wantsLayer = true
        setBoundsOrigin(NSPoint(x: -Self.margin, y: -Self.margin))
        addToolTip(bounds, owner: self, userData: nil)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(String(localized: "Picture position"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        setBoundsOrigin(NSPoint(x: -Self.margin, y: -Self.margin))
        removeAllToolTips()
        addToolTip(bounds, owner: self, userData: nil)
    }

    /// Takes what SwiftUI has. A drag or a pinch going on is newer than the look it brings,
    /// which is the editor's own change coming back.
    func update(
        style: IconStyle, alignment: PictureAlignment, guides: [SnapGuide], isAdjusting: Bool,
        picture: SourceImage?, isEnabled: Bool, movesPicture: Bool, side: CGFloat
    ) {
        var moved = false
        if dragged == nil, pinch == nil, style != self.style || alignment != self.alignment {
            // Changed from elsewhere (undo, the reset button, another folder's look): any
            // nudges in a row were finished there, before the change.
            nudgeEnd?.cancel()
            nudgeEnd = nil
            self.style = style
            self.alignment = alignment
            moved = true
        }
        let changed = moved || picture !== self.picture || isEnabled != self.isEnabled
            || movesPicture != self.movesPicture || side != self.side
        if changed || guides != self.guides || isAdjusting != self.isAdjusting {
            needsDisplay = true
        }
        self.guides = guides
        self.isAdjusting = isAdjusting
        self.picture = picture
        self.isEnabled = isEnabled
        self.movesPicture = movesPicture
        self.side = side
        setAccessibilityValue(accessibilityDescription)
        if changed { queueCursorUpdate() }
    }

    // MARK: - Parts

    private var target: CGRect { IconGeometry.targetRect(for: style, canvas: side, flipped: true) }

    /// Whether the picture has anywhere to go inside its rectangle.
    private var pictureCanMove: Bool {
        guard movesPicture, let picture else { return false }
        let room = IconGeometry.room(imageSize: picture.size, in: target, mode: style.mode)
        return max(room.width, room.height) >= 0.5
    }

    /// What pressing at `point` would do.
    func part(at point: CGPoint) -> Part {
        guard isEnabled else { return .none }
        let target = target
        let shortSide = min(target.width, target.height)
        // Handles win where they overlap the edge; on a small rectangle they reach less far,
        // so there is still an inside to grab.
        let reach = min(11, max(5, shortSide / 4))
        let nearest = ResizeHandle.allCases
            .map { (handle: $0, distance: hypot(point.x - $0.position(in: target).x, point.y - $0.position(in: target).y)) }
            .min { $0.distance < $1.distance }
        if let nearest, nearest.distance <= reach {
            return .handle(nearest.handle)
        }
        let inside = min(4, shortSide / 6)
        let onEdge = target.insetBy(dx: -6, dy: -6).contains(point) && !target.insetBy(dx: inside, dy: inside).contains(point)
        if onEdge { return .frame }
        if target.contains(point) { return pictureCanMove ? .picture : .frame }
        return .none
    }

    /// The pointer over `part`.
    func cursor(for part: Part) -> NSCursor {
        switch part {
        case .handle(let handle): handle.cursor
        case .picture: dragged == .picture ? .closedHand : .openHand
        case .frame, .none: .arrow
        }
    }

    // MARK: - Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        tracking = area
    }

    override func cursorUpdate(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        hover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        setHovered(.none)
        NSCursor.arrow.set()
    }

    private func hover(at point: CGPoint) {
        let part = part(at: point)
        setHovered(part)
        cursor(for: part).set()
    }

    private func setHovered(_ part: Part) {
        guard part != hovered else { return }
        hovered = part
        needsDisplay = true
    }

    /// Updates the pointer once SwiftUI is done updating: looking up what is under the
    /// pointer in the middle of that would have it lay itself out again.
    private func queueCursorUpdate() {
        guard !cursorUpdateIsQueued else { return }
        cursorUpdateIsQueued = true
        Task { [weak self] in
            self?.cursorUpdateIsQueued = false
            self?.updateCursor()
        }
    }

    /// Shows the right pointer for wherever it is now, after something moved under it: a
    /// drag that ended, a look changed by a button or by undo.
    /// - Parameter afterDrag: the pointer was ours during a drag; if the drag ended away from
    ///   the editor, nothing else puts it back.
    private func updateCursor(afterDrag: Bool = false) {
        guard let window, window.isKeyWindow, dragged == nil else {
            setHovered(.none)
            return
        }
        let location = window.mouseLocationOutsideOfEventStream
        let point = convert(location, from: nil)
        // Only when the pointer is really over the editor, not over something on top of it.
        guard bounds.contains(point),
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber,
              window.contentView?.hitTest(location) === self
        else {
            setHovered(.none)
            if afterDrag { NSCursor.arrow.set() }
            return
        }
        hover(at: point)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        finishNudge()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let newWindow else { return }
        // A window that becomes key under a still pointer gets no mouse moves to set it right.
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateCursor() }
            })
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        switch part(at: point) {
        case .handle: String(localized: "Drag to resize. ⇧ keeps the proportions, ⌥ resizes around the middle.")
        case .frame: String(localized: "Drag to move the frame.")
        case .picture: String(localized: "Drag to move the picture in its frame. Double-click puts it back in the middle.")
        case .none: ""
        }
    }

    // MARK: - Dragging

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        finishNudge()
        let start = convert(event.locationInWindow, from: nil)
        let part = part(at: start)
        if event.clickCount == 2 {
            if part == .picture { centerPicture() }
            return
        }
        guard part != .none else { return }
        track(part, from: start)
    }

    /// Follows the pointer until the button is let go. Modifier keys count as soon as they
    /// change; Escape puts everything back where it was.
    private func track(_ part: Part, from start: CGPoint) {
        dragged = part
        cursor(for: part).set()
        needsDisplay = true
        var origin: (style: IconStyle, alignment: PictureAlignment)?
        var point = start

        func follow(_ modifiers: NSEvent.ModifierFlags) {
            let offset = CGSize(width: point.x - start.x, height: point.y - start.y)
            if origin == nil {
                // A click that doesn't move isn't a change.
                guard hypot(offset.width, offset.height) >= 1 else { return }
                origin = (style, alignment)
                actions.begin()
                setAdjusting(true)
            }
            if let origin { drag(part, from: origin, by: offset, modifiers: modifiers) }
        }

        window?.trackEvents(
            matching: [.leftMouseDragged, .leftMouseUp, .flagsChanged, .keyDown],
            timeout: NSEvent.foreverDuration, mode: .eventTracking
        ) { event, stop in
            guard let event else { return }
            switch event.type {
            case .leftMouseDragged:
                point = convert(event.locationInWindow, from: nil)
                follow(event.modifierFlags)
            case .flagsChanged:
                follow(event.modifierFlags)
            case .keyDown where event.keyCode == 53:
                if let origin { set(origin.style, origin.alignment) }
                stop.pointee = true
            case .leftMouseUp:
                stop.pointee = true
            default:
                break
            }
        }

        dragged = nil
        if origin != nil {
            showGuides([])
            setAdjusting(false)
            actions.commit()
        }
        needsDisplay = true
        updateCursor(afterDrag: true)
    }

    private func drag(_ part: Part, from origin: (style: IconStyle, alignment: PictureAlignment), by offset: CGSize, modifiers: NSEvent.ModifierFlags) {
        // Holding Command places things freely, as in most design apps.
        let snaps = !modifiers.contains(.command)
        let snapping = StyleEditor.snapping(side: side)
        let dx = offset.width / side, dy = offset.height / side
        switch part {
        case .frame:
            let moved = origin.style.rect.offsetBy(dx: dx, dy: dy)
            let snapped = snaps ? snapping.move(moved) : (rect: moved, guides: [])
            set(rect: snapped.rect)
            showGuides(snapped.guides)
        case .handle(let handle):
            let keepRatio = modifiers.contains(.shift) && handle.isCorner
            let fromCenter = modifiers.contains(.option)
            let resized = handle.resize(origin.style.rect, dx: dx, dy: dy, keepRatio: keepRatio, fromCenter: fromCenter)
            let snapped = snaps && !keepRatio
                ? snapping.resize(resized, moving: handle.edges, symmetric: fromCenter) : (rect: resized, guides: [])
            set(rect: snapped.rect)
            showGuides(snapped.guides)
        case .picture:
            guard let picture else { return }
            let moved = IconGeometry.alignment(origin.alignment, movedBy: offset, imageSize: picture.size, in: target, mode: style.mode)
            let snapped = snaps
                ? snapping.pan(moved, imageSize: picture.size, in: style.rect, mode: style.mode) : (alignment: moved, guides: [])
            set(style, snapped.alignment)
            showGuides(snapped.guides)
        case .none:
            break
        }
    }

    override func magnify(with event: NSEvent) {
        guard isEnabled, dragged == nil else { return }
        switch event.phase {
        case .began:
            finishNudge()
            pinch = (style, 0)
            actions.begin()
            setAdjusting(true)
        case .changed:
            guard var current = pinch else { return }
            current.magnification += event.magnification
            pinch = current
            let start = current.start
            let scale = max(1 + current.magnification, 0.05)
            let width = min(max(start.width * scale, IconStyle.minimumSide), 1)
            let height = min(max(start.height * scale, IconStyle.minimumSide), 1)
            set(rect: CGRect(x: start.rect.midX - width / 2, y: start.rect.midY - height / 2, width: width, height: height))
        case .ended, .cancelled:
            guard let current = pinch else { return }
            if event.phase == .cancelled { set(current.start, alignment) }
            pinch = nil
            setAdjusting(false)
            actions.commit()
            updateCursor()
        default:
            break
        }
    }

    /// A double-click on a picture that was moved puts it back in the middle.
    private func centerPicture() {
        guard alignment != .centered else { return }
        actions.begin()
        set(style, .centered)
        actions.commit()
    }

    // MARK: - Keyboard

    /// Arrow keys move the rectangle by a point, ten with Shift; with Option they move the
    /// picture inside it. One undo step per burst.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let step: CGFloat = modifiers.contains(.shift) ? 10 : 1
        let offset: CGSize? = switch event.specialKey {
        case .leftArrow: CGSize(width: -step, height: 0)
        case .rightArrow: CGSize(width: step, height: 0)
        case .upArrow: CGSize(width: 0, height: -step)
        case .downArrow: CGSize(width: 0, height: step)
        default: nil
        }
        guard isEnabled, dragged == nil, pinch == nil, let offset, modifiers.isDisjoint(with: [.command, .control]) else {
            return super.keyDown(with: event)
        }
        if modifiers.contains(.option) {
            guard pictureCanMove, let picture else { return }
            let moved = IconGeometry.alignment(alignment, movedBy: offset, imageSize: picture.size, in: target, mode: style.mode)
            guard moved != alignment else { return }
            nudge { set(style, moved) }
        } else {
            let rect = style.rect.offsetBy(dx: offset.width / side, dy: offset.height / side)
            nudge { set(rect: rect) }
        }
    }

    private func nudge(_ change: () -> Void) {
        if nudgeEnd == nil { actions.begin() }
        nudgeEnd?.cancel()
        change()
        nudgeEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.finishNudge()
        }
    }

    private func finishNudge() {
        guard let nudgeEnd else { return }
        nudgeEnd.cancel()
        self.nudgeEnd = nil
        actions.commit()
    }

    override func resignFirstResponder() -> Bool {
        finishNudge()
        return super.resignFirstResponder()
    }

    // MARK: - Changes

    private func set(rect: CGRect) {
        var style = style
        style.rect = rect
        set(style, alignment)
    }

    private func set(_ style: IconStyle, _ alignment: PictureAlignment) {
        guard style != self.style || alignment != self.alignment else { return }
        self.style = style
        self.alignment = alignment
        needsDisplay = true
        setAccessibilityValue(accessibilityDescription)
        actions.change(style, alignment)
    }

    /// Shows the guides, with a tap on a Force Touch trackpad as the picture lands on one.
    private func showGuides(_ newGuides: [SnapGuide]) {
        guard newGuides != guides else { return }
        if !Set(newGuides).isSubset(of: guides) {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        guides = newGuides
        needsDisplay = true
        actions.showGuides(newGuides)
    }

    private func setAdjusting(_ adjusting: Bool) {
        guard adjusting != isAdjusting else { return }
        isAdjusting = adjusting
        needsDisplay = true
        actions.adjust(adjusting)
    }

    private var accessibilityDescription: String {
        let percent = { (value: Double) in "\(Int((value * 100).rounded()))%" }
        return "\(percent(style.width)) wide, \(percent(style.height)) tall, \(style.mode == .fill ? "fill" : "fit")"
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let canvas = side
        context.saveGState()
        // The renderer's drawing assumes a bottom-left origin.
        context.translateBy(x: 0, y: canvas)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .high
        if let folder = Self.folderImage {
            context.draw(folder, in: CGRect(x: 0, y: 0, width: canvas, height: canvas))
        }
        drawPicture(in: context, canvas: canvas)
        context.restoreGState()

        drawGuides()
        if isEnabled {
            drawFrame()
        }
    }

    /// The picture, or without one the area it will take, softly.
    private func drawPicture(in context: CGContext, canvas: CGFloat) {
        let target = IconGeometry.targetRect(for: style, canvas: canvas, flipped: false)
        guard let picture else {
            let radius = IconGeometry.cornerRadius(for: target, canvas: canvas)
            context.saveGState()
            if let silhouette = Self.surface?.silhouette {
                context.clip(to: CGRect(x: 0, y: 0, width: canvas, height: canvas), mask: silhouette)
            }
            context.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(CGColor(gray: 1, alpha: 0.35))
            context.fillPath()
            context.restoreGState()
            return
        }
        if isAdjusting {
            // While it moves: faintly, the parts the rectangle or the folder's outline cut off,
            // as far as the editor goes.
            let drawn = IconGeometry.imageRect(imageSize: picture.size, in: target, mode: style.mode, alignment: alignment, flipped: false)
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: canvas, height: canvas))
            context.setAlpha(0.22)
            picture.draw(in: drawn, context: context)
            context.restoreGState()
        }
        IconRenderer.drawPicture(picture, style: style, alignment: alignment, canvas: canvas, on: Self.surface, in: context)
    }

    private func drawGuides() {
        guard !guides.isEmpty else { return }
        let path = NSBezierPath()
        path.lineWidth = 1
        for guide in guides {
            let position = guide.position * side
            let from = (guide.extent?.lowerBound ?? 0) * side
            let to = (guide.extent?.upperBound ?? 1) * side
            switch guide.axis {
            case .vertical:
                path.move(to: NSPoint(x: position, y: from))
                path.line(to: NSPoint(x: position, y: to))
            case .horizontal:
                path.move(to: NSPoint(x: from, y: position))
                path.line(to: NSPoint(x: to, y: position))
            }
        }
        NSColor.systemPink.setStroke()
        path.stroke()
    }

    /// The rectangle, a little bolder while the pointer is on it or it is being moved, and
    /// its handles.
    private func drawFrame() {
        let target = target
        let bold = hovered == .frame || dragged == .frame
        let width: CGFloat = bold ? 2.5 : 1.5

        NSGraphicsContext.saveGraphicsState()
        let outline = NSShadow()
        outline.shadowColor = NSColor.black.withAlphaComponent(0.35)
        outline.shadowBlurRadius = 1.5
        outline.set()
        NSColor.white.withAlphaComponent(bold ? 1 : 0.95).setStroke()
        let frame = NSBezierPath(rect: target.insetBy(dx: width / 2, dy: width / 2))
        frame.lineWidth = width
        frame.stroke()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        let lift = NSShadow()
        lift.shadowColor = NSColor.black.withAlphaComponent(0.4)
        lift.shadowBlurRadius = 1.5
        lift.shadowOffset = NSSize(width: 0, height: -0.5)
        lift.set()
        NSColor.white.setFill()
        for handle in ResizeHandle.allCases {
            let center = handle.position(in: target)
            NSBezierPath(ovalIn: NSRect(x: center.x - 5, y: center.y - 5, width: 10, height: 10)).fill()
        }
        NSGraphicsContext.restoreGraphicsState()
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
