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
    /// SHA-256 of the icon resource PrettyFolder wrote. If the folder's icon no longer
    /// matches, somebody else changed it and PrettyFolder keeps its hands off.
    var iconDigest: String
    var created: Date
    var updated: Date
}

/// Keeps the list of managed folders and the pictures they use, under
/// `~/Library/Application Support/PrettyFolder`.
///
/// Pictures are stored by content hash, so the same picture on many folders is kept once.
struct FolderLibrary {
    private struct Snapshot: Codable {
        var version = 1
        var records: [FolderRecord]
    }

    let directory: URL
    private(set) var records: [UUID: FolderRecord] = [:]

    var picturesDirectory: URL { directory.appendingPathComponent("Pictures", isDirectory: true) }
    private var indexURL: URL { directory.appendingPathComponent("Library.json", isDirectory: false) }

    init(directory: URL) {
        self.directory = directory
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: indexURL),
           let snapshot = try? decoder.decode(Snapshot.self, from: data) {
            records = Dictionary(snapshot.records.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
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
        guard !records.values.contains(where: { $0.pictureName == name }) else { return }
        try? FileManager.default.removeItem(at: pictureURL(named: name))
    }

    /// Removes stored pictures that no record points to (left over after a crash, say).
    func collectGarbage() {
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
