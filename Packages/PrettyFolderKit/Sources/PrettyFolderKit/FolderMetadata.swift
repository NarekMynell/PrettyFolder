import Foundation

/// The two small things PrettyFolder does to a folder besides writing its icon: telling Finder
/// that the icon changed, and keeping the folder's modification date as it was.
enum FolderMetadata {
    private static let finderInfo = "com.apple.FinderInfo"
    /// Bytes 26–27 of a folder's Finder info. They once held the folder's comment ID; the
    /// system now calls them reserved and nothing reads them.
    private static let counterOffset = 26

    /// Finder doesn't look at a folder's custom icon again when only the icon is replaced, and
    /// keeps showing the old picture. It does when the folder's Finder info changes, so this
    /// counts up in the reserved bytes: the Finder info changes and nothing else does.
    static func noteIconChanged(_ folder: URL) {
        guard case .value(var info) = ExtendedAttributes.read(named: finderInfo, at: folder), info.count == 32 else { return }
        let index = info.startIndex + counterOffset
        let count = (UInt16(info[index]) << 8 | UInt16(info[index + 1])) &+ 1
        info[index] = UInt8(count >> 8)
        info[index + 1] = UInt8(count & 0xFF)
        ExtendedAttributes.set(info, named: finderInfo, at: folder)
    }

    /// Puts the counter back to zero, for a folder that no longer has a picture.
    static func forgetIconChanges(_ folder: URL) {
        guard case .value(var info) = ExtendedAttributes.read(named: finderInfo, at: folder), info.count == 32 else { return }
        let index = info.startIndex + counterOffset
        guard info[index] != 0 || info[index + 1] != 0 else { return }
        info[index] = 0
        info[index + 1] = 0
        if info.allSatisfy({ $0 == 0 }) {
            ExtendedAttributes.remove(named: finderInfo, at: folder)
        } else {
            ExtendedAttributes.set(info, named: finderInfo, at: folder)
        }
    }

    /// The icon file inside a folder is replaced along with the icon, which would make the
    /// folder look modified, and jump in windows sorted by date. Pass the date this returns to
    /// `restoreModificationDate` afterwards.
    static func modificationDate(of folder: URL) -> timespec? {
        folder.withUnsafeFileSystemRepresentation { path in
            var info = stat()
            guard let path, lstat(path, &info) == 0 else { return nil }
            return info.st_mtimespec
        }
    }

    static func restoreModificationDate(_ date: timespec, of folder: URL) {
        folder.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            // Leave the access date alone.
            var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), date]
            _ = utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
        }
    }
}
