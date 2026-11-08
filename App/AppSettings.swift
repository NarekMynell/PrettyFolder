import Foundation
import Observation
import PrettyFolderKit

/// User preferences, stored in the app's defaults.
@Observable
final class AppSettings {
    static let shared = AppSettings()

    private enum Key {
        static let defaultStyle = "DefaultStyle"
        static let showsDropTarget = "ShowsDropTarget"
        static let showsHoverButtons = "ShowsHoverButtons"
        /// What the hover buttons' setting was called when there was a single tab button.
        static let opensPickerFromTab = "OpensPickerFromTab"
        static let showsMenuBarIcon = "ShowsMenuBarIcon"
        static let checksForUpdates = "ChecksForUpdates"
        static let hasLaunchedBefore = "HasLaunchedBefore"
        static let lastPictureFolder = "LastPictureFolder"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// The look new pictures get, and that folders without their own look follow.
    var defaultStyle: IconStyle {
        didSet {
            if let data = try? JSONEncoder().encode(defaultStyle) { defaults.set(data, forKey: Key.defaultStyle) }
        }
    }

    /// Show the "Set as Icon" target while an image is dragged over a folder.
    var showsDropTarget: Bool {
        didSet { defaults.set(showsDropTarget, forKey: Key.showsDropTarget) }
    }

    /// Buttons along the top of a folder's icon while the pointer is over it.
    var showsHoverButtons: Bool {
        didSet { defaults.set(showsHoverButtons, forKey: Key.showsHoverButtons) }
    }

    var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) }
    }

    /// Once a day, ask GitHub whether there's a newer version (see `UpdateChecker`).
    var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Key.checksForUpdates) }
    }

    /// `false` only on the very first launch.
    var hasLaunchedBefore: Bool {
        didSet { defaults.set(hasLaunchedBefore, forKey: Key.hasLaunchedBefore) }
    }

    /// Where the picture picker opens next time.
    var lastPictureFolder: URL? {
        didSet { defaults.set(lastPictureFolder?.path, forKey: Key.lastPictureFolder) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.showsDropTarget: true,
            Key.showsHoverButtons: defaults.object(forKey: Key.opensPickerFromTab) as? Bool ?? true,
            Key.showsMenuBarIcon: true,
            Key.checksForUpdates: true,
        ])
        defaultStyle = defaults.data(forKey: Key.defaultStyle)
            .flatMap { try? JSONDecoder().decode(IconStyle.self, from: $0) } ?? .standard
        showsDropTarget = defaults.bool(forKey: Key.showsDropTarget)
        showsHoverButtons = defaults.bool(forKey: Key.showsHoverButtons)
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        checksForUpdates = defaults.bool(forKey: Key.checksForUpdates)
        hasLaunchedBefore = defaults.bool(forKey: Key.hasLaunchedBefore)
        lastPictureFolder = defaults.string(forKey: Key.lastPictureFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
