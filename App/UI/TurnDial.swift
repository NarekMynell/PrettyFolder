import AppKit
import SwiftUI

/// Connects the dial to the editor above it, which does the turning: the dial makes the same
/// change, undo step, snapping and feedback as turning the picture on the folder itself.
@MainActor
final class TurnLink {
    weak var editor: StyleEditorView?
}

/// Turns the picture to any angle: a ruler below the folder that slides sideways under a fixed
/// needle, like a wheel under the picture. Drag it, scroll on it, or use the arrow keys; a
/// double-click puts the picture upright.
struct TurnDial: NSViewRepresentable {
    /// How far the picture is turned, counterclockwise.
    var degrees: Double
    var isEnabled: Bool
    let link: TurnLink

    func makeNSView(context: Context) -> TurnDialView {
        TurnDialView()
    }

    func updateNSView(_ view: TurnDialView, context: Context) {
        view.link = link
        view.update(degrees: degrees, isEnabled: isEnabled)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: TurnDialView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 240, height: TurnDialView.height)
    }
}

/// The dial's view. Its scale reads counterclockwise turns to the left of the needle, so
/// dragging it to the right turns the picture to the left, as a wheel below it would, and
/// the left arrow key does the same.
final class TurnDialView: NSView, NSMenuItemValidation {
    static let height: CGFloat = 40
    /// How far the ruler slides for a degree, in points.
    static let pointsPerDegree: CGFloat = 3
    /// How close a drag comes to upright or a quarter turn to stick to it, in degrees: four
    /// and a half points, about what the editor's snapping takes.
    static let reach = 1.5
    /// How far the pointer goes before a press becomes a drag.
    static let dragThreshold: CGFloat = 2

