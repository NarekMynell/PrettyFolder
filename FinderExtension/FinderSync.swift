import Cocoa
import FinderSync
import PrettyFolderIPC
import UniformTypeIdentifiers
import os

/// Adds the folder picture items to Finder's right-click menu and toolbar button.
///
/// The extension is sandboxed and never touches folders itself: it tells the app which
/// folders were clicked, and the app does the work.
///
/// `FIFinderSync` itself is not tied to an actor, so neither is this class; Finder calls
/// it on the main thread, and the few AppKit calls are explicitly made there.
nonisolated final class FinderSync: FIFinderSync, @unchecked Sendable {
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "FinderExtension")

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
        let menu = NSMenu(title: "")
        let tag = menuKind.rawValue

        guard !folders.isEmpty else {
            // The toolbar button with nothing selected still offers the settings.
            guard menuKind == .toolbarItemMenu else { return nil }
            menu.addItem(item(String(localized: "PrettyFolder Settings…"), #selector(openSettings(_:)), symbol: "gearshape", tag: tag))
            return menu
        }

        let single = folders.count == 1
        menu.addItem(item(
            single ? String(localized: "Choose Folder Picture…") : String(localized: "Choose Picture for \(folders.count) Folders…"),
            #selector(choosePicture(_:)), symbol: "photo.badge.plus", tag: tag
        ))
        menu.addItem(item(
            single ? String(localized: "Remove Folder Picture") : String(localized: "Remove Pictures from \(folders.count) Folders"),
            #selector(removePicture(_:)), symbol: "xmark.circle", tag: tag
        ))

        let options = NSMenu(title: "")
        if single {
            options.addItem(item(String(localized: "Adjust This Folder's Look…"), #selector(adjust(_:)), symbol: "crop", tag: tag))
        }
        options.addItem(item(String(localized: "Default Look & Settings…"), #selector(openSettings(_:)), symbol: "gearshape", tag: tag))
        let optionsItem = NSMenuItem(title: String(localized: "Folder Picture Options"), action: nil, keyEquivalent: "")
        optionsItem.image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: nil)
        optionsItem.submenu = options
        menu.addItem(optionsItem)
        return menu
    }

    // Menu actions arrive on the main thread, like any menu item's.
    @MainActor @objc private func choosePicture(_ sender: NSMenuItem) { send(.chooseImage, menuTag: sender.tag) }
    @MainActor @objc private func removePicture(_ sender: NSMenuItem) { send(.removeImage, menuTag: sender.tag) }
    @MainActor @objc private func adjust(_ sender: NSMenuItem) { send(.adjust, menuTag: sender.tag) }
    @MainActor @objc private func openSettings(_ sender: NSMenuItem) { send(.settings, menuTag: sender.tag) }

    // MARK: - Talking to the app

    private func send(_ action: FolderCommand.Action, menuTag: Int) {
        // The tag remembers which kind of menu the item came from.
        let kind = FIMenuKind(rawValue: UInt(max(menuTag, 0))) ?? .contextualMenuForItems
        let folders = action.needsFolders ? targets(for: kind) : []
        guard !action.needsFolders || !folders.isEmpty else { return }
        let command = FolderCommand(action, folders: folders)

        // The app sits three levels up: PrettyFolder.app/Contents/PlugIns/<this>.appex
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let configuration = NSWorkspace.OpenConfiguration()
        // Removing is instant and needs no window; everything else shows one.
        configuration.activates = action != .removeImage
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

    /// Runs AppKit work on the main thread, where Finder normally calls us anyway.
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
