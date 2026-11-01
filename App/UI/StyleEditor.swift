import AppKit
import PrettyFolderKit
import SwiftUI

/// The folder icon, big, with the picture on it to place by hand: drag the rectangle to move
/// it, its handles to resize it, and pinch or scroll to make it bigger or smaller; drag with
/// the right button (or Control, or after a double-click) to move the picture inside it. The
/// arrow keys nudge the rectangle (the picture with ⌥), and ⌘+ and ⌘− make it bigger or
/// smaller. The picture is always as big as Fill or Fit makes it in the rectangle.
///
/// While something moves it snaps to the folder's edges and center, and the picture to the
/// middle of its rectangle (hold Command to place things freely). It is drawn with the
/// renderer's own drawing, outline, light and all, so what it shows is exactly what the icon
/// gets.
struct StyleEditor: NSViewRepresentable {
    @Binding var style: IconStyle
    @Binding var placement: PicturePlacement
    /// The lines the picture is lined up with while it is being dragged.
    @Binding var guides: [SnapGuide]
    /// `true` while the picture is being moved or resized; the parts that get cut off show
    /// faintly meanwhile.
    @Binding var isAdjusting: Bool
    let picture: SourceImage?
    var isEnabled = true
    /// Whether the picture can be moved inside its rectangle. A folder's own can; the default
    /// look always has it in the middle.
    var placesPicture = false
    var side: CGFloat = 320
    /// A change begins: a drag, a pinch, the first of a burst of keys or of scrolling.
    var onBegin: () -> Void = {}
    /// The change is finished: a drag or a pinch ended, a burst settled.
    var onCommit: () -> Void = {}

    /// Snapping kicks in within 6 points, whatever the editor's size.
    static func snapping(side: CGFloat) -> IconSnapping { IconSnapping(threshold: 6 / side) }

    func makeNSView(context: Context) -> StyleEditorView {
        StyleEditorView()
    }

    func updateNSView(_ view: StyleEditorView, context: Context) {
        view.actions = StyleEditorView.Actions(
            current: { (style, placement) },
            change: { style = $0; placement = $1 },
            showGuides: { guides = $0 },
            adjust: { isAdjusting = $0 },
            begin: onBegin,
            commit: onCommit
        )
        view.update(
            style: style, placement: placement, guides: guides, isAdjusting: isAdjusting,
            picture: picture, isEnabled: isEnabled, placesPicture: placesPicture, side: side
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StyleEditorView, context: Context) -> CGSize? {
        CGSize(width: side + 2 * StyleEditorView.margin, height: side + 2 * StyleEditorView.margin)
    }
}

/// What the editor draws and how it takes the mouse, the trackpad and the keyboard. The
/// pointer always shows what pressing there would do: a resize arrow on a handle, a hand over
/// the rectangle, which a drag moves, the arrow everywhere else.
final class StyleEditorView: NSView, NSViewToolTipOwner, NSMenuItemValidation {
    /// Room around the folder, so the handles of a rectangle at its edges show and can be
    /// grabbed whole. The folder's top-left corner is the origin all the same.
    static let margin: CGFloat = 12
    /// How far the pointer goes with the button down before a click becomes a drag: a click,
    /// the first of a double-click say, never moves anything.
    static let dragThreshold: CGFloat = 3
    /// How much one press of ⌘+ or ⌘− makes the rectangle bigger or smaller.
    static let zoomStep: CGFloat = 1.1

    struct Actions {
        /// The look as the model has it now.
        var current: () -> (IconStyle, PicturePlacement) = { (.standard, .centered) }
        var change: (IconStyle, PicturePlacement) -> Void = { _, _ in }
        var showGuides: ([SnapGuide]) -> Void = { _ in }
        var adjust: (Bool) -> Void = { _ in }
        var begin: () -> Void = {}
        var commit: () -> Void = {}
    }

    /// A part of the editor, by what pressing on it does.
    enum Part: Equatable {
        /// Resizes the rectangle.
        case handle(ResizeHandle)
        /// Moves the rectangle: its inside, and a band around its edge. The right button, or
        /// the second click of a double-click, takes hold of the picture instead.
        case frame
        /// Nothing.
        case none
    }

