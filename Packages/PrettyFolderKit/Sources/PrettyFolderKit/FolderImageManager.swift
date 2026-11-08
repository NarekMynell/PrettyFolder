import AppKit
import UniformTypeIdentifiers

/// What happened to one folder during an operation.
public struct FolderOutcome: Sendable, Equatable {
    public let folder: URL
    /// `nil` on success, otherwise a sentence that can be shown to the user.
    public let failure: String?

    public var succeeded: Bool { failure == nil }

    public init(folder: URL, failure: String?) {
        self.folder = folder
        self.failure = failure
    }

    static func ok(_ folder: URL) -> FolderOutcome { FolderOutcome(folder: folder, failure: nil) }
    static func failed(_ folder: URL, _ error: Error) -> FolderOutcome {
        FolderOutcome(folder: folder, failure: error.localizedDescription)
    }
}

/// Everything the look editor needs to show a managed folder.
public struct FolderLook: Sendable, Equatable {
    public let folder: URL
    /// The stored copy of the picture.
    public let pictureURL: URL
    /// The style currently in effect.
    public let style: IconStyle
    /// Where the picture sits in the style's rectangle.
    public let placement: PicturePlacement
    /// `true` when the folder follows the default look.
    public let followsDefault: Bool
}

/// An icon PrettyFolder drew for a folder. It isn't changed after it's made, so it can be
/// handed to the main thread.
public struct RenderedIcon: @unchecked Sendable {
    public let image: NSImage
    /// Counts up with every icon written, so the newest of several can be told apart.
    public let sequence: Int
}

/// What happened to a folder's icon (see `FolderImageManager.onIconChange`).
public enum IconChange: Sendable {
    /// A new icon is on disk. Finder is told about it once the handler returns.
    case written(RenderedIcon)
    /// The folder has its standard icon again.
    case removed
}

public enum FolderImageError: LocalizedError {
    case renderFailed
    case setIconFailed(String)
    case diskFull(String)
    case notManaged(String)
    case cannotStorePicture
    case unreachable(String)
    case stopped
    case pictureLost(String)
    case newerList

    public var errorDescription: String? {
        switch self {
        case .renderFailed: return "The icon could not be drawn."
        case .setIconFailed(let name): return "macOS refused to change the icon of “\(name)”. Check that PrettyFolder may access this location in System Settings › Privacy & Security."
        case .diskFull(let name): return "There isn't enough room on the disk of “\(name)” for its new icon. Make some room there and try again."
        case .notManaged(let name): return "“\(name)” doesn't have a picture from PrettyFolder."
        case .cannotStorePicture: return "The picture could not be saved."
        case .unreachable(let name): return "PrettyFolder couldn't reach “\(name)”. If it's on a disk that isn't connected, connect the disk and try again."
        case .stopped: return "PrettyFolder is quitting."
        case .pictureLost(let name): return "PrettyFolder no longer has its copy of the picture on “\(name)”. Choose the picture again to change how it looks."
        case .newerList: return "A newer version of PrettyFolder keeps track of this folder. Update PrettyFolder to change how it looks."
        }
    }
}

