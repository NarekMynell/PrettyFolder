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
        static let opensPickerFromTab = "OpensPickerFromTab"
        static let showsMenuBarIcon = "ShowsMenuBarIcon"
        static let hasCompletedWelcome = "HasCompletedWelcome"
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

    /// Clicking a folder's tab opens the picture picker.
    var opensPickerFromTab: Bool {
        didSet { defaults.set(opensPickerFromTab, forKey: Key.opensPickerFromTab) }
    }

    var showsMenuBarIcon: Bool {
        didSet { defaults.set(showsMenuBarIcon, forKey: Key.showsMenuBarIcon) }
    }

    var hasCompletedWelcome: Bool {
        didSet { defaults.set(hasCompletedWelcome, forKey: Key.hasCompletedWelcome) }
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
            Key.opensPickerFromTab: true,
            Key.showsMenuBarIcon: true,
        ])
        defaultStyle = defaults.data(forKey: Key.defaultStyle)
            .flatMap { try? JSONDecoder().decode(IconStyle.self, from: $0) } ?? .standard
        showsDropTarget = defaults.bool(forKey: Key.showsDropTarget)
        opensPickerFromTab = defaults.bool(forKey: Key.opensPickerFromTab)
        showsMenuBarIcon = defaults.bool(forKey: Key.showsMenuBarIcon)
        hasCompletedWelcome = defaults.bool(forKey: Key.hasCompletedWelcome)
        hasLaunchedBefore = defaults.bool(forKey: Key.hasLaunchedBefore)
        lastPictureFolder = defaults.string(forKey: Key.lastPictureFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
    }
}
