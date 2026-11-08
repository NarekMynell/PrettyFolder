import CoreServices
import Foundation
import os

/// How far a search for folders goes.
public enum FolderSearchReach: Sendable, Hashable {
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
        home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
        spotlight: () -> [URL]? = { indexedIconFiles() }
    ) -> [URL] {
        var found = (spotlight() ?? []).map(folder(holding:)).filter(hasMarker)
        switch reach {
        case .spotlight:
            break
        case .placesWithoutSpotlight:
            // A disk `mdutil` can't say anything about in time (it asks Spotlight too) is left to
            // the next search.
            found += markedFolders(in: otherDisks().filter { isIndexed($0) == false })
            if isIndexed(URL(fileURLWithPath: "/")) == false { found += markedFolders(in: placesInHome(home, knownPaths: knownPaths)) }
        case .everywhere:
            found += markedFolders(in: otherDisks() + placesInHome(home, knownPaths: knownPaths))
        }
        return worthChanging(found)
    }

    /// Runs a search on `reach`'s own thread and waits for it there. The threads all tasks share
    /// are as many as the Mac has cores and mustn't wait on Spotlight or a disk: a search can,
    /// for as long as they take. Searches of one reach take turns.
    static func run<T: Sendable>(_ reach: FolderSearchReach, _ work: @escaping @Sendable () -> T) async -> T {
        await perform(on: queues[reach] ?? checking, work)
    }

    /// Looks at the folders holding icon files Spotlight has just reported.
    static func check<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await perform(on: checking, work)
    }

    private static func perform<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    private static let queues: [FolderSearchReach: DispatchQueue] = [
        .spotlight: DispatchQueue(label: "com.narekmynell.PrettyFolder.search.spotlight", qos: .utility),
        // Started by a disk being connected, with nobody waiting for it.
        .placesWithoutSpotlight: DispatchQueue(label: "com.narekmynell.PrettyFolder.search.places", qos: .background),
        .everywhere: DispatchQueue(label: "com.narekmynell.PrettyFolder.search.everywhere", qos: .utility),
    ]
    private static let checking = DispatchQueue(label: "com.narekmynell.PrettyFolder.search.check", qos: .utility)

    /// The folders with the marker on them that could be changed, among those holding `iconFiles`.
    static func markedFolders(holding iconFiles: [URL]) -> [URL] {
        worthChanging(iconFiles.map(folder(holding:)).filter(hasMarker))
    }

    private static func folder(holding iconFile: URL) -> URL {
        iconFile.deletingLastPathComponent()
    }

    /// How long Spotlight gets to answer. It takes well under a second, but it can also not answer
    /// at all: twelve searches in a row waited for good one night, from the moment the Mac locked.
    static let spotlightPatience: TimeInterval = 10

    /// The icon files Spotlight knows, or `nil` if it doesn't say in time. It doesn't index the
    /// markers, but it does the file's name, and few folders have one. A new one is found within
    /// seconds.
    ///
    /// Asked through `mdfind`, which is stopped when its time is up. A query made in this process
    /// can't be: one Spotlight never answers keeps its thread for good, and even one that doesn't
    /// wait for its results first waits for Spotlight to take it.
    static func indexedIconFiles(within patience: TimeInterval = spotlightPatience) -> [URL]? {
        guard let result = Subprocess.run("/usr/bin/mdfind", ["-0", "kMDItemFSName == \"Icon\r\""], within: patience),
              result.status == 0
        else { return nil }
        return result.output.split(separator: "\0").map { URL(fileURLWithPath: String($0), isDirectory: false) }
    }

    /// The disks here that could be changed, other than the Mac's own.
    private static func otherDisks() -> [URL] {
        let keys: [URLResourceKey] = [.volumeIsLocalKey, .volumeIsReadOnlyKey]
        let disks = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        // Local first, from what the list already says: looking inside a network disk to see whether
        // it holds a Mac could wait for as long as its server takes to answer, or for good.
        return disks.filter { disk in
            guard disk.path.hasPrefix("/Volumes/"), let values = try? disk.resourceValues(forKeys: Set(keys)),
                  values.volumeIsLocal == true, values.volumeIsReadOnly != true
            else { return false }
            return !holdsWholeMac(disk)
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

    /// What Spotlight says about a disk, `nil` if it doesn't say in time. Nothing else tells
    /// without a privileged look.
    private static func isIndexed(_ disk: URL) -> Bool? {
        // One stopped on the way (the app is quitting) says nothing either: not "not indexed", which
        // would have the whole disk walked.
        guard let result = Subprocess.run("/usr/bin/mdutil", ["-s", disk.path], within: spotlightPatience), result.status == 0 else { return nil }
        return result.output.contains("Indexing enabled")
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
///
/// The query lives on a queue of its own: starting it waits for Spotlight to take it, for as long
/// as that takes, and the main thread mustn't wait for Spotlight.
@MainActor
public final class FolderSpotlightWatch {
    private let queue = OperationQueue()
    private let query: Unchecked<NSMetadataQuery>
    private var observer: NSObjectProtocol?

    public init(found: @escaping @MainActor ([URL]) -> Void) {
        queue.name = "com.narekmynell.PrettyFolder.spotlight-watch"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let query = NSMetadataQuery()
        query.predicate = NSPredicate(format: "%K == %@", NSMetadataItemFSNameKey, "Icon\r")
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.operationQueue = queue
        self.query = Unchecked(query)
        // Read on the query's queue, before it changes again; only the paths go on.
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: nil) { note in
            let added = note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem] ?? []
            let files = added.compactMap { ($0.value(forAttribute: NSMetadataItemPathKey) as? String).map { URL(fileURLWithPath: $0) } }
            guard !files.isEmpty else { return }
            Task { @MainActor in found(files) }
        }
        queue.addOperation { [query = self.query] in query.value.start() }
    }
}

/// Hands a value that isn't `Sendable` to the one queue that uses it from then on.
struct Unchecked<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}
