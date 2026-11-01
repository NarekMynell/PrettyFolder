import AppKit
import Testing
import UniformTypeIdentifiers
@testable import PrettyFolderKit

/// These tests change real folder icons, but only inside a temporary directory.
@Suite(.serialized) struct FolderImageManagerTests {
    let temp: TemporaryDirectory
    let manager: FolderImageManager
    let picture: URL

    init() throws {
        temp = try TemporaryDirectory()
        manager = FolderImageManager(directory: try temp.folder("Library"), defaultStyle: .standard)
        picture = temp.file("photo.jpg")
        TestImages.write(TestImages.solid(width: 640, height: 480, red: 1, green: 0.5, blue: 0), to: picture, type: .jpeg)
    }

    private var libraryDirectory: URL { temp.url.appendingPathComponent("Library") }

    private func storedPictures() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: libraryDirectory.appendingPathComponent("Pictures").path)) ?? []
    }

    @Test func appliesAndRemovesAnImage() async throws {
        let folder = try temp.folder("Projects")
        let outcomes = await manager.apply(imageAt: picture, to: [folder])
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(FolderInspector.hasCustomIcon(folder))
        #expect(FileManager.default.fileExists(atPath: FolderInspector.iconFileURL(for: folder).path))
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) != nil)

        let look = try #require(await manager.look(for: folder))
        #expect(look.followsDefault)
        #expect(look.style == .standard)
        #expect(await manager.managedFolderCount() == 1)
        #expect(storedPictures().count == 1)

        let removed = await manager.removeImage(from: [folder])
        #expect(removed.allSatisfy { $0.succeeded })
        #expect(!FolderInspector.hasCustomIcon(folder))
        #expect(!FileManager.default.fileExists(atPath: FolderInspector.iconFileURL(for: folder).path))
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == nil)
        #expect(await manager.managedFolderCount() == 0)
        #expect(storedPictures().isEmpty)
    }

    @Test func sharesOnePictureBetweenFolders() async throws {
        let folders = try ["A", "B", "C"].map { try temp.folder($0) }
        let outcomes = await manager.apply(imageAt: picture, to: folders)
        #expect(outcomes.count == 3 && outcomes.allSatisfy { $0.succeeded })
        #expect(storedPictures().count == 1)

        _ = await manager.removeImage(from: [folders[0]])
        #expect(storedPictures().count == 1, "still used by B and C")
        _ = await manager.removeImage(from: Array(folders.dropFirst()))
        #expect(storedPictures().isEmpty)
    }

    @Test func refusesFilesAndPackages() async throws {
        let app = try temp.folder("Tool.app")
        let file = temp.file("file.txt")
        try Data("x".utf8).write(to: file)
        let outcomes = await manager.apply(imageAt: picture, to: [app, file, temp.url.appendingPathComponent("missing")])
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(!FolderInspector.hasCustomIcon(app))
        #expect(storedPictures().isEmpty)
    }

    @Test func reportsUnreadablePictures() async throws {
        let folder = try temp.folder("Folder")
        let bogus = temp.file("bogus.png")
        try Data("not a picture".utf8).write(to: bogus)
        let outcomes = await manager.apply(imageAt: bogus, to: [folder])
        #expect(outcomes.count == 1 && !outcomes[0].succeeded)
        #expect(!FolderInspector.hasCustomIcon(folder))
    }

    @Test func localStyleSticksAndCanBeReset() async throws {
        let folder = try temp.folder("Local")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let before = try #require(FolderInspector.iconResource(of: folder))

        let custom = IconStyle(x: 0.05, y: 0.05, width: 0.5, height: 0.5, mode: .fit)
        try await manager.setStyle(custom, alignment: .centered, for: folder)
        let look = try #require(await manager.look(for: folder))
        #expect(look.style == custom && !look.followsDefault)
        #expect(FolderInspector.iconResource(of: folder) != before)

        // A new picture keeps the folder's own look.
        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 100, height: 300, red: 0, green: 0, blue: 1), to: other, type: .png)
        _ = await manager.apply(imageAt: other, to: [folder])
        #expect(await manager.look(for: folder)?.style == custom)
        #expect(storedPictures().count == 1, "the replaced picture is cleaned up")

        try await manager.setStyle(nil, alignment: .centered, for: folder)
        #expect(await manager.look(for: folder)?.followsDefault == true)
    }

    /// The counter `FolderMetadata` keeps in the folder's Finder info.
    private static func changeCount(_ folder: URL) -> Int {
        guard let info = ExtendedAttributes.value(named: "com.apple.FinderInfo", at: folder), info.count == 32 else { return 0 }
        return Int(info[info.startIndex + 26]) << 8 | Int(info[info.startIndex + 27])
    }

    private func modificationDate(_ url: URL) -> Date? {
        try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
    }

    @Test func finderIsToldAboutReplacedIcons() async throws {
        let folder = try temp.folder("Replaced")
        _ = await manager.apply(imageAt: picture, to: [folder])
        #expect(Self.changeCount(folder) == 0, "a first icon shows by itself")

        try await manager.setStyle(IconStyle(x: 0.1, y: 0.2, width: 0.6, height: 0.5, mode: .fit), alignment: .centered, for: folder)
        #expect(Self.changeCount(folder) == 1)
        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), to: other, type: .png)
        _ = await manager.apply(imageAt: other, to: [folder])
        #expect(Self.changeCount(folder) == 2)
        #expect(FolderInspector.hasCustomIcon(folder))

        _ = await manager.removeImage(from: [folder])
        #expect(Self.changeCount(folder) == 0, "nothing is left behind")
        #expect(!FolderInspector.hasCustomIcon(folder))
    }

    @Test func theAppGetsEachIconBeforeFinderIsTold() async throws {
        final class Seen: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [(name: String, count: Int, sequence: Int?)] = []
            func add(_ name: String, _ count: Int, _ sequence: Int?) { lock.withLock { items.append((name, count, sequence)) } }
            var all: [(name: String, count: Int, sequence: Int?)] { lock.withLock { items } }
        }
        let seen = Seen()
        let folder = try temp.folder("Watched")
        await manager.onIconChange { url, change in
            switch change {
            case .written(let icon):
                #expect(icon.image.size.width > 0)
                seen.add(url.lastPathComponent, Self.changeCount(url), icon.sequence)
            case .removed:
                seen.add(url.lastPathComponent, Self.changeCount(url), nil)
            }
        }
        _ = await manager.apply(imageAt: picture, to: [folder])
        try await manager.setStyle(IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill), alignment: .centered, for: folder)
        #expect(Self.changeCount(folder) == 1)
        _ = await manager.removeImage(from: [folder])

        #expect(seen.all.map(\.name) == ["Watched", "Watched", "Watched"])
        #expect(seen.all.map(\.count) == [0, 0, 0], "Finder is told only after the app has the icon")
        let sequences = seen.all.map(\.sequence)
        #expect(sequences[2] == nil, "then the picture is gone")
        #expect((sequences[0] ?? 0) < (sequences[1] ?? 0), "newer icons count higher")
    }

    @Test func aPictureRemovedWhileTheAppLooksIsNotAnnounced() async throws {
        let folder = try temp.folder("Gone")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let manager = self.manager
        // Other work runs on the manager while the app has the icon.
        await manager.onIconChange { url, change in
            if case .written = change { _ = await manager.removeImage(from: [url]) }
        }
        try await manager.setStyle(IconStyle(x: 0.1, y: 0.1, width: 0.5, height: 0.5, mode: .fill), alignment: .centered, for: folder)
        #expect(!FolderInspector.hasCustomIcon(folder))
        #expect(Self.changeCount(folder) == 0)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == nil)
        #expect(await manager.look(for: folder) == nil)
    }

    @Test func redrawingTellsFinderToo() async throws {
        let folder = try temp.folder("Redrawn")
        _ = await manager.apply(imageAt: picture, to: [folder])
        _ = await manager.setDefaultStyle(IconStyle(x: 0.2, y: 0.2, width: 0.6, height: 0.6, mode: .fit), updateExisting: true)
        #expect(Self.changeCount(folder) == 1)
        _ = await manager.redrawAll()
        #expect(Self.changeCount(folder) == 2)
    }

    @Test func aPictureRemovedElsewhereLeavesNothingBehind() async throws {
        let folder = try temp.folder("Elsewhere")
        _ = await manager.apply(imageAt: picture, to: [folder])
        try await manager.setStyle(IconStyle(x: 0.2, y: 0.2, width: 0.5, height: 0.5, mode: .fill), alignment: .centered, for: folder)
        #expect(Self.changeCount(folder) == 1)
        // As Get Info does it.
        NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: [])
        await manager.prune()
        #expect(Self.changeCount(folder) == 0)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == nil)
        #expect(await manager.managedFolderCount() == 0)
    }

    @Test func pictureChangesKeepTheFolderDate() async throws {
        let folder = try temp.folder("Dated")
        let past = Date(timeIntervalSince1970: 1_000_000_000)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: folder.path)

        _ = await manager.apply(imageAt: picture, to: [folder])
        #expect(modificationDate(folder) == past)
        try await manager.setStyle(IconStyle(x: 0.2, y: 0.2, width: 0.5, height: 0.5, mode: .fill), alignment: .centered, for: folder)
        #expect(modificationDate(folder) == past)
        _ = await manager.removeImage(from: [folder])
        #expect(modificationDate(folder) == past)
    }

    @Test func theChangeCounterLeavesTheRestOfTheFinderInfoAlone() throws {
        let folder = try temp.folder("Counted")
        var info = Data(count: 32)
        info[8] = 0x04
        info[0] = 0x12
        info[26] = 0xFF
        info[27] = 0xFF
        ExtendedAttributes.set(info, named: "com.apple.FinderInfo", at: folder)

        FolderMetadata.noteIconChanged(folder)
        var expected = info
        expected[26] = 0
        expected[27] = 0
        #expect(ExtendedAttributes.value(named: "com.apple.FinderInfo", at: folder) == expected, "it wraps around")
        FolderMetadata.noteIconChanged(folder)
        expected[27] = 1
        #expect(ExtendedAttributes.value(named: "com.apple.FinderInfo", at: folder) == expected)

        FolderMetadata.forgetIconChanges(folder)
        expected[27] = 0
        #expect(ExtendedAttributes.value(named: "com.apple.FinderInfo", at: folder) == expected)

        // Nothing else set: the Finder info goes away entirely, as on a folder never touched.
        var only = Data(count: 32)
        only[27] = 3
        ExtendedAttributes.set(only, named: "com.apple.FinderInfo", at: folder)
        FolderMetadata.forgetIconChanges(folder)
        #expect(ExtendedAttributes.value(named: "com.apple.FinderInfo", at: folder) == nil)
    }

    @Test func defaultStyleCanUpdateExistingFolders() async throws {
        let follower = try temp.folder("Follower")
        let pinned = try temp.folder("Pinned")
        _ = await manager.apply(imageAt: picture, to: [follower, pinned])
        let pinnedStyle = IconStyle(x: 0, y: 0, width: 0.3, height: 0.3, mode: .fill)
        try await manager.setStyle(pinnedStyle, alignment: .centered, for: pinned)
        let pinnedIcon = FolderInspector.iconResource(of: pinned)
        let followerIcon = FolderInspector.iconResource(of: follower)

        let newDefault = IconStyle(x: 0.2, y: 0.2, width: 0.6, height: 0.6, mode: .fit)
        let outcomes = await manager.setDefaultStyle(newDefault, updateExisting: true)
        #expect(outcomes.count == 1 && outcomes.allSatisfy { $0.succeeded })
        #expect(await manager.look(for: follower)?.style == newDefault)
        #expect(FolderInspector.iconResource(of: follower) != followerIcon)
        #expect(FolderInspector.iconResource(of: pinned) == pinnedIcon, "folders with their own look are untouched")
    }

    @Test func defaultStyleCanSpareExistingFolders() async throws {
        let folder = try temp.folder("Existing")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let icon = FolderInspector.iconResource(of: folder)

        let newDefault = IconStyle(x: 0.2, y: 0.2, width: 0.6, height: 0.6, mode: .fit)
        let outcomes = await manager.setDefaultStyle(newDefault, updateExisting: false)
        #expect(outcomes.isEmpty)
        let look = try #require(await manager.look(for: folder))
        #expect(look.style == .standard && !look.followsDefault, "pinned to the old default")
        #expect(FolderInspector.iconResource(of: folder) == icon)

        let newcomer = try temp.folder("Newcomer")
        _ = await manager.apply(imageAt: picture, to: [newcomer])
        #expect(await manager.look(for: newcomer)?.style == newDefault)
    }

    @Test func leavesIconsChangedBySomeoneElseAlone() async throws {
        let folder = try temp.folder("Changed")
        _ = await manager.apply(imageAt: picture, to: [folder])

        // Something else (Finder's Get Info, another app) replaces the icon.
        let foreign = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
        #expect(NSWorkspace.shared.setIcon(foreign, forFile: folder.path, options: []))
        let foreignResource = FolderInspector.iconResource(of: folder)

        #expect(await manager.look(for: folder) == nil)
        _ = await manager.setDefaultStyle(IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fit), updateExisting: true)
        #expect(FolderInspector.iconResource(of: folder) == foreignResource)

        await manager.prune()
        #expect(await manager.managedFolderCount() == 0)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == nil)
    }

    private func libraryJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: libraryDirectory.appendingPathComponent("Library.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func recordedPaths() throws -> [String] {
        let records = try libraryJSON()["records"] as? [[String: Any]] ?? []
        return records.compactMap { $0["lastKnownPath"] as? String }
    }

    @Test func followsRenamedFolders() async throws {
        let folder = try temp.folder("Before")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let renamed = temp.url.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)

        try await manager.setStyle(IconStyle(x: 0.1, y: 0.1, width: 0.4, height: 0.4, mode: .fill), alignment: .centered, for: renamed)
        await manager.prune()
        #expect(await manager.managedFolderCount() == 1)
        // The new path sticks; it isn't overwritten by the copy of the record setStyle worked on.
        #expect(try recordedPaths() == [FolderInspector.canonicalPath(renamed.path)])
    }

    @Test func copiesBecomeTheirOwnFolders() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = temp.url.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)

        let style = IconStyle(x: 0.3, y: 0.3, width: 0.3, height: 0.3, mode: .fit)
        try await manager.setStyle(style, alignment: .centered, for: copy)
        #expect(await manager.managedFolderCount() == 2)
        #expect(await manager.look(for: original)?.followsDefault == true)
        #expect(await manager.look(for: copy)?.style == style)

        // Removing the copy's picture must not forget the original.
        _ = await manager.removeImage(from: [copy])
        #expect(await manager.look(for: original) != nil)
    }

    @Test func removingACopyKeepsAnOriginalThatCantBeFound() async throws {
        let original = try temp.folder("OnAnotherDisk")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = temp.url.appendingPathComponent("CopyOnDesktop", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        // Stands in for the original's disk being ejected.
        let away = try TemporaryDirectory()
        try FileManager.default.moveItem(at: original, to: away.url.appendingPathComponent("Parked"))
        try FileManager.default.removeItem(at: away.url)

        _ = await manager.removeImage(from: [copy])
        #expect(!FolderInspector.hasCustomIcon(copy))
        #expect(await manager.managedFolderCount() == 1, "the original's record is kept")
        #expect(storedPictures().count == 1)
    }

    @Test func aFolderMovedToAnotherDiskKeepsItsRecord() async throws {
        let original = try temp.folder("Moving")
        let style = IconStyle(x: 0.2, y: 0.2, width: 0.5, height: 0.5, mode: .fit)
        _ = await manager.apply(imageAt: picture, to: [original])
        try await manager.setStyle(style, alignment: .centered, for: original)
        // Finder moves across disks by copying and then deleting the original.
        let moved = temp.url.appendingPathComponent("Moved", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: moved)
        try FileManager.default.removeItem(at: original)

        let look = try #require(await manager.look(for: moved))
        #expect(look.style == style)
        #expect(await manager.managedFolderCount() == 1, "taken over, not duplicated")
        #expect(try recordedPaths() == [FolderInspector.canonicalPath(moved.path)])
    }

    @Test func forgetsFoldersMissingForTooLong() async throws {
        let folder = try temp.folder("Doomed")
        _ = await manager.apply(imageAt: picture, to: [folder])
        try FileManager.default.removeItem(at: folder)

        await manager.prune()
        #expect(await manager.managedFolderCount() == 1, "it may be on a disk that isn't connected")
        #expect(storedPictures().count == 1)

        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod / 2))
        #expect(await manager.managedFolderCount() == 1)

        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
        #expect(await manager.managedFolderCount() == 0)
        #expect(storedPictures().isEmpty)
    }

    @Test func aFolderThatComesBackIsNoLongerMissing() async throws {
        let folder = try temp.folder("Back")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let away = try TemporaryDirectory()
        let elsewhere = away.url.appendingPathComponent("Back", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: elsewhere)

        // Still found through its bookmark, even outside the folder it started in.
        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
        #expect(await manager.managedFolderCount() == 1)
        #expect(try recordedPaths() == [FolderInspector.canonicalPath(elsewhere.path)])
    }

    @Test func refusesToRemoveIconsFromPackages() async throws {
        let app = try temp.folder("Tool.app")
        let foreign = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemOrange.setFill()
            rect.fill()
            return true
        }
        #expect(NSWorkspace.shared.setIcon(foreign, forFile: app.path, options: []))
        let outcomes = await manager.removeImage(from: [app])
        #expect(outcomes.count == 1 && !outcomes[0].succeeded)
        #expect(FolderInspector.hasCustomIcon(app), "the package was not touched")
    }

    @Test func anUnreadableLibraryIsSetAsideAndItsPicturesKept() async throws {
        let folder = try temp.folder("Kept")
        _ = await manager.apply(imageAt: picture, to: [folder])
        #expect(storedPictures().count == 1)
        try Data("{ not json".utf8).write(to: libraryDirectory.appendingPathComponent("Library.json"))

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        #expect(await reopened.managedFolderCount() == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
        #expect(files.contains { $0.hasPrefix("Library-unreadable-") }, "the bad file is kept for later")

        // Nothing cleans away pictures the unreadable list may still need.
        await reopened.prune()
        let other = try temp.folder("Other")
        let png = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 50, height: 50, red: 0, green: 0, blue: 1), to: png, type: .png)
        _ = await reopened.apply(imageAt: png, to: [other])
        _ = await reopened.removeImage(from: [other])
        #expect(storedPictures().count == 2)
    }

    @Test func aLibraryFromANewerVersionIsNeverOverwritten() async throws {
        let index = libraryDirectory.appendingPathComponent("Library.json")
        let newer = Data(#"{"version": 99, "records": [], "somethingNew": true}"#.utf8)
        try newer.write(to: index)

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        let folder = try temp.folder("Fresh")
        _ = await reopened.apply(imageAt: picture, to: [folder])
        #expect(FolderInspector.hasCustomIcon(folder), "the app keeps working")
        #expect(try Data(contentsOf: index) == newer)
    }

    @Test func aMovedPictureStaysPutUntilANewPictureComes() async throws {
        let folder = try temp.folder("Moved")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let centered = FolderInspector.iconResource(of: folder)

        // Moving the picture doesn't give the folder a look of its own.
        let low = PictureAlignment(x: 0.5, y: 1)
        try await manager.setStyle(nil, alignment: low, for: folder)
        var look = try #require(await manager.look(for: folder))
        #expect(look.alignment == low && look.followsDefault)
        #expect(FolderInspector.iconResource(of: folder) != centered)

        // It stays where it was through a new default look and a redraw.
        let newDefault = IconStyle(x: 0.1, y: 0.3, width: 0.8, height: 0.3, mode: .fill)
        _ = await manager.setDefaultStyle(newDefault, updateExisting: true)
        _ = await manager.redrawAll()
        look = try #require(await manager.look(for: folder))
        #expect(look.alignment == low && look.style == newDefault)
        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: newDefault)
        #expect(await reopened.look(for: folder)?.alignment == low)

        // A new picture starts in the middle, in the folder's own look if it has one.
        let own = IconStyle(x: 0.2, y: 0.3, width: 0.6, height: 0.4, mode: .fit)
        try await manager.setStyle(own, alignment: low, for: folder)
        _ = await manager.apply(imageAt: picture, to: [folder])
        look = try #require(await manager.look(for: folder))
        #expect(look.alignment == .centered && look.style == own)
    }

    @Test func removeAllCleansUp() async throws {
        let folders = try ["One", "Two"].map { try temp.folder($0) }
        _ = await manager.apply(imageAt: picture, to: folders)
        _ = await manager.removeAll()
        #expect(folders.allSatisfy { !FolderInspector.hasCustomIcon($0) })
        #expect(await manager.managedFolderCount() == 0)
        #expect(storedPictures().isEmpty)
    }

    @Test func survivesARestart() async throws {
        let folder = try temp.folder("Persistent")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        #expect(await reopened.managedFolderCount() == 1)
        #expect(await reopened.look(for: folder) != nil)
    }

    @Test func appliesImageData() async throws {
        let folder = try temp.folder("FromData")
        let data = try Data(contentsOf: picture)
        let outcomes = await manager.apply(imageData: data, type: .jpeg, to: [folder])
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(FolderInspector.hasCustomIcon(folder))
    }

    @Test func keepsSVGAsVector() async throws {
        let folder = try temp.folder("Vector")
        let svg = temp.file("logo.svg")
        try TestImages.writeSVG(to: svg, width: 40, height: 40)
        _ = await manager.apply(imageAt: svg, to: [folder])
        #expect(storedPictures().first?.hasSuffix(".svg") == true)
    }
}
