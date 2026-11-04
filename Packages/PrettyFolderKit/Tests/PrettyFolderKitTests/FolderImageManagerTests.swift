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

    /// A folder with something in it and a date in the past, as folders usually are.
    private func lived(in name: String) throws -> URL {
        let folder = try temp.folder(name)
        try Data("notes".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: folder.path)
        return folder
    }

    @Test func takingThePictureOffLeavesNoTrace() async throws {
        let folder = try lived(in: "Pristine")
        let before = FolderSnapshot(folder)

        // Everything that leaves something on a folder: a picture, a look of its own, a moved
        // picture, a replaced picture (Finder is told through the Finder info).
        _ = await manager.apply(imageAt: picture, to: [folder])
        try await manager.setStyle(IconStyle(x: 0, y: 0, width: 1, height: 0.6, mode: .fill), placement: PicturePlacement(x: 0.1, y: 0.9), for: folder)
        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), to: other, type: .png)
        _ = await manager.apply(imageAt: other, to: [folder])
        #expect(FolderSnapshot(folder) != before)
        #expect(FolderSnapshot(folder).modified?.tv_sec == before.modified?.tv_sec, "the date never changes")

        _ = await manager.removeImage(from: [folder])
        #expect(FolderSnapshot(folder) == before, "attributes, contents and date as they were")
        #expect(await manager.managedFolderCount() == 0)
        #expect(storedPictures().isEmpty)
        #expect((try libraryJSON()["records"] as? [Any])?.isEmpty == true)
    }

    @Test func removingEverythingLeavesNoTrace() async throws {
        let folders = try ["First", "Second"].map(lived(in:))
        let before = folders.map(FolderSnapshot.init)
        _ = await manager.apply(imageAt: picture, to: folders)
        try await manager.setStyle(nil, placement: PicturePlacement(x: 0.5, y: 0), for: folders[1])
        _ = await manager.removeAll()
        #expect(folders.map(FolderSnapshot.init) == before)
        #expect(storedPictures().isEmpty)
        #expect((try libraryJSON()["records"] as? [Any])?.isEmpty == true)
    }

    @Test func aPictureTakenOffElsewhereIsForgottenWithoutATrace() async throws {
        let folder = try lived(in: "Elsewhere")
        let before = FolderSnapshot(folder)
        _ = await manager.apply(imageAt: picture, to: [folder])
        try await manager.setStyle(IconStyle(x: 0.1, y: 0.1, width: 0.8, height: 0.8, mode: .fit), placement: .natural, for: folder)

        // Finder's Get Info takes the icon off; the next tidy-up notices.
        #expect(NSWorkspace.shared.setIcon(nil, forFile: folder.path, options: []))
        await manager.prune()
        var after = FolderSnapshot(folder)
        after.modified = before.modified  // Finder changed the date, not PrettyFolder
        #expect(after == before)
        #expect(await manager.managedFolderCount() == 0)
        #expect(storedPictures().isEmpty)
    }

    @Test func aRedrawSavesEachFolderBeforeTheAppHearsOfIt() async throws {
        let folders = try ["R1", "R2", "R3"].map { try temp.folder($0) }
        _ = await manager.apply(imageAt: picture, to: folders)
        let checks = Checks()
        let index = libraryDirectory.appendingPathComponent("Library.json")
        await manager.onIconChange { folder, _ in
            // What a copy of the app started right now would find on disk.
            let saved = (try? Data(contentsOf: index)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let records = saved?["records"] as? [[String: Any]] ?? []
            let path = FolderInspector.canonicalPath(folder.path)
            let digest = records.first { $0["lastKnownPath"] as? String == path }?["iconDigest"] as? String
            checks.add(digest != nil && digest == FolderInspector.iconResource(of: folder)?.sha256)
        }
        _ = await manager.redrawAll()
        #expect(checks.results == [true, true, true])
    }

    @Test func removeAllKeepsWhatItCannotReachAndSaysSo() async throws {
        let reachable = try temp.folder("Reachable")
        let gone = try temp.folder("Gone")
        let locked = try temp.folder("Locked")
        _ = await manager.apply(imageAt: picture, to: [reachable, gone, locked])
        try FileManager.default.removeItem(at: gone)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let outcomes = await manager.removeAll()
        #expect(!FolderInspector.hasCustomIcon(reachable))
        let failed = Set(outcomes.filter { !$0.succeeded }.map(\.folder.lastPathComponent))
        #expect(failed == ["Gone", "Locked"])
        #expect(await manager.managedFolderCount() == 2, "kept, to be done when they can be reached")
        #expect(storedPictures().count == 1, "still needed by them")

        // Once the folder can be changed again, removing everything finishes the job.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        _ = await manager.removeAll()
        #expect(!FolderInspector.hasCustomIcon(locked))
        #expect(await manager.managedFolderCount() == 1, "the deleted folder is remembered until it's been gone a while")
    }

    @Test func foldersInsidePackagesAreLeftAlone() async throws {
        let app = try temp.folder("Tool.app")
        let inside = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let outcomes = await manager.apply(imageAt: picture, to: [inside])
        #expect(outcomes.count == 1 && !outcomes[0].succeeded)
        #expect(!FileManager.default.fileExists(atPath: FolderInspector.iconFileURL(for: inside).path))
        #expect(throws: FolderInspector.Problem.insidePackage("Contents")) { try FolderInspector.validate(inside) }
    }

    @Test func aPictureOverSomeoneElsesIconReplacesTheOldRecordRightAway() async throws {
        let folder = try temp.folder("Taken")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let first = try #require(storedPictures().first)
        let foreign = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        #expect(NSWorkspace.shared.setIcon(foreign, forFile: folder.path, options: []))

        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 120, height: 80, red: 0.2, green: 0.8, blue: 0.2), to: other, type: .png)
        _ = await manager.apply(imageAt: other, to: [folder])
        #expect(await manager.managedFolderCount() == 1)
        #expect(!storedPictures().contains(first))
        #expect(await manager.look(for: folder)?.followsDefault == true)
    }

    @Test func forgettingAFolderClearsTheCountUnderSomeoneElsesIcon() async throws {
        let folder = try temp.folder("Counted")
        _ = await manager.apply(imageAt: picture, to: [folder])
        try await manager.setStyle(IconStyle(x: 0.1, y: 0.2, width: 0.6, height: 0.5, mode: .fit), placement: .natural, for: folder)
        #expect(Self.changeCount(folder) == 1)
        let foreign = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemPink.setFill()
            rect.fill()
            return true
        }
        #expect(NSWorkspace.shared.setIcon(foreign, forFile: folder.path, options: []))
        await manager.prune()
        #expect(Self.changeCount(folder) == 0)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == nil)
        #expect(FolderInspector.hasCustomIcon(folder), "their icon stays")
    }

    @Test func anIconFileLeftWithoutItsFlagIsTakenAway() async throws {
        let folder = try lived(in: "Unflagged")
        let before = FolderSnapshot(folder)
        _ = await manager.apply(imageAt: picture, to: [folder])
        // Something turns the custom icon flag off and leaves the icon file.
        var info = try #require(ExtendedAttributes.value(named: "com.apple.FinderInfo", at: folder))
        info[info.startIndex + 8] &= ~0x04
        ExtendedAttributes.set(info, named: "com.apple.FinderInfo", at: folder)

        await manager.prune()
        let after = FolderSnapshot(folder)
        #expect(after.contents == before.contents, "our icon file is gone")
        #expect(after.modified?.tv_sec == before.modified?.tv_sec)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == nil)
        #expect(storedPictures().isEmpty)
    }

    @Test func foldersWithTheSameLookShareOneIcon() async throws {
        let folders = try ["S1", "S2", "S3"].map { try temp.folder($0) }
        let images = Images()
        await manager.onIconChange { _, change in
            if case .written(let icon) = change { images.add(icon.image) }
        }
        _ = await manager.apply(imageAt: picture, to: folders)
        #expect(images.all.count == 3)
        #expect(images.all.allSatisfy { $0 === images.all[0] }, "drawn once")
    }

    @Test func theLookAndThePicturesPlaceChangeOnTheirOwn() async throws {
        let folder = try temp.folder("Parts")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let low = PicturePlacement(x: 0.5, y: 1)
        try await manager.setPlacement(low, for: folder)
        let own = IconStyle(x: 0.1, y: 0.3, width: 0.8, height: 0.5, mode: .fill)
        try await manager.setStyle(own, for: folder)
        var look = try #require(await manager.look(for: folder))
        #expect(look.style == own && look.placement == low, "a new look keeps the picture where it was")
        try await manager.setPlacement(.natural, for: folder)
        look = try #require(await manager.look(for: folder))
        #expect(look.style == own && look.placement == .natural, "moving the picture keeps the look")
    }

    @Test func onlyItsOwnIconCountsAsAPicture() async throws {
        let folder = try temp.folder("Owned")
        _ = await manager.apply(imageAt: picture, to: [folder])
        #expect(await manager.showsOwnPicture(folder))
        let foreign = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemBrown.setFill()
            rect.fill()
            return true
        }
        #expect(NSWorkspace.shared.setIcon(foreign, forFile: folder.path, options: []))
        #expect(FolderImageManager.appearsToHavePicture(folder), "the quick guess is fooled")
        #expect(await !manager.showsOwnPicture(folder))
    }

    @Test func afterStoppingNothingIsWritten() async throws {
        let folder = try temp.folder("Late")
        await manager.stop()
        let outcomes = await manager.apply(imageAt: picture, to: [folder])
        #expect(outcomes.isEmpty || outcomes.allSatisfy { !$0.succeeded })
        #expect(!FolderInspector.hasCustomIcon(folder))
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
        try await manager.setStyle(custom, placement: .natural, for: folder)
        let look = try #require(await manager.look(for: folder))
        #expect(look.style == custom && !look.followsDefault)
        #expect(FolderInspector.iconResource(of: folder) != before)

        // A new picture keeps the folder's own look.
        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 100, height: 300, red: 0, green: 0, blue: 1), to: other, type: .png)
        _ = await manager.apply(imageAt: other, to: [folder])
        #expect(await manager.look(for: folder)?.style == custom)
        #expect(storedPictures().count == 1, "the replaced picture is cleaned up")

        try await manager.setStyle(nil, placement: .natural, for: folder)
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

        try await manager.setStyle(IconStyle(x: 0.1, y: 0.2, width: 0.6, height: 0.5, mode: .fit), placement: .natural, for: folder)
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
        try await manager.setStyle(IconStyle(x: 0, y: 0, width: 1, height: 1, mode: .fill), placement: .natural, for: folder)
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
        try await manager.setStyle(IconStyle(x: 0.1, y: 0.1, width: 0.5, height: 0.5, mode: .fill), placement: .natural, for: folder)
        #expect(!FolderInspector.hasCustomIcon(folder))
        #expect(Self.changeCount(folder) == 0)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == nil)
        #expect(await manager.look(for: folder) == nil)
    }

    /// While the app has the first folder's icon, something takes the picture off that folder.
    /// The other folders are still to get the picture, and need it for as long as they have it.
    @Test func aPictureOnItsWayToMoreFoldersStaysWhenTheFirstOneLosesIt() async throws {
        let first = try temp.folder("First"), second = try temp.folder("Second")
        let manager = self.manager
        await manager.onIconChange { url, change in
            if case .written = change, url.lastPathComponent == "First" {
                _ = await manager.removeImage(from: [url])
            }
        }
        let outcomes = await manager.apply(imageAt: picture, to: [first, second])
        #expect(outcomes.allSatisfy { $0.succeeded })

        let look = try #require(await manager.look(for: second))
        #expect(FileManager.default.fileExists(atPath: look.pictureURL.path), "the second folder's picture is gone")
        await manager.onIconChange(nil)
        // The look can still be changed, which needs the picture.
        try await manager.setStyle(IconStyle(x: 0.2, y: 0.3, width: 0.6, height: 0.4, mode: .fit), placement: .natural, for: second)
        #expect(storedPictures().count == 1)
    }

    /// The same when the first folder gets another picture meanwhile.
    @Test func aPictureOnItsWayToMoreFoldersStaysWhenTheFirstOneGetsAnother() async throws {
        let first = try temp.folder("First"), second = try temp.folder("Second")
        let other = temp.file("other.jpg")
        TestImages.write(TestImages.solid(width: 300, height: 300, red: 0, green: 0, blue: 1), to: other, type: .jpeg)
        let manager = self.manager
        let replaced = Checks()
        await manager.onIconChange { url, change in
            if case .written = change, url.lastPathComponent == "First", replaced.results.isEmpty {
                replaced.add(true)
                _ = await manager.apply(imageAt: other, to: [url])
            }
        }
        _ = await manager.apply(imageAt: picture, to: [first, second])
        await manager.onIconChange(nil)

        let look = try #require(await manager.look(for: second))
        #expect(FileManager.default.fileExists(atPath: look.pictureURL.path), "the second folder's picture is gone")
        #expect(storedPictures().count == 2)
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
        try await manager.setStyle(IconStyle(x: 0.2, y: 0.2, width: 0.5, height: 0.5, mode: .fill), placement: .natural, for: folder)
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
        try await manager.setStyle(IconStyle(x: 0.2, y: 0.2, width: 0.5, height: 0.5, mode: .fill), placement: .natural, for: folder)
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
        try await manager.setStyle(pinnedStyle, placement: .natural, for: pinned)
        let pinnedIcon = FolderInspector.iconResource(of: pinned)
        let followerIcon = FolderInspector.iconResource(of: follower)

        let newDefault = IconStyle(x: 0.2, y: 0.2, width: 0.6, height: 0.6, mode: .fit)
        let outcomes = await manager.setDefaultStyle(newDefault, updateExisting: true)
        #expect(outcomes.count == 1 && outcomes.allSatisfy { $0.succeeded })
        #expect(await manager.look(for: follower)?.style == newDefault)
        #expect(FolderInspector.iconResource(of: follower) != followerIcon)
        #expect(FolderInspector.iconResource(of: pinned) == pinnedIcon, "folders with their own look are untouched")
    }

    /// A folder on a disk that isn't connected can't be redrawn with the new default look. It
    /// follows that look all the same, so it gets it once it can be reached.
    @Test func aFolderOutOfReachCatchesUpWithTheNewDefaultLook() async throws {
        let folder = try temp.folder("Disk/Away")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let before = try #require(FolderInspector.iconResource(of: folder))

        let disk = folder.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: disk)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: disk) }
        _ = await manager.setDefaultStyle(IconStyle(x: 0.2, y: 0.3, width: 0.6, height: 0.4, mode: .fit), updateExisting: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: disk)
        #expect(FolderInspector.iconResource(of: folder) == before, "it couldn't be reached")

        let outcomes = await manager.redrawOutdated()
        #expect(outcomes.count == 1)
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(FolderInspector.iconResource(of: folder) != before, "it still shows the old default look")
        #expect(await manager.redrawOutdated().isEmpty, "and only once")
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

        try await manager.setStyle(IconStyle(x: 0.1, y: 0.1, width: 0.4, height: 0.4, mode: .fill), placement: .natural, for: renamed)
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
        try await manager.setStyle(style, placement: .natural, for: copy)
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
        try await manager.setStyle(style, placement: .natural, for: original)
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

    @Test func anUnreadableLibraryIsSetAsideAndThePicturesItNamesKept() async throws {
        let folder = try temp.folder("Kept")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let kept = try #require(storedPictures().first)
        // Cut off halfway: not JSON any more, but the picture's name is still in it.
        let index = libraryDirectory.appendingPathComponent("Library.json")
        let text = try String(contentsOf: index, encoding: .utf8)
        let cut = try #require(text.range(of: kept)?.upperBound)
        try Data(text[..<cut].utf8).write(to: index)

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        #expect(await reopened.managedFolderCount() == 0)
        let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
        #expect(files.contains { $0.hasPrefix("Library-unreadable-") }, "the bad file is kept for later")

        // The picture the set-aside list names stays; everything else is cleaned up as usual.
        await reopened.prune()
        let other = try temp.folder("Other")
        let png = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 50, height: 50, red: 0, green: 0, blue: 1), to: png, type: .png)
        _ = await reopened.apply(imageAt: png, to: [other])
        #expect(storedPictures().count == 2)
        _ = await reopened.removeImage(from: [other])
        #expect(storedPictures() == [kept])
    }

    @Test func aNewerLibraryIsLeftAloneEvenWhenItsRecordsLookDifferent() async throws {
        let index = libraryDirectory.appendingPathComponent("Library.json")
        let newer = Data(#"{"version": 99, "records": [{"somethingElse": 1}]}"#.utf8)
        try newer.write(to: index)

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        let folder = try temp.folder("Fresh")
        _ = await reopened.apply(imageAt: picture, to: [folder])
        #expect(FolderInspector.hasCustomIcon(folder), "the app keeps working")
        _ = await reopened.removeImage(from: [folder])
        await reopened.prune()
        #expect(try Data(contentsOf: index) == newer)
        let files = try FileManager.default.contentsOfDirectory(atPath: libraryDirectory.path)
        #expect(!files.contains { $0.hasPrefix("Library-unreadable-") }, "not taken for a broken list")
        #expect(storedPictures().count == 1, "its pictures are never deleted")
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
        let low = PicturePlacement(x: 0.5, y: 1)
        try await manager.setStyle(nil, placement: low, for: folder)
        var look = try #require(await manager.look(for: folder))
        #expect(look.placement == low && look.followsDefault)
        #expect(FolderInspector.iconResource(of: folder) != centered)

        // It stays where it was through a new default look and a redraw.
        let newDefault = IconStyle(x: 0.1, y: 0.3, width: 0.8, height: 0.3, mode: .fill)
        _ = await manager.setDefaultStyle(newDefault, updateExisting: true)
        _ = await manager.redrawAll()
        look = try #require(await manager.look(for: folder))
        #expect(look.placement == low && look.style == newDefault)
        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: newDefault)
        #expect(await reopened.look(for: folder)?.placement == low)

        // A new picture starts in the middle, in the folder's own look if it has one.
        let own = IconStyle(x: 0.2, y: 0.3, width: 0.6, height: 0.4, mode: .fit)
        try await manager.setStyle(own, placement: low, for: folder)
        _ = await manager.apply(imageAt: picture, to: [folder])
        look = try #require(await manager.look(for: folder))
        #expect(look.placement == .natural && look.style == own)
    }

    @Test func iconsDrawnBeforeTheDrawingChangedAreDrawnAgainOnce() async throws {
        let old = try temp.folder("Old")
        let current = try temp.folder("Current")
        _ = await manager.apply(imageAt: picture, to: [old, current])
        // Make one look as if an earlier version drew it: no revision in its record.
        let index = libraryDirectory.appendingPathComponent("Library.json")
        func records() throws -> [[String: Any]] {
            let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])
            #expect(json["version"] as? Int == 2, "the list is saved as version 2")
            return try #require(json["records"] as? [[String: Any]])
        }
        #expect(try records().allSatisfy { $0["revision"] as? Int == IconRenderer.revision })
        let earlier = try records().map { record in
            var record = record
            if (record["lastKnownPath"] as? String)?.hasSuffix("/Old") == true { record.removeValue(forKey: "revision") }
            return record
        }
        try JSONSerialization.data(withJSONObject: ["version": 1, "records": earlier]).write(to: index)

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        let written = Folders()
        await reopened.onIconChange { folder, change in
            if case .written = change { written.add(folder) }
        }
        let outcomes = await reopened.redrawOutdated()
        #expect(outcomes.map(\.folder.lastPathComponent) == ["Old"] && outcomes.allSatisfy(\.succeeded))
        #expect(written.all.map(\.lastPathComponent) == ["Old"], "only the old one is drawn again")
        #expect(try records().allSatisfy { $0["revision"] as? Int == IconRenderer.revision }, "and remembered as drawn now")
        let oldIsOurs = await reopened.showsOwnPicture(old), currentIsOurs = await reopened.showsOwnPicture(current)
        #expect(oldIsOurs && currentIsOurs)
        // Once is enough.
        #expect(await reopened.redrawOutdated().isEmpty)
        #expect(await FolderImageManager(directory: libraryDirectory, defaultStyle: .standard).redrawOutdated().isEmpty)
    }

    @Test func aReplacedIconIsNeverHalfWritten() async throws {
        let folder = try temp.folder("Watched")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let iconFile = FolderInspector.iconFileURL(for: folder).path
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("TemporaryItems")
        let scratchBefore = Set((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])

        // Someone looking at the folder all the time, as Finder may at any moment: whenever
        // it says it has a custom icon, the icon file must be there with a whole icon in it.
        let watcher = IconWatcher(folder: folder, iconFile: iconFile)
        let thread = Thread { watcher.watch() }
        thread.start()
        for step in 0..<6 {
            let style = IconStyle(x: 0.05 * Double(step), y: 0.3, width: 0.6, height: 0.5, mode: step.isMultiple(of: 2) ? .fill : .fit)
            try await manager.setStyle(style, placement: PicturePlacement(x: 0.5, y: Double(step) / 5), for: folder)
        }
        let seen = watcher.stop()
        #expect(seen.looks > 100, "the watcher looked often enough to have caught a gap")
        #expect(seen.gaps.isEmpty, "seen without a whole icon: \(seen.gaps)")

        // Done right, it is the folder's own icon, and nothing is left where it was made.
        #expect(await manager.showsOwnPicture(folder))
        let scratchAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: scratch.path)) ?? [])
        #expect(scratchAfter.subtracting(scratchBefore).isEmpty)
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

    @Test func keepsDroppedSVGDataAsVector() async throws {
        let folder = try temp.folder("Dropped")
        let svg = temp.file("dropped.svg")
        try TestImages.writeSVG(to: svg, width: 40, height: 40)
        let outcomes = await manager.apply(imageData: try Data(contentsOf: svg), type: .svg, to: [folder])
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(storedPictures().first?.hasSuffix(".svg") == true)
        #expect(try ImageLoader.load(contentsOf: #require(await manager.look(for: folder)).pictureURL).hasAlpha)
    }

    @Test func removingEverythingForgetsIconsSomeoneElseChanged() async throws {
        let folder = try temp.folder("Theirs")
        _ = await manager.apply(imageAt: picture, to: [folder])
        #expect(NSWorkspace.shared.setIcon(NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.green.setFill()
            rect.fill()
            return true
        }, forFile: folder.path, options: []))

        let outcomes = await manager.removeAll()
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(await manager.managedFolderCount() == 0)
        #expect(FolderInspector.hasCustomIcon(folder), "their icon stays")
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == nil)
        #expect(storedPictures().isEmpty)
    }

    @Test func aFolderThatCantBeReadIsKeptAndReported() async throws {
        let folder = try temp.folder("Locked/Away")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let parent = folder.deletingLastPathComponent().path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent) }

        await manager.prune()
        #expect(await manager.managedFolderCount() == 1, "nothing can be concluded from a folder that can't be read")
        let outcomes = await manager.removeAll()
        #expect(outcomes.count == 1)
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(await manager.managedFolderCount() == 1)
        #expect(storedPictures().count == 1)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent)
        await manager.prune()
        #expect(await manager.managedFolderCount() == 1, "and it's still known when it can be read again")
        #expect(await manager.showsOwnPicture(folder))
    }

    @Test func aMissingPictureIsReportedAndTheRecordKept() async throws {
        let folder = try temp.folder("Lost")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let look = try #require(await manager.look(for: folder))
        try FileManager.default.removeItem(at: look.pictureURL)

        let outcomes = await manager.redrawAll()
        #expect(outcomes.count == 1)
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(await manager.managedFolderCount() == 1)
        #expect(await manager.showsOwnPicture(folder), "its icon is as it was")
    }

    @Test func aFolderWithoutAPictureHasNoLookToChange() async throws {
        let folder = try temp.folder("Plain")
        await #expect(throws: FolderImageError.self) {
            try await manager.setPlacement(.natural, for: folder)
        }
        #expect(!FolderInspector.hasCustomIcon(folder))
    }

    @Test func keepsSVGAsVector() async throws {
        let folder = try temp.folder("Vector")
        let svg = temp.file("logo.svg")
        try TestImages.writeSVG(to: svg, width: 40, height: 40)
        _ = await manager.apply(imageAt: svg, to: [folder])
        #expect(storedPictures().first?.hasSuffix(".svg") == true)
    }
}


