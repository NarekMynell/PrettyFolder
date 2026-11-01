import AppKit
import Observation
import PrettyFolderKit
import os

/// Turns the two in-Finder helpers (the drop badge and the buttons on folders) on and off
/// as settings and the Accessibility permission change.
final class FinderIntegration {
    private let settings: AppSettings
    private let permission = AccessibilityPermission.shared
    private let finder = FinderProcess()
    private let accessibility = FinderAccessibility()
    private let dropBadge = DropBadgeController()
    private let hoverButtons = HoverButtonsController()
    private lazy var dragWatcher = DragWatcher(finder: finder, accessibility: accessibility, badge: dropBadge)
    private lazy var hoverWatcher = HoverWatcher(finder: finder, accessibility: accessibility, buttons: hoverButtons)
    private lazy var iconCover = IconCover(finder: finder, accessibility: accessibility)
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Finder")

    init(actions: FolderActions, settings: AppSettings) {
        self.settings = settings
        dropBadge.onDrop = { [weak actions] picture, folder in
            await actions?.apply(picture, to: folder) ?? false
        }
        hoverButtons.onAction = { [weak self, weak actions] action, folder in
            // Only for the folder that is still under the buttons.
            self?.hoverWatcher.confirm(folder) {
                guard let actions else { return }
                switch action {
                case .choose: actions.chooseImage(for: [folder])
                case .remove: actions.removeImage(from: [folder])
                case .settings: actions.showEditor(for: [folder])
                }
            }
        }
    }

    func start() {
        apply()
        observe()
    }

    /// Shows the folder's new icon over its icon in Finder while Finder loads it (see `IconCover`).
    func cover(_ folder: URL, with icon: RenderedIcon) async {
        await iconCover.cover(folder, with: icon)
    }

    func uncover(_ folder: URL) {
        iconCover.uncover(folder)
    }

    private func apply() {
        let allowed = permission.isGranted
        log.debug("Accessibility granted: \(allowed); drop badge \(self.settings.showsDropTarget), buttons on folders \(self.settings.showsHoverButtons)")
        if allowed && settings.showsDropTarget { dragWatcher.start() } else { dragWatcher.stop() }
        if allowed && settings.showsHoverButtons { hoverWatcher.start() } else { hoverWatcher.stop() }
    }

    private func observe() {
        withObservationTracking {
            _ = permission.isGranted
            _ = settings.showsDropTarget
            _ = settings.showsHoverButtons
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observe()
            }
        }
    }
}
