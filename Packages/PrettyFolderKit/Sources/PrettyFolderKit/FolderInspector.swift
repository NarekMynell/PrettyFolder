import Foundation

/// Answers questions about a folder on disk without changing it.
public enum FolderInspector {
    public enum Problem: LocalizedError, Equatable {
        case missing(String)
        case notAFolder(String)
        case package(String)
        case volume(String)
        case readOnly(String)

        public var errorDescription: String? {
            switch self {
            case .missing(let name): return "“\(name)” no longer exists."
            case .notAFolder(let name): return "“\(name)” is not a folder."
            case .package(let name): return "“\(name)” is an app or a package. Changing its icon could break it, so PrettyFolder leaves it alone."
            case .volume(let name): return "“\(name)” is a disk, not a folder."
            case .readOnly(let name): return "You don't have permission to change “\(name)”."
            }
        }
    }

    /// Checks that `url` is a plain folder whose icon can be changed safely.
    ///
    /// Packages (apps, bundles, Photos libraries…) are refused: writing an icon file
    /// inside an app bundle invalidates its code signature.
    public static func validate(_ url: URL) throws {
        let name = FileManager.default.displayName(atPath: url.path)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .isVolumeKey, .isSymbolicLinkKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { throw Problem.missing(name) }
        if values.isSymbolicLink == true || values.isDirectory != true { throw Problem.notAFolder(name) }
        if values.isPackage == true { throw Problem.package(name) }
        if values.isVolume == true { throw Problem.volume(name) }
        if !FileManager.default.isWritableFile(atPath: url.path) { throw Problem.readOnly(name) }
    }

    public static func isEligible(_ url: URL) -> Bool {
        (try? validate(url)) != nil
    }

    /// Whether Finder shows a custom icon for the folder (the `kHasCustomIcon` Finder flag).
    public static func hasCustomIcon(_ url: URL) -> Bool {
        guard let info = ExtendedAttributes.value(named: "com.apple.FinderInfo", at: url), info.count >= 10 else {
            return false
        }
        // FinderInfo starts with a 16-byte FolderInfo; finderFlags is a big-endian UInt16 at offset 8.
        let flags = UInt16(info[info.startIndex + 8]) << 8 | UInt16(info[info.startIndex + 9])
        return flags & 0x0400 != 0
    }

    /// The hidden `Icon\r` file that holds a folder's custom icon.
    public static func iconFileURL(for folder: URL) -> URL {
        folder.appendingPathComponent("Icon\r", isDirectory: false)
    }

    /// The raw icon resource of the folder, if it has one.
    public static func iconResource(of folder: URL) -> Data? {
        ExtendedAttributes.value(named: "com.apple.ResourceFork", at: iconFileURL(for: folder))
    }
}

/// Thin wrapper over the `xattr` system calls. Never follows symlinks.
enum ExtendedAttributes {
    static func value(named name: String, at url: URL) -> Data? {
        url.withUnsafeFileSystemRepresentation { path -> Data? in
            guard let path else { return nil }
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size > 0 else { return nil }
            var data = Data(count: size)
            let read = data.withUnsafeMutableBytes { getxattr(path, name, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
            guard read >= 0 else { return nil }
            return data.prefix(read)
        }
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
