import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// One folder that got its icon from PrettyFolder.
public struct FolderRecord: Codable, Sendable, Identifiable {
    public let id: UUID
    /// Follows the folder when it is moved or renamed.
    var bookmark: Data
    var lastKnownPath: String
    /// File name of the stored copy of the picture, inside the pictures directory.
    var pictureName: String
    /// The folder's own look; `nil` means it follows the default look.
    public var style: IconStyle?
    /// Where the picture sits in the look's rectangle; `nil` in the middle.
    public var placement: PicturePlacement?
    /// SHA-256 of the icon resource PrettyFolder wrote. If the folder's icon no longer
    /// matches, somebody else changed it and PrettyFolder keeps its hands off.
    var iconDigest: String
    var created: Date
    var updated: Date
    /// Set while the folder can't be found; the record is dropped after a grace period.
    var missingSince: Date?

    init(
        id: UUID, bookmark: Data, lastKnownPath: String, pictureName: String, style: IconStyle?,
        placement: PicturePlacement? = nil, iconDigest: String, created: Date, updated: Date, missingSince: Date? = nil
    ) {
        self.id = id
        self.bookmark = bookmark
        self.lastKnownPath = lastKnownPath
        self.pictureName = pictureName
        self.style = style
        self.placement = placement
        self.iconDigest = iconDigest
        self.created = created
        self.updated = updated
        self.missingSince = missingSince
    }

    /// Where the picture sat used to be kept as its alignment.
    private enum EarlierKeys: String, CodingKey {
        case alignment
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        bookmark = try container.decode(Data.self, forKey: .bookmark)
        lastKnownPath = try container.decode(String.self, forKey: .lastKnownPath)
        pictureName = try container.decode(String.self, forKey: .pictureName)
        style = try container.decodeIfPresent(IconStyle.self, forKey: .style)
        placement = try container.decodeIfPresent(PicturePlacement.self, forKey: .placement)
            ?? decoder.container(keyedBy: EarlierKeys.self).decodeIfPresent(PicturePlacement.self, forKey: .alignment)
        iconDigest = try container.decode(String.self, forKey: .iconDigest)
        created = try container.decode(Date.self, forKey: .created)
        updated = try container.decode(Date.self, forKey: .updated)
        missingSince = try container.decodeIfPresent(Date.self, forKey: .missingSince)
    }
}

/// Keeps the list of managed folders and the pictures they use, under
/// `~/Library/Application Support/PrettyFolder`.
///
/// Pictures are stored by content hash, so the same picture on many folders is kept once.
struct FolderLibrary {
    private struct Snapshot: Codable {
        static let currentVersion = 1
        var version = currentVersion
        var records: [FolderRecord]
    }

    /// Just the version, which every list has, whatever its records look like.
    private struct Header: Decodable {
        var version: Int
    }

    let directory: URL
    private(set) var records: [UUID: FolderRecord] = [:]

    /// The list was written by a newer PrettyFolder: use what of it can be read, but never
    /// overwrite it or delete pictures it may need.
    private(set) var isReadOnly = false
    /// Pictures named in lists that couldn't be read and were set aside. They stay, so such
    /// a list can still be put right by hand; every other picture is cleaned up as usual.
    private var setAsidePictures: Set<String> = []

    var picturesDirectory: URL { directory.appendingPathComponent("Pictures", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("Library.json", isDirectory: false) }
    private static let unreadablePrefix = "Library-unreadable-"

    init(directory: URL) {
        self.directory = directory
        load()
        setAsidePictures = Self.pictures(namedInListsSetAsideIn: directory)
    }

    private mutating func load() {
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let data = try Data(contentsOf: indexURL)
            // A newer PrettyFolder may have changed what its records look like: tell by the
            // version first, so its list is never taken for a broken one.
            if let header = try? decoder.decode(Header.self, from: data), header.version > Snapshot.currentVersion {
                isReadOnly = true
                if let snapshot = try? decoder.decode(Snapshot.self, from: data) {
                    records = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                }
                return
            }
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            records = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        } catch {
            // Don't let one bad file wipe everything: keep it next to the new one for a
            // closer look, and start over. The pictures it names stay.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = directory.appendingPathComponent(Self.unreadablePrefix + stamp + ".json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
        }
    }

