import Foundation

/// Answers questions about a folder on disk without changing it.
public enum FolderInspector {
    public enum Problem: LocalizedError, Equatable {
        case missing(String)
        case notAFolder(String)
        case package(String)
        case insidePackage(String)
        case volume(String)
        case readOnly(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let name): return "“\(name)” no longer exists."
            case .notAFolder(let name): return "“\(name)” is not a folder."
            case .package(let name): return "“\(name)” is an app or a package. Changing its icon could break it, so PrettyFolder leaves it alone."
            case .insidePackage(let name): return "“\(name)” is inside an app or a package. Changing its icon could break it, so PrettyFolder leaves it alone."
            case .volume(let name): return "“\(name)” is a disk, not a folder."
            case .readOnly(let name): return "You don't have permission to change “\(name)”."
            }
        }
    }

    /// Checks that `url` is a plain folder whose icon can be changed safely.
    ///
    /// Packages (apps, bundles, Photos libraries…) and the folders inside them are refused:
    /// writing or removing an icon file inside an app bundle invalidates its code signature.
    public static func validate(_ url: URL) throws {
        let name = FileManager.default.displayName(atPath: url.path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isVolumeKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { throw Problem.missing(name) }
        if values.isSymbolicLink == true || values.isDirectory != true { throw Problem.notAFolder(name) }
        if values.isPackage == true { throw Problem.package(name) }
        if isInsidePackage(url) { throw Problem.insidePackage(name) }
        if values.isVolume == true { throw Problem.volume(name) }
        if !FileManager.default.isWritableFile(atPath: url.path) { throw Problem.readOnly(name) }
    }

    /// Whether any folder that `url` is in is a package, whatever links lead there.
    private static func isInsidePackage(_ url: URL) -> Bool {
        var folder = URL(fileURLWithPath: canonicalPath(url.path), isDirectory: true).deletingLastPathComponent()
        while folder.pathComponents.count > 1 {
            if (try? folder.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true { return true }
            folder.deleteLastPathComponent()
        }
        return false
    }

    /// Whether Finder shows a custom icon for the folder (the `kHasCustomIcon` Finder flag).
    public static func hasCustomIcon(_ url: URL) -> Bool {
        customIconFlag(url) == true
    }

    /// Like `hasCustomIcon`, but `nil` when the folder can't be read right now
    /// (no permission, disk going away), which is not the same as "no custom icon".
    static func customIconFlag(_ url: URL) -> Bool? {
        switch ExtendedAttributes.read(named: FolderMetadata.finderInfo, at: url) {
        case .missing:
            return false
        case .unreadable:
            return nil
        case .value(let info):
            guard info.count >= 10 else { return false }
            // FinderInfo starts with a 16-byte FolderInfo; finderFlags is a big-endian UInt16 at offset 8.
            let flags = UInt16(info[info.startIndex + 8]) << 8 | UInt16(info[info.startIndex + 9])
            return flags & 0x0400 != 0
        }
    }

    /// The path with symbolic links resolved (`/var/…` becomes `/private/var/…`), which is
    /// the form bookmarks resolve to. Paths that no longer exist work too: the part that
    /// still exists is resolved and the rest appended.
    static func canonicalPath(_ path: String) -> String {
        var existing = URL(fileURLWithPath: path).standardizedFileURL
        var missing: [String] = []
        while existing.path != "/", !FileManager.default.fileExists(atPath: existing.path) {
            missing.insert(existing.lastPathComponent, at: 0)
            existing.deleteLastPathComponent()
        }
        guard let resolved = realpath(existing.path, nil) else { return path }
        defer { free(resolved) }
        var result = URL(fileURLWithPath: String(cString: resolved))
        for component in missing { result.appendPathComponent(component) }
        return result.path
    }

    /// The hidden `Icon\r` file that holds a folder's custom icon.
    public static func iconFileURL(for folder: URL) -> URL {
        folder.appendingPathComponent("Icon\r", isDirectory: false)
    }

    /// Whether the folder is known to have no icon file. Not when it can't be looked into.
    static func hasNoIconFile(_ folder: URL) -> Bool {
        iconFileURL(for: folder).withUnsafeFileSystemRepresentation { path in
            var info = stat()
            guard let path else { return false }
            return lstat(path, &info) != 0 && errno == ENOENT
        }
    }

    /// The raw icon resource of the folder, if it has one.
    public static func iconResource(of folder: URL) -> Data? {
        ExtendedAttributes.value(named: "com.apple.ResourceFork", at: iconFileURL(for: folder))
    }
}

/// Thin wrapper over the `xattr` system calls. Never follows symlinks.
enum ExtendedAttributes {
    enum Read {
        case value(Data)
        /// The item has no such attribute.
        case missing
        /// The item or attribute couldn't be read (permissions, the item is gone…).
        case unreadable
    }

    static func read(named name: String, at url: URL) -> Read {
        url.withUnsafeFileSystemRepresentation { path -> Read in
            guard let path else { return .unreadable }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 { return errno == ENOATTR ? .missing : .unreadable }
            guard size > 0 else { return .value(Data()) }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read >= 0 else { return errno == ENOATTR ? .missing : .unreadable }
            return .value(data.prefix(read))
        }
    }

    static func value(named name: String, at url: URL) -> Data? {
        if case .value(let data) = read(named: name, at: url), !data.isEmpty { return data }
        return nil
    }

    @discardableResult
    static func set(_ data: Data, named name: String, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return data.withUnsafeBytes { setxattr(path, name, $0.baseAddress, data.count, 0, XATTR_NOFOLLOW) } == 0
        }
    }

    @discardableResult
    static func remove(named name: String, at url: URL) -> Bool {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return false }
            return removexattr(path, name, XATTR_NOFOLLOW) == 0
        }
    }
}
