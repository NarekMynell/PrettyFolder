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
///
/// That also keeps the old icon when the new one can't be written whole: on a disk that is all
/// but full, `setIcon` can leave an icon file with no picture in it and still say it worked.
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
    /// had before, if that was swapped out: discard it once Finder knows. A folder that has an
    /// icon keeps it when the new one can't be written whole.
    static func write(_ image: NSImage, to folder: URL) -> (written: Bool, replaced: Replaced?) {
        if FolderInspector.hasCustomIcon(folder) {
            switch swap(image, into: folder) {
            case .swapped(let replaced):
                return (true, replaced)
            case .failed:
                return (false, nil)
            case .cannotStage, .lostItsFlag:
                // A disk with no room for a scratch folder of the system's (a network disk, say)
                // gets the icon the usual way; so does a folder whose icon was taken off meanwhile,
                // which needs the flag that says it has one again.
                break
            }
        }
        // A first icon shows only once the folder's custom icon flag goes on, after the file is
        // written. The caller checks what was written (see `isWhole`).
        return (NSWorkspace.shared.setIcon(image, forFile: folder.path, options: options), nil)
    }

    private enum Swap {
        case swapped(Replaced)
        /// The new icon couldn't be made whole, or put in place: the old one is still there.
        case failed
        /// There is no place on the disk to make it.
        case cannotStage
        /// It is in place, but somebody took the folder's icon off meanwhile.
        case lostItsFlag
    }

    /// Makes the icon for a scratch folder on the same disk as `folder`, checks that it is whole,
    /// and puts its icon file in place of the folder's own, which goes to the scratch folder.
    private static func swap(_ image: NSImage, into folder: URL) -> Swap {
        let files = FileManager.default
        guard let scratch = try? files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: folder, create: true) else {
            return .cannotStage
        }
        let replaced = Replaced(directory: scratch)
        let staging = scratch.appendingPathComponent("Icon", isDirectory: true)
        guard (try? files.createDirectory(at: staging, withIntermediateDirectories: false)) != nil,
              NSWorkspace.shared.setIcon(image, forFile: staging.path, options: options),
              FolderInspector.iconResource(of: staging).map(isWhole) == true,
              move(FolderInspector.iconFileURL(for: staging), over: FolderInspector.iconFileURL(for: folder))
        else {
            replaced.discard()
            return .failed
        }
        guard FolderInspector.customIconFlag(folder) == true else {
            replaced.discard()
            return .lostItsFlag
        }
        return .swapped(replaced)
    }

    /// Whether an icon file's resource fork holds a whole icon: an `icns` resource with at least
    /// one picture in it that can be read. A disk that ran out of room part way through leaves
    /// the resource's frame and no picture.
    static func isWhole(_ resourceFork: Data) -> Bool {
        let bytes = [UInt8](resourceFork)
        func number(at offset: Int) -> Int? {
            guard offset >= 0, offset + 4 <= bytes.count else { return nil }
            return bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        }
        // A resource fork starts with where its data and its map are, and how long each is, and
        // all of both must be there. Each resource in the data is its length and its bytes; an
        // icon file has one resource, the icon.
        guard let dataOffset = number(at: 0), let mapOffset = number(at: 4),
              let dataLength = number(at: 8), let mapLength = number(at: 12),
              dataOffset + dataLength <= bytes.count, mapLength > 0, mapOffset + mapLength <= bytes.count,
              let length = number(at: dataOffset), length > 8, 4 + length <= dataLength
        else { return false }
        let icon = Data(bytes[(dataOffset + 4)..<(dataOffset + 4 + length)])
        guard icon.prefix(4) == Data("icns".utf8),
              let image = NSImage(data: icon), image.representations.contains(where: { $0.pixelsWide > 0 && $0.pixelsHigh > 0 })
        else { return false }
        return true
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
