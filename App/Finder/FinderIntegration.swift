import AppKit
import Observation

/// Turns the two in-Finder helpers (drop badge, tab button) on and off as settings and
/// the Accessibility permission change.
final class FinderIntegration {
    private let settings: AppSettings
    private let permission = AccessibilityPermission.shared
    private let finder = FinderProcess()
    private let accessibility = FinderAccessibility()
    private let dropBadge = DropBadgeController()
    private let tabBadge = TabBadgeController()
    private lazy var dragWatcher = DragWatcher(finder: finder, accessibility: accessibility, badge: dropBadge)
    private lazy var tabWatcher = TabWatcher(finder: finder, accessibility: accessibility, badge: tabBadge)

    init(actions: FolderActions, settings: AppSettings) {
        self.settings = settings
        dropBadge.onDrop = { [weak actions] picture, folder in
            await actions?.apply(picture, to: folder) ?? false
        }
        tabBadge.onAction = { [weak actions] action, folder in
            guard let actions else { return }
            switch action {
            case .choose: actions.chooseImage(for: [folder])
            case .remove: actions.removeImage(from: [folder])
            case .adjust: actions.adjust(folder)
            case .settings: actions.showSettings()
            }
        }
    }

    func start() {
        apply()
        observe()
    }

    private func apply() {
        let allowed = permission.isGranted
        if allowed && settings.showsDropTarget { dragWatcher.start() } else { dragWatcher.stop() }
        if allowed && settings.opensPickerFromTab { tabWatcher.start() } else { tabWatcher.stop() }
    }

    private func observe() {
        withObservationTracking {
            _ = permission.isGranted
            _ = settings.showsDropTarget
            _ = settings.opensPickerFromTab
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.apply()
                self?.observe()
            }
        }
    }
}
