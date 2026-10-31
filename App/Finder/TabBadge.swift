import AppKit
import PrettyFolderKit
import SwiftUI

/// A small button that covers a folder's tab while the pointer rests on it.
/// Click: choose a picture. Option-click: remove the picture. Right-click: more.
///
/// The click lands on this button instead of Finder, so Finder never sees a click it
/// would have to interpret (no accidental selection, no double-click confusion).
final class TabBadgeController {
    enum Action { case choose, remove, adjust, settings }

    var onAction: ((Action, URL) -> Void)?

    private let panel = OverlayPanel()
    private let buttonView = TabButtonView()
    private(set) var folder: URL?

    init() {
        panel.contentView = buttonView
        buttonView.onClick = { [weak self] event in self?.clicked(event) }
        buttonView.onExit = { [weak self] in self?.hide() }
    }

    var isVisible: Bool { panel.isVisible }

    func contains(_ point: NSPoint) -> Bool {
        panel.isVisible && panel.frame.insetBy(dx: -2, dy: -2).contains(point)
    }

    /// The area of `item`'s icon that counts as the tab, in AppKit screen coordinates.
    static func tabZone(for item: FinderItem) -> NSRect {
        let icon = ScreenSpace.appKitRect(item.iconFrame)
        let tab = FolderArtwork.tabRegion
        let zone = NSRect(
            x: icon.minX + tab.minX * icon.width,
            y: icon.maxY - tab.maxY * icon.height,
            width: tab.width * icon.width,
            height: tab.height * icon.height
        )
        // A little slack: the tab is a thin strip, especially on small icons.
        return zone.insetBy(dx: -3, dy: -3)
    }

    func show(for item: FinderItem) {
        let zone = Self.tabZone(for: item)
        let height = min(max(item.iconFrame.height * 0.2, 16), 26)
        let width = max(zone.width - 2, height * 1.8)
        let frame = NSRect(x: zone.midX - width / 2, y: zone.midY - height / 2, width: width, height: height)
        folder = item.url
        buttonView.symbolSize = height * 0.62
        panel.setFrame(frame, display: true)
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                panel.animator().alphaValue = 1
            }
        }
        NSCursor.pointingHand.set()
    }

    func hide() {
        guard panel.isVisible else { return }
        folder = nil
        panel.orderOut(nil)
    }

    private func clicked(_ event: NSEvent) {
        guard let folder else { return }
        if event.type == .rightMouseDown || event.modifierFlags.contains(.control) {
            showMenu(for: folder, event: event)
            return
        }
        hide()
        onAction?(event.modifierFlags.contains(.option) ? .remove : .choose, folder)
    }

    private func showMenu(for folder: URL, event: NSEvent) {
        let menu = NSMenu()
        let entries: [(String, Action)] = [
            (String(localized: "Choose Picture…"), .choose),
            (String(localized: "Remove Picture"), .remove),
            (String(localized: "Adjust Picture…"), .adjust),
            (String(localized: "PrettyFolder Settings…"), .settings),
        ]
        for (index, entry) in entries.enumerated() {
            if index == 2 { menu.addItem(.separator()) }
            menu.addItem(MenuActionItem.make(title: entry.0) { [weak self] in
                self?.onAction?(entry.1, folder)
            })
        }
        NSMenu.popUpContextMenu(menu, with: event, for: buttonView)
        hide()
    }
}

/// The badge itself: a tinted capsule with a picture symbol.
private final class TabButtonView: NSView {
    var onClick: ((NSEvent) -> Void)?
    var onExit: (() -> Void)?
    var symbolSize: CGFloat = 11 {
        didSet { if symbolSize != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "Choose Folder Picture"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.pointingHand.set() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseDown(with event: NSEvent) { onClick?(event) }
    override func rightMouseDown(with event: NSEvent) { onClick?(event) }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let capsule = NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2)
        NSColor.controlAccentColor.withAlphaComponent(0.95).setFill()
        capsule.fill()
        NSColor.white.withAlphaComponent(0.55).setStroke()
        capsule.lineWidth = 1
        capsule.stroke()

        let configuration = NSImage.SymbolConfiguration(pointSize: symbolSize, weight: .bold)
            .applying(.init(paletteColors: [.white]))
        guard let symbol = NSImage(systemSymbolName: "photo.badge.plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return }
        let size = symbol.size
        symbol.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
    }
}

/// Menu items that run a closure, so small menus need no target objects.
enum MenuActionItem {
    static func make(title: String, keyEquivalent: String = "", handler: @escaping () -> Void) -> NSMenuItem {
        let target = ClosureTarget(handler)
        let item = NSMenuItem(title: title, action: #selector(ClosureTarget.run(_:)), keyEquivalent: keyEquivalent)
        item.target = target
        // `target` is weak; the represented object keeps the closure alive with the item.
        item.representedObject = target
        return item
    }
}

/// An Objective-C target that calls a closure.
final class ClosureTarget: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    @objc func run(_ sender: Any?) {
        handler()
    }
}
