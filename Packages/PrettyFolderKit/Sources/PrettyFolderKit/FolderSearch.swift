import CoreServices
import Foundation

/// How far a search for folders goes.
public enum FolderSearchReach: Sendable {
    /// What Spotlight knows: quick, and most of what there is.
    case spotlight
    /// That, and the disks here that Spotlight stays off.
    case placesWithoutSpotlight
    /// That, and every other disk here, whatever Spotlight says, and what it leaves out of the home
    /// folder: hidden folders, caches, those it has been told to leave alone. A network disk could
    /// take hours and isn't looked through: its folders are known once they have been opened.
    case everywhere
}

/// Looks across the Mac's disks for folders that may show a picture from PrettyFolder, for those
/// the list doesn't know: a copy nobody has opened, a folder moved to another disk.
enum FolderSearch {
    /// The folders with the marker on them that could be changed.
    static func markedFolders(
        _ reach: FolderSearchReach,
        knownPaths: [String],
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) -> [URL] {
        var found = indexedIconFiles().map(folder(holding:)).filter(hasMarker)
        switch reach {
        case .spotlight:
            break
        case .placesWithoutSpotlight:
            found += markedFolders(in: otherDisks().filter { !isIndexed($0) })
            if !isIndexed(URL(fileURLWithPath: "/")) { found += markedFolders(in: placesInHome(home, knownPaths: knownPaths)) }
        case .everywhere:
            found += markedFolders(in: otherDisks() + placesInHome(home, knownPaths: knownPaths))
        }
        return worthChanging(found)
    }

    /// The folders with the marker on them that could be changed, among those holding `iconFiles`.
    static func markedFolders(holding iconFiles: [URL]) -> [URL] {
        worthChanging(iconFiles.map(folder(holding:)).filter(hasMarker))
    }

    private static func folder(holding iconFile: URL) -> URL {
        iconFile.deletingLastPathComponent()
    }

    /// The icon files Spotlight knows. It doesn't index the markers, but it does the file's name,
    /// and few folders have one. A new one is found within seconds.
    private static func indexedIconFiles() -> [URL] {
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemFSName == \"Icon\r\"" as CFString, nil, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        else { return [] }
        return (0..<MDQueryGetResultCount(query)).compactMap { index -> URL? in
            guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
            let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
            guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { return nil }
            return URL(fileURLWithPath: path, isDirectory: false)
        }
    }

    /// The disks here that could be changed, other than the Mac's own.
    private static func otherDisks() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey]
        let disks = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return disks.filter { disk in
            guard disk.path.hasPrefix("/Volumes/"), !holdsWholeMac(disk), let values = try? disk.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsLocal == true && values.volumeIsReadOnly != true
        }
    }

    /// What there is to go through in a home folder. Not where macOS would stop to ask for
    /// permission, unless a known folder is there, so it has been given. `Library` is other apps'
    /// business, apart from their caches.
    static func placesInHome(_ home: URL, knownPaths: [String]) -> [URL] {
        let asksFirst = ["Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures"]
        let items = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        let places = items.filter { item in
            let name = item.lastPathComponent
            if name == "Library" || device(of: item) != device(of: home) { return false }
            let path = FolderInspector.canonicalPath(item.path) + "/"
            return !asksFirst.contains(name) || knownPaths.contains { ($0 + "/").hasPrefix(path) }
        }
        return places + [home.appendingPathComponent("Library/Caches", isDirectory: true)]
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

    /// Goes through whole places, leaving out what has no business being changed, and disks mounted
    /// inside them: another disk is looked at as such, or not at all. One folder is open for a moment
    /// at a time, and none in between, so a disk can be ejected meanwhile.
    static func markedFolders(in places: [URL]) -> [URL] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        func isToGoThrough(_ item: URL) -> Bool {
            guard let values = try? item.resourceValues(forKeys: Set(keys)) else { return false }
            return values.isDirectory == true && values.isSymbolicLink != true && values.isPackage != true && !isSetApart(item.lastPathComponent)
        }
        var waiting = places.filter(isToGoThrough)
        var found = waiting.filter(hasMarker)
        while let folder = waiting.popLast() {
            autoreleasepool {
                let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys, options: [])) ?? []
                let disk = device(of: folder)
                for item in items where isToGoThrough(item) && device(of: item) == disk {
                    if hasMarker(item) { found.append(item) }
                    waiting.append(item)
                }
            }
        }
        return found
    }

    private static func device(of item: URL) -> dev_t? {
        item.withUnsafeFileSystemRepresentation { path in
            var info = stat()
            guard let path, lstat(path, &info) == 0 else { return nil }
            return info.st_dev
        }
    }

    private static func hasMarker(_ folder: URL) -> Bool {
        ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) != nil
    }

    /// A folder in a trash isn't looked for until it is put back, and a backup is a record of how
    /// things were: changing it, or even failing to, helps nobody. (A folder already on the list
    /// goes on being looked after in the trash, for when it comes back.)
    private static func worthChanging(_ folders: [URL]) -> [URL] {
        var seen = Set<String>()
        var disks: [String: Bool] = [:]
        return folders.filter { folder in
            guard seen.insert(folder.path).inserted, !folder.pathComponents.contains(where: isSetApart) else { return false }
            let parts = folder.pathComponents
            if parts.count > 2, parts[1] == "Volumes" {
                let disk = URL(fileURLWithPath: "/Volumes/" + parts[2], isDirectory: true)
                let whole = disks[parts[2]] ?? holdsWholeMac(disk)
                disks[parts[2]] = whole
                if whole { return false }
            }
            return (try? FolderInspector.validate(folder)) != nil
        }
    }

    /// A disk with a whole Mac on it, its system or just its data: a clone made by a backup app, or
    /// another Mac's disk. The folders on it aren't this person's to tidy up.
    private static func holdsWholeMac(_ disk: URL) -> Bool {
        func has(_ path: String) -> Bool { FileManager.default.fileExists(atPath: disk.appendingPathComponent(path).path) }
        return has("System/Library/CoreServices/SystemVersion.plist") || (has("Users") && has("Library"))
    }

    private static func isSetApart(_ name: String) -> Bool {
        name.hasPrefix(".Trash") || name.hasSuffix(".previous") || name.hasSuffix(".inprogress")
            || ["$RECYCLE.BIN", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems",
                "Backups.backupdb", ".timemachine", ".MobileBackups"].contains(name)
    }
}

/// Tells about icon files as Spotlight gets to know them, however long after a disk was connected
/// that is. The first answer, everything it knows at the start, is the search's to give. It is
/// kept for as long as the app runs.
@MainActor
public final class FolderSpotlightWatch {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?

    public init(found: @escaping @MainActor ([URL]) -> Void) {
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "Icon\r")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let files = added.compactMap { ($0.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) } }
            guard !files.isEmpty else { return }
            MainActor.assumeIsolated { found(files) }
        }
        query.start()
    }
}
