import Cocoa
import FinderSync
import PrettyFolderIPC
import UniformTypeIdentifiers
import os

/// Adds Folder Picture… to Finder's right-click menu and to its optional toolbar button.
///
/// The extension is sandboxed and never touches folders itself: it tells the app which
/// folders were clicked, and the app does the work.
///
/// `FIFinderSync` is not tied to an actor and Finder calls it on background queues, so
/// this class isn't either; the few AppKit calls are explicitly made on the main thread.
nonisolated final class FinderSync: FIFinderSync, @unchecked Sendable {
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "FinderExtension")
    private static let appIdentifier = "com.narekmynell.PrettyFolder"

    override init() {
        super.init()
        // Every folder on every disk. Without badges this costs Finder nothing.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    // MARK: - Toolbar button (optional: View › Customize Toolbar…)

    override var toolbarItemName: String { "PrettyFolder" }

    override var toolbarItemToolTip: String {
        String(localized: "Folder pictures")
    }

    override var toolbarItemImage: NSImage {
        NSImage(systemSymbolName: "photo.on.rectangle", accessibilityDescription: "PrettyFolder") ?? NSImage()
    }

    // MARK: - Menus

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        let folders = targets(for: menuKind)
        return onMain { self.buildMenu(for: menuKind, folders: folders) }
    }

    @MainActor
    private func buildMenu(for menuKind: FIMenuKind, folders: [URL]) -> NSMenu? {
        let tag = menuKind.rawValue
        let menu = NSMenu(title: "")
        if !folders.isEmpty {
            // One item; the window it opens has everything else.
            menu.addItem(item(String(localized: "Folder Picture…"), #selector(openFolders(_:)), symbol: "photo.on.rectangle.angled", tag: tag))
        } else if menuKind == .toolbarItemMenu {
            // The toolbar button with nothing to work on still opens the window.
            menu.addItem(item(String(localized: "PrettyFolder Settings…"), #selector(openSettings(_:)), symbol: "gearshape", tag: tag))
        } else {
            return nil
        }
        return menu
    }

    // Finder Sync delivers menu actions on its own XPC queue, not the main thread,
    // with a copy of the menu item; only its tag is read, through plain KVC.
    @objc private func openFolders(_ sender: Any?) { send(.adjust, menuTag: Self.tag(of: sender)) }
    @objc private func openSettings(_ sender: Any?) { send(.settings, menuTag: Self.tag(of: sender)) }

    private static func tag(of sender: Any?) -> Int {
        ((sender as? NSObject)?.value(forKey: "tag") as? NSNumber)?.intValue ?? -1
    }

    // MARK: - Talking to the app

    private func send(_ action: FolderCommand.Action, menuTag: Int) {
        // The tag remembers which kind of menu the item came from.
        let kind = menuTag >= 0 ? FIMenuKind(rawValue: UInt(menuTag)) ?? .contextualMenuForItems : .contextualMenuForItems
        let folders = action.needsFolders ? targets(for: kind) : []
        guard !action.needsFolders || !folders.isEmpty else { return }
        let command = FolderCommand(action, folders: folders)
        log.info("Asking the app to \(action.rawValue, privacy: .public) \(folders.count) folder(s)")

        // The app sits three levels up: PrettyFolder.app/Contents/PlugIns/<this>.appex
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        // Finder is in front; let the app come forward with its window.
        onMain { NSApplication.shared.yieldActivation(toApplicationWithBundleIdentifier: Self.appIdentifier) }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([command.url], withApplicationAt: appURL, configuration: configuration) { [log] _, error in
            if let error {
                log.error("Could not reach the app: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// The folders a menu is about. Files, apps and other packages are left out.
    private func targets(for kind: FIMenuKind) -> [URL] {
        let controller = FIFinderSyncController.default()
        let selected = controller.selectedItemURLs() ?? []
        let candidates: [URL]
        switch kind {
        case .contextualMenuForItems, .contextualMenuForSidebar:
            candidates = selected
        case .contextualMenuForContainer:
            candidates = controller.targetedURL().map { [$0] } ?? []
        case .toolbarItemMenu:
            candidates = selected.isEmpty ? (controller.targetedURL().map { [$0] } ?? []) : selected
        @unknown default:
            candidates = []
        }
        return candidates.filter(Self.isPlainFolder)
    }

    /// Decided from the URL alone: the extension can't (and shouldn't) look at the disk.
    private static func isPlainFolder(_ url: URL) -> Bool {
        guard url.isFileURL, url.hasDirectoryPath, url.path != "/" else { return false }
        let ext = url.pathExtension
        if !ext.isEmpty, let type = UTType(filenameExtension: ext, conformingTo: .directory), type.conforms(to: .package) {
            return false
        }
        // Volume roots ("/Volumes/Disk") are disks, not folders.
        return !(url.path.hasPrefix("/Volumes/") && url.pathComponents.count <= 3)
    }

    @MainActor
    private func item(_ title: String, _ action: Selector, symbol: String, tag: UInt) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = Int(tag)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        return item
    }

    /// Runs AppKit work (building menus) on the main thread.
    private func onMain<T>(_ work: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { MainThreadResult(value: work()) }.value
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { MainThreadResult(value: work()) } }.value
    }
}

/// Carries a value made on the main thread back to the caller, which only reads it.
nonisolated private struct MainThreadResult<T>: @unchecked Sendable {
    let value: T
}
