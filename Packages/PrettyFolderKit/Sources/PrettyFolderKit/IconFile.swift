import AppKit

/// Writes a folder's custom icon, the hidden `Icon\r` file in it, so that Finder never finds
/// a folder without its picture while a new one is on its way.
///
/// `NSWorkspace.setIcon(_:forFile:options:)` replaces an icon by deleting the old file and
/// writing a new one, and the new file holds no picture for the tenth of a second or more it
/// takes to encode one. Finder may look at the icon just then, after an earlier change say,
/// and show a plain folder. So a folder that already shows an icon gets the new one made
/// elsewhere on the same disk and swapped with the old one in a single step: whoever looks
/// finds one whole icon or the other.
enum IconFile {
    /// An icon file that was swapped out. It is kept until Finder has been told about the new
    /// one, so anyone in the middle of reading it can finish.
    struct Replaced: Sendable {
        fileprivate let directory: URL

        func discard() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static let options: NSWorkspace.IconCreationOptions = [.excludeQuickDrawElementsIconCreationOption]

    /// Gives `folder` the icon `image`. Returns whether it has it now, and the icon file it
    /// had before, if that was swapped out: discard it once Finder knows.
    static func write(_ image: NSImage, to folder: URL) -> (written: Bool, replaced: Replaced?) {
        if FolderInspector.hasCustomIcon(folder), let replaced = swap(image, into: folder) {
            return (true, replaced)
        }
        // A first icon shows only once the folder's custom icon flag goes on, after the file is
        // written; a disk where the swap can't be done gets the icon the usual way.
        return (NSWorkspace.shared.setIcon(image, forFile: folder.path, options: options), nil)
    }

    /// Makes the icon for a scratch folder on the same disk as `folder` and puts its icon
    /// file in place of the folder's own, which goes to the scratch folder.
    private static func swap(_ image: NSImage, into folder: URL) -> Replaced? {
        let files = FileManager.default
        guard let scratch = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true) else {
            return nil
        }
        let replaced = Replaced(directory: scratch)
        let staging = scratch.appendingPathComponent("Icon", isDirectory: true)
        guard (try? files.createDirectory(at: staging, withIntermediateDirectories: false)) != nil,
              NSWorkspace.shared.setIcon(image, forFile: staging.path, options: options),
              move(FolderInspector.iconFileURL(for: staging), over: FolderInspector.iconFileURL(for: folder)),
              // Somebody may have taken the folder's icon off meanwhile; then it needs the flag too.
              FolderInspector.customIconFlag(folder) == true
        else {
            replaced.discard()
            return nil
        }
        return replaced
    }

    /// Puts `source` where `destination` is. The two trade places where the disk can do that:
    /// a plain move would delete the old file under anyone in the middle of reading it.
    private static func move(_ source: URL, over destination: URL) -> Bool {
        source.withUnsafeFileSystemRepresentation { from in
            destination.withUnsafeFileSystemRepresentation { to in
                guard let from, let to else { return false }
                if renamex_np(from, to, UInt32(RENAME_SWAP)) == 0 { return true }
                // No old file to trade places with, or a disk that can't.
                return rename(from, to) == 0
            }
        }
    }
}
