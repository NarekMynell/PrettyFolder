import AppKit

/// A borderless, transparent panel that floats over Finder without ever taking focus
/// away from it. Both on-screen badges (the drop target and the tab button) live in one.
final class OverlayPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        isExcludedFromWindowsMenu = true
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    // Never steal the keyboard from Finder.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