/// Puts pictures on folder icons, takes them off again and keeps track of them.
///
/// Work runs on this actor one piece at a time between its `await`s, where the app is told
/// about a change. Everything is saved before each of them, and whatever might have changed
/// meanwhile is read again after it. The icon itself is made by
/// `NSWorkspace.setIcon(_:forFile:options:)`, the same call Finder's own Get Info uses, and
/// one that takes another's place is put there whole (see `IconFile`).
public actor FolderImageManager {
    /// Extended attribute that ties a folder to its record.
    static let markerAttribute = "com.narekmynell.prettyfolder"

    private var library: FolderLibrary
    /// See `onIconChange`.
    private var iconChanged: (@Sendable (URL, IconChange) async -> Void)?
    private var iconsWritten = 0
    /// Set when the app quits: nothing more is written, and long runs end at the next folder.
    private var isStopped = false
    /// Set when a record was refreshed in memory (a folder moved) but not written yet.
    private var hasUnsavedChanges = false
    /// Set while folders found on the disks get their records (see `takeOn`).
    private var isFinding = false
    /// Folders found showing a picture from PrettyFolder that nothing says anything about any more:
    /// copies from before folders carried their look. They can only have it taken off. (One that
    /// says which picture it shows, and it isn't here, comes from another Mac or another person on
    /// this one, and stays theirs.)
    private var strays = Set<URL>()
    private lazy var renderer = IconRenderer()
    /// See `findFolders`: the reaches searched now, those to be searched (again) after that, and
    /// who waits for which. Twelve searches once waited at the same time for a Spotlight that
    /// never answered, one for each disk connected while the Mac was locked.
    private var searchesUnderWay: Set<FolderSearchReach> = []
    private var searchesAskedFor: Set<FolderSearchReach> = []
    private var waitingForSearch: [FolderSearchReach: [Int: CheckedContinuation<Void, Never>]] = [:]
    private var waitingForNextSearch: [FolderSearchReach: [Int: CheckedContinuation<Void, Never>]] = [:]
    private var searchTickets = 0
    /// Goes through the disks (`FolderSearch.markedFolders`); a test can stand in for it.
    private let searcher: @Sendable (FolderSearchReach, [String]) -> [URL]
    public private(set) var defaultStyle: IconStyle
    private let unusedPictureAllowance: Int

    public init(directory: URL, defaultStyle: IconStyle) {
        self.init(directory: directory, defaultStyle: defaultStyle, unusedPictureAllowance: Self.unusedPictureAllowance)
    }

    init(
        directory: URL, defaultStyle: IconStyle, unusedPictureAllowance: Int,
        searcher: @escaping @Sendable (FolderSearchReach, [String]) -> [URL] = { FolderSearch.markedFolders($0, knownPaths: $1) }
    ) {
        self.library = FolderLibrary(directory: directory)
        self.defaultStyle = defaultStyle
        self.unusedPictureAllowance = unusedPictureAllowance
        self.searcher = searcher
    }

    /// Called whenever a folder's icon changes. A new icon comes before Finder is told about
    /// it: Finder shows its plain folder for a moment while it loads a changed icon, and the app
    /// covers that moment with the icon Finder is about to load.
    public func onIconChange(_ handler: (@Sendable (URL, IconChange) async -> Void)?) {
        iconChanged = handler
    }

    /// A quick guess at whether `folder` shows a picture from PrettyFolder: it carries the
    /// marker and a custom icon. Cheap enough to ask while the pointer moves; the icon
    /// itself isn't compared, so ask `showsOwnPicture` before relying on it.
    public static func appearsToHavePicture(_ folder: URL) -> Bool {
        ExtendedAttributes.value(named: markerAttribute, at: folder) != nil && FolderInspector.hasCustomIcon(folder)
    }

    /// Whether `folder` shows exactly the icon PrettyFolder made for it, and not one somebody
    /// else put there since.
    public func showsOwnPicture(_ folder: URL) -> Bool {
        guard let id = markerID(of: folder) else { return false }
        if let record = library.record(id) { return isStillOurs(record, folder) }
        return carriedLook(of: folder) != nil
    }

    /// For quitting: lets the folder being written finish, then writes nothing more. Long runs
    /// (Redraw All, Remove All, a picture for many folders) end at the next folder.
    public func stop() {
        isStopped = true
    }

    /// `~/Library/Application Support/PrettyFolder`
    public static var standardDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PrettyFolder", isDirectory: true)
    }

    // MARK: - Putting pictures on folders

    /// Puts the picture in `imageURL` on every folder. Folders keep their own look if they
    /// have one; the picture starts in the middle of it, at the size the look gives it.
    public func apply(imageAt imageURL: URL, to folders: [URL]) async -> [FolderOutcome] {
        // A link to a picture is that picture, whose type says how to keep it.
        let imageURL = imageURL.resolvingSymlinksInPath()
        let type = (try? imageURL.resourceValues(forKeys: [.contentTypeKey]))?.contentType
            ?? UTType(filenameExtension: imageURL.pathExtension)
        let picture: SourceImage
        do {
            picture = try await ImageLoader.loadAllowingQuickLook(contentsOf: imageURL)
        } catch {
            return folders.map { .failed($0, error) }
        }
        guard let stored = PictureEncoder.storableData(for: picture, original: imageURL, originalType: type) else {
            return folders.map { .failed($0, FolderImageError.cannotStorePicture) }
        }
        return await apply(picture, storedAs: stored, to: folders)
    }

    /// Puts a picture given as raw data (from a drag or the clipboard) on every folder.
    public func apply(imageData: Data, type: UTType?, to folders: [URL]) async -> [FolderOutcome] {
        let picture: SourceImage
        do {
            picture = try ImageLoader.load(data: imageData, typeHint: type)
        } catch {
            return folders.map { .failed($0, error) }
        }
        let stored: (data: Data, fileExtension: String)?
        if case .vector = picture.content, let type {
            stored = PictureEncoder.storableData(forVectorData: imageData, type: type)
                ?? PictureEncoder.storableData(for: picture, original: nil, originalType: nil)
        } else {
            stored = PictureEncoder.storableData(for: picture, original: nil, originalType: nil)
        }
        guard let stored else { return folders.map { .failed($0, FolderImageError.cannotStorePicture) } }
        return await apply(picture, storedAs: stored, to: folders)
    }

    private func apply(_ picture: SourceImage, storedAs stored: (data: Data, fileExtension: String), to folders: [URL]) async -> [FolderOutcome] {
        let pictureName: String
        // One already there may have been kept for copies of a folder that had it.
        let wasThere = library.hasPicture(stored.data, fileExtension: stored.fileExtension)
        do {
            pictureName = try library.storePicture(stored.data, fileExtension: stored.fileExtension)
        } catch {
            return folders.map { .failed($0, FolderImageError.cannotStorePicture) }
        }

        var outcomes: [FolderOutcome] = []
        // Folders with the same look get the very same icon, drawn once.
        var drawn: [IconStyle: NSImage] = [:]
        for folder in unique(folders) {
            if isStopped { break }
            do {
                try FolderInspector.validate(folder)
                // The last folder may have lost the picture while the app was told about it, and
                // the stored copy went with it. It is still needed here.
                _ = try library.storePicture(stored.data, fileExtension: stored.fileExtension)
                // Keep the folder's own look when it already had a picture from us. Where the
                // old picture sat in it, and how big, says nothing about the new one.
                let existing = ownedRecord(for: folder)
                let stale = existing == nil ? staleRecord(of: folder) : nil
                let bookmark = try folder.bookmarkData()
                let style = existing?.style ?? defaultStyle
                let image = try drawn[style] ?? draw(picture, style: style, placement: .natural)
                drawn[style] = image
                let id = existing?.id ?? UUID()
                // Asked first, before anything changes: a folder that refuses its marker couldn't
                // be told apart later.
                let earlierMarker = ExtendedAttributes.value(named: Self.markerAttribute, at: folder)
                guard ExtendedAttributes.set(Data(id.uuidString.utf8), named: Self.markerAttribute, at: folder) else {
                    throw FolderImageError.setIconFailed(displayName(folder))
                }
                let icon: WrittenIcon
                do {
                    icon = try writeIcon(image, to: folder)
                } catch {
                    if let earlierMarker {
                        ExtendedAttributes.set(earlierMarker, named: Self.markerAttribute, at: folder)
                    } else {
                        ExtendedAttributes.remove(named: Self.markerAttribute, at: folder)
                    }
                    throw error
                }
                let now = Date()
                let record = FolderRecord(
                    id: id,
                    bookmark: bookmark,
                    lastKnownPath: FolderInspector.canonicalPath(folder.path),
                    pictureName: pictureName,
                    style: existing?.style,
                    iconDigest: icon.digest,
                    created: existing?.created ?? now,
                    updated: now,
                    fileNumber: FolderInspector.fileNumber(of: folder)
                )
                carry(record, on: folder)
                library.upsert(record)
                // The record from before someone else changed the icon goes now, not at the next tidy-up.
                if let stale { library.remove(stale.id) }
                if let oldPicture = existing?.pictureName, oldPicture != pictureName {
                    library.retirePictureIfUnused(oldPicture)
                }
                persist()
                outcomes.append(.ok(folder))
                await show(icon)
            } catch {
                outcomes.append(.failed(folder, error))
            }
        }
        // Nothing may have worked; don't keep a picture no folder uses.
        if !wasThere { library.deletePictureIfUnused(pictureName) }
        persist()
        return outcomes
    }

    // MARK: - Removing pictures

    /// Puts every folder back to the standard icon. Works for any custom icon, not only
    /// the ones PrettyFolder made, because that is what "remove" means in Finder too.
    public func removeImage(from folders: [URL]) async -> [FolderOutcome] {
        var outcomes: [FolderOutcome] = []
        var removed: [URL] = []
        for folder in unique(folders) {
            if isStopped { break }
            // Never reach into apps or other packages: removing an icon file from a bundle
            // breaks its signature just like adding one.
            do {
                try FolderInspector.validate(folder)
            } catch {
                outcomes.append(.failed(folder, error))
                continue
            }
            let id = markerID(of: folder)
            // A copied folder carries the original's marker; only drop the record if it is really
            // this folder's. Asked now: the marker and the icon are how that is told.
            var isItsRecord = false
            if let id, var record = library.record(id) { isItsRecord = describes(&record, folder) }
            let hadIcon = FolderInspector.hasCustomIcon(folder)
                || FileManager.default.fileExists(atPath: FolderInspector.iconFileURL(for: folder).path)
            if hadIcon {
                let removed = FolderMetadata.keepingModificationDate(of: folder) {
                    NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: [])
                }
                guard removed else {
                    outcomes.append(.failed(folder, FolderImageError.setIconFailed(displayName(folder))))
                    continue
                }
            }
            FolderMetadata.forgetIconChanges(folder)
            ExtendedAttributes.remove(named: Self.markerAttribute, at: folder)
            CarriedLook.remove(from: folder)
            if let id, isItsRecord { library.remove(id) }
            outcomes.append(.ok(folder))
            removed.append(folder)
        }
        persist()
        // A folder may have a new picture already, put on while the app was being told about
        // another one.
        for folder in removed where !Self.appearsToHavePicture(folder) {
            await iconChanged?(folder, .removed)
        }
        return outcomes
    }

    // MARK: - Per-folder look

    /// The look of a folder that has a picture from PrettyFolder, or `nil`. A copy of such a
    /// folder, looked at for the first time, gets a record of its own (see `ownedRecord`).
    public func look(for folder: URL) async -> FolderLook? {
        guard var record = ownedRecord(for: folder) else { return nil }
        if hasUnsavedChanges { persist() }
        // Moved out of reach, a folder may have missed a new default look. Now it's found.
        if (record.revision ?? 1) < IconRenderer.revision {
            _ = await redraw([record], progress: nil)
            guard let redrawn = library.record(record.id) else { return nil }
            record = redrawn
        }
        return FolderLook(
            folder: folder,
            pictureURL: library.pictureURL(named: record.pictureName),
            style: record.style ?? defaultStyle,
            placement: record.placement ?? .natural,
            followsDefault: record.style == nil
        )
    }

    /// Changes one folder's look and where its picture sits in it. Pass `nil` for the look to
    /// make the folder follow the default look again.
    public func setStyle(_ style: IconStyle?, placement: PicturePlacement, for folder: URL) async throws {
        try await change(folder) { record in
            record.style = style
            record.placement = placement == .natural ? nil : placement
        }
    }

    /// Changes one folder's look; its picture stays where it is in it. Pass `nil` to make the
    /// folder follow the default look again.
    public func setStyle(_ style: IconStyle?, for folder: URL) async throws {
        try await change(folder) { $0.style = style }
    }

    /// Moves one folder's picture inside its look, which stays as it is.
    public func setPlacement(_ placement: PicturePlacement, for folder: URL) async throws {
        try await change(folder) { $0.placement = placement == .natural ? nil : placement }
    }

    /// Changes a folder's record with `edit`, as it is when the change comes in, and redraws it.
    private func change(_ folder: URL, _ edit: (inout FolderRecord) -> Void) async throws {
        guard var record = ownedRecord(for: folder) else {
            guard FileManager.default.fileExists(atPath: folder.path) else {
                throw FolderInspector.Problem.missing(displayName(folder))
            }
            throw FolderImageError.notManaged(displayName(folder))
        }
        // Its list can't be saved, and that list would no longer recognize the new icon as ours.
        guard !library.isReadOnly else { throw FolderImageError.newerList }
        let picture = try loadPicture(of: record, for: folder)
        edit(&record)
        record.wasFound = nil
        let icon = try writeIcon(draw(picture, style: record.style ?? defaultStyle, placement: record.placement ?? .natural), to: folder)
        record.iconDigest = icon.digest
        record.revision = IconRenderer.revision
        record.updated = Date()
        carry(record, on: folder)
        library.upsert(record)
        persist()
        await show(icon)
    }

    // MARK: - Default look

    /// Number of folders that follow the default look. Those deleted aren't counted, though
    /// they stay on the list for a while.
    public func folderCountFollowingDefault() -> Int {
        library.records.values.filter { $0.style == nil && !isGone($0) }.count
    }

    /// Number of folders on the list, deleted ones included.
    public func managedFolderCount() -> Int {
        library.records.count
    }

    /// Number of folders with a picture, for saying so: those known and not deleted, and those
    /// that can only have it taken off.
    public func folderCountWithPictures() -> Int {
        library.records.values.filter { !isGone($0) }.count + currentStrays().count
    }

    /// Those that are still what they were when they were found. `justRemoved`: records Remove All
    /// has just let go of, which their copies still name.
    private func currentStrays(justRemoved: Set<UUID> = []) -> [URL] {
        strays.filter { Self.appearsToHavePicture($0) && isStray($0, justRemoved: justRemoved) }
    }

    /// Whether a record's folder has been deleted, as far as can be told: it can't be found, and
    /// nothing stands in the way of finding it.
    private func isGone(_ record: FolderRecord) -> Bool {
        var record = record
        guard resolve(&record) == nil, !FolderInspector.isOnDiskThatIsAway(record.lastKnownPath) else { return false }
        if FolderInspector.isKnownToBeAbsent(record.lastKnownPath) { return true }
        // Another folder has taken its place, unless what is there can't be read.
        if case .unreadable = ExtendedAttributes.read(named: Self.markerAttribute, at: URL(fileURLWithPath: record.lastKnownPath)) { return false }
        return true
    }

    /// Changes the default look.
    /// - Parameter updateExisting: `true` redraws every folder that follows the default;
    ///   `false` pins those folders to the old look so only new pictures get the new one.
    public func setDefaultStyle(
        _ style: IconStyle,
        updateExisting: Bool,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async -> [FolderOutcome] {
        let previous = defaultStyle
        defaultStyle = style
        guard previous != style else { return [] }

        let followers = library.records.values.filter { $0.style == nil }
        if !updateExisting {
            for var record in followers {
                record.style = previous
                library.upsert(record)
            }
            persist()
            return []
        }
        // They follow the new look from now on. Those this run doesn't get to, on a disk that
        // isn't connected or because the app quits, get it once they can (`redrawOutdated`).
        for var record in followers {
            record.revision = nil
            library.upsert(record)
        }
        persist()
        return await redraw(followers, progress: progress)
    }

    // MARK: - Maintenance

    /// Redraws every managed folder, for example after a macOS update changed the folder artwork.
    public func redrawAll(progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [FolderOutcome] {
        renderer = IconRenderer()
        return await redraw(Array(library.records.values), progress: progress)
    }

    /// Redraws the folders whose icon an earlier version drew differently (see
    /// `IconRenderer.revision`). Folders that can't be reached now keep theirs until next time.
    public func redrawOutdated() async -> [FolderOutcome] {
        // A disk may have come back: its folders aren't missing any more, whichever are behind.
        for var record in library.records.values where record.missingSince != nil {
            _ = resolve(&record)
        }
        if hasUnsavedChanges { persist() }
        // Not those only found on a disk: nobody asked for anything on what may be a backup.
        let outdated = library.records.values.filter { ($0.revision ?? 1) < IconRenderer.revision && $0.wasFound != true }
        guard !outdated.isEmpty else { return [] }
        return await redraw(outdated, progress: nil)
    }

    /// Takes every PrettyFolder picture off and forgets about them, before uninstalling. A
    /// folder that can't be reached or changed right now (on a disk that isn't connected,
    /// say) keeps its record and comes back as a failure, so it can be done later; a folder
    /// whose icon someone else changed is only forgotten.
    ///
    /// With `search` still going on, what it turns up goes the same way once it is done. A picture
    /// given to a folder meanwhile is new, and stays.
    public func removeAll(progress: (@Sendable (Int, Int) -> Void)? = nil, whileSearching search: Task<Void, Never>? = nil) async -> [FolderOutcome] {
        var outcomes = await removeKnown(onlyFound: false, progress: progress)
        if let search {
            await search.value
            let later = await removeKnown(onlyFound: true, progress: progress)
            let retried = Set(later.map(\.folder.path))
            outcomes = outcomes.filter { !retried.contains($0.folder.path) } + later
        }
        // Stopped for quitting: whatever was done is saved already, and a copy starting meanwhile
        // may be about to use a picture this would delete.
        if !isStopped {
            library.collectGarbage()
            persist()
        }
        return outcomes
    }

    private func removeKnown(onlyFound: Bool, progress: (@Sendable (Int, Int) -> Void)?) async -> [FolderOutcome] {
        var outcomes: [FolderOutcome] = []
        var handled = Set<UUID>()
        func isDue(_ record: (key: UUID, value: FolderRecord)) -> Bool {
            !handled.contains(record.key) && (!onlyFound || record.value.wasFound == true)
        }
        // Drops and menu actions keep working meanwhile, so always take the library as it
        // is now rather than a list made at the start.
        while !isStopped, let id = library.records.first(where: isDue)?.key {
            handled.insert(id)
            guard var record = library.record(id) else { continue }
            if let folder = resolve(&record) {
                switch ownership(of: folder, by: record) {
                case .ours:
                    let outcome = await removeImage(from: [folder])
                    outcomes += outcome
                    if let now = library.record(id), now.lastKnownPath != record.lastKnownPath {
                        // A copy under the same marker came on the list while the app was being
                        // told: it has its own picture to lose.
                        handled.remove(id)
                    } else if outcome.allSatisfy(\.succeeded), library.record(id) != nil {
                        // Normally gone with the picture already; not when the folder's marker
                        // pointed elsewhere.
                        library.remove(id)
                        persist()
                    }
                case .theirs:
                    forget(folder, record: record)
                    library.remove(id)
                    persist()
                case .unknown:
                    outcomes.append(.failed(folder, FolderImageError.unreachable(displayName(folder))))
                }
            } else if isGone(record) {
                // Deleted. Nothing to take off, and nothing to tell.
                library.remove(id)
                persist()
            } else {
                let folder = URL(fileURLWithPath: record.lastKnownPath, isDirectory: true)
                outcomes.append(.failed(folder, FolderImageError.unreachable(displayName(folder))))
            }
            let left = library.records.filter(isDue).count
            progress?(handled.count, handled.count + left)
            await Task.yield()
        }
        if !isStopped {
            let found = currentStrays(justRemoved: handled)
            let done = await removeImage(from: found)
            // Those it didn't work for are still there to be told about, and tried again.
            strays = Set(done.filter { !$0.succeeded }.map(\.folder))
            outcomes += done
        }
        return outcomes
    }

    /// How long a folder that can't be found is remembered. It may be on a disk that
    /// isn't connected, or moved to another disk and not touched since. A picture no folder
    /// on the list uses stays at least as long, for copies on such a disk.
    public static let missingGracePeriod: TimeInterval = 90 * 24 * 60 * 60

    /// Past that, pictures no folder on the list uses stay as long as they all fit in this many
    /// bytes, the oldest going first: such a copy can still be changed years later.
    public static let unusedPictureAllowance = 500 * 1024 * 1024

    /// Puts on the list the folders across the Mac's disks that show a picture from PrettyFolder
    /// and aren't on it yet: copies nobody has opened, folders moved to another disk or around one
    /// where they can't be followed. From then on a new default look, Redraw All and Remove All
    /// reach them like any other. The disks are searched off this actor, unhurried unless someone
    /// is waiting for it.
    ///
    /// Returns once a search that began after the call is done, or once `patience` is up: the
    /// search goes on, and what it finds still comes on the list. A search of a reach goes on at
    /// a time, and those asked for meanwhile are one search after it, however many there are.
    public func findFolders(_ reach: FolderSearchReach = .spotlight, patience: Duration? = nil) async {
        searchTickets += 1
        let ticket = searchTickets
        let givingUp = patience.map { patience in
            Task {
                guard (try? await Task.sleep(for: patience)) != nil else { return }
                stopWaiting(ticket, for: reach)
            }
        }
        await withCheckedContinuation { continuation in
            waitingForNextSearch[reach, default: [:]][ticket] = continuation
            searchesAskedFor.insert(reach)
            if searchesUnderWay.insert(reach).inserted {
                Task { await search(reach) }
            }
        }
        givingUp?.cancel()
    }

    private func search(_ reach: FolderSearchReach) async {
        while searchesAskedFor.remove(reach) != nil {
            waitingForSearch[reach] = waitingForNextSearch.removeValue(forKey: reach)
            let known = library.records.values.map(\.lastKnownPath)
            let found = await FolderSearch.run(reach) { [searcher] in searcher(reach, known) }
            await takeOn(found)
            for waiting in (waitingForSearch.removeValue(forKey: reach) ?? [:]).values {
                waiting.resume()
            }
        }
        searchesUnderWay.remove(reach)
    }

    private func stopWaiting(_ ticket: Int, for reach: FolderSearchReach) {
        let waiting = waitingForNextSearch[reach]?.removeValue(forKey: ticket)
            ?? waitingForSearch[reach]?.removeValue(forKey: ticket)
        waiting?.resume()
    }

    /// The same for icon files Spotlight has just got to know about.
    public func takeOn(iconFiles: [URL]) async {
        let found = await FolderSearch.check { FolderSearch.markedFolders(holding: iconFiles) }
        await takeOn(found)
    }

    /// Those among `folders` that show a picture from PrettyFolder get a record, if they have none.
    func takeOn(_ folders: [URL]) async {
        guard !library.isReadOnly else { return }
        // Most are known, right where they were: no need to read their icon.
        let new = folders.filter { folder in
            guard let id = markerID(of: folder), let record = library.record(id) else { return true }
            return record.lastKnownPath != FolderInspector.canonicalPath(folder.path) || record.fileNumber != FolderInspector.fileNumber(of: folder)
        }
        // A few at a time, the list saved after each few: saving it after each one takes longer the
        // longer it gets. Other work gets its turn in between.
        var next = new[...]
        while !next.isEmpty, !isStopped {
            isFinding = true
            for folder in next.prefix(32) where ownedRecord(for: folder) == nil && isStray(folder) {
                strays.insert(folder)
            }
            isFinding = false
            next = next.dropFirst(32)
            persist()
            await Task.yield()
        }
    }

    /// Forgets folders whose icon was changed by something else, and folders that have
    /// been missing for longer than `missingGracePeriod`. Folders that can't be read right
    /// now are kept as they are.
    public func prune(now: Date = Date()) {
        var changed = false
        for id in Array(library.records.keys) {
            guard var record = library.record(id) else { continue }
            guard let folder = resolve(&record) else {
                if let since = record.missingSince {
                    if now.timeIntervalSince(since) > Self.missingGracePeriod {
                        library.remove(id, at: now)
                        changed = true
                    }
                } else {
                    record.missingSince = now
                    library.upsert(record)
                    changed = true
                }
                continue
            }
            if ownership(of: folder, by: record) == .theirs {
                // Someone replaced or removed the icon; what we left on the folder is stale too.
                forget(folder, record: record)
                library.remove(id, at: now)
                changed = true
            } else if record.revision == IconRenderer.revision, record.iconDigest == FolderInspector.iconResource(of: folder)?.sha256,
                      CarriedLook.read(from: folder)?.iconDigest != record.iconDigest {
                // From before folders carried their look. Others are about to be redrawn.
                carry(record, on: folder)
            }
        }
        library.collectGarbage(retiredBefore: now.addingTimeInterval(-Self.missingGracePeriod), allowance: unusedPictureAllowance)
        if changed || hasUnsavedChanges { persist() }
    }

    // MARK: - Internals

    private func redraw(_ records: [FolderRecord], progress: (@Sendable (Int, Int) -> Void)?) async -> [FolderOutcome] {
        var outcomes: [FolderOutcome] = []
        // Folders with the same picture come one after another, so only one is open at a time.
        let records = records.sorted { $0.pictureName < $1.pictureName }
        var open: (name: String, picture: SourceImage)?
        for (index, original) in records.enumerated() {
            if Task.isCancelled || isStopped { break }
            // The record may have changed while this loop was suspended.
            guard var record = library.record(original.id) else { continue }
            if let folder = resolve(&record), isStillOurs(record, folder) {
                do {
                    guard !library.isReadOnly else { throw FolderImageError.newerList }
                    // It may have been moved into an app since it got its picture.
                    try FolderInspector.validate(folder)
                    let picture: SourceImage
                    if let open, open.name == record.pictureName {
                        picture = open.picture
                    } else {
                        open = nil
                        picture = try loadPicture(of: record, for: folder)
                        open = (record.pictureName, picture)
                    }
                    let image = try draw(picture, style: record.style ?? defaultStyle, placement: record.placement ?? .natural)
                    let icon = try writeIcon(image, to: folder)
                    record.iconDigest = icon.digest
                    record.revision = IconRenderer.revision
                    record.updated = Date()
                    carry(record, on: folder)
                    library.upsert(record)
                    // Saved before the app is told: if it quits meanwhile, the library still
                    // knows the folder's new icon as its own.
                    persist()
                    outcomes.append(.ok(folder))
                    await show(icon)
                } catch {
                    outcomes.append(.failed(folder, error))
                }
            }
            progress?(index + 1, records.count)
            await Task.yield()
        }
        persist()
        return outcomes
    }

    /// An icon that was just written, still to be shown in Finder.
    private struct WrittenIcon {
        let folder: URL
        let image: NSImage
        /// The digest of what was written.
        let digest: String
        /// Whether it took the place of another custom icon.
        let replaced: Bool
        let sequence: Int
        /// The icon file it took the place of, until Finder has been told.
        let oldFile: IconFile.Replaced?
    }

    /// The stored copy of the picture on `folder`.
    private func loadPicture(of record: FolderRecord, for folder: URL) throws -> SourceImage {
        let url = library.pictureURL(named: record.pictureName)
        guard FileManager.default.fileExists(atPath: url.path) else { throw FolderImageError.pictureLost(displayName(folder)) }
        return try ImageLoader.load(contentsOf: url)
    }

    /// The icon for `picture` in `style`.
    private func draw(_ picture: SourceImage, style: IconStyle, placement: PicturePlacement) throws -> NSImage {
        let icon: NSImage? = autoreleasepool { renderer.makeIcon(with: picture, style: style, placement: placement) }
        guard let icon else { throw FolderImageError.renderFailed }
        return icon
    }

    /// Writes the icon. Finder isn't told yet: see `show`, which every icon written goes to.
    private func writeIcon(_ image: NSImage, to folder: URL) throws -> WrittenIcon {
        guard !isStopped else { throw FolderImageError.stopped }
        let replacing = FolderInspector.hasCustomIcon(folder)
        let hadIconFile = !FolderInspector.hasNoIconFile(folder)
        let (written, oldFile) = FolderMetadata.keepingModificationDate(of: folder) {
            autoreleasepool { IconFile.write(image, to: folder) }
        }
        // Whole, too: on a disk that is all but full, macOS can say it worked and leave an icon
        // file with no picture in it.
        guard written, let resource = FolderInspector.iconResource(of: folder), IconFile.isWhole(resource) else {
            oldFile?.discard()
            // macOS may have got as far as the file before being refused the rest. A folder that
            // had no icon of its own goes back to having none.
            if !hadIconFile {
                FolderMetadata.keepingModificationDate(of: folder) {
                    _ = NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: [])
                }
                removeIconFile(of: folder)
            }
            throw Self.isAlmostFull(folder) ? FolderImageError.diskFull(displayName(folder)) : FolderImageError.setIconFailed(displayName(folder))
        }
        library.noteWrittenIcon(resource.sha256)
        iconsWritten += 1
        return WrittenIcon(folder: folder, image: image, digest: resource.sha256, replaced: replacing, sequence: iconsWritten, oldFile: oldFile)
    }

    /// Whether the disk `folder` is on has too little room left for an icon (a megabyte or so, twice
    /// while the new one is made beside the old).
    private static func isAlmostFull(_ folder: URL) -> Bool {
        var folder = folder
        folder.removeAllCachedResourceValues()
        guard let free = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity else { return false }
        return free < 8 << 20
    }

    /// Gets Finder to show an icon that was just written. A first icon shows by itself,
    /// because Finder sees the custom icon flag go on; a replaced one needs telling. The app
    /// gets the icon first, to cover the moment Finder shows a plain folder while it loads it.
    ///
    /// Called once the library is saved: other work may run on the actor while the app is
    /// asked, so the folder is checked again afterwards.
    private func show(_ icon: WrittenIcon) async {
        defer { icon.oldFile?.discard() }
        // Removed in the meantime.
        guard Self.appearsToHavePicture(icon.folder) else { return }
        await iconChanged?(icon.folder, .written(RenderedIcon(image: icon.image, sequence: icon.sequence)))
        guard icon.replaced, Self.appearsToHavePicture(icon.folder) else { return }
        FolderMetadata.noteIconChanged(icon.folder)
    }

    private func removeIconFile(of folder: URL) {
        FolderMetadata.keepingModificationDate(of: folder) {
            try? FileManager.default.removeItem(at: FolderInspector.iconFileURL(for: folder))
        }
    }

    /// The folder's icon isn't PrettyFolder's any more: leave nothing of ours on it. That is
    /// the marker, the count in its Finder info, and our icon file when only the custom icon
    /// flag was turned off and the file was left behind.
    private func forget(_ folder: URL, record: FolderRecord) {
        let carriedDigest = CarriedLook.read(from: folder)?.iconDigest
        if markerID(of: folder) == record.id {
            ExtendedAttributes.remove(named: Self.markerAttribute, at: folder)
            CarriedLook.remove(from: folder)
        }
        if FolderInspector.customIconFlag(folder) == false, let digest = FolderInspector.iconResource(of: folder)?.sha256,
           digest == record.iconDigest || digest == carriedDigest {
            removeIconFile(of: folder)
        }
        FolderMetadata.forgetIconChanges(folder)
    }

    /// The record the folder's marker points to when it is this folder's own, but the icon is
    /// no longer PrettyFolder's: somebody else changed it since.
    private func staleRecord(of folder: URL) -> FolderRecord? {
        guard let id = markerID(of: folder), var record = library.record(id) else { return nil }
        if describes(&record, folder) { return record }
        // Its folder can't be found with its disk here, and this one has its marker. This is what
        // became of it, or a copy; if there is another such folder, the search finds it again.
        return resolve(&record) == nil && !FolderInspector.isOnDiskThatIsAway(record.lastKnownPath) ? record : nil
    }

    /// The record for `folder` if PrettyFolder made its current icon.
    ///
    /// Its marker may lead to the record of the folder it was copied from, however that one has
    /// changed since, or to none at all. A copy gets a record of its own, so it can be edited on
    /// its own, from what it says about its icon.
    private func ownedRecord(for folder: URL) -> FolderRecord? {
        guard let id = markerID(of: folder) else { return nil }
        let carried = carriedLook(of: folder)
        guard var record = library.record(id) else {
            return carried.flatMap { newRecord(for: folder, showing: $0, id: id) }
        }
        guard isStillOurs(record, folder) else { return nil }
        let original = resolve(&record)
        if let original, sameItem(original, folder) { return record }
        guard original == nil, seemsToHaveMoved(record, to: folder) else {
            return newRecord(for: folder, showing: carried ?? CarriedLook(of: record, defaultStyle: defaultStyle))
        }
        guard let bookmark = try? folder.bookmarkData() else { return nil }
        record.bookmark = bookmark
        record.lastKnownPath = FolderInspector.canonicalPath(folder.path)
        record.missingSince = nil
        record.fileNumber = FolderInspector.fileNumber(of: folder)
        if carried == nil, record.revision == IconRenderer.revision { carry(record, on: folder) }
        library.upsert(record)
        persist()
        return record
    }

    /// Whether `folder` is most likely what became of a record's folder that can't be found: moved
    /// to another disk, since Finder does that by copying, then deleting. It shows what the record
    /// says, and the disk the record's folder was on is there, without it. With that disk away,
    /// the folder is on it, and this is a copy.
    private func seemsToHaveMoved(_ record: FolderRecord, to folder: URL) -> Bool {
        record.iconDigest == FolderInspector.iconResource(of: folder)?.sha256
            && !FolderInspector.isOnDiskThatIsAway(record.lastKnownPath)
    }

    /// A new record for a folder whose icon `look` describes, under the marker it has if its `id`
    /// is free, for a list set aside may yet be put right. Without its picture the icon couldn't
    /// be changed, or even drawn again: it comes from another Mac, say.
    private func newRecord(for folder: URL, showing look: CarriedLook, id: UUID? = nil) -> FolderRecord? {
        guard FileManager.default.fileExists(atPath: library.pictureURL(named: look.pictureName).path),
              let bookmark = try? folder.bookmarkData()
        else { return nil }
        let now = Date()
        var record = FolderRecord(
            id: id ?? UUID(), bookmark: bookmark, lastKnownPath: FolderInspector.canonicalPath(folder.path),
            pictureName: look.pictureName, style: nil, iconDigest: look.iconDigest,
            created: now, updated: now, fileNumber: FolderInspector.fileNumber(of: folder)
        )
        record.take(look, defaultStyle: defaultStyle)
        record.wasFound = isFinding ? true : nil
        // A list that can't be saved wouldn't find the folder again by a new marker. It can be
        // looked at all the same; changing it is refused.
        if library.isReadOnly { return record }
        // One that can't take the marker couldn't find its record again.
        if id == nil, !ExtendedAttributes.set(Data(record.id.uuidString.utf8), named: Self.markerAttribute, at: folder) {
            return nil
        }
        look.write(to: folder)
        library.upsert(record)
        persist()
        return record
    }

    /// Whether a folder without a record, and none to be had, is a copy from before folders carried
    /// their look. The marker is all there is to go by, unless it is the record's own folder, whose
    /// icon someone else has changed.
    private func isStray(_ folder: URL, justRemoved: Set<UUID> = []) -> Bool {
        guard let id = markerID(of: folder), FolderInspector.customIconFlag(folder) == true, CarriedLook.read(from: folder) == nil,
              let resource = FolderInspector.iconResource(of: folder)
        else { return false }
        let record = library.record(id)
        // Only with an icon PrettyFolder drew. The marker goes on before the icon, so a write cut
        // short (the app stopped in between) can leave it on a folder showing its owner's icon, or on
        // an icon file with nothing in it that its owner replaces later; that marker names no record.
        // An icon from before the list kept track of them counts on a copy of a folder it knows.
        let namesAKnownFolder = record != nil || justRemoved.contains(id)
        guard library.wroteIcon(resource.sha256)
                || (namesAKnownFolder && (Self.iconFileDate(of: folder) ?? .distantFuture) < library.writtenIconsSince)
        else { return false }
        guard var record else { return true }
        return !describes(&record, folder)
    }

    /// When the folder's icon file was written.
    private static func iconFileDate(of folder: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: FolderInspector.iconFileURL(for: folder).path))?[.modificationDate] as? Date
    }

    /// What `folder` says about its icon, if that is the icon it shows.
    private func carriedLook(of folder: URL) -> CarriedLook? {
        guard FolderInspector.customIconFlag(folder) == true, let look = CarriedLook.read(from: folder),
              FolderInspector.iconResource(of: folder)?.sha256 == look.iconDigest
        else { return nil }
        return look
    }

    /// Leaves on the folder what it needs to know about the icon just drawn for `record`.
    private func carry(_ record: FolderRecord, on folder: URL) {
        CarriedLook(of: record, defaultStyle: defaultStyle).write(to: folder)
    }

    /// Whether `record` describes `folder` itself, not the folder `folder` was copied from.
    private func describes(_ record: inout FolderRecord, _ folder: URL) -> Bool {
        if let original = resolve(&record) {
            return sameItem(original, folder)
        }
        // The original can't be found right now (on a disk that was ejected, say): go by
        // the path, and when in doubt keep the record.
        return FolderInspector.canonicalPath(record.lastKnownPath) == FolderInspector.canonicalPath(folder.path)
            || seemsToHaveMoved(record, to: folder)
    }

    private enum Ownership {
        /// The folder shows exactly the icon PrettyFolder wrote.
        case ours
        /// The icon is gone or different: something else changed it.
        case theirs
        /// The folder can't be read right now; don't conclude anything.
        case unknown
    }

    private func ownership(of folder: URL, by record: FolderRecord) -> Ownership {
        switch FolderInspector.customIconFlag(folder) {
        case nil:
            return .unknown
        case false?:
            return .theirs
        case true?:
            guard let resource = FolderInspector.iconResource(of: folder) else {
                return FolderInspector.hasNoIconFile(folder) ? .theirs : .unknown
            }
            let digest = resource.sha256
            return digest == record.iconDigest || digest == CarriedLook.read(from: folder)?.iconDigest ? .ours : .theirs
        }
    }

    private func isStillOurs(_ record: FolderRecord, _ folder: URL) -> Bool {
        ownership(of: folder, by: record) == .ours
    }

    private func markerID(of folder: URL) -> UUID? {
        ExtendedAttributes.value(named: Self.markerAttribute, at: folder)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(UUID.init(uuidString:))
    }

    /// Finds the folder a record points to, following moves and renames. Refreshes the
    /// record's bookmark and path both in the library and in `record`, so callers go on
    /// with the up-to-date copy instead of saving an old one over it later.
    private func resolve(_ record: inout FolderRecord) -> URL? {
        var stale = false
        var resolved = try? URL(
            resolvingBookmarkData: record.bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        // A bookmark looks at the old path first, and what is there may be another folder by now:
        // a new one, or a copy given the old name. This one still has its number, unless it went
        // to another disk: then it gets its record back when it is next looked at (see `ownedRecord`).
        if let number = record.fileNumber, resolved.map({ number != FolderInspector.fileNumber(of: $0) }) ?? true,
           let moved = FolderInspector.item(numbered: number, near: resolved ?? URL(fileURLWithPath: record.lastKnownPath)),
           markerID(of: moved) == record.id {
            resolved = moved
            stale = true
        }
        guard let url = resolved, markerID(of: url) == record.id else { return nil }
        var changed = false
        if stale, let fresh = try? url.bookmarkData() {
            record.bookmark = fresh
            changed = true
        }
        if let number = FolderInspector.fileNumber(of: url), number != record.fileNumber {
            record.fileNumber = number
            changed = true
        }
        if record.lastKnownPath != url.path {
            record.lastKnownPath = url.path
            changed = true
        }
        if record.missingSince != nil {
            record.missingSince = nil
            changed = true
        }
        // It shows an icon the record doesn't know: put back from a backup, say. It knows best,
        // as long as its picture is still here.
        var replaced: String?
        if let carried = CarriedLook.read(from: url), carried.iconDigest != record.iconDigest, carriedLook(of: url) != nil,
           FileManager.default.fileExists(atPath: library.pictureURL(named: carried.pictureName).path) {
            replaced = record.pictureName
            record.take(carried, defaultStyle: defaultStyle)
            changed = true
        }
        if changed {
            library.upsert(record)
            hasUnsavedChanges = true
        }
        if let replaced { library.retirePictureIfUnused(replaced) }
        return url
    }

    private func sameItem(_ a: URL, _ b: URL) -> Bool {
        // A URL remembers what it read, and the one given may be from before the folder at that
        // path was replaced.
        var a = a, b = b
        a.removeAllCachedResourceValues()
        b.removeAllCachedResourceValues()
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let first = (try? a.resourceValues(forKeys: key))?.fileResourceIdentifier,
              let second = (try? b.resourceValues(forKeys: key))?.fileResourceIdentifier
        else { return a.standardizedFileURL.path == b.standardizedFileURL.path }
        return first.isEqual(second)
    }

    private func unique(_ folders: [URL]) -> [URL] {
        var seen = Set<String>()
        return folders.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    private func displayName(_ folder: URL) -> String {
        FileManager.default.displayName(atPath: folder.path)
    }

    /// Saves the library. When that fails (a full disk, say), the next change tries again.
    private func persist() {
        guard !isFinding else {
            hasUnsavedChanges = true
            return
        }
        do {
            try library.save()
            hasUnsavedChanges = false
        } catch {
            hasUnsavedChanges = true
        }
    }
}
