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
    public var alignment: PictureAlignment?
    /// SHA-256 of the icon resource PrettyFolder wrote. If the folder's icon no longer
    /// matches, somebody else changed it and PrettyFolder keeps its hands off.
    var iconDigest: String
    var created: Date
    var updated: Date
    /// Set while the folder can't be found; the record is dropped after a grace period.
    var missingSince: Date?
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

    let directory: URL
    private(set) var records: [UUID: FolderRecord] = [:]

    /// The list was written by a newer PrettyFolder: use it, but never overwrite it or
    /// delete pictures it may need.
    private(set) var isReadOnly = false

    var picturesDirectory: URL { directory.appendingPathComponent("Pictures", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("Library.json", isDirectory: false) }
    private static let unreadablePrefix = "Library-unreadable-"

    init(directory: URL) {
        self.directory = directory
        guard FileManager.default.fileExists(atPath: indexURL.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let snapshot = try decoder.decode(Snapshot.self, from: Data(contentsOf: indexURL))
            records = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            isReadOnly = snapshot.version > Snapshot.currentVersion
        } catch {
            // Don't let one bad file wipe everything: keep it next to the new one for a
            // closer look, and start over. Its pictures stay (see `keepsAllPictures`).
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let aside = directory.appendingPathComponent(Self.unreadablePrefix + stamp + ".json")
            try? FileManager.default.moveItem(at: indexURL, to: aside)
        }
    }

    /// While a list that couldn't be read is lying around, no stored picture is deleted:
    /// any of them may belong to it.
    private var keepsAllPictures: Bool {
        if isReadOnly { return true }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return files.contains { $0.hasPrefix(Self.unreadablePrefix) }
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
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let name = digest + "." + fileExtension.lowercased()
        let url = pictureURL(named: name)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        }
        return name
    }

    func deletePictureIfUnused(_ name: String) {
        guard !keepsAllPictures, !records.values.contains(where: { $0.pictureName == name }) else { return }
        try? FileManager.default.removeItem(at: pictureURL(named: name))
    }

    /// Removes stored pictures that no record points to (left over after a crash, say).
    func collectGarbage() {
        guard !keepsAllPictures else { return }
        let used = Set(records.values.map(\.pictureName))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: picturesDirectory.path)) ?? []
        for name in files where !used.contains(name) && !name.hasPrefix(".") {
            try? FileManager.default.removeItem(at: pictureURL(named: name))
        }
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
