import AppKit
import CryptoKit
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
    /// `true` when the folder follows the default look.
    public let followsDefault: Bool
}

public enum FolderImageError: LocalizedError {
    case renderFailed
    case setIconFailed(String)
    case notManaged(String)
    case cannotStorePicture

    public var errorDescription: String? {
        switch self {
        case .renderFailed: return "The icon could not be drawn."
        case .setIconFailed(let name): return "macOS refused to change the icon of “\(name)”. Check that PrettyFolder may access this location in System Settings › Privacy & Security."
        case .notManaged(let name): return "“\(name)” doesn't have a picture from PrettyFolder."
        case .cannotStorePicture: return "The picture could not be saved."
        }
    }
}

/// Puts pictures on folder icons, takes them off again and keeps track of them.
///
/// All work is serialized on this actor, so two requests for the same folder can never
/// race. The actual icon is written with `NSWorkspace.setIcon(_:forFile:options:)`,
/// the same call Finder's own Get Info uses.
public actor FolderImageManager {
    /// Extended attribute that ties a folder to its record.
    static let markerAttribute = "com.narekmynell.prettyfolder"

    private var library: FolderLibrary
    private lazy var renderer = IconRenderer()
    public private(set) var defaultStyle: IconStyle

    public init(directory: URL, defaultStyle: IconStyle) {
        self.library = FolderLibrary(directory: directory)
        self.defaultStyle = defaultStyle
    }

    /// `~/Library/Application Support/PrettyFolder`
    public static var standardDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PrettyFolder", isDirectory: true)
    }

    // MARK: - Putting pictures on folders

    /// Puts the picture in `imageURL` on every folder. Folders keep their own look if they have one.
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
        return apply(picture, storedAs: stored, to: folders)
    }

    /// Puts a picture given as raw data (from a drag or the clipboard) on every folder.
    public func apply(imageData: Data, type: UTType?, to folders: [URL]) -> [FolderOutcome] {
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
        return apply(picture, storedAs: stored, to: folders)
    }

    private func apply(_ picture: SourceImage, storedAs stored: (data: Data, fileExtension: String), to folders: [URL]) -> [FolderOutcome] {
        let pictureName: String
        do {
            pictureName = try library.storePicture(stored.data, fileExtension: stored.fileExtension)
        } catch {
            return folders.map { .failed($0, FolderImageError.cannotStorePicture) }
        }

        var outcomes: [FolderOutcome] = []
        for folder in unique(folders) {
            do {
                try FolderInspector.validate(folder)
                // Keep the folder's own look when it already had a picture from us.
                let existing = ownedRecord(for: folder)
                let style = existing?.style
                let digest = try writeIcon(picture, style: style ?? defaultStyle, to: folder)
                let now = Date()
                let record = FolderRecord(
                    id: existing?.id ?? UUID(),
                    bookmark: try folder.bookmarkData(),
                    lastKnownPath: folder.path,
                    pictureName: pictureName,
                    style: style,
                    iconDigest: digest,
                    created: existing?.created ?? now,
                    updated: now
                )
                ExtendedAttributes.set(Data(record.id.uuidString.utf8), named: Self.markerAttribute, at: folder)
                library.upsert(record)
                if let oldPicture = existing?.pictureName, oldPicture != pictureName {
                    library.deletePictureIfUnused(oldPicture)
                }
                outcomes.append(.ok(folder))
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
    public func removeImage(from folders: [URL]) -> [FolderOutcome] {
        var outcomes: [FolderOutcome] = []
        for folder in unique(folders) {
            let id = markerID(of: folder)
            let hadIcon = FolderInspector.hasCustomIcon(folder)
                || FileManager.default.fileExists(atPath: FolderInspector.iconFileURL(for: folder).path)
            if hadIcon && !NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: []) {
                outcomes.append(.failed(folder, FolderImageError.setIconFailed(displayName(folder))))
                continue
            }
            ExtendedAttributes.remove(named: Self.markerAttribute, at: folder)
            // A copied folder carries the original's marker; only drop the record if it is really this folder's.
            if let id, let record = library.record(id), resolve(record).map({ sameItem($0, folder) }) ?? true {
                library.remove(id)
            }
            outcomes.append(.ok(folder))
        }
        persist()
        return outcomes
    }

    // MARK: - Per-folder look

    /// The look of a folder that has a picture from PrettyFolder, or `nil`.
    public func look(for folder: URL) -> FolderLook? {
        guard let record = ownedRecord(for: folder) else { return nil }
        return FolderLook(
            folder: folder,
            pictureURL: library.pictureURL(named: record.pictureName),
            style: record.style ?? defaultStyle,
            followsDefault: record.style == nil
        )
    }

    /// Changes one folder's look. Pass `nil` to make it follow the default look again.
    public func setStyle(_ style: IconStyle?, for folder: URL) throws {
        guard var record = ownedRecord(for: folder) else {
            throw FolderImageError.notManaged(displayName(folder))
        }
        let picture = try ImageLoader.load(contentsOf: library.pictureURL(named: record.pictureName))
        record.style = style
        record.iconDigest = try writeIcon(picture, style: style ?? defaultStyle, to: folder)
        record.updated = Date()
        library.upsert(record)
        persist()
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
        return await redraw(followers, progress: progress)
    }

    /// Lets the app tell the manager about the default look it loaded from preferences,
    /// without touching any folder.
    public func adoptDefaultStyle(_ style: IconStyle) {
        defaultStyle = style
    }

    // MARK: - Maintenance

    /// Redraws every managed folder, for example after a macOS update changed the folder artwork.
    public func redrawAll(progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [FolderOutcome] {
        renderer = IconRenderer()
        return await redraw(Array(library.records.values), progress: progress)
    }

    /// Takes every PrettyFolder picture off and forgets about them. Used before uninstalling.
    public func removeAll(progress: (@Sendable (Int, Int) -> Void)? = nil) async -> [FolderOutcome] {
        let records = Array(library.records.values)
        var outcomes: [FolderOutcome] = []
        for (index, record) in records.enumerated() {
            if let folder = resolve(record), isStillOurs(record, folder) {
                outcomes += removeImage(from: [folder])
            }
            library.remove(record.id)
            progress?(index + 1, records.count)
            await Task.yield()
        }
        library.collectGarbage()
        persist()
        return outcomes
    }

    /// Forgets folders that were deleted or whose icon was changed by something else.
    public func prune() {
        var changed = false
        for record in library.records.values {
            guard let folder = resolve(record) else {
                library.remove(record.id)
                changed = true
                continue
            }
            if !isStillOurs(record, folder) {
                // Someone replaced or removed the icon; our marker is stale too.
                if markerID(of: folder) == record.id {
                    ExtendedAttributes.remove(named: Self.markerAttribute, at: folder)
                }
                library.remove(record.id)
                changed = true
            }
        }
        library.collectGarbage()
        if changed { persist() }
    }

    // MARK: - Internals

    private func redraw(_ records: [FolderRecord], progress: (@Sendable (Int, Int) -> Void)?) async -> [FolderOutcome] {
        var outcomes: [FolderOutcome] = []
        var pictures: [String: SourceImage] = [:]
        for (index, original) in records.enumerated() {
            if Task.isCancelled { break }
            // The record may have changed while this loop was suspended.
            guard var record = library.record(original.id) else { continue }
            if let folder = resolve(record), isStillOurs(record, folder) {
                do {
                    let picture: SourceImage
                    if let cached = pictures[record.pictureName] {
                        picture = cached
                    } else {
                        picture = try ImageLoader.load(contentsOf: library.pictureURL(named: record.pictureName))
                        pictures[record.pictureName] = picture
                    }
                    record.iconDigest = try writeIcon(picture, style: record.style ?? defaultStyle, to: folder)
                    record.lastKnownPath = folder.path
                    record.updated = Date()
                    library.upsert(record)
                    outcomes.append(.ok(folder))
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

    /// Renders the icon, writes it and returns the digest of what was written.
    private func writeIcon(_ picture: SourceImage, style: IconStyle, to folder: URL) throws -> String {
        let icon: NSImage? = autoreleasepool { renderer.makeIcon(with: picture, style: style) }
        guard let icon else { throw FolderImageError.renderFailed }
        let written = autoreleasepool {
            NSWorkspace.shared.setIcon(icon, forFile: folder.path, options: [.excludeQuickDrawElementsIconCreationOption])
        }
        guard written, let resource = FolderInspector.iconResource(of: folder) else {
            throw FolderImageError.setIconFailed(displayName(folder))
        }
        return Self.digest(resource)
    }

    /// The record for `folder` if PrettyFolder made its current icon.
    /// A copy of a managed folder gets its own record, so it can be edited on its own.
    private func ownedRecord(for folder: URL) -> FolderRecord? {
        guard let id = markerID(of: folder), var record = library.record(id), isStillOurs(record, folder) else {
            return nil
        }
        if let original = resolve(record), sameItem(original, folder) {
            return record
        }
        // The folder is a copy (or the original moved to another volume): adopt it.
        guard let bookmark = try? folder.bookmarkData() else { return nil }
        let now = Date()
        record = FolderRecord(
            id: UUID(), bookmark: bookmark, lastKnownPath: folder.path, pictureName: record.pictureName,
            style: record.style, iconDigest: record.iconDigest, created: now, updated: now
        )
        ExtendedAttributes.set(Data(record.id.uuidString.utf8), named: Self.markerAttribute, at: folder)
        library.upsert(record)
        persist()
        return record
    }

    private func isStillOurs(_ record: FolderRecord, _ folder: URL) -> Bool {
        guard FolderInspector.hasCustomIcon(folder), let resource = FolderInspector.iconResource(of: folder) else {
            return false
        }
        return Self.digest(resource) == record.iconDigest
    }

    private func markerID(of folder: URL) -> UUID? {
        ExtendedAttributes.value(named: Self.markerAttribute, at: folder)
            .flatMap { String(data: $0, encoding: .utf8) }
            .flatMap(UUID.init(uuidString:))
    }

    private func resolve(_ record: FolderRecord) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: record.bookmark,
            options: [.withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ) else { return nil }
        if stale, let fresh = try? url.bookmarkData() {
            var updated = record
            updated.bookmark = fresh
            updated.lastKnownPath = url.path
            library.upsert(updated)
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

    private func persist() {
        try? library.save()
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
