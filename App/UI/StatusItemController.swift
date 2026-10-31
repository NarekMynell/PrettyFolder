import AppKit
import Observation

/// The menu bar icon. Optional: it can be hidden in Settings.
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
            item.button?.image = NSImage(systemSymbolName: "photo.on.rectangle.angled", accessibilityDescription: "PrettyFolder")
            item.button?.toolTip = "PrettyFolder"
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            self.item = item
        } else if !settings.showsMenuBarIcon, let item {
            NSStatusBar.system.removeStatusItem(item)
            self.item = nil
        }
    }

    // Rebuilt every time it opens, so the setup items reflect the current state.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let finderExtension = FinderExtensionStatus.shared
        let permission = AccessibilityPermission.shared
        finderExtension.refresh()
        permission.refresh()

        if !finderExtension.isEnabled {
            menu.addItem(MenuActionItem.make(title: String(localized: "Turn On the Finder Menu…"), handler: { finderExtension.enable() }))
        }
        if !permission.isGranted {
            menu.addItem(MenuActionItem.make(title: String(localized: "Allow Accessibility for Drag and Tab…"), handler: { permission.request() }))
        }
        if menu.numberOfItems > 0 { menu.addItem(.separator()) }

        menu.addItem(MenuActionItem.make(title: String(localized: "Settings…"), keyEquivalent: ",") { [weak self] in self?.actions.showSettings() })
        menu.addItem(MenuActionItem.make(title: String(localized: "Welcome & How to Use")) { [weak self] in self?.actions.showWelcome() })
        menu.addItem(.separator())
        menu.addItem(MenuActionItem.make(title: String(localized: "Quit PrettyFolder"), keyEquivalent: "q") { NSApp.terminate(nil) })
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