    /// What a drag moves.
    enum Drag: Equatable {
        case handle(ResizeHandle)
        case frame
        /// The picture inside the rectangle: with the right button, Control, or after a
        /// double-click.
        case picture
    }

    var actions = Actions()

    private var style = IconStyle.standard
    private var placement = PicturePlacement.centered
    private var guides: [SnapGuide] = []
    private var isAdjusting = false
    private var picture: SourceImage?
    private var isEnabled = true
    private var placesPicture = false
    private var side: CGFloat = 320

    /// The part under the pointer; the rectangle's edge lights up while it's the rectangle.
    private var hovered = Part.none
    /// What is being dragged.
    private var dragged: Drag?
    /// A pinch going on: where it started and how far it has gone.
    private var pinch: (start: (style: IconStyle, placement: PicturePlacement), magnification: CGFloat)?
    /// Arrow keys, ⌘+ and ⌘−, and scrolling in a row make one change, finished once they stop
    /// for a moment.
    private var burstEnd: Task<Void, Never>?
    /// The rectangle the scrolling or keys going on ask for, before it sticks to the folder's
    /// edges: snapped each time, small steps would never get away from them.
    private var requestedRect: CGRect?
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
        updateToolTips()
    }

    /// Takes what SwiftUI has. While a drag or a pinch goes on, the editor's own look is the
    /// one that counts; once it's over, the model's is taken again (`catchUp`).
    func update(
        style: IconStyle, placement: PicturePlacement, guides: [SnapGuide], isAdjusting: Bool,
        picture: SourceImage?, isEnabled: Bool, placesPicture: Bool, side: CGFloat
    ) {
        var moved = false
        if dragged == nil, pinch == nil, style != self.style || placement != self.placement {
            // Changed from elsewhere (undo, the reset button, another folder's look): the model
            // finished any burst of keys or scrolling before making the change.
            if let burstEnd {
                burstEnd.cancel()
                self.burstEnd = nil
                requestedRect = nil
                // What showed while it went on goes with it, once SwiftUI is done updating.
                Task { [weak self] in
                    guard let self, self.burstEnd == nil, self.pinch == nil, self.dragged == nil else { return }
                    showGuides([])
                    setAdjusting(false)
                }
            }
            self.style = style
            self.placement = placement
            moved = true
        }
        let changed = moved || picture !== self.picture || isEnabled != self.isEnabled
            || placesPicture != self.placesPicture || side != self.side
        if changed || guides != self.guides || isAdjusting != self.isAdjusting {
            needsDisplay = true
        }
        self.guides = guides
        self.isAdjusting = isAdjusting
        self.picture = picture
        self.isEnabled = isEnabled
        self.placesPicture = placesPicture
        self.side = side
        // Turned off in the middle of a pinch (the picture was taken off in Finder, say).
        if !isEnabled { endPinch(restoring: true) }
        setAccessibilityValue(accessibilityDescription)
        if changed {
            updateToolTips()
            queueCursorUpdate()
        }
    }

    /// After a drag or a pinch, shows the look the model has: the gesture's own, once the
    /// model took it, or another one if the model moved on meanwhile (to other folders, say).
    private func catchUp() {
        let (style, placement) = actions.current()
        guard style != self.style || placement != self.placement else { return }
        self.style = style
        self.placement = placement
        needsDisplay = true
        setAccessibilityValue(accessibilityDescription)
    }

    // MARK: - Parts

    private var target: CGRect { IconGeometry.targetRect(for: style, canvas: side, flipped: true) }

    /// Whether there is a picture to move inside its rectangle.
    private var canPlacePicture: Bool { placesPicture && picture != nil }

    /// What pressing at `point` would do.
    func part(at point: CGPoint) -> Part {
        guard isEnabled else { return .none }
        let target = target
        // Handles win where they overlap the edge.
        let reach = handleReach(for: target)
        let nearest = ResizeHandle.allCases
            .map { (handle: $0, distance: hypot(point.x - $0.position(in: target).x, point.y - $0.position(in: target).y)) }
            .min { $0.distance < $1.distance }
        if let nearest, nearest.distance <= reach {
            return .handle(nearest.handle)
        }
        return grabArea(for: target).contains(point) ? .frame : .none
    }