/// Collects what a handler on another task found.
private final class Checks: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [Bool] = []
    func add(_ result: Bool) { lock.withLock { collected.append(result) } }
    var results: [Bool] { lock.withLock { collected } }
}

private final class Images: @unchecked Sendable {
    private let lock = NSLock()
    private var collected: [NSImage] = []
    func add(_ image: NSImage) { lock.withLock { collected.append(image) } }
    var all: [NSImage] { lock.withLock { collected } }
}

/// Looks at a folder's icon over and over on a thread of its own, noting every moment the
/// folder claims a custom icon without a whole one in its icon file.
private final class IconWatcher: @unchecked Sendable {
    private let folder: URL
    private let iconFile: String
    private let lock = NSLock()
    private var running = true
    private var looks = 0
    private var gaps: [String: Int] = [:]

    init(folder: URL, iconFile: String) {
        self.folder = folder
        self.iconFile = iconFile
    }

    func watch() {
        while lock.withLock({ running }) {
            var gap: String?
            if FolderInspector.hasCustomIcon(folder) {
                let size = getxattr(iconFile, "com.apple.ResourceFork", nil, 0, 0, XATTR_NOFOLLOW)
                if access(iconFile, F_OK) != 0 {
                    gap = "no icon file"
                } else if size < 0 {
                    gap = "an icon file without an icon"
                } else if size < 4096 {
                    gap = "an icon file with an empty icon (\(size) bytes)"
                }
            }
            lock.withLock {
                looks += 1
                if let gap { gaps[gap, default: 0] += 1 }
            }
        }
    }

    func stop() -> (looks: Int, gaps: [String: Int]) {
        lock.withLock {
            running = false
            return (looks, gaps)
        }
    }
}

/// Folders handed to a callback from another thread.
private final class Folders: @unchecked Sendable {
    private let lock = NSLock()
    private var folders: [URL] = []

    func add(_ folder: URL) {
        lock.withLock { folders.append(folder) }
    }

    var all: [URL] {
        lock.withLock { folders }
    }
}
