import AppKit
import PrettyFolderKit
import SwiftUI

/// The folder icon, big, with the picture on it to place by hand: drag the rectangle to move
/// it, its handles to resize it, and pinch or scroll to make it bigger or smaller, well past
/// the folder; drag with the right button (or Control, or after a double-click) to move the
/// picture inside it, and turn the picture to any angle with the dial below it (`TurnDial`), by
/// twisting on the trackpad or by dragging just outside a corner. The arrow keys nudge the rectangle (the picture with ⌥), ⌘+ and ⌘− make it bigger
/// or smaller, and ⌘L and ⌘R turn the picture. The picture is always as big as Fill or Fit
/// makes it in the rectangle, turned as it is.
///
/// While something moves it snaps to the folder's edges and center, the picture to the
/// middle of its rectangle and to upright and quarter turns (hold Command to place things
/// freely). It is drawn with the renderer's own drawing, outline, light and all, so what it
/// shows is exactly what the icon gets. The rectangle shows only while the pointer is over
/// the editor, thin and outside the picture, so it never hides what the icon gets.
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
    /// Whether the picture can be moved and turned inside its rectangle. A folder's own can;
    /// the default look always has it in the middle, upright.
    var placesPicture = false
    var side: CGFloat = StyleEditor.side
    /// A change begins: a drag, a pinch, the first of a burst of keys or of scrolling. `true`
    /// while the pointer or the fingers hold on to something until the change is done.
    var onBegin: (_ holding: Bool) -> Void = { _ in }
    /// The change is finished: a drag or a pinch ended, a burst settled.
    var onCommit: () -> Void = {}
    /// Lets the dial below the folder turn the picture through the editor.
    var turnLink: TurnLink?

    /// How big the window shows the folder, in points.
    static let side: CGFloat = 300

    /// Snapping kicks in within 6 points, whatever the editor's size.
    static func snapping(side: CGFloat) -> IconSnapping { IconSnapping(threshold: 6 / side) }

    /// `placement` turned `degrees` further, the picture staying where it is as far as its new
    /// size lets it, the way the editor turns it.
    static func placement(_ placement: PicturePlacement, turnedBy degrees: Double, imageSize: CGSize, style: IconStyle) -> PicturePlacement {
        IconGeometry.placement(
            placement, turnedTo: placement.rotation + degrees, imageSize: imageSize, style: style,
            canvas: side, folder: StyleEditorView.folderEdges
        )
    }

    func makeNSView(context: Context) -> StyleEditorView {
        StyleEditorView()
    }

    func updateNSView(_ view: StyleEditorView, context: Context) {
        turnLink?.editor = view
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
/// the rectangle, which a drag moves, a turning arrow just outside its corners, the arrow
/// everywhere else.
final class StyleEditorView: NSView, NSViewToolTipOwner, NSMenuItemValidation {
    /// Room around the folder, so the handles of a rectangle at its edges show and can be
    /// grabbed whole, and its corners can be turned from. The folder's top-left corner is the
    /// origin all the same.
    static let margin: CGFloat = 16
    /// How far the pointer goes with the button down before a click becomes a drag: a click,
    /// the first of a double-click say, never moves anything.
    static let dragThreshold: CGFloat = 3
    /// How much one press of ⌘+ or ⌘− makes the rectangle bigger or smaller.
    static let zoomStep: CGFloat = 1.1
    /// How far out from a corner of the rectangle the picture can be taken hold of to turn it.
    static let turnReach: CGFloat = 24
    /// The steps the picture turns in with Shift held, in degrees.
    static let turnStep = 15.0

    struct Actions {
        /// The look as the model has it now.
        var current: () -> (IconStyle, PicturePlacement) = { (.standard, .natural) }
        var change: (IconStyle, PicturePlacement) -> Void = { _, _ in }
        var showGuides: ([SnapGuide]) -> Void = { _ in }
        var adjust: (Bool) -> Void = { _ in }
        /// `true` for a drag or a gesture, which holds on until it ends.
        var begin: (_ holding: Bool) -> Void = { _ in }
        var commit: () -> Void = {}
    }

    /// A part of the editor, by what pressing on it does.
    enum Part: Equatable {
        /// Resizes the rectangle.
        case handle(ResizeHandle)
        /// Moves the rectangle: its inside, and a band around its edge. The right button, or
        /// the second click of a double-click, takes hold of the picture instead.
        case frame
        /// Turns the picture: just outside a corner of the rectangle.
        case turn(ResizeHandle)
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
        /// The picture's turn, from a corner of the rectangle.
        case turn(ResizeHandle)
    }

    var actions = Actions()

    private var style = IconStyle.standard
    private var placement = PicturePlacement.natural
    private var guides: [SnapGuide] = []
    private var isAdjusting = false
    private var picture: SourceImage?
    private var isEnabled = true
    private var placesPicture = false
    private var side: CGFloat = StyleEditor.side

    /// The part under the pointer.
    private var hovered = Part.none
    /// Whether the pointer is over the editor; the rectangle shows meanwhile.
    private var pointerIsInside = false
    /// What is being dragged.
    private var dragged: Drag?
    /// Pinching and turning on the trackpad, which can go on at once and make one change:
    /// the look when the first of them began, and how far each has gone.
    private var gestureStart: (style: IconStyle, placement: PicturePlacement)?
    private var pinching: (startRect: CGRect, magnification: CGFloat)?
    private var twisting: (startRotation: Double, center: CGPoint, rotation: Double)?
    /// The dial being dragged, which turns the picture around this middle (unit coordinates).
    private var dialing: CGPoint?
    /// Keys or scrolling on the dial, in a burst: the turn asked for so far, and the middle
    /// the picture turns around.
    private var burstTurn: (rotation: Double, center: CGPoint)?
    /// The turn, shown by the rectangle while the picture is being turned.
    private var turnShown: Double?
    /// Whether the turn going on has stuck to upright or a quarter turn.
    private var turnIsStuck = false
    /// Arrow keys, ⌘+ and ⌘−, and scrolling in a row make one change, finished once they stop
    /// for a moment.
    private var burstEnd: Task<Void, Never>?
    /// The rectangle the scrolling or keys going on ask for, before it sticks to the folder's
    /// edges: snapped each time, small steps would never get away from them.
    private var requestedRect: CGRect?
    private var tracking: NSTrackingArea?
    private var windowObservers: [NSObjectProtocol] = []
    private var cursorUpdateIsQueued = false
    /// The rectangle and its handles, in a view of their own over the folder, so they can
    /// fade in and out by themselves.
    private let frameView = FrameView()
    /// Whether the rectangle is meant to show, as last asked of `frameView`.
    private var frameIsShown: Bool?

    /// The plain folder, rendered once at full size so it stays sharp at any editor size.
    private static let renderer = IconRenderer()
    private static let folderImage = renderer.render(nil, style: .standard, pixelSize: 1024)
    private static let surface = renderer.surface(pixelSize: 1024)
    /// Where the folder's edges are, as the editor draws it.
    static var folderEdges: FolderEdges { surface?.edges ?? .standard }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 320))
        wantsLayer = true
        setBoundsOrigin(NSPoint(x: -Self.margin, y: -Self.margin))
        frameView.frame = bounds
        frameView.autoresizingMask = [.width, .height]
        frameView.alphaValue = 0
        addSubview(frameView)
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
        frameView.setBoundsOrigin(NSPoint(x: -Self.margin, y: -Self.margin))
        updateToolTips()
    }

    /// Takes what SwiftUI has. While a drag or a gesture goes on, the editor's own look is the
    /// one that counts; once it's over, the model's is taken again (`catchUp`).
    func update(
        style: IconStyle, placement: PicturePlacement, guides: [SnapGuide], isAdjusting: Bool,
        picture: SourceImage?, isEnabled: Bool, placesPicture: Bool, side: CGFloat
    ) {
        var moved = false
        if dragged == nil, !isGesturing, style != self.style || placement != self.placement {
            // Changed from elsewhere (undo, the reset button, another folder's look): the model
            // finished any burst of keys or scrolling before making the change.
            if let burstEnd {
                burstEnd.cancel()
                self.burstEnd = nil
                requestedRect = nil
                burstTurn = nil
                // What showed while it went on goes with it, once SwiftUI is done updating.
                Task { [weak self] in
                    guard let self, self.burstEnd == nil, !self.isGesturing, self.dragged == nil else { return }
                    showGuides([])
                    showTurn(nil)
                    setAdjusting(false)
                    refreshFrame()
                }
            }
            self.style = style
            self.placement = placement
            moved = true
        }
        let changed = moved || picture !== self.picture || isEnabled != self.isEnabled
            || placesPicture != self.placesPicture || side != self.side
        let redraws = changed || guides != self.guides || isAdjusting != self.isAdjusting
        self.guides = guides
        self.isAdjusting = isAdjusting
        self.picture = picture
        self.isEnabled = isEnabled
        self.placesPicture = placesPicture
        self.side = side
        if redraws { redraw() }
        // Turned off in the middle of a gesture (the picture was taken off in Finder, say).
        if !isEnabled { endGestures(restoring: true) }
        setAccessibilityValue(accessibilityDescription)
        if changed {
            updateToolTips()
            queueCursorUpdate()
        }
    }

    /// After a drag or a gesture, shows the look the model has: the gesture's own, once the
    /// model took it, or another one if the model moved on meanwhile (to other folders, say).
    private func catchUp() {
        let (style, placement) = actions.current()
        guard style != self.style || placement != self.placement else { return }
        self.style = style
        self.placement = placement
        redraw()
        setAccessibilityValue(accessibilityDescription)
    }

    /// Draws the folder again, and the rectangle over it.
    private func redraw() {
        needsDisplay = true
        refreshFrame()
    }

    // MARK: - Parts

    private var target: CGRect { IconGeometry.targetRect(for: style, canvas: side, flipped: true) }

    /// Whether there is a picture to move and turn inside its rectangle.
    private var canPlacePicture: Bool { placesPicture && picture != nil }

    private var isGesturing: Bool { pinching != nil || twisting != nil || dialing != nil }

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
        if grabArea(for: target).contains(point) { return .frame }
        if let corner = turningCorner(at: point, of: target) { return .turn(corner) }
        return .none
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

    /// The corner of the rectangle the picture can be turned from at `point`: outside the
    /// rectangle, close to the corner, away from the rectangle on both sides.
    private func turningCorner(at point: CGPoint, of target: CGRect) -> ResizeHandle? {
        guard canPlacePicture else { return nil }
        for corner in ResizeHandle.corners {
            let position = corner.position(in: target)
            let dx = point.x - position.x, dy = point.y - position.y
            guard hypot(dx, dy) <= Self.turnReach else { continue }
            // Out from the corner, not along one of its sides.
            let outward = corner.outward
            if dx * outward.x >= -4, dy * outward.y >= -4 { return corner }
        }
        return nil
    }

    /// The pointer over `part`.
    func cursor(for part: Part) -> NSCursor {
        switch part {
        case .handle(let handle): handle.cursor
        case .frame: .openHand
        case .turn(let corner): TurnCursor.cursor(for: corner)
        case .none: .arrow
        }
    }

    /// The pointer while `drag` goes on.
    func cursor(for drag: Drag) -> NSCursor {
        switch drag {
        case .handle(let handle): handle.cursor
        case .frame, .picture: .closedHand
        case .turn(let corner): TurnCursor.cursor(for: corner)
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
        setPointerInside(false)
        setHovered(.none)
        NSCursor.arrow.set()
    }

    private func hover(at point: CGPoint) {
        let part = part(at: point)
        setPointerInside(true)
        setHovered(part)
        cursor(for: part).set()
    }

    private func setHovered(_ part: Part) {
        guard part != hovered else { return }
        hovered = part
        refreshFrame()
    }

    private func setPointerInside(_ inside: Bool) {
        guard inside != pointerIsInside else { return }
        pointerIsInside = inside
        refreshFrame()
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
            if window?.isKeyWindow != true { setPointerInside(false) }
            return
        }
        let location = window.mouseLocationOutsideOfEventStream
        let point = convert(location, from: nil)
        // Only when the pointer is really over the editor, not over something on top of it.
        guard bounds.contains(point),
              NSWindow.windowNumber(at: NSEvent.mouseLocation, belowWindowWithWindowNumber: 0) == window.windowNumber,
              window.contentView?.hitTest(location) === self
        else {
            setPointerInside(false)
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
        endGestures(restoring: true)
        guard let newWindow else { return }
        let center = NotificationCenter.default
        // A window that becomes key under a still pointer gets no mouse moves to set it right.
        windowObservers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.queueCursorUpdate() }
        })
        // An alert or another window takes over: a gesture can't finish, and the pointer is no
        // longer the editor's to set.
        windowObservers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: newWindow, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowResignedKey() }
        })
    }

    private func windowResignedKey() {
        endGestures(restoring: true)
        if hovered != .none, let window, bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)) {
            NSCursor.arrow.set()
        }
        setHovered(.none)
        setPointerInside(false)
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
        if canPlacePicture {
            for corner in ResizeHandle.corners {
                let position = corner.position(in: target), reach = Self.turnReach
                addToolTip(NSRect(x: position.x - reach, y: position.y - reach, width: 2 * reach, height: 2 * reach), owner: self, userData: nil)
            }
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        switch part(at: point) {
        case .handle(let handle) where handle.isCorner:
            String(localized: "Drag to resize. ⇧ keeps the proportions, ⌥ resizes around the middle.")
        case .handle:
            String(localized: "Drag to resize. ⌥ resizes around the middle.")
        case .frame where canPlacePicture:
            String(localized: "Drag to move the frame; pinch or scroll to make it bigger or smaller. Drag with the right button, or double-click and drag, to move the picture inside it. Turn the picture with the dial below, or twist on the trackpad.")
        case .frame:
            String(localized: "Drag to move the frame; pinch or scroll to make it bigger or smaller.")
        case .turn:
            String(localized: "Drag to turn the picture. ⇧ turns it in steps of 15°.")
        case .none:
            ""
        }
    }

    // MARK: - Dragging

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }
    override var acceptsFirstResponder: Bool { isEnabled }

    override func becomeFirstResponder() -> Bool {
        // The window takes it as its first responder once this returns.
        Task { [weak self] in self?.refreshFrame() }
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, !isGesturing else { return }
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
        case .turn(let corner):
            track(.turn(corner), from: start, button: .left)
        case .none:
            break
        }
    }

    /// The right button takes hold of the picture, anywhere on the rectangle, handles too.
    override func rightMouseDown(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard isEnabled, !isGesturing, canPlacePicture, grabArea(for: target).contains(start) else {
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

    /// Where a drag began: the look, and the picture's middle (unit coordinates), which turning
    /// keeps where it is.
    private struct DragStart {
        let style: IconStyle
        let placement: PicturePlacement
        let center: CGPoint
    }

    /// Follows the pointer until the button is let go. Modifier keys count as soon as they
    /// change; Escape puts everything back where it was.
    private func track(_ drag: Drag, from start: CGPoint, button: Button) {
        dragged = drag
        cursor(for: drag).set()
        redraw()
        var origin: DragStart?
        var point = start

        func follow(_ modifiers: NSEvent.ModifierFlags) {
            let offset = CGSize(width: point.x - start.x, height: point.y - start.y)
            if origin == nil {
                // A click that doesn't go anywhere isn't a change.
                guard hypot(offset.width, offset.height) >= Self.dragThreshold else { return }
                origin = DragStart(style: style, placement: placement, center: pictureCenter())
                actions.begin(true)
                setAdjusting(true)
            }
            if let origin { self.drag(drag, from: origin, start: start, to: point, modifiers: modifiers) }
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
            showTurn(nil)
            setAdjusting(false)
            actions.commit()
        }
        catchUp()
        redraw()
        updateToolTips()
        updateCursor(afterDrag: true)
    }

    private func drag(_ drag: Drag, from origin: DragStart, start: CGPoint, to point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        // Holding Command places things freely, as in most design apps.
        let snaps = !modifiers.contains(.command)
        let snapping = StyleEditor.snapping(side: side)
        let offset = CGSize(width: point.x - start.x, height: point.y - start.y)
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
            let moved = IconGeometry.placement(
                origin.placement, movedBy: offset, imageSize: picture.size, style: style, canvas: side, folder: Self.folderEdges
            )
            let snapped = snaps
                ? snapping.pan(moved, imageSize: picture.size, style: style, canvas: side, folder: Self.folderEdges)
                : (placement: moved, guides: [])
            set(style, snapped.placement)
            showGuides(snapped.guides)
        case .turn:
            // By how far the pointer went around the rectangle's middle.
            let middle = CGPoint(x: target.midX, y: target.midY)
            func angle(_ point: CGPoint) -> Double {
                atan2(Double(middle.y - point.y), Double(point.x - middle.x)) * 180 / .pi
            }
            turnPicture(to: origin.placement.rotation + angle(point) - angle(start), keeping: origin.center, modifiers: modifiers)
        }
    }

    /// The picture's middle, in unit coordinates.
    private func pictureCenter() -> CGPoint {
        guard let picture else { return CGPoint(x: style.rect.midX, y: style.rect.midY) }
        return IconGeometry.pictureCenter(imageSize: picture.size, style: style, placement: placement, canvas: side, folder: Self.folderEdges)
    }

    /// Turns the picture to `degrees`, its middle at `center` as far as its new size lets it:
    /// in steps of 15° with Shift, sticking to upright and quarter turns within `reach` unless
    /// Command is held.
    private func turnPicture(
        to degrees: Double, keeping center: CGPoint, modifiers: NSEvent.ModifierFlags, reach: Double = IconSnapping.turnThreshold
    ) {
        guard let picture else { return }
        var degrees = degrees
        var stuck = false
        if modifiers.contains(.shift) {
            degrees = (degrees / Self.turnStep).rounded() * Self.turnStep
        } else if !modifiers.contains(.command) {
            (degrees, stuck) = IconSnapping.turn(degrees, within: reach)
        }
        if stuck, !turnIsStuck {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        turnIsStuck = stuck
        let turned = IconGeometry.placement(
            near: center, rotation: degrees, imageSize: picture.size, style: style, canvas: side, folder: Self.folderEdges
        )
        set(style, turned)
        showTurn(turned.rotation)
    }

    // MARK: - Pinching and turning

    /// A pinch or a twist begins: the first of them starts the change both make.
    private func beginGesture() -> Bool {
        guard isEnabled, dragged == nil else { return false }
        if !isGesturing {
            finishBurst()
            gestureStart = (style, placement)
            actions.begin(true)
            setAdjusting(true)
        }
        return true
    }

    /// Pinching makes the rectangle bigger or smaller around its middle; the picture in it
    /// follows, as big as Fill or Fit makes it there.
    override func magnify(with event: NSEvent) {
        pinch(event.phase, by: event.magnification, modifiers: event.modifierFlags)
    }

    /// Twisting two fingers on the trackpad turns the picture, around its own middle.
    override func rotate(with event: NSEvent) {
        // Counterclockwise is positive, as for the picture's turn.
        twist(event.phase, by: Double(event.rotation), modifiers: event.modifierFlags)
    }

    /// A step of a pinch: `magnification` more than the last one, as `NSEvent` has it.
    func pinch(_ phase: NSEvent.Phase, by magnification: CGFloat, modifiers: NSEvent.ModifierFlags) {
        switch phase {
        case .began:
            guard pinching == nil, beginGesture() else { return }
            pinching = (style.rect, 0)
        case .changed:
            guard isEnabled, var current = pinching else { return }
            current.magnification += magnification
            pinching = current
            // Multiplied in, so pinching out and back in comes back to the same size.
            let scaled = IconGeometry.scaled(current.startRect, by: exp(current.magnification))
            scaleFrame(to: scaled, snaps: !modifiers.contains(.command))
            queueCursorUpdate()
        case .ended:
            pinching = nil
            endGestureIfDone()
        case .cancelled:
            endGestures(restoring: true)
        default:
            break
        }
    }

    /// A step of a twist: `degrees` further counterclockwise than the last one.
    func twist(_ phase: NSEvent.Phase, by degrees: Double, modifiers: NSEvent.ModifierFlags) {
        switch phase {
        case .began:
            guard twisting == nil, canPlacePicture, beginGesture() else { return }
            twisting = (placement.rotation, pictureCenter(), 0)
            turnIsStuck = false
        case .changed:
            guard isEnabled, var current = twisting else { return }
            current.rotation += degrees
            twisting = current
            turnPicture(to: current.startRotation + current.rotation, keeping: current.center, modifiers: modifiers)
        case .ended:
            twisting = nil
            showTurn(nil)
            endGestureIfDone()
        case .cancelled:
            endGestures(restoring: true)
        default:
            break
        }
    }

    /// Finishes the change once neither a pinch nor a twist is left going.
    private func endGestureIfDone() {
        guard !isGesturing, gestureStart != nil else { return }
        finishGestures()
    }

    /// Finishes pinching and turning, kept or put back where they started. Also when their end
    /// never comes: the editor turned off, or an alert or another window took over.
    private func endGestures(restoring: Bool) {
        guard let start = gestureStart else { return }
        if restoring { set(start.style, start.placement) }
        pinching = nil
        twisting = nil
        dialing = nil
        finishGestures()
    }

    private func finishGestures() {
        gestureStart = nil
        showGuides([])
        showTurn(nil)
        setAdjusting(false)
        actions.commit()
        catchUp()
        updateToolTips()
        queueCursorUpdate()
    }

    // MARK: - Bigger and smaller

    /// Scrolling makes the rectangle bigger or smaller too, like pinching, for a mouse's wheel
    /// above all: up makes it bigger.
    override func scrollWheel(with event: NSEvent) {
        guard isEnabled, dragged == nil, !isGesturing else { return super.scrollWheel(with: event) }
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
        guard isEnabled, dragged == nil, !isGesturing else { return }
        if burstTurn != nil { finishBurst() }
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

    // MARK: - Quarter turns

    @objc func rotateLeft(_ sender: Any?) {
        turnByQuarter(counterclockwise: true)
    }

    @objc func rotateRight(_ sender: Any?) {
        turnByQuarter(counterclockwise: false)
    }

    /// A quarter turn of the picture, as a change of its own.
    private func turnByQuarter(counterclockwise: Bool) {
        guard canPlacePicture, let picture else { return }
        let turned = StyleEditor.placement(placement, turnedBy: counterclockwise ? 90 : -90, imageSize: picture.size, style: style)
        change { set(style, turned) }
    }

    // MARK: - The dial

    /// How far the picture is turned, as the editor has it now.
    var turn: Double { placement.rotation }

    /// Whether the picture can be turned now, from the dial.
    var canTurn: Bool { isEnabled && canPlacePicture && dragged == nil && !isGesturing }

    /// The dial is taken hold of: one change, as for a twist, until it is let go. `false` when
    /// the picture can't be turned now.
    func beginDialTurn() -> Bool {
        guard dialing == nil, canTurn, beginGesture() else { return false }
        dialing = pictureCenter()
        turnIsStuck = false
        refreshFrame()
        return true
    }

    /// The dial dragged to `degrees`: sticking to upright and quarter turns within `reach`.
    func dialTurn(to degrees: Double, modifiers: NSEvent.ModifierFlags, reach: Double) {
        guard isEnabled, let center = dialing else { return }
        turnPicture(to: degrees, keeping: center, modifiers: modifiers, reach: reach)
    }

    /// The dial let go, or put back with Escape.
    func endDialTurn(restoring: Bool) {
        guard dialing != nil else { return }
        guard !restoring else { return endGestures(restoring: true) }
        dialing = nil
        showTurn(nil)
        endGestureIfDone()
    }

    /// Keys or scrolling on the dial: `degrees` further, as one burst with the turns right
    /// before and after. With `steps`, to the next multiple of 15° that way instead.
    func dialTurn(by degrees: Double, steps: Bool = false) {
        guard canTurn, degrees != 0 else { return }
        // Moving or resizing in a burst of its own: the picture's middle has moved since.
        if burstEnd != nil, burstTurn == nil { finishBurst() }
        burst(adjusting: true) {
            var current = burstTurn ?? (placement.rotation, pictureCenter())
            // Whole degrees, as the dial reads; scrolling adds up fractions until they count.
            let shown = current.rotation.rounded()
            current.rotation = !steps ? current.rotation + degrees
                : degrees > 0 ? ((shown / Self.turnStep).rounded(.down) + 1) * Self.turnStep
                : ((shown / Self.turnStep).rounded(.up) - 1) * Self.turnStep
            burstTurn = current
            turnPicture(to: current.rotation.rounded(), keeping: current.center, modifiers: .command)
        }
    }

    /// The picture upright again, where it is.
    func turnUpright() {
        guard canTurn, placement.rotation != 0, let picture else { return }
        let upright = IconGeometry.placement(
            near: pictureCenter(), rotation: 0, imageSize: picture.size, style: style, canvas: side, folder: Self.folderEdges
        )
        change { set(style, upright) }
    }

    // MARK: - Changes made at once

    /// One change, made at once and undone as one: an action from VoiceOver, a quarter turn.
    private func change(_ make: () -> Void) {
        guard isEnabled, dragged == nil, !isGesturing else { return }
        finishBurst()
        actions.begin(false)
        make()
        actions.commit()
        updateToolTips()
        queueCursorUpdate()
    }

    /// The picture back in the middle, turned as it is.
    private func centerPicture() {
        guard !placement.isCentered else { return }
        change { set(style, placement.centered) }
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
        guard isEnabled, dragged == nil, !isGesturing, let offset, modifiers.isDisjoint(with: [.command, .control]) else {
            return super.keyDown(with: event)
        }
        // Turning from the dial is a burst of its own.
        if burstTurn != nil { finishBurst() }
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
        let moved = IconGeometry.placement(placement, movedBy: offset, imageSize: picture.size, style: style, canvas: side, folder: Self.folderEdges)
        return moved == placement ? nil : moved
    }

    /// Makes `change` part of the burst going on, or starts one. With `adjusting`, the parts
    /// cut off show faintly until it settles.
    private func burst(adjusting: Bool = false, _ change: () -> Void) {
        if burstEnd == nil {
            actions.begin(false)
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
        refreshFrame()
    }

    private func finishBurst() {
        guard let burstEnd else { return }
        burstEnd.cancel()
        self.burstEnd = nil
        requestedRect = nil
        burstTurn = nil
        showTurn(nil)
        showGuides([])
        setAdjusting(false)
        actions.commit()
        updateToolTips()
        refreshFrame()
    }

    override func resignFirstResponder() -> Bool {
        finishBurst()
        Task { [weak self] in self?.refreshFrame() }
        return super.resignFirstResponder()
    }

    // MARK: - Undo

    /// ⌘Z right after a burst of keys or scrolling undoes it, as a change of its own; during a
    /// gesture there is nothing finished to undo yet.
    @objc func undo(_ sender: Any?) {
        guard dragged == nil, !isGesturing else { return }
        finishBurst()
        undoManager?.undo()
    }

    @objc func redo(_ sender: Any?) {
        guard dragged == nil, !isGesturing, burstEnd == nil else { return }
        undoManager?.redo()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(zoomIn(_:)), #selector(zoomOut(_:)):
            return isEnabled && dragged == nil && !isGesturing
        case #selector(rotateLeft(_:)), #selector(rotateRight(_:)):
            return isEnabled && canPlacePicture && dragged == nil && !isGesturing
        default:
            break
        }
        guard let undoManager, dragged == nil, !isGesturing else { return false }
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
            list.append(action(String(localized: "Rotate Picture Left")) { $0.turnByQuarter(counterclockwise: true) })
            list.append(action(String(localized: "Rotate Picture Right")) { $0.turnByQuarter(counterclockwise: false) })
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
        redraw()
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

    /// Shows how far the picture is turned while it is being turned; `nil` when it isn't.
    private func showTurn(_ degrees: Double?) {
        guard degrees != turnShown else { return }
        turnShown = degrees
        if degrees == nil { turnIsStuck = false }
        refreshFrame()
    }

    private func setAdjusting(_ adjusting: Bool) {
        guard adjusting != isAdjusting else { return }
        isAdjusting = adjusting
        redraw()
        actions.adjust(adjusting)
    }

    private var accessibilityDescription: String {
        let width = style.width.formatted(.percent.precision(.fractionLength(0)))
        let height = style.height.formatted(.percent.precision(.fractionLength(0)))
        let frame = style.mode == .fill
            ? String(localized: "\(width) wide, \(height) tall, fills its frame")
            : String(localized: "\(width) wide, \(height) tall, fits in its frame")
        guard placesPicture, placement.rotation != 0 else { return frame }
        return frame + ", " + String(localized: "turned \(Self.turnText(placement.rotation))")
    }

    /// A turn as it is shown: whole degrees, counterclockwise positive.
    static func turnText(_ degrees: Double) -> String {
        let whole = Int(degrees.rounded())
        return whole < 0 ? "−\(-whole)°" : "\(whole)°"
    }

    // MARK: - The rectangle

    /// Whether the rectangle shows: while the pointer is over the editor, while something in it
    /// changes, and while it has the keyboard's focus ring.
    private var showsFrame: Bool {
        guard isEnabled else { return false }
        let focused = NSApp.isFullKeyboardAccessEnabled && window?.isKeyWindow == true && window?.firstResponder === self
        return pointerIsInside || dragged != nil || isGesturing || burstEnd != nil || focused
    }

    /// Tells the rectangle's view what to show, and fades it in or out.
    private func refreshFrame() {
        frameView.look = FrameView.Look(
            frame: target,
            showsHandles: !isAdjusting && dragged == nil && !isGesturing,
            hovered: { if case .handle(let handle) = hovered { handle } else { nil } }(),
            isHighlighted: hovered == .frame || dragged == .frame,
            isFaint: isAdjusting,
            turn: turnShown.map(Self.turnText)
        )
        let shown = showsFrame
        guard shown != frameIsShown else { return }
        frameIsShown = shown
        NSAnimationContext.runAnimationGroup { context in
            context.duration = shown ? 0.12 : 0.25
            context.allowsImplicitAnimation = true
            frameView.animator().alphaValue = shown ? 1 : 0
        }
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
        drawIcon(in: context, canvas: canvas)
        context.restoreGState()
        drawGuides()
    }

    /// The folder with the picture on it, or without one the area it will take, softly.
    private func drawIcon(in context: CGContext, canvas: CGFloat) {
        let bounds = CGRect(x: 0, y: 0, width: canvas, height: canvas)
        guard let picture else {
            if let folder = Self.folderImage { context.draw(folder, in: bounds) }
            let target = IconGeometry.targetRect(for: style, canvas: canvas, flipped: false)
            let radius = IconGeometry.cornerRadius(for: target, canvas: canvas)
            context.saveGState()
            if let silhouette = Self.surface?.silhouette {
                context.clip(to: bounds, mask: silhouette)
            }
            context.addPath(CGPath(roundedRect: target, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.setFillColor(CGColor(gray: 1, alpha: 0.35))
            context.fillPath()
            context.restoreGState()
            return
        }
        let layout = IconGeometry.layout(
            imageSize: picture.size, style: style, placement: placement, canvas: canvas, flipped: false, folder: Self.folderEdges
        )
        if let surface = Self.surface {
            IconRenderer.draw(picture, style: style, placement: placement, canvas: canvas, on: surface, in: context)
        } else {
            // The folder's artwork couldn't be measured: the picture goes over it, unshaped.
            if let folder = Self.folderImage { context.draw(folder, in: bounds) }
            context.saveGState()
            context.addPath(layout.visible)
            context.clip()
            IconRenderer.drawPicture(picture, in: layout, context: context)
            context.restoreGState()
        }
        guard isAdjusting else { return }
        // While it moves: faintly, the parts the rectangle or the folder's outline cut off, as
        // far as the editor goes.
        let margin = Self.margin
        let everywhere = bounds.insetBy(dx: -margin, dy: -margin)
        context.saveGState()
        context.addRect(everywhere)
        context.addPath(layout.visible)
        context.clip(using: .evenOdd)
        context.setAlpha(0.22)
        IconRenderer.drawPicture(picture, in: layout, context: context)
        context.restoreGState()
        // Inside the part that shows, only where the folder's outline cut it off.
        context.saveGState()
        context.addPath(layout.visible)
        context.clip()
        context.setAlpha(0.22)
        context.setBlendMode(.destinationOver)
        IconRenderer.drawPicture(picture, in: layout, context: context)
        context.restoreGState()
    }

    private func drawGuides() {
        guard !guides.isEmpty else { return }
        NSColor.systemPink.setStroke()
        for guide in guides {
            let path = NSBezierPath()
            path.lineWidth = 1
            let position = guide.position * side
            let from = (guide.extent?.lowerBound ?? 0) * side
            let to = (guide.extent?.upperBound ?? 1) * side
            guard guide.tilt != 0 else {
                switch guide.axis {
                case .vertical:
                    path.move(to: NSPoint(x: position, y: from))
                    path.line(to: NSPoint(x: position, y: to))
                case .horizontal:
                    path.move(to: NSPoint(x: from, y: position))
                    path.line(to: NSPoint(x: to, y: position))
                }
                path.stroke()
                continue
            }
            // A turned line through the middle of its extent, across the rectangle it is in.
            let middle = (from + to) / 2
            let center = guide.axis == .vertical ? NSPoint(x: position, y: middle) : NSPoint(x: middle, y: position)
            // Counterclockwise on screen, with the y axis pointing down.
            let tilt = guide.tilt
            let direction = guide.axis == .vertical
                ? CGVector(dx: sin(tilt), dy: cos(tilt)) : CGVector(dx: cos(tilt), dy: -sin(tilt))
            let length = hypot(target.width, target.height)
            path.move(to: NSPoint(x: center.x - direction.dx * length, y: center.y - direction.dy * length))
            path.line(to: NSPoint(x: center.x + direction.dx * length, y: center.y + direction.dy * length))
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: target).addClip()
            path.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

/// The rectangle the picture is in and its handles, drawn over the folder: a thin line just
/// outside the picture, so none of it is hidden, and small handles. While something changes,
/// only the line shows, faintly; while the picture turns, by how much.
private final class FrameView: NSView {
    struct Look: Equatable {
        /// The rectangle, in the editor's coordinates.
        var frame: CGRect
        var showsHandles: Bool
        /// The handle under the pointer, a little bigger.
        var hovered: ResizeHandle?
        /// The pointer is on the rectangle, or it is being moved.
        var isHighlighted: Bool
        var isFaint: Bool
        /// How far the picture is turned, while it is being turned.
        var turn: String?
    }

    var look: Look? {
        didSet { if look != oldValue { needsDisplay = true } }
    }

    override var isFlipped: Bool { true }

    /// The editor below takes the mouse.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let look else { return }
        let frame = look.frame
        let line: CGFloat = 1
        NSGraphicsContext.saveGraphicsState()
        // Outside the picture only, rim and all: none of its pixels change.
        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: frame))
        outside.windingRule = .evenOdd
        outside.addClip()
        // A dark rim around the line keeps it in sight on light pictures.
        let rim = NSShadow()
        rim.shadowColor = NSColor.black.withAlphaComponent(look.isFaint ? 0.25 : 0.5)
        rim.shadowBlurRadius = 1.5
        rim.set()
        NSColor.white.withAlphaComponent(look.isFaint ? 0.55 : look.isHighlighted ? 1 : 0.85).setStroke()
        let outline = NSBezierPath(rect: frame.insetBy(dx: -line / 2, dy: -line / 2))
        outline.lineWidth = line
        outline.stroke()
        NSGraphicsContext.restoreGraphicsState()

        if look.showsHandles {
            NSGraphicsContext.saveGraphicsState()
            let lift = NSShadow()
            lift.shadowColor = NSColor.black.withAlphaComponent(0.35)
            lift.shadowBlurRadius = 1.5
            lift.shadowOffset = NSSize(width: 0, height: -0.5)
            lift.set()
            NSColor.white.setFill()
            for handle in ResizeHandle.allCases {
                let center = handle.position(in: frame)
                let radius: CGFloat = handle == look.hovered ? 4.5 : 3.5
                NSBezierPath(ovalIn: NSRect(x: center.x - radius, y: center.y - radius, width: 2 * radius, height: 2 * radius)).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }

        if let turn = look.turn {
            drawLabel(turn, near: frame)
        }
    }

    /// A small label above the rectangle, or inside its top when there is no room above.
    private func drawLabel(_ text: String, near frame: CGRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.white,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let size = string.size()
        let pill = CGSize(width: size.width + 12, height: size.height + 4)
        let near = bounds.intersection(frame.insetBy(dx: -40, dy: -40))
        let visible = near.isNull ? bounds : near
        var origin = CGPoint(x: frame.midX - pill.width / 2, y: frame.minY - pill.height - 8)
        if origin.y < bounds.minY + 2 { origin.y = max(frame.minY, bounds.minY) + 8 }
        origin.x = min(max(origin.x, visible.minX + 2), visible.maxX - pill.width - 2)
        let rect = CGRect(origin: origin, size: pill)
        NSColor.black.withAlphaComponent(0.7).setFill()
        NSBezierPath(roundedRect: rect, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        string.draw(at: CGPoint(x: rect.minX + 6, y: rect.minY + 2))
    }
}

/// The pointer just outside a corner of the rectangle: a curved arrow around the corner,
/// which says the picture turns.
private enum TurnCursor {
    private static var cursors: [ResizeHandle: NSCursor] = [:]

    static func cursor(for corner: ResizeHandle) -> NSCursor {
        if let cursor = cursors[corner] { return cursor }
        let turns: CGFloat = switch corner {
        case .topRight: 0
        case .topLeft: 1
        case .bottomLeft: 2
        default: 3
        }
        let size = NSSize(width: 24, height: 24)
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: turns * .pi / 2)
            // An arc bowing out to the top right, with an arrowhead at each end.
            let arc = CGMutablePath()
            let center = CGPoint(x: -5, y: -5), radius: CGFloat = 12
            arc.addArc(center: center, radius: radius, startAngle: .pi * 0.08, endAngle: .pi * 0.42, clockwise: false)
            func head(at angle: CGFloat, pointing direction: CGFloat) -> CGPath {
                let tip = CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
                let along = CGVector(dx: -sin(angle) * direction, dy: cos(angle) * direction)
                let across = CGVector(dx: cos(angle), dy: sin(angle))
                let path = CGMutablePath()
                path.move(to: CGPoint(x: tip.x + along.dx * 4.5, y: tip.y + along.dy * 4.5))
                path.addLine(to: CGPoint(x: tip.x + across.dx * 4, y: tip.y + across.dy * 4))
                path.addLine(to: CGPoint(x: tip.x - across.dx * 4, y: tip.y - across.dy * 4))
                path.closeSubpath()
                return path
            }
            let heads = [head(at: .pi * 0.08, pointing: -1), head(at: .pi * 0.42, pointing: 1)]
            // White first, wider, so the black arrow has a rim on any background.
            for (color, width) in [(NSColor.white.cgColor, CGFloat(4)), (NSColor.black.cgColor, CGFloat(1.6))] {
                context.setStrokeColor(color)
                context.setFillColor(color)
                context.setLineWidth(width)
                context.setLineJoin(.round)
                context.addPath(arc)
                context.strokePath()
                for path in heads {
                    context.addPath(path)
                    context.drawPath(using: width > 2 ? .fillStroke : .fill)
                }
            }
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: size.width / 2, y: size.height / 2))
        cursors[corner] = cursor
        return cursor
    }
}

/// The eight resize handles and how each one moves the rectangle's edges.
enum ResizeHandle: CaseIterable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    static let corners: [ResizeHandle] = [.topLeft, .topRight, .bottomRight, .bottomLeft]

    var isCorner: Bool { Self.corners.contains(self) }

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

    /// Which way is away from the rectangle, from this handle: −1, 0 or 1 on each axis, with
    /// the y axis pointing down.
    var outward: CGPoint {
        CGPoint(x: movesLeft ? -1 : movesRight ? 1 : 0, y: movesTop ? -1 : movesBottom ? 1 : 0)
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

    /// Moves the edges this handle owns. Never lets the rectangle flip, go below the smallest
    /// size or above the largest, or go where a style can't be (see `IconStyle.origins`).
    /// `keepRatio` keeps its proportions (corners only); `fromCenter` moves the opposite edges
    /// too, so the middle stays put.
    func resize(_ rect: CGRect, dx: Double, dy: Double, keepRatio: Bool, fromCenter: Bool) -> CGRect {
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

/// Pictures for the editor: small enough to stay quick, sharp enough for its size.
enum PreviewPicture {
    /// The longer side of a picture in the editor: as big as the ones icons are made from, so a
    /// picture made several times as big as the folder stays sharp there too.
    nonisolated static let maxSide = 2048

    /// Always a bitmap: vectors are rasterized at full size, so tiny SVGs stay sharp too.
    /// Reads and decodes the file, so better not on the main thread.
    nonisolated static func load(_ url: URL) -> SourceImage? {
        guard let picture = try? ImageLoader.load(contentsOf: url),
              let bitmap = picture.bitmap(maxSide: maxSide)
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

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