    /// How far a handle can be grabbed from: less on a small rectangle, so there is still an
    /// inside to grab.
    private func handleReach(for target: CGRect) -> CGFloat {
        min(11, max(5, min(target.width, target.height) / 4))
    }

    /// Where the rectangle can be taken hold of: all of it, and a little around it, so that a
    /// thin one can still be grabbed.
    private func grabArea(for target: CGRect) -> CGRect {
        target.insetBy(dx: -6, dy: -6)
    }

    /// The pointer over `part`.
    func cursor(for part: Part) -> NSCursor {
        switch part {
        case .handle(let handle): handle.cursor
        case .frame: .openHand
        case .none: .arrow
        }
    }

    /// The pointer while `drag` goes on.
    func cursor(for drag: Drag) -> NSCursor {
        switch drag {
        case .handle(let handle): handle.cursor
        case .frame, .picture: .closedHand
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
        finishBurst()
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        endPinch(restoring: true)
        guard let newWindow else { return }
        let center = NotificationCenter.default
        // A window that becomes key under a still pointer gets no mouse moves to set it right.
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueCursorUpdate() }
        })
        // An alert or another window takes over: a pinch can't finish, and the pointer is no
        // longer the editor's to set.
        windowObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowResignedKey() }
        })
    }

    private func windowResignedKey() {
        endPinch(restoring: true)
        if hovered != .none, let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.arrow.set()
        }
        setHovered(.none)
    }

    /// A tool tip for each part, so moving from one to another brings up its own words.
    private func updateToolTips() {
        removeAllToolTips()
        guard isEnabled, dragged == nil else { return }
        let target = target
        let reach = handleReach(for: target)
        for handle in ResizeHandle.allCases {
            let center = handle.position(in: target)
            addToolTip(NSRect(x: center.x - reach, y: center.y - reach, width: 2 * reach, height: 2 * reach), owner: self, userData: nil)
        }
        addToolTip(grabArea(for: target), owner: self, userData: nil)
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        switch part(at: point) {
        case .handle(let handle) where handle.isCorner:
            String(localized: "Drag to resize. ⇧ keeps the proportions, ⌥ resizes around the middle.")
        case .handle:
            String(localized: "Drag to resize. ⌥ resizes around the middle.")
        case .frame where canPlacePicture:
            String(localized: "Drag to move the frame; pinch or scroll to make it bigger or smaller. Drag with the right button, or double-click and drag, to move the picture inside it.")
        case .frame:
            String(localized: "Drag to move the frame; pinch or scroll to make it bigger or smaller.")
        case .none:
            ""
        }
    }

    // MARK: - Dragging

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        finishBurst()
        let start = convert(event.locationInWindow, from: nil)
        // Control-click is the Mac's right click: Control and drag moves the picture too.
        if event.modifierFlags.contains(.control) {
            if canPlacePicture, grabArea(for: target).contains(start) {
                track(.picture, from: start, button: .left)
            }
            return
        }
        switch part(at: start) {
        case .handle(let handle):
            track(.handle(handle), from: start, button: .left)
        case .frame:
            // A press moves the rectangle; the second click of a double-click, the picture in it.
            track(event.clickCount >= 2 && canPlacePicture ? .picture : .frame, from: start, button: .left)
        case .none:
            break
        }
    }

    /// The right button takes hold of the picture, anywhere on the rectangle, handles too.
    override func rightMouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard isEnabled, canPlacePicture, grabArea(for: target).contains(start) else {
            return super.rightMouseDown(with: event)
        }
        window?.makeFirstResponder(self)
        finishBurst()
        track(.picture, from: start, button: .right)
    }

    /// The events of the button a drag is made with.
    private struct Button {
        let dragged: NSEvent.EventType
        let draggedMask: NSEvent.EventTypeMask
        let up: NSEvent.EventType
        let upMask: NSEvent.EventTypeMask

        static let left = Button(dragged: .leftMouseDragged, draggedMask: .leftMouseDragged, up: .leftMouseUp, upMask: .leftMouseUp)
        static let right = Button(dragged: .rightMouseDragged, draggedMask: .rightMouseDragged, up: .rightMouseUp, upMask: .rightMouseUp)
    }

    /// Follows the pointer until the button is let go. Modifier keys count as soon as they
    /// change; Escape puts everything back where it was.
    private func track(_ drag: Drag, from start: CGPoint, button: Button) {
        dragged = drag
        cursor(for: drag).set()
        needsDisplay = true
        var origin: (style: IconStyle, placement: PicturePlacement)?
        var point = start

        func follow(_ modifiers: NSEvent.ModifierFlags) {
            let offset = CGSize(width: point.x - start.x, height: point.y - start.y)
            if origin == nil {
                // A click that doesn't go anywhere isn't a change.
                guard hypot(offset.width, offset.height) >= Self.dragThreshold else { return }
                origin = (style, placement)
                actions.begin()
                setAdjusting(true)
            }
            if let origin { self.drag(drag, from: origin, by: offset, modifiers: modifiers) }
        }

        window?.trackEvents(
            matching: [button.draggedMask, button.upMask, .flagsChanged, .keyDown],
            timeout: NSEvent.foreverDuration, mode: .eventTracking
        ) { event, stop in
            guard let event else { return }
            switch event.type {
            case button.dragged:
                point = convert(event.locationInWindow, from: nil)
                follow(event.modifierFlags)
            case .flagsChanged:
                follow(event.modifierFlags)
            case .keyDown where event.charactersIgnoringModifiers == "\u{1b}":
                if let origin { set(origin.style, origin.placement) }
                stop.pointee = true
            case button.up:
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
        catchUp()
        needsDisplay = true
        updateToolTips()
        updateCursor(afterDrag: true)
    }

    private func drag(_ drag: Drag, from origin: (style: IconStyle, placement: PicturePlacement), by offset: CGSize, modifiers: NSEvent.ModifierFlags) {
        // Holding Command places things freely, as in most design apps.
        let snaps = !modifiers.contains(.command)
        let snapping = StyleEditor.snapping(side: side)
        let dx = offset.width / side, dy = offset.height / side
        switch drag {
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
            let moved = IconGeometry.placement(origin.placement, movedBy: offset, imageSize: picture.size, in: target, mode: style.mode)
            let snapped = snaps
                ? snapping.pan(moved, imageSize: picture.size, in: style.rect, mode: style.mode) : (placement: moved, guides: [])
            set(style, snapped.placement)
            showGuides(snapped.guides)
        }
    }

    // MARK: - Bigger and smaller

    /// Pinching makes the rectangle bigger or smaller around its middle; the picture in it
    /// follows, as big as Fill or Fit makes it there.
    override func magnify(with event: NSEvent) {
        switch event.phase {
        case .began:
            guard isEnabled, dragged == nil, pinch == nil else { return }
            finishBurst()
            pinch = ((style, placement), 0)
            actions.begin()
            setAdjusting(true)
        case .changed:
            guard isEnabled, var current = pinch else { return }
            current.magnification += event.magnification
            pinch = current
            // Multiplied in, so pinching out and back in comes back to the same size.
            let scaled = IconGeometry.scaled(current.start.style.rect, by: exp(current.magnification))
            scaleFrame(to: scaled, snaps: !event.modifierFlags.contains(.command))
            queueCursorUpdate()
        case .ended:
            endPinch(restoring: false)
        case .cancelled:
            endPinch(restoring: true)
        default:
            break
        }
    }

    /// Finishes a pinch, kept or put back where it started. Also when its end never comes:
    /// the editor turned off, or an alert or another window took over.
    private func endPinch(restoring: Bool) {
        guard let current = pinch else { return }
        if restoring { set(current.start.style, current.start.placement) }
        pinch = nil
        showGuides([])
        setAdjusting(false)
        actions.commit()
        catchUp()
        updateToolTips()
        queueCursorUpdate()
    }

    /// Scrolling makes the rectangle bigger or smaller too, like pinching, for a mouse's wheel
    /// above all: up makes it bigger.
    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, dragged == nil, pinch == nil else { return super.scrollWheel(with: event) }
        // What a trackpad goes on sending once the fingers are off it would go on and on.
        guard event.momentumPhase.isEmpty else { return }
        // Up is up whichever way scrolling is set to go.
        var delta = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        // A wheel counts in lines, a trackpad in points.
        delta *= event.hasPreciseScrollingDeltas ? 0.004 : 0.1
        guard delta != 0 else { return }
        zoom(by: exp(delta), snaps: !event.modifierFlags.contains(.command))
    }

    @objc func zoomIn(_ sender: Any?) {
        zoom(by: Self.zoomStep, snaps: true)
    }

    @objc func zoomOut(_ sender: Any?) {
        zoom(by: 1 / Self.zoomStep, snaps: true)
    }

    /// Makes the rectangle `factor` times as big around its middle, as one burst with the
    /// changes right before and after it.
    private func zoom(by factor: CGFloat, snaps: Bool) {
        guard isEnabled, dragged == nil, pinch == nil else { return }
        burst(adjusting: true) {
            // From the size asked for so far: sticking to an edge doesn't hold it back.
            let requested = IconGeometry.scaled(requestedRect ?? style.rect, by: factor)
            requestedRect = requested
            scaleFrame(to: requested, snaps: snaps)
        }
    }

    /// The rectangle at `rect`, which is the one there is made bigger or smaller: close to
    /// the folder's edges, its own stick to them (see `IconSnapping.scale`).
    private func scaleFrame(to rect: CGRect, snaps: Bool) {
        let snapped = snaps ? StyleEditor.snapping(side: side).scale(rect) : (rect: rect, guides: [])
        set(rect: snapped.rect)
        showGuides(snapped.guides)
    }

    // MARK: - Changes made at once

    /// One change, made at once and undone as one: an action from VoiceOver.
    private func change(_ make: () -> Void) {
        guard isEnabled, dragged == nil, pinch == nil else { return }
        finishBurst()
        actions.begin()
        make()
        actions.commit()
        updateToolTips()
        queueCursorUpdate()
    }

    /// The picture back in the middle.
    private func centerPicture() {
        guard placement != .centered else { return }
        change { set(style, .centered) }
    }

    /// The rectangle `offset` points away.
    private func moveFrame(by offset: CGSize) {
        let rect = style.rect.offsetBy(dx: offset.width / side, dy: offset.height / side)
        change { set(rect: rect) }
    }

    /// The rectangle `factor` times as big, around its middle.
    private func scaleFrame(by factor: CGFloat) {
        let rect = IconGeometry.scaled(style.rect, by: factor)
        change { set(rect: rect) }
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
            guard let moved = picture(movedBy: offset) else { return }
            burst { set(style, moved) }
        } else {
            let rect = style.rect.offsetBy(dx: offset.width / side, dy: offset.height / side)
            burst { set(rect: rect) }
        }
    }

    /// Where the picture goes when moved by `offset` points; `nil` when it can't move that way.
    private func picture(movedBy offset: CGSize) -> PicturePlacement? {
        guard canPlacePicture, let picture else { return nil }
        let moved = IconGeometry.placement(placement, movedBy: offset, imageSize: picture.size, in: target, mode: style.mode)
        return moved == placement ? nil : moved
    }

    /// Makes `change` part of the burst going on, or starts one. With `adjusting`, the parts
    /// cut off show faintly until it settles.
    private func burst(adjusting: Bool = false, _ change: () -> Void) {
        if burstEnd == nil {
            actions.begin()
            requestedRect = nil
        }
        if adjusting { setAdjusting(true) }
        burstEnd?.cancel()
        change()
        queueCursorUpdate()
        burstEnd = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.finishBurst()
        }
    }

    private func finishBurst() {
        guard let burstEnd else { return }
        burstEnd.cancel()
        self.burstEnd = nil
        requestedRect = nil
        showGuides([])
        setAdjusting(false)
        actions.commit()
        updateToolTips()
    }

    override func resignFirstResponder() -> Bool {
        finishBurst()
        return super.resignFirstResponder()
    }

    // MARK: - Undo

    /// ⌘Z right after a burst of keys or scrolling undoes it, as a change of its own; during a
    /// pinch there is nothing finished to undo yet.
    @objc func undo(_ sender: Any?) {
        guard dragged == nil, pinch == nil else { return }
        finishBurst()
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard dragged == nil, pinch == nil, burstEnd == nil else { return }
        undoManager?.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return isEnabled && dragged == nil && pinch == nil
        default:
            break
        }
        guard let undoManager, dragged == nil, pinch == nil else { return false }
        switch menuItem.action {
        case #selector(undo(_:)):
            // Keys or scrolling still going on are about to become a change.
            guard burstEnd == nil else {
                menuItem.title = undoManager.undoMenuTitle(forUndoActionName: "")
                return true
            }
            menuItem.title = undoManager.undoMenuItemTitle
            return undoManager.canUndo
        case #selector(redo(_:)):
            menuItem.title = undoManager.redoMenuItemTitle
            return burstEnd == nil && undoManager.canRedo
        default:
            return true
        }
    }

    // MARK: - VoiceOver and the keyboard

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        guard isEnabled else { return nil }
        func action(_ name: String, _ perform: @escaping (StyleEditorView) -> Void) -> NSAccessibilityCustomAction {
            NSAccessibilityCustomAction(name: name) { [weak self] in
                guard let self else { return false }
                perform(self)
                return true
            }
        }
        let step: CGFloat = 10
        var list = [
            action(String(localized: "Move Frame Left")) { $0.moveFrame(by: CGSize(width: -step, height: 0)) },
            action(String(localized: "Move Frame Right")) { $0.moveFrame(by: CGSize(width: step, height: 0)) },
            action(String(localized: "Move Frame Up")) { $0.moveFrame(by: CGSize(width: 0, height: -step)) },
            action(String(localized: "Move Frame Down")) { $0.moveFrame(by: CGSize(width: 0, height: step)) },
            action(String(localized: "Make Frame Bigger")) { $0.scaleFrame(by: Self.zoomStep) },
            action(String(localized: "Make Frame Smaller")) { $0.scaleFrame(by: 1 / Self.zoomStep) },
        ]
        if canPlacePicture {
            for (name, offset) in [(String(localized: "Move Picture Left"), CGSize(width: -step, height: 0)),
                                   (String(localized: "Move Picture Right"), CGSize(width: step, height: 0)),
                                   (String(localized: "Move Picture Up"), CGSize(width: 0, height: -step)),
                                   (String(localized: "Move Picture Down"), CGSize(width: 0, height: step))] {
                list.append(action(name) { editor in
                    guard let moved = editor.picture(movedBy: offset) else { return }
                    editor.change { editor.set(editor.style, moved) }
                })
            }
            list.append(action(String(localized: "Center Picture")) { $0.centerPicture() })
        }
        return list
    }

    // A focus ring for those who move around with the keyboard; a click shows the frame
    // and its handles instead.
    override var focusRingType: NSFocusRingType {
        get { NSApp.isFullKeyboardAccessEnabled ? .exterior : .none }
        set {}
    }

    override var focusRingMaskBounds: NSRect {
        NSRect(x: 0, y: 0, width: side, height: side)
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: focusRingMaskBounds, xRadius: 8, yRadius: 8).fill()
    }

    // MARK: - Changes

    private func set(rect: CGRect) {
        var style = style
        style.rect = rect
        set(style, placement)
    }

    private func set(_ style: IconStyle, _ placement: PicturePlacement) {
        guard style != self.style || placement != self.placement else { return }
        self.style = style
        self.placement = placement
        needsDisplay = true
        setAccessibilityValue(accessibilityDescription)
        actions.change(style, placement)
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
        let width = style.width.formatted(.percent.precision(.fractionLength(0)))
        let height = style.height.formatted(.percent.precision(.fractionLength(0)))
        return style.mode == .fill
            ? String(localized: "\(width) wide, \(height) tall, fills its frame")
            : String(localized: "\(width) wide, \(height) tall, fits in its frame")
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
            let drawn = IconGeometry.imageRect(imageSize: picture.size, in: target, mode: style.mode, placement: placement, flipped: false)
            context.saveGState()
            context.clip(to: CGRect(x: 0, y: 0, width: canvas, height: canvas))
            context.setAlpha(0.22)
            picture.draw(in: drawn, context: context)
            context.restoreGState()
        }
        IconRenderer.drawPicture(picture, style: style, placement: placement, canvas: canvas, on: Self.surface, in: context)
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
    /// Reads and decodes the file, so better not on the main thread.
    nonisolated static func load(_ url: URL) -> SourceImage? {
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
