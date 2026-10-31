import AppKit
import PrettyFolderKit
import UniformTypeIdentifiers

/// A picture that arrives by drag and drop: a file, a file promise (Photos, Safari
/// and others hand those out) or raw image data.
enum DroppedPicture {
    case file(URL)
    case promise(NSFilePromiseReceiver)
    case data(Data, UTType)

    /// Raw image types worth reading, best first.
    private static let dataTypes: [UTType] = [.png, .heic, .jpeg, .tiff, .gif, .webP, .svg, .pdf, .bmp]

    /// A quick look at a pasteboard, cheap enough to run once per drag: does it carry a picture?
    static func isPresent(on pasteboard: NSPasteboard) -> Bool {
        let types = Set(pasteboard.types ?? [])
        if types.contains(.fileURL), imageFileURL(on: pasteboard) != nil { return true }
        if !types.isDisjoint(with: NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }),
           imagePromise(on: pasteboard) != nil {
            return true
        }
        return dataTypes.contains { types.contains(NSPasteboard.PasteboardType($0.identifier)) }
    }

    /// The best picture on the pasteboard. Files win over promises, promises over raw data,
    /// because the raw data is often just a screen-sized preview.
    static func read(from pasteboard: NSPasteboard) -> DroppedPicture? {
        if let url = imageFileURL(on: pasteboard) { return .file(url) }
        if let promise = imagePromise(on: pasteboard) { return .promise(promise) }
        for type in dataTypes {
            if let data = pasteboard.data(forType: NSPasteboard.PasteboardType(type.identifier)), !data.isEmpty {
                return .data(data, type)
            }
        }
        return nil
    }

    private static func imageFileURL(on pasteboard: NSPasteboard) -> URL? {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
        // Decide by the name only: no disk access while the drag is still in flight.
        return urls?.first { url in
            !url.hasDirectoryPath && UTType(filenameExtension: url.pathExtension).map(ImageLoader.isImageType) == true
        }
    }

    private static func imagePromise(on pasteboard: NSPasteboard) -> NSFilePromiseReceiver? {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self], options: nil) as? [NSFilePromiseReceiver]
        return receivers?.first { receiver in
            receiver.fileTypes.contains { UTType($0).map(ImageLoader.isImageType) == true }
        }
    }
}