    var link: TurnLink?
    private(set) var degrees = 0.0
    private(set) var isEnabled = false
    /// The ruler is held.
    private(set) var isDragging = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 240, height: Self.height))
        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel(String(localized: "Turn"))
        setAccessibilityEnabled(false)
        setAccessibilityValue(StyleEditorView.turnText(0))
        toolTip = String(localized: "Drag to turn the picture to any angle. ⇧ turns it in steps of 15°. Double-click to make it upright.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func update(degrees: Double, isEnabled: Bool) {
        let enabledChanged = isEnabled != self.isEnabled
        guard degrees != self.degrees || enabledChanged else { return }
        let before = StyleEditorView.turnText(shownDegrees)
        self.degrees = degrees
        self.isEnabled = isEnabled
        needsDisplay = true
        setAccessibilityEnabled(isEnabled)
        let value = StyleEditorView.turnText(shownDegrees)
        setAccessibilityValue(value)
        if value != before { NSAccessibility.post(element: self, notification: .valueChanged) }
        if enabledChanged {
            window?.invalidateCursorRects(for: self)
            if !isEnabled, window?.firstResponder === self { window?.makeFirstResponder(nil) }
        }
    }

    /// What the dial reads: the picture's turn, or upright when there is nothing to turn.
    private var shownDegrees: Double { isEnabled ? degrees : 0 }

    private var editor: StyleEditorView? {
        guard isEnabled, let editor = link?.editor, editor.canTurn else { return nil }
        return editor
    }

    // MARK: - Mouse

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { false }

    override func resetCursorRects() {
        if isEnabled { addCursorRect(bounds, cursor: .openHand) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let editor else { return }
        window?.makeFirstResponder(self)
        if event.clickCount >= 2 {
            editor.turnUpright()
            return
        }
        let start = convert(event.locationInWindow, from: nil)
        var from = editor.turn
        var point = start
        var began = false

        func follow(_ modifiers: NSEvent.ModifierFlags) {
            let dx = point.x - start.x
            if !began {
                guard abs(dx) >= Self.dragThreshold, editor.beginDialTurn() else { return }
                from = editor.turn
                began = true
                isDragging = true
                NSCursor.closedHand.set()
            }
            // Whole degrees: the readout shows what the picture gets.
            let target = (from + Double(dx / Self.pointsPerDegree)).rounded()
            editor.dialTurn(to: target, modifiers: modifiers, reach: Self.reach)
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
                if began { follow(event.modifierFlags) }
            case .keyDown where event.charactersIgnoringModifiers == "\u{1b}":
                if began { editor.endDialTurn(restoring: true) }
                stop.pointee = true
            case .leftMouseUp:
                stop.pointee = true
            default:
                break
            }
        }
        if began { editor.endDialTurn(restoring: false) }
        isDragging = false
        window?.invalidateCursorRects(for: self)
        if bounds.contains(convert(window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)) {
            (isEnabled ? NSCursor.openHand : NSCursor.arrow).set()
        } else {
            NSCursor.arrow.set()
        }
    }

    /// Scrolling slides the ruler: sideways as the fingers go, or a degree for each step of
    /// a mouse's wheel, up turning the picture to the left.
    override func scrollWheel(with event: NSEvent) {
        guard let editor, event.momentumPhase.isEmpty else { return super.scrollWheel(with: event) }
        // Which way the fingers or the wheel went, whichever way scrolling is set to go.
        let inverted = event.isDirectionInvertedFromDevice
        let right = inverted ? event.scrollingDeltaX : -event.scrollingDeltaX
        let up = inverted ? -event.scrollingDeltaY : event.scrollingDeltaY
        let delta = abs(right) > abs(up) ? right : up
        let degrees = event.hasPreciseScrollingDeltas ? Double(delta / Self.pointsPerDegree) : Double(delta)
        editor.dialTurn(by: degrees)
    }

    // MARK: - Keyboard

    override var acceptsFirstResponder: Bool { isEnabled }

    override var canBecomeKeyView: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }

    /// The left arrow turns the picture a degree to the left, the right arrow to the right;
    /// with Shift, to the next multiple of 15°.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let way: Double? = switch event.specialKey {
        case .leftArrow: 1
        case .rightArrow: -1
        default: nil
        }
        guard let way, modifiers.isDisjoint(with: [.command, .control, .option]) else { return super.keyDown(with: event) }
        editor?.dialTurn(by: way, steps: modifiers.contains(.shift))
    }

    override var focusRingType: NSFocusRingType {
        get { NSApp.isFullKeyboardAccessEnabled ? .exterior : .none }
        set {}
    }

    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6).fill()
    }

    // ⌘Z and ⌘⇧Z go through the editor, which finishes a burst of turns first; so do ⌘+ and
    // ⌘−, which only the editor knows.
    @objc func undo(_ sender: Any?) { link?.editor?.undo(sender) }
    @objc func redo(_ sender: Any?) { link?.editor?.redo(sender) }
    @objc func zoomIn(_ sender: Any?) { link?.editor?.zoomIn(sender) }
    @objc func zoomOut(_ sender: Any?) { link?.editor?.zoomOut(sender) }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        link?.editor?.validateMenuItem(menuItem) ?? false
    }

    // MARK: - VoiceOver

    override func accessibilityPerformIncrement() -> Bool {
        guard let editor else { return false }
        editor.dialTurn(by: 1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard let editor else { return false }
        editor.dialTurn(by: -1)
        return true
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let shown = shownDegrees
        let opacity: CGFloat = isEnabled ? 1 : 0.35
        let middle = bounds.midX
        let rulerY: CGFloat = 27

        // The readout, over the needle.
        let text = NSAttributedString(string: StyleEditorView.turnText(shown), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor.withAlphaComponent(0.85 * opacity),
        ])
        let size = text.size()
        // The minus sign and the degree sign hang outside, so the number sits over the needle.
        let degreeSign = NSAttributedString(string: "°", attributes: text.attributes(at: 0, effectiveRange: nil)).size().width
        let minus = shown.rounded() < 0 ? NSAttributedString(string: "−", attributes: text.attributes(at: 0, effectiveRange: nil)).size().width : 0
        text.draw(at: CGPoint(x: (middle - (size.width - degreeSign - minus) / 2 - minus).rounded(), y: 0))

        // The ruler: a tick every 3°, a long one every 15°, a dot under upright and the
        // quarter turns. It fades out toward its ends.
        context.saveGState()
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        let reachInDegrees = Double(bounds.width / 2 / Self.pointsPerDegree) + 3
        let first = Int((shown - reachInDegrees).rounded(.down)), last = Int((shown + reachInDegrees).rounded(.up))
        for degree in first...last where degree % 3 == 0 {
            let x = middle - CGFloat(Double(degree) - shown) * Self.pointsPerDegree
            let long = degree % 15 == 0
            let height: CGFloat = long ? 14 : 7
            context.setFillColor(NSColor.labelColor.withAlphaComponent((long ? 0.55 : 0.25) * opacity).cgColor)
            context.fill(CGRect(x: x - 0.5, y: rulerY - height / 2, width: 1, height: height))
            if degree % 90 == 0 {
                context.setFillColor(NSColor.labelColor.withAlphaComponent(0.45 * opacity).cgColor)
                context.fillEllipse(in: CGRect(x: x - 1.5, y: rulerY + 9.5, width: 3, height: 3))
            }
        }
        context.setBlendMode(.destinationIn)
        let fade = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceGray(),
            colors: [CGColor(gray: 0, alpha: 0), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 1), CGColor(gray: 0, alpha: 0)] as CFArray,
            locations: [0, 0.28, 0.72, 1]
        )!
        context.drawLinearGradient(fade, start: CGPoint(x: bounds.minX, y: 0), end: CGPoint(x: bounds.maxX, y: 0), options: [])
        context.endTransparencyLayer()
        context.restoreGState()

        // The needle.
        let needle = CGRect(x: middle - 1, y: rulerY - 11, width: 2, height: 22)
        context.setFillColor(NSColor.controlAccentColor.withAlphaComponent(opacity).cgColor)
        context.addPath(CGPath(roundedRect: needle, cornerWidth: 1, cornerHeight: 1, transform: nil))
        context.fillPath()
    }
}
