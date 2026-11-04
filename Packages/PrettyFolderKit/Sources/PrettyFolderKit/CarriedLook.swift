import Foundation

/// What a folder says about the icon on it, in an extended attribute that goes wherever the
/// folder goes.
///
/// The list of folders has one record per folder. A copy of a folder starts out with the
/// original's marker and no record of its own, and by the time it is first looked at, the
/// original may have changed, lost its picture or be gone. What the copy shows is still
/// written down here. The same goes for a folder moved to another disk, and for one put back
/// from a backup.
struct CarriedLook: Codable, Equatable {
    static let attribute = "com.narekmynell.prettyfolder.look"

    /// The stored copy of the picture.
    let pictureName: String
    /// The look the icon was drawn with, even when it is the default look: that may be another by now.
    let style: IconStyle
    let followsDefault: Bool
    let placement: PicturePlacement?
    /// The icon all this is about. On a folder showing another one, it says nothing.
    let iconDigest: String
    let revision: Int?

    init(of record: FolderRecord, defaultStyle: IconStyle) {
        pictureName = record.pictureName
        style = record.style ?? defaultStyle
        followsDefault = record.style == nil
        placement = record.placement
        iconDigest = record.iconDigest
        revision = record.revision
    }

    /// Anything can write this, and a folder can come from anywhere: the name of a picture is
    /// only taken if it is the name of a stored one, a hash and an extension, and no path.
    static func read(from folder: URL) -> CarriedLook? {
        guard let data = ExtendedAttributes.value(named: attribute, at: folder),
              let look = try? JSONDecoder().decode(CarriedLook.self, from: data),
              look.pictureName.wholeMatch(of: /[0-9a-f]{64}\.[A-Za-z0-9]+/) != nil
        else { return nil }
        return look
    }

    /// A folder that can't take it is no worse off than one from before there was such a thing.
    func write(to folder: URL) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        ExtendedAttributes.set(data, named: Self.attribute, at: folder)
    }

    static func remove(from folder: URL) {
        ExtendedAttributes.remove(named: attribute, at: folder)
    }
}

extension FolderRecord {
    /// Makes the record say what the folder says about its icon. A folder that followed the default
    /// look goes on doing so only if the icon still shows it: the default may have changed
    /// since, and the icon doesn't change until someone changes it.
    mutating func take(_ look: CarriedLook, defaultStyle: IconStyle) {
        pictureName = look.pictureName
        style = look.followsDefault && look.style == defaultStyle ? nil : look.style
        placement = look.placement
        iconDigest = look.iconDigest
        revision = look.revision
    }
}
