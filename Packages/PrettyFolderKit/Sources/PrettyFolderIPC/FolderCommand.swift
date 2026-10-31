import Foundation

/// A request from the Finder extension (or any other caller) to the app.
///
/// Commands travel as `prettyfolder://<action>?path=<folder>&path=<folder>…` URLs.
/// The extension is sandboxed and cannot touch other folders itself, so it only
/// describes what the user picked in Finder and lets the app do the work.
public struct FolderCommand: Equatable, Sendable {
    public enum Action: String, Sendable, CaseIterable {
        /// Show a file picker and put the chosen image on the folders.
        case chooseImage = "choose"
        /// Put the folders back to the standard icon.
        case removeImage = "remove"
        /// Open the app's window for the folders: their picture, its place and its scaling.
        case adjust = "adjust"
        /// Open the app's window without a folder: the default look and the settings.
        case settings = "settings"

        /// Whether the action makes sense without any folder attached.
        public var needsFolders: Bool { self != .settings }
    }

    public static let scheme = "prettyfolder"

    public var action: Action
    public var folders: [URL]

    public init(_ action: Action, folders: [URL] = []) {
        self.action = action
        self.folders = folders
    }

    /// Characters that can stay readable inside a query value. Everything else,
    /// including `&`, `=`, `+`, `#` and `?`, gets percent-encoded so that any
    /// folder name survives the round trip.
    private static let valueAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "-._~/")
        return set
    }()

    public var url: URL {
        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = action.rawValue
        if !folders.isEmpty {
            components.percentEncodedQuery = folders
                .map { "path=" + ($0.path.addingPercentEncoding(withAllowedCharacters: Self.valueAllowed) ?? "") }
                .joined(separator: "&")
        }
        // Every piece above is either fixed or percent-encoded, so this cannot fail.
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host?.lowercased(),
              let action = Action(rawValue: host)
        else { return nil }

        let paths = (components.percentEncodedQueryItems ?? [])
            .filter { $0.name == "path" }
            .compactMap { $0.value?.removingPercentEncoding }
            .filter { $0.hasPrefix("/") }

        if action.needsFolders && paths.isEmpty { return nil }
        self.action = action
        self.folders = paths.map { URL(fileURLWithPath: $0, isDirectory: true).standardizedFileURL }
    }
}
