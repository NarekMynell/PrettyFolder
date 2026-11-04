import CoreServices
import Foundation

/// How far a search for folders goes.
public enum FolderSearchReach: Sendable {
    /// What Spotlight knows: quick, and most of what there is.
    case spotlight
    /// That, and every other disk here that Spotlight stays off.
    case disksWithoutSpotlight
    /// That, and every other disk here, whatever Spotlight says: one it has only just started on
    /// knows little yet, and it leaves some folders out on any disk.
    case everyDisk
}

/// Looks across the Mac's disks for folders that may show a picture from PrettyFolder, for those
/// the list doesn't know: a copy nobody has opened, a folder moved to another disk.
///
/// Spotlight doesn't look everywhere: hidden folders, caches and folders it has been told to leave
/// out it never knows about. On this Mac's own disk those stay unknown until they are opened.
enum FolderSearch {
    /// The folders with the marker on them that could be changed.
    static func markedFolders(_ reach: FolderSearchReach, patience: TimeInterval) -> [URL] {
        var seen = Set<String>()
        var found = indexedIconFiles()
        if reach != .spotlight {
            let deadline = Date().addingTimeInterval(patience)
            for disk in otherDisks() where reach == .everyDisk || !isIndexed(disk) {
                found += markedFolders(on: disk, until: deadline)
            }
        }
        return found.filter { seen.insert($0.path).inserted && isWorthChanging($0) }
    }

    /// The folders Spotlight knows an icon file in. It doesn't index the markers, but it does the
    /// file's name, and few folders have one. A new one is found within seconds.
    private static func indexedIconFiles() -> [URL] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemFSName == \"Icon\r\"" as CFString, nil, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        else { return [] }
        return (0..<MDQueryGetResultCount(query)).compactMap { index -> URL? in
            guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
            return URL(fileURLWithPath: path, isDirectory: false).deletingLastPathComponent()
        }.filter(hasMarker)
    }

    /// The disks here that could be changed, other than the Mac's own.
    private static func otherDisks() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey]
        let disks = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return disks.filter { disk in
            guard disk.path.hasPrefix("/Volumes/"), let values = try? disk.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsLocal == true && values.volumeIsReadOnly != true
        }
    }

    /// What Spotlight says about a disk. Nothing else tells without a privileged look.
    private static func isIndexed(_ disk: URL) -> Bool {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
        tool.arguments = ["-s", disk.path]
        let output = Pipe()
        tool.standardOutput = output
        tool.standardError = FileHandle.nullDevice
        guard (try? tool.run()) != nil else { return false }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        tool.waitUntilExit()
        return String(decoding: data, as: UTF8.self).contains("Indexing enabled")
    }

    /// Goes through a whole disk, leaving out what has no business being changed. One folder is
    /// open for a moment at a time, and none in between, so the disk can be ejected meanwhile.
    static func markedFolders(on disk: URL, until deadline: Date = .distantFuture) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        var found: [URL] = []
        var waiting = [disk]
        while let folder = waiting.popLast(), Date() <= deadline {
            autoreleasepool {
                let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
                for item in items {
                    guard let values = try? item.resourceValues(forKeys: Set(keys)), values.isDirectory == true,
                          values.isSymbolicLink != true, values.isPackage != true, !isSetApart(item.lastPathComponent)
                    else { continue }
                    if hasMarker(item) { found.append(item) }
                    waiting.append(item)
                }
            }
        }
        return found
    }

    private static func hasMarker(_ folder: URL) -> Bool {
        ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) != nil
    }

    /// A folder in a trash isn't looked for until it is put back, and a backup is a record of how
    /// things were: changing it, or even failing to, helps nobody. (A folder already on the list
    /// goes on being looked after in the trash, for when it comes back. A clone of a disk made by a
    /// backup app can't be told by its name: it is treated as what it is, copies of folders.)
    private static func isWorthChanging(_ folder: URL) -> Bool {
        guard !folder.pathComponents.contains(where: isSetApart) else { return false }
        return (try? FolderInspector.validate(folder)) != nil
    }

    private static func isSetApart(_ name: String) -> Bool {
        name.hasPrefix(".Trash") || name.hasSuffix(".previous") || name.hasSuffix(".inprogress")
            || ["$RECYCLE.BIN", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
                "Backups.backupdb", ".timemachine", ".MobileBackups"].contains(name)
    }
}