    /// The stored pictures that lists set aside as unreadable mention, found by their names
    /// (a content hash and an extension) however broken the rest of the file is.
    private static func pictures(namedInListsSetAsideIn directory: URL) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var names = Set<String>()
        for file in files where file.hasPrefix(unreadablePrefix) {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(file)) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for match in text.matches(of: /[0-9a-f]{64}\.[A-Za-z0-9]+/) {
                names.insert(String(match.output))
            }
        }
        return names
    }

    /// Whether a stored picture must stay even though no record here uses it.
    private func mustKeep(_ name: String) -> Bool {
        isReadOnly || setAsidePictures.contains(name)
    }

    func record(_ id: UUID) -> FolderRecord? { records[id] }

    mutating func upsert(_ record: FolderRecord) {
        records[record.id] = record
    }

    mutating func remove(_ id: UUID) {
        guard let removed = records.removeValue(forKey: id) else { return }
        deletePictureIfUnused(removed.pictureName)
    }

    func save() throws {
        guard !isReadOnly else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let sorted = records.values.sorted { $0.created < $1.created }
        try encoder.encode(Snapshot(records: sorted)).write(to: indexURL, options: .atomic)
    }

    func pictureURL(named name: String) -> URL {
        picturesDirectory.appendingPathComponent(name, isDirectory: false)
    }

    /// Stores bytes under their hash and returns the file name.
    func storePicture(_ data: Data, fileExtension: String) throws -> String {
        try FileManager.default.createDirectory(at: picturesDirectory, withIntermediateDirectories: true)
        let name = data.sha256 + "." + fileExtension.lowercased()
        let url = pictureURL(named: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return name
    }

    func deletePictureIfUnused(_ name: String) {
        guard !mustKeep(name), !records.values.contains(where: { $0.pictureName == name }) else { return }
        try? FileManager.default.removeItem(at: pictureURL(named: name))
    }

    /// Removes stored pictures that no record points to (left over after a crash, say).
    func collectGarbage() {
        guard !isReadOnly else { return }
        let used = Set(records.values.map(\.pictureName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: picturesDirectory.path)) ?? []
        for name in files where !used.contains(name) && !mustKeep(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: pictureURL(named: name))
        }
    }
}

extension Data {
    /// The SHA-256 of the bytes, in lowercase hex.
    var sha256: String {
        SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined()
    }
}

/// Turns any accepted input into the bytes PrettyFolder keeps for later re-rendering.
enum PictureEncoder {
    /// Vector files are kept as they are, up to this size. Bigger ones are rasterized.
    static let maxVectorBytes = 20 * 1024 * 1024

    static func storableData(for picture: SourceImage, original: URL?, originalType: UTType?) -> (data: Data, fileExtension: String)? {
        if case .vector = picture.content, let type = originalType, ImageLoader.isVectorType(type),
           let original, let size = (try? original.resourceValues(forKeys: [.fileSizeKey]))?.fileSize,
           size <= maxVectorBytes, let data = try? Data(contentsOf: original) {
            return (data, type.conforms(to: .svg) ? "svg" : "pdf")
        }
        let maxSide = ImageLoader.maxLongSide
        guard let bitmap = picture.bitmap(maxSide: maxSide) else { return nil }
        return encode(bitmap, keepAlpha: picture.hasAlpha)
    }

    static func storableData(forVectorData data: Data, type: UTType) -> (data: Data, fileExtension: String)? {
        guard ImageLoader.isVectorType(type), data.count <= maxVectorBytes else { return nil }
        return (data, type.conforms(to: .svg) ? "svg" : "pdf")
    }

    static func encode(_ image: CGImage, keepAlpha: Bool) -> (data: Data, fileExtension: String)? {
        let type: UTType = keepAlpha ? .png : .jpeg
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let options: [CFString: Any] = keepAlpha ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data, keepAlpha ? "png" : "jpg")
    }
}
