import AppKit
import PrettyFolderKit

/// Small buttons along the top of a folder's icon while the pointer is over it: choose a
/// picture, remove it, and open the folder in PrettyFolder's window.
///
/// They sit in a little window of their own above Finder, so a click on them never
/// reaches Finder, and everything else about the folder (selecting it, opening it,
/// dragging it) works as always.
final class HoverButtonsController {
    enum Action: CaseIterable {
        case choose, remove, settings

        var symbol: String {
            switch self {
            case .choose: "photo.badge.plus"
            case .remove: "trash"
            case .settings: "slider.horizontal.3"
            }
        }

        var title: String {
            switch self {
            case .choose: String(localized: "Choose a Picture")
            case .remove: String(localized: "Remove the Picture")
            case .settings: String(localized: "Picture Settings")
            }
        }
    }

    var onAction: ((Action, URL) -> Void)?
    /// The pointer left the buttons; whoever shows them decides whether they stay.
    var onExit: (() -> Void)?

    private let panel = OverlayPanel()
    private let bar = HoverBarView()
    private(set) var folder: URL?

    init() {
        panel.contentView = bar
        // The system draws the shadow, outside the panel, so it never catches a click
        // meant for the folder around the buttons.
        panel.hasShadow = true
        bar.onAction = { [weak self] action in self?.perform(action) }
        bar.onExit = { [weak self] in self?.onExit?() }
    }

    var isVisible: Bool { panel.isVisible && folder != nil }

    /// Whether `point` (AppKit screen coordinates) is over the buttons.
    func contains(_ point: NSPoint) -> Bool {
        isVisible && panel.frame.contains(point)
    }

    /// Shows the buttons on `item`'s icon; the remove button only when there is a picture.
    func show(for item: FinderItem, canRemove: Bool) {
        let actions: [Action] = canRemove ? [.choose, .remove, .settings] : [.choose, .settings]
        let icon = ScreenSpace.appKitRect(item.iconFrame)
        let layout = HoverBarView.Layout(icon: icon, buttonCount: actions.count)
        let screen = ScreenSpace.visibleFrame(containing: icon)
        var frame = layout.barFrame
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)

        folder = item.url
        bar.configure(actions: actions, layout: layout)
        if panel.frame != frame {
            panel.setFrame(frame, display: true)
            panel.invalidateShadow()
        }
        guard !panel.isVisible else { return }
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        folder = nil
        bar.reset()
        panel.orderOut(nil)
    }

    private func perform(_ action: Action) {
        guard let folder else { return }
        hide()
        onAction?(action, folder)
    }
}

/// The dark capsule with the buttons in it.
final class HoverBarView: NSView {
    /// Where the capsule and its buttons go on a folder icon.
    struct Layout: Equatable {
        let buttonSize: CGFloat
        let spacing: CGFloat
        let padding: CGFloat
        /// The capsule itself, in screen coordinates.
        let barFrame: NSRect

        init(icon: NSRect, buttonCount: Int) {
            buttonSize = min(max((icon.width * 0.18).rounded(), 20), 26)
            spacing = (buttonSize * 0.12).rounded()
            padding = (buttonSize * 0.14).rounded()
            let width = CGFloat(buttonCount) * buttonSize + CGFloat(max(buttonCount - 1, 0)) * spacing + 2 * padding
            let height = buttonSize + 2 * padding
            // Over the folder's tab: the top of the folder, clear of where pictures usually go.
            let centerFromTop = max(height / 2 + 1, icon.height * FolderArtwork.shape.tab.midY)
            barFrame = NSRect(x: (icon.midX - width / 2).rounded(), y: (icon.maxY - centerFromTop - height / 2).rounded(), width: width, height: height)
        }
    }

    var onAction: ((HoverButtonsController.Action) -> Void)?
    var onExit: (() -> Void)?
    private var buttons: [HoverButtonView] = []
    private var layout: Layout?

    override var isFlipped: Bool { true }

    func configure(actions: [HoverButtonsController.Action], layout: Layout) {
        if buttons.map(\.action) != actions {
            buttons.forEach { $0.removeFromSuperview() }
            buttons = actions.map { action in
                let button = HoverButtonView(action: action)
                button.onClick = { [weak self] in self?.onAction?(action) }
                addSubview(button)
                return button
            }
        }
        guard layout != self.layout else { return }
        self.layout = layout
        for (index, button) in buttons.enumerated() {
            button.frame = NSRect(
                x: layout.padding + CGFloat(index) * (layout.buttonSize + layout.spacing),
                y: layout.padding,
                width: layout.buttonSize,
                height: layout.buttonSize
            )
        }
        needsDisplay = true
    }

    /// Forgets hover and pressed states, so the buttons look fresh next time.
    func reset() {
        buttons.forEach { $0.reset() }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseExited(with event: NSEvent) {
        onExit?()
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor(white: 0.1, alpha: 0.78).setFill()
        capsule.fill()

        let edge = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2 - 0.5, yRadius: rect.height / 2 - 0.5)
        edge.lineWidth = 1
        NSColor(white: 1, alpha: 0.16).setStroke()
        edge.stroke()
    }
}

/// One round button: a white symbol that lights up under the pointer.
private final class HoverButtonView: NSView {
    let action: HoverButtonsController.Action
    var onClick: (() -> Void)?

    private var isHovered = false {
        didSet { if isHovered != oldValue { needsDisplay = true } }
    }
    // A click is a press and a release on the button, like any button: pressing and
    // dragging away does nothing.
    private var isPressed = false {
        didSet { if isPressed != oldValue { needsDisplay = true } }
    }

    init(action: HoverButtonsController.Action) {
        self.action = action
        super.init(frame: .zero)
        toolTip = action.title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(action.title)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func reset() {
        isHovered = false
        isPressed = false
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
    }

    override func mouseDragged(with event: NSEvent) {
        isPressed = bounds.contains(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        let clicked = isPressed && bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        if clicked { onClick?() }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    #if DEBUG
    /// For the README media, which can't move the real pointer.
    func showHighlight(hovered: Bool, pressed: Bool) {
        isHovered = hovered
        isPressed = pressed
    }
    #endif

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isPressed {
            let fill: NSColor = action == .remove
                ? .systemRed.withAlphaComponent(isPressed ? 1 : 0.88)
                : NSColor(white: 1, alpha: isPressed ? 0.34 : 0.2)
            fill.setFill()
            NSBezierPath(ovalIn: bounds).fill()
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: (bounds.height * 0.46).rounded(), weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: action.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = symbol.size
        let rect = NSRect(x: (bounds.midX - size.width / 2).rounded(), y: (bounds.midY - size.height / 2).rounded(), width: size.width, height: size.height)
        symbol.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

#if DEBUG
extension HoverBarView {
    /// For the README media: draws one button as if the pointer were on it.
    func highlight(_ action: HoverButtonsController.Action?, pressed: Bool = false) {
        for case let button as HoverButtonView in subviews {
            button.showHighlight(hovered: button.action == action, pressed: pressed && button.action == action)
        }
    }
}
#endif
