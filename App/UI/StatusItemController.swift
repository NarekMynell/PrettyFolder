import AppKit
import Observation
import PrettyFolderKit

/// The menu bar icon. Optional: it can be hidden in the settings.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let actions: FolderActions
    private let settings: AppSettings
    private var item: NSStatusItem?

    init(actions: FolderActions, settings: AppSettings) {
        self.actions = actions
        self.settings = settings
        super.init()
        update()
        observe()
    }

    private func observe() {
        withObservationTracking {
            _ = settings.showsMenuBarIcon
            _ = UpdateChecker.shared.newer
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.update()
                self?.observe()
            }
        }
    }

    private func update() {
        if settings.showsMenuBarIcon, item == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !settings.showsMenuBarIcon, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
        if let button = item?.button {
            let newer = UpdateChecker.shared.newer
            button.image = Self.icon(withDot: newer != nil)
            button.toolTip = newer.map { String(localized: "PrettyFolder \($0.description) is available") } ?? "PrettyFolder"
        }
    }

    /// The menu bar icon, with a dot in its corner when there's a newer version, the way macOS
    /// marks things that want a look.
    static func icon(withDot: Bool) -> NSImage? {
        guard let symbol = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "PrettyFolder") else { return nil }
        guard withDot else { return symbol }
        let side = 5.5
        let image = NSImage(size: symbol.size, flipped: false) { bounds in
            symbol.draw(in: bounds)
            let dot = NSRect(x: bounds.maxX - side, y: bounds.maxY - side, width: side, height: side)
            // A gap around the dot keeps it apart from the picture's lines.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -1.25, dy: -1.25)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.black.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = String(localized: "PrettyFolder, update available")
        return image
    }

    /// The menu is open, and what it offers to set up.
    private var isOpen = false
    private var offered: (finderMenu: Bool, accessibility: Bool)?

    // Rebuilt every time it opens, from what is known already: nothing here may wait for the
    // system. A menu that is opening has the keyboard of every app until it shows, and on
    // 2026-11-06 this one kept it for an hour, waiting in `isExtensionEnabled`. The answers asked
    // for here usually come while the menu is open, which then changes to show them; the app also
    // asks at launch, when it comes to the front and when the user leaves System Settings.
    func menuNeedsUpdate(_ menu: NSMenu) {
        MainThreadWatchdog.menuOpening()
        fill(menu)
        FinderExtensionStatus.shared.refresh { [weak self, weak menu] _ in self?.update(menu) }
        AccessibilityPermission.shared.refresh { [weak self, weak menu] _ in self?.update(menu) }
    }

    func menuWillOpen(_ menu: NSMenu) {
        isOpen = true
    }

    func menuDidClose(_ menu: NSMenu) {
        isOpen = false
        MainThreadWatchdog.menuClosed()
    }

    /// A newer answer came while the menu is open: it changes if that changes what it offers.
    private func update(_ menu: NSMenu?) {
        guard isOpen, let menu, offered.map({ $0 != Self.setUpOffers() }) ?? true else { return }
        fill(menu)
    }

    /// What there is to set up: the Finder menu, Accessibility.
    private static func setUpOffers() -> (finderMenu: Bool, accessibility: Bool) {
        (FinderExtensionStatus.shared.needsTurningOn, AccessibilityPermission.shared.isGranted == false)
    }

    private func fill(_ menu: NSMenu) {
        menu.removeAllItems()
        let finderExtension = FinderExtensionStatus.shared
        let permission = AccessibilityPermission.shared
        let offers = Self.setUpOffers()
        offered = offers

        if offers.finderMenu {
            menu.addItem(MenuActionItem.make(title: String(localized: "Turn On the Finder Menu…"), handler: { finderExtension.enable() }))
        }
        if offers.accessibility {
            menu.addItem(MenuActionItem.make(title: String(localized: "Allow Accessibility…"), handler: { permission.request() }))
        }
        if let newer = UpdateChecker.shared.newer {
            menu.addItem(MenuActionItem.make(title: String(localized: "Download PrettyFolder \(newer.description)…")) { UpdateChecker.shared.openReleasePage() })
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        menu.addItem(MenuActionItem.make(title: String(localized: "Settings…"), keyEquivalent: ",") { [weak self] in self?.actions.showEditor() })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem.make(title: String(localized: "Quit PrettyFolder"), keyEquivalent: "q") { AppDelegate.quit() })
    }
}

/// A main menu nobody sees (the app has no menu bar of its own) but that gives the
/// app's windows the usual keyboard shortcuts: ⌘W, ⌘Q, copy and paste.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: String(localized: "Quit PrettyFolder"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(submenu: appMenu, title: "PrettyFolder")

        let edit = NSMenu(title: String(localized: "Edit"))
        edit.addItem(withTitle: String(localized: "Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: String(localized: "Redo"), action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: String(localized: "Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: String(localized: "Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: String(localized: "Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: String(localized: "Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(submenu: edit, title: edit.title)

        // Makes the picture's frame in the window bigger or smaller. ⌘= as well as ⌘+, which
        // needs Shift on many keyboards. And turns the picture, with Preview's keys.
        let view = NSMenu(title: String(localized: "View"))
        view.addItem(withTitle: String(localized: "Zoom In"), action: #selector(StyleEditorView.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: String(localized: "Zoom In"), action: #selector(StyleEditorView.zoomIn(_:)), keyEquivalent: "=")
        // A keyboard layout whose Command key only knows the Latin lower row (Armenian Phonetic, for
        // one) sends ⌘+ as ⌘⇧=, which neither of those takes.
        view.addItem(withTitle: String(localized: "Zoom In"), action: #selector(StyleEditorView.zoomIn(_:)), keyEquivalent: "=")
            .keyEquivalentModifierMask = [.command, .shift]
        view.addItem(withTitle: String(localized: "Zoom Out"), action: #selector(StyleEditorView.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(.separator())
        view.addItem(withTitle: String(localized: "Rotate Left"), action: #selector(StyleEditorView.rotateLeft(_:)), keyEquivalent: "l")
        view.addItem(withTitle: String(localized: "Rotate Right"), action: #selector(StyleEditorView.rotateRight(_:)), keyEquivalent: "r")
        main.addItem(submenu: view, title: view.title)

        let window = NSMenu(title: String(localized: "Window"))
        window.addItem(withTitle: String(localized: "Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: String(localized: "Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(submenu: window, title: window.title)
        return main
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
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
