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
    case notManaged(String)
    case cannotStorePicture
    case unreachable(String)
    case stopped

    public var errorDescription: String? {
        switch self {
        case .renderFailed: return "The icon could not be drawn."
        case .setIconFailed(let name): return "macOS refused to change the icon of “\(name)”. Check that PrettyFolder may access this location in System Settings › Privacy & Security."
        case .notManaged(let name): return "“\(name)” doesn't have a picture from PrettyFolder."
        case .cannotStorePicture: return "The picture could not be saved."
        case .unreachable(let name): return "PrettyFolder couldn't reach “\(name)”. If it's on a disk that isn't connected, connect the disk and try again."
        case .stopped: return "PrettyFolder is quitting."
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
    private lazy var renderer = IconRenderer()
    public private(set) var defaultStyle: IconStyle

    public init(directory: URL, defaultStyle: IconStyle) {
        self.library = FolderLibrary(directory: directory)
        self.defaultStyle = defaultStyle
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
        guard let id = markerID(of: folder), let record = library.record(id) else { return false }
        return isStillOurs(record, folder)
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
                let icon = try writeIcon(image, to: folder)
                let now = Date()
                let record = FolderRecord(
                    id: existing?.id ?? UUID(),
                    bookmark: bookmark,
                    lastKnownPath: FolderInspector.canonicalPath(folder.path),
                    pictureName: pictureName,
                    style: existing?.style,
                    iconDigest: icon.digest,
                    created: existing?.created ?? now,
                    updated: now
                )
                ExtendedAttributes.set(Data(record.id.uuidString.utf8), named: Self.markerAttribute, at: folder)
                library.upsert(record)
                // The record from before someone else changed the icon goes now, not at the next tidy-up.
                if let stale { library.remove(stale.id) }
                if let oldPicture = existing?.pictureName, oldPicture != pictureName {
                    library.deletePictureIfUnused(oldPicture)
                }
                persist()
                outcomes.append(.ok(folder))
                await show(icon)
            } catch {
                outcomes.append(.failed(folder, error))
            }
        }
        // Nothing may have worked; don't keep a picture no folder uses.
        library.deletePictureIfUnused(pictureName)
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
            // A copied folder carries the original's marker; only drop the record if it is really this folder's.
            if let id, var record = library.record(id), describes(&record, folder) {
                library.remove(id)
            }
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
    public func look(for folder: URL) -> FolderLook? {
        guard let record = ownedRecord(for: folder) else { return nil }
        if hasUnsavedChanges { persist() }
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
            throw FolderImageError.notManaged(displayName(folder))
        }
        let picture = try ImageLoader.load(contentsOf: library.pictureURL(named: record.pictureName))
        edit(&record)
        let icon = try writeIcon(draw(picture, style: record.style ?? defaultStyle, placement: record.placement ?? .natural), to: folder)
        record.iconDigest = icon.digest
        record.revision = IconRenderer.revision
        record.updated = Date()
        library.upsert(record)
        persist()
        await show(icon)
    }

    // MARK: - Default look

    /// Number of folders that follow the default look.
    public func folderCountFollowingDefault() -> Int {
        library.records.values.filter { $0.style == nil }.count
    }

    public func managedFolderCount() -> Int {
        library.records.count
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
        let outdated = library.records.values.filter { ($0.revision ?? 1) < IconRenderer.revision }
        guard !outdated.isEmpty else { return [] }
        return await redraw(outdated, progress: nil)
    }

    /// Takes every PrettyFolder picture off and forgets about them, before uninstalling. A
    /// folder that can't be reached or changed right now (on a disk that isn't connected,
    /// say) keeps its record and comes back as a failure, so it can be done later; a folder
    /// whose icon someone else changed is only forgotten.
    public func removeAll(progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [FolderOutcome] {
        var outcomes: [FolderOutcome] = []
        var handled = Set<UUID>()
        // Drops and menu actions keep working meanwhile, so always take the library as it
        // is now rather than a list made at the start.
        while !isStopped, let id = library.records.keys.first(where: { !handled.contains($0) }) {
            handled.insert(id)
            guard var record = library.record(id) else { continue }
            if let folder = resolve(&record) {
                switch ownership(of: folder, by: record) {
                case .ours:
                    let outcome = await removeImage(from: [folder])
                    outcomes += outcome
                    // Normally gone with the picture already; not when the folder's marker
                    // pointed elsewhere.
                    if outcome.allSatisfy(\.succeeded), library.record(id) != nil {
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
            } else {
                let folder = URL(fileURLWithPath: record.lastKnownPath, isDirectory: true)
                outcomes.append(.failed(folder, FolderImageError.unreachable(displayName(folder))))
            }
            let left = library.records.keys.filter { !handled.contains($0) }.count
            progress?(handled.count, handled.count + left)
            await Task.yield()
        }
        library.collectGarbage()
        persist()
        return outcomes
    }

    /// How long a folder that can't be found is remembered. It may be on a disk that
    /// isn't connected, or moved to another disk and not touched since.
    public static let missingGracePeriod: TimeInterval = 90 * 24 * 60 * 60

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
                        library.remove(id)
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
                library.remove(id)
                changed = true
            }
        }
        library.collectGarbage()
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
                    let picture: SourceImage
                    if let open, open.name == record.pictureName {
                        picture = open.picture
                    } else {
                        open = nil
                        picture = try ImageLoader.load(contentsOf: library.pictureURL(named: record.pictureName))
                        open = (record.pictureName, picture)
                    }
                    let image = try draw(picture, style: record.style ?? defaultStyle, placement: record.placement ?? .natural)
                    let icon = try writeIcon(image, to: folder)
                    record.iconDigest = icon.digest
                    record.revision = IconRenderer.revision
                    record.updated = Date()
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
        let (written, oldFile) = FolderMetadata.keepingModificationDate(of: folder) {
            autoreleasepool { IconFile.write(image, to: folder) }
        }
        guard written, let resource = FolderInspector.iconResource(of: folder) else {
            oldFile?.discard()
            throw FolderImageError.setIconFailed(displayName(folder))
        }
        iconsWritten += 1
        return WrittenIcon(folder: folder, image: image, digest: resource.sha256, replaced: replacing, sequence: iconsWritten, oldFile: oldFile)
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

    /// The folder's icon isn't PrettyFolder's any more: leave nothing of ours on it. That is
    /// the marker, the count in its Finder info, and our icon file when only the custom icon
    /// flag was turned off and the file was left behind.
    private func forget(_ folder: URL, record: FolderRecord) {
        if markerID(of: folder) == record.id {
            ExtendedAttributes.remove(named: Self.markerAttribute, at: folder)
        }
        if FolderInspector.customIconFlag(folder) == false,
           FolderInspector.iconResource(of: folder)?.sha256 == record.iconDigest {
            FolderMetadata.keepingModificationDate(of: folder) {
                try? FileManager.default.removeItem(at: FolderInspector.iconFileURL(for: folder))
            }
        }
        FolderMetadata.forgetIconChanges(folder)
    }

    /// The record the folder's marker points to when it is this folder's own, but the icon is
    /// no longer PrettyFolder's: somebody else changed it since.
    private func staleRecord(of folder: URL) -> FolderRecord? {
        guard let id = markerID(of: folder), var record = library.record(id), describes(&record, folder) else { return nil }
        return record
    }

    /// The record for `folder` if PrettyFolder made its current icon.
    /// A copy of a managed folder gets its own record, so it can be edited on its own.
    private func ownedRecord(for folder: URL) -> FolderRecord? {
        guard let id = markerID(of: folder), var record = library.record(id), isStillOurs(record, folder) else {
            return nil
        }
        let original = resolve(&record)
        if let original, sameItem(original, folder) { return record }
        guard let bookmark = try? folder.bookmarkData() else { return nil }
        if original != nil {
            // A copy of a managed folder: give it a record of its own.
            let now = Date()
            record = FolderRecord(
                id: UUID(), bookmark: bookmark, lastKnownPath: FolderInspector.canonicalPath(folder.path),
                pictureName: record.pictureName,
                style: record.style, placement: record.placement, iconDigest: record.iconDigest, revision: record.revision,
                created: now, updated: now
            )
            ExtendedAttributes.set(Data(record.id.uuidString.utf8), named: Self.markerAttribute, at: folder)
        } else {
            // The original is nowhere to be found: most likely this is it, moved to another
            // disk (Finder moves across disks by copying, then deleting). Take the record over.
            record.bookmark = bookmark
            record.lastKnownPath = FolderInspector.canonicalPath(folder.path)
            record.missingSince = nil
        }
        library.upsert(record)
        persist()
        return record
    }

    /// Whether `record` describes `folder` itself, not the folder `folder` was copied from.
    private func describes(_ record: inout FolderRecord, _ folder: URL) -> Bool {
        if let original = resolve(&record) {
            return sameItem(original, folder)
        }
        // The original can't be found right now (on a disk that was ejected, say): go by
        // the path, and when in doubt keep the record.
        return FolderInspector.canonicalPath(record.lastKnownPath) == FolderInspector.canonicalPath(folder.path)
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
                let iconFileExists = FileManager.default.fileExists(atPath: FolderInspector.iconFileURL(for: folder).path)
                return iconFileExists ? .unknown : .theirs
            }
            return resource.sha256 == record.iconDigest ? .ours : .theirs
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
        guard let url = try? URL(
            resolvingBookmarkData: record.bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        var changed = false
        if stale, let fresh = try? url.bookmarkData() {
            record.bookmark = fresh
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
        if changed {
            library.upsert(record)
            hasUnsavedChanges = true
        }
        return url
    }

    private func sameItem(_ a: URL, _ b: URL) -> Bool {
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
        do {
            try library.save()
            hasUnsavedChanges = false
        } catch {
            hasUnsavedChanges = true
        }
    }
}
