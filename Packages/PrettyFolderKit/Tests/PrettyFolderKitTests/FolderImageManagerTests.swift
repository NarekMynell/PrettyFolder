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
        manager = FolderImageManager(directory: try temp.folder("Library"), defaultStyle: .standard, unusedPictureAllowance: 0)
        picture = temp.file("photo.jpg")
        TestImages.write(TestImages.solid(width: 640, height: 480, red: 1, green: 0.5, blue: 0), to: picture, type: .jpeg)
    }

    private var libraryDirectory: URL { temp.url.appendingPathComponent("Library") }

    private func storedPictures() -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: libraryDirectory.appendingPathComponent("Pictures").path)) ?? []
    }

    /// A picture no folder on the list uses stays for a while, for copies the list doesn't know
    /// about (see `FolderLibrary.retirePictureIfUnused`), and goes after that.
    private func expectStoredPicturesGone() async {
        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
        #expect(storedPictures().isEmpty)
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
        await expectStoredPicturesGone()
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
        await expectStoredPicturesGone()
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
        await expectStoredPicturesGone()
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
        #expect(failed == ["Locked"], "a deleted folder has nothing to take off, and nothing to tell")
        #expect(await manager.managedFolderCount() == 1, "kept, to be done when it can be reached")
        #expect(storedPictures().count == 1, "still needed by it")

        // Once the folder can be changed again, removing everything finishes the job.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        _ = await manager.removeAll()
        #expect(!FolderInspector.hasCustomIcon(locked))
        #expect(await manager.managedFolderCount() == 0)
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

    @Test func foldersInsidePackagesAreLeftAloneThroughLinksToo() async throws {
        let app = try temp.folder("Tool.app")
        let inside = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let link = temp.url.appendingPathComponent("Shortcut", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)

        let through = link.appendingPathComponent("Contents", isDirectory: true)
        let outcomes = await manager.apply(imageAt: picture, to: [through])
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(!FolderInspector.hasCustomIcon(inside))
        #expect(!FileManager.default.fileExists(atPath: FolderInspector.iconFileURL(for: inside).path))
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
        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
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
        await expectStoredPicturesGone()
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
        await expectStoredPicturesGone()
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
        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
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

    /// What the list says after the original's disk is ejected: it was on a disk that isn't there.
    private func ejected(_ folder: URL) throws -> FolderImageManager {
        let away = try TemporaryDirectory()
        try FileManager.default.moveItem(at: folder, to: away.url.appendingPathComponent("Parked"))
        try FileManager.default.removeItem(at: away.url)
        let index = libraryDirectory.appendingPathComponent("Library.json")
        var list = try libraryJSON()
        var records = try #require(list["records"] as? [[String: Any]])
        for i in records.indices { records[i]["lastKnownPath"] = "/Volumes/PrettyFolder Test Disk Away/\(folder.lastPathComponent)" }
        list["records"] = records
        try JSONSerialization.data(withJSONObject: list).write(to: index)
        return FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
    }

    @Test func removingACopyKeepsAnOriginalOnADiskThatIsAway() async throws {
        let original = try temp.folder("OnAnotherDisk")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = temp.url.appendingPathComponent("CopyOnDesktop", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        let reopened = try ejected(original)

        _ = await reopened.removeImage(from: [copy])
        #expect(!FolderInspector.hasCustomIcon(copy))
        #expect(await reopened.managedFolderCount() == 1, "the original's record is kept")
        #expect(storedPictures().count == 1)
    }

    @Test func aCopyLookedAtWhileTheOriginalsDiskIsAwayLeavesItsRecord() async throws {
        let original = try temp.folder("OnAnotherDisk")
        _ = await manager.apply(imageAt: picture, to: [original])
        let marker = ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: original)
        let copy = temp.url.appendingPathComponent("CopyOnDesktop", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        let reopened = try ejected(original)

        #expect(await reopened.look(for: copy) != nil)
        #expect(await reopened.managedFolderCount() == 2)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: copy) != marker)
    }

    // MARK: - Moved, and then

    @Test func takingThePictureOffARenamedFolderForgetsIt() async throws {
        let folder = try lived(in: "Before")
        let before = FolderSnapshot(folder)
        _ = await manager.apply(imageAt: picture, to: [folder])
        let renamed = temp.url.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)

        // Nobody opened it after the move: the button on the folder does this directly.
        let outcomes = await manager.removeImage(from: [renamed])
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(await manager.managedFolderCount() == 0, "no record left behind to fail later")
        #expect(FolderSnapshot(renamed).attributes == before.attributes)
        await expectStoredPicturesGone()
    }

    @Test func takingThePictureOffAFolderMovedToAnotherDiskForgetsIt() async throws {
        let original = try temp.folder("Moving")
        _ = await manager.apply(imageAt: picture, to: [original])
        let moved = try copy(original, as: "OnTheOtherDisk")
        try FileManager.default.removeItem(at: original)

        _ = await manager.removeImage(from: [moved])
        #expect(await manager.managedFolderCount() == 0)
        #expect((await manager.removeAll()).isEmpty, "nothing out of reach to report")
    }

    /// Duplicate a folder, rename the original, and name the duplicate as the original was.
    @Test func aRenamedOriginalIsNotConfusedWithADuplicateInItsPlace() async throws {
        let original = try temp.folder("Reports")
        _ = await manager.apply(imageAt: picture, to: [original])
        let duplicate = try copy(original, as: "Reports copy")
        let renamed = temp.url.appendingPathComponent("Reports 2025", isDirectory: true)
        try FileManager.default.moveItem(at: original, to: renamed)
        try FileManager.default.moveItem(at: duplicate, to: original)

        let shown = FolderInspector.iconResource(of: renamed)
        _ = await manager.setDefaultStyle(turned, updateExisting: true)
        #expect(FolderInspector.iconResource(of: renamed) != shown, "the record stays with the folder it was made for")
        #expect(try recordedPaths() == [FolderInspector.canonicalPath(renamed.path)])
    }

    @Test func aFolderMovedIntoAPackageIsNotWrittenTo() async throws {
        let folder = try temp.folder("Assets")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let app = try temp.folder("Tool.app")
        let inside = app.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: inside)
        let shown = FolderInspector.iconResource(of: inside)

        let outcomes = await manager.redrawAll()
        #expect(outcomes.allSatisfy { !$0.succeeded })
        _ = await manager.setDefaultStyle(turned, updateExisting: true)
        #expect(await manager.look(for: inside) != nil)
        #expect(FolderInspector.iconResource(of: inside) == shown)
    }

    // MARK: - What a folder says about itself

    @Test func aRedrawKeepsWhatAFolderPutBackCarries() async throws {
        let folder = try temp.folder("Restored")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let first = try #require(await manager.look(for: folder)).pictureURL
        let backup = try copy(folder, as: "Backup")
        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), to: other, type: .png)
        _ = await manager.apply(imageAt: other, to: [folder])
        try await manager.setStyle(turned, placement: .natural, for: folder)
        let second = try #require(await manager.look(for: folder)).pictureURL
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: backup, to: folder)

        _ = await manager.redrawAll()
        let look = try #require(await manager.look(for: folder))
        #expect(look.pictureURL == first, "not the picture it had before it was put back")
        #expect(look.style == .standard)

        // Its picture is the one in use now, and the other is the one that goes in time.
        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
        #expect(FileManager.default.fileExists(atPath: first.path))
        #expect(!FileManager.default.fileExists(atPath: second.path))
    }

    @Test func aNewDefaultLookLeavesTheLookOfAFolderPutBack() async throws {
        let folder = try temp.folder("Restored")
        _ = await manager.apply(imageAt: picture, to: [folder])
        try await manager.setStyle(turned, placement: .natural, for: folder)
        let backup = try copy(folder, as: "Backup")
        // Back to following the default look: the list says so now, the backup doesn't.
        try await manager.setStyle(nil, placement: .natural, for: folder)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: backup, to: folder)

        _ = await manager.setDefaultStyle(IconStyle(x: 0.3, y: 0.3, width: 0.3, height: 0.3, mode: .fill), updateExisting: true)
        let look = try #require(await manager.look(for: folder))
        #expect(look.style == turned && !look.followsDefault)
    }

    @Test func aCopyUnderAListThatCantBeSavedCanBeLookedAtButNotChanged() async throws {
        let original = try temp.folder("Known")
        _ = await manager.apply(imageAt: picture, to: [original])
        let marker = ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: original)
        let copy = try copy(original, as: "Copy")
        let index = libraryDirectory.appendingPathComponent("Library.json")
        let saved = try Data(contentsOf: index)
        var list = try libraryJSON()
        list["version"] = 99
        try JSONSerialization.data(withJSONObject: list).write(to: index)

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        #expect(await reopened.look(for: copy) != nil)
        await #expect(throws: FolderImageError.self) {
            try await reopened.setPlacement(PicturePlacement(x: 0.1, y: 0.1), for: copy)
        }
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: copy) == marker)
        #expect(await reopened.managedFolderCount() == 1)
        #expect(try Data(contentsOf: index) != saved, "still the newer list, untouched")
    }

    @Test func aPictureNameFromAFolderStaysInsideThePictures() async throws {
        let folder = try temp.folder("Crafted")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let elsewhere = temp.file("elsewhere.png")
        TestImages.write(TestImages.solid(width: 50, height: 50, red: 0, green: 1, blue: 0), to: elsewhere, type: .png)
        let attribute = try #require(ExtendedAttributes.value(named: CarriedLook.attribute, at: folder))
        var json = try #require(JSONSerialization.jsonObject(with: attribute) as? [String: Any])
        json["pictureName"] = "../../elsewhere.png"
        ExtendedAttributes.set(try JSONSerialization.data(withJSONObject: json), named: CarriedLook.attribute, at: folder)
        #expect(CarriedLook.read(from: folder) == nil)
    }

    @Test func aListThatCantBeSavedLeavesMarkersAlone() async throws {
        let folder = try temp.folder("Known")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let marker = ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder)
        let index = libraryDirectory.appendingPathComponent("Library.json")
        try Data(#"{"version": 99, "records": [{"somethingElse": 1}]}"#.utf8).write(to: index)

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        _ = await reopened.look(for: folder)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == marker)
        await #expect(throws: FolderImageError.self) {
            try await reopened.setPlacement(PicturePlacement(x: 0.1, y: 0.1), for: folder)
        }
    }

    /// With the list set aside, a folder gets a record under its own marker again, so the list
    /// can still be put right by hand.
    @Test func aFolderLookedAtAfterItsListWasSetAsideKeepsItsMarker() async throws {
        let folder = try temp.folder("Known")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let marker = ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder)
        try Data("not a list".utf8).write(to: libraryDirectory.appendingPathComponent("Library.json"))

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        #expect(await reopened.look(for: folder) != nil)
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder) == marker)
    }

    @Test func anIconFileLeftWithoutItsFlagGoesOnAFolderPutBackToo() async throws {
        let folder = try temp.folder("Unflagged")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let backup = try copy(folder, as: "Backup")
        try await manager.setStyle(turned, placement: .natural, for: folder)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: backup, to: folder)
        var info = try #require(ExtendedAttributes.value(named: "com.apple.FinderInfo", at: folder))
        info[info.startIndex + 8] &= ~0x04
        ExtendedAttributes.set(info, named: "com.apple.FinderInfo", at: folder)

        await manager.prune()
        #expect(!FileManager.default.fileExists(atPath: FolderInspector.iconFileURL(for: folder).path))
        #expect(ExtendedAttributes.value(named: CarriedLook.attribute, at: folder) == nil)
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

    // MARK: - A folder carries its own look

    private func copy(_ folder: URL, as name: String) throws -> URL {
        let copy = temp.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: copy)
        return copy
    }

    private var turned: IconStyle { IconStyle(x: 0.1, y: 0.2, width: 0.5, height: 0.6, mode: .fit) }

    @Test func aCopyStaysAdjustableAfterTheOriginalChanges() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let shown = FolderInspector.iconResource(of: original)
        let copy = try copy(original, as: "Copy")

        // The original moves on before the copy is ever looked at.
        try await manager.setStyle(turned, placement: PicturePlacement(x: 0.2, y: 0.8), for: original)
        #expect(FolderInspector.iconResource(of: original) != shown)

        #expect(await manager.showsOwnPicture(copy))
        let look = try #require(await manager.look(for: copy))
        #expect(look.style == .standard && look.followsDefault, "what the copy shows, not what the original has now")
        #expect(look.placement == .natural)
        #expect(FolderInspector.iconResource(of: copy) == shown, "looking changes nothing on the folder")

        let own = IconStyle(x: 0, y: 0, width: 0.4, height: 0.4, mode: .fill)
        try await manager.setStyle(own, placement: .natural, for: copy)
        #expect(await manager.look(for: copy)?.style == own)
        #expect(await manager.look(for: original)?.style == turned, "and the original is left alone")
        #expect(await manager.managedFolderCount() == 2)
    }

    @Test func aCopyKeepsItsPictureWhenTheOriginalGetsAnother() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let before = try #require(await manager.look(for: original)).pictureURL
        let copy = try copy(original, as: "Copy")

        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), to: other, type: .png)
        _ = await manager.apply(imageAt: other, to: [original])

        let look = try #require(await manager.look(for: copy))
        #expect(look.pictureURL == before)
        #expect(FileManager.default.fileExists(atPath: look.pictureURL.path), "still there to be drawn again")
        try await manager.setPlacement(PicturePlacement(x: 0.3, y: 0.3), for: copy)
        #expect(await manager.look(for: original)?.pictureURL != before)
    }

    @Test func aCopyKeepsItsPictureWhenTheOriginalsIsTakenOff() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = try copy(original, as: "Copy")
        _ = await manager.removeImage(from: [original])
        #expect(!FolderInspector.hasCustomIcon(original))

        #expect(await manager.managedFolderCount() == 0, "nothing knows about the copy yet")
        let look = try #require(await manager.look(for: copy))
        #expect(FileManager.default.fileExists(atPath: look.pictureURL.path))
        #expect(await manager.managedFolderCount() == 1)
        try await manager.setPlacement(PicturePlacement(x: 0.3, y: 0.3), for: copy)

        // Taken off the copy too, it goes after the grace period, and not before.
        _ = await manager.removeImage(from: [copy])
        await manager.prune()
        #expect(storedPictures().count == 1)
        await expectStoredPicturesGone()
    }

    @Test func aCopyOutlivesAnOriginalLongForgotten() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = try copy(original, as: "Copy")
        try FileManager.default.removeItem(at: original)
        await manager.prune()
        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
        #expect(await manager.managedFolderCount() == 0)
        #expect(await manager.look(for: copy) != nil)
    }

    @Test func copiesOfACopyGoTheirOwnWays() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let first = try copy(original, as: "First")
        let second = try copy(first, as: "Second")
        try await manager.setStyle(turned, placement: .natural, for: original)
        let small = IconStyle(x: 0, y: 0, width: 0.3, height: 0.3, mode: .fit)
        try await manager.setStyle(small, placement: .natural, for: first)
        let third = try copy(first, as: "Third")
        try await manager.setStyle(IconStyle(x: 0.5, y: 0.5, width: 0.3, height: 0.3, mode: .fit), placement: .natural, for: first)

        #expect(await manager.look(for: second)?.style == .standard)
        #expect(await manager.look(for: third)?.style == small)
        #expect(await manager.managedFolderCount() == 4)
        let markers = [original, first, second, third].compactMap { ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: $0) }
        #expect(Set(markers).count == 4)
    }

    /// Whichever the choice was when the default look changed, nothing changes on the copy
    /// until someone changes it.
    @Test func aCopyBehindANewDefaultLookKeepsWhatItShows() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = try copy(original, as: "Copy")
        let shown = FolderInspector.iconResource(of: copy)
        _ = await manager.setDefaultStyle(turned, updateExisting: true)
        #expect(await manager.look(for: original)?.style == turned)

        let look = try #require(await manager.look(for: copy))
        #expect(look.style == .standard && !look.followsDefault)
        #expect(FolderInspector.iconResource(of: copy) == shown)
    }

    @Test func aCopyOfAFolderFollowingTheDefaultGoesOnFollowingIt() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = try copy(original, as: "Copy")
        try await manager.setPlacement(PicturePlacement(x: 0.2, y: 0.2), for: original)
        #expect(await manager.look(for: copy)?.followsDefault == true)
        _ = await manager.setDefaultStyle(turned, updateExisting: true)
        #expect(await manager.look(for: copy)?.style == turned)
    }

    @Test func aFolderMovedToAnotherDiskAndThenCopiedBackIsTwoFolders() async throws {
        let original = try temp.folder("Moving")
        _ = await manager.apply(imageAt: picture, to: [original])
        let moved = try copy(original, as: "OnTheOtherDisk")
        try FileManager.default.removeItem(at: original)
        #expect(await manager.look(for: moved) != nil)
        #expect(await manager.managedFolderCount() == 1)
        try await manager.setStyle(turned, placement: .natural, for: moved)

        let back = try copy(moved, as: "Moving")
        try await manager.setPlacement(PicturePlacement(x: 0.1, y: 0.1), for: moved)
        #expect(await manager.look(for: back)?.style == turned)
        #expect(await manager.managedFolderCount() == 2)
    }

    /// A copy whose original is on a disk that isn't connected, and has moved on since, doesn't
    /// take over the original's record: it wouldn't describe what the copy shows.
    @Test func anOlderCopyLeavesTheRecordOfAnOriginalOutOfReach() async throws {
        let original = try temp.folder("OnAnotherDisk")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = try copy(original, as: "Copy")
        try await manager.setStyle(turned, placement: .natural, for: original)
        // Stands in for the original's disk being ejected.
        let away = try TemporaryDirectory()
        try FileManager.default.moveItem(at: original, to: away.url.appendingPathComponent("Parked"))
        try FileManager.default.removeItem(at: away.url)

        #expect(await manager.look(for: copy)?.style == .standard)
        #expect(await manager.managedFolderCount() == 2, "the original's is kept for when it's back")
    }

    @Test func aMovedFolderIsFoundWithANewOneInItsOldPlace() async throws {
        let folder = try temp.folder("Invoices")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let archive = try temp.folder("Archive")
        let moved = archive.appendingPathComponent("Invoices", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        _ = try temp.folder("Invoices")

        // Nobody has looked at it, and it still follows the default look and gets redrawn.
        let shown = FolderInspector.iconResource(of: moved)
        _ = await manager.setDefaultStyle(turned, updateExisting: true)
        #expect(FolderInspector.iconResource(of: moved) != shown)
        #expect(try recordedPaths() == [FolderInspector.canonicalPath(moved.path)])
        await manager.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
        #expect(await manager.managedFolderCount() == 1)
    }

    /// Finder moves across disks by copying and deleting, so nothing leads to the new place
    /// until the folder is looked at, and then it catches up.
    @Test func aFolderMovedOutOfReachCatchesUpOnceFound() async throws {
        let original = try temp.folder("Moving")
        _ = await manager.apply(imageAt: picture, to: [original])
        let moved = try copy(original, as: "OnTheOtherDisk")
        try FileManager.default.removeItem(at: original)
        let shown = FolderInspector.iconResource(of: moved)

        _ = await manager.setDefaultStyle(turned, updateExisting: true)
        #expect(FolderInspector.iconResource(of: moved) == shown, "out of reach")

        let look = try #require(await manager.look(for: moved))
        #expect(look.style == turned && look.followsDefault)
        #expect(FolderInspector.iconResource(of: moved) != shown, "shows what the window says it has")
    }

    /// A folder put back from a backup, or one whose icon was written just before a crash, shows
    /// an icon its record has never heard of. It says itself what that is.
    @Test func aFolderPutBackFromABackupHasItsOldLookBack() async throws {
        let folder = try temp.folder("Restored")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let backup = try copy(folder, as: "Backup")
        let old = FolderInspector.iconResource(of: folder)
        try await manager.setStyle(turned, placement: .natural, for: folder)
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.moveItem(at: backup, to: folder)

        await manager.prune()
        #expect(await manager.showsOwnPicture(folder))
        let look = try #require(await manager.look(for: folder))
        #expect(look.style == .standard && look.followsDefault)
        #expect(FolderInspector.iconResource(of: folder) == old)
        #expect(await manager.managedFolderCount() == 1)
    }

    @Test func foldersFromBeforeLooksWereCarriedGetThemAtTheNextTidyUp() async throws {
        let folder = try temp.folder("Older")
        _ = await manager.apply(imageAt: picture, to: [folder])
        ExtendedAttributes.remove(named: CarriedLook.attribute, at: folder)
        let copy = try copy(folder, as: "OlderCopy")

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        await reopened.prune()
        #expect(ExtendedAttributes.value(named: CarriedLook.attribute, at: folder) != nil)
        // A copy from then that still matches its original is recognized by its record.
        #expect(await reopened.look(for: copy) != nil)
        #expect(ExtendedAttributes.value(named: CarriedLook.attribute, at: copy) != nil)
        try await reopened.setStyle(turned, placement: .natural, for: folder)
        #expect(await reopened.look(for: copy)?.style == .standard)
    }

    @Test func someoneElsesIconOnACopyIsNotOurs() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = try copy(original, as: "Copy")
        let foreign = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.systemTeal.setFill()
            rect.fill()
            return true
        }
        #expect(NSWorkspace.shared.setIcon(foreign, forFile: copy.path, options: []))
        #expect(await !manager.showsOwnPicture(copy))
        #expect(await manager.look(for: copy) == nil)

        // Nor when the original has moved on as well.
        try await manager.setStyle(turned, placement: .natural, for: original)
        #expect(await manager.look(for: copy) == nil)
        await manager.prune()
        #expect(FolderInspector.hasCustomIcon(copy), "left alone")

        // A new picture puts it right, with what it says about its icon replaced.
        _ = await manager.apply(imageAt: picture, to: [copy])
        #expect(await manager.look(for: copy)?.style == .standard)
    }

    @Test func aPictureNoLongerKeptIsNotPretendedTo() async throws {
        let folder = try lived(in: "FromAnotherMac")
        let before = FolderSnapshot(folder)
        _ = await manager.apply(imageAt: picture, to: [folder])

        // The same folder as another Mac, say, would find it: no list, no pictures.
        let elsewhere = FolderImageManager(directory: try temp.folder("OtherLibrary"), defaultStyle: .standard)
        #expect(await elsewhere.showsOwnPicture(folder), "it can still be taken off")
        #expect(await elsewhere.look(for: folder) == nil)
        #expect(await elsewhere.managedFolderCount() == 0)

        _ = await elsewhere.removeImage(from: [folder])
        #expect(FolderSnapshot(folder) == before)
    }

    @Test func changingAFolderThatIsGoneSaysSo() async throws {
        let folder = try temp.folder("Gone")
        _ = await manager.apply(imageAt: picture, to: [folder])
        try FileManager.default.removeItem(at: folder)
        await #expect(throws: FolderInspector.Problem.self) {
            try await manager.setPlacement(PicturePlacement(x: 0.1, y: 0.1), for: folder)
        }
    }

    @Test func aFailedPictureDoesntTakeOneACopyStillNeeds() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = try copy(original, as: "Copy")
        _ = await manager.removeImage(from: [original])
        let file = temp.file("file.txt")
        try Data("x".utf8).write(to: file)
        #expect(await manager.apply(imageAt: picture, to: [file]).allSatisfy { !$0.succeeded })
        #expect(await manager.look(for: copy) != nil)
        #expect(storedPictures().count == 1)
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
        #expect(storedPictures().count == 1, "it may still be on a copy")
        await manager.prune(now: Date().addingTimeInterval(2 * FolderImageManager.missingGracePeriod + 120))
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

        let reopened = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard, unusedPictureAllowance: 0)
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
        await reopened.prune(now: Date().addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
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

    /// A bookmark looks at the old path first, where a new folder of the old name now is.
    @Test func aRenamedFolderStaysManagedWhenANewOneTakesItsOldName() async throws {
        let folder = try temp.folder("Invoices")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let renamed = temp.url.appendingPathComponent("Invoices 2025", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)
        let newcomer = try temp.folder("Invoices")

        await manager.prune()
        #expect(await manager.managedFolderCount() == 1)
        #expect(storedPictures().count == 1)
        #expect(!FolderInspector.hasCustomIcon(newcomer))
        #expect(await manager.showsOwnPicture(renamed))
        // Looked at, it has its record back, and can be changed and taken off.
        try await manager.setPlacement(PicturePlacement(x: 0.1, y: 0.5), for: renamed)
        #expect(try recordedPaths() == [FolderInspector.canonicalPath(renamed.path)])
        let outcomes = await manager.removeImage(from: [renamed])
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(await manager.managedFolderCount() == 0)
        await expectStoredPicturesGone()
    }

    @Test func twoFoldersThatSwapNamesStayManaged() async throws {
        let first = try temp.folder("Alpha"), second = try temp.folder("Beta")
        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), to: other, type: .png)
        _ = await manager.apply(imageAt: picture, to: [first])
        _ = await manager.apply(imageAt: other, to: [second])
        let between = temp.url.appendingPathComponent("Between", isDirectory: true)
        try FileManager.default.moveItem(at: first, to: between)
        try FileManager.default.moveItem(at: second, to: first)
        try FileManager.default.moveItem(at: between, to: second)

        await manager.prune()
        #expect(await manager.managedFolderCount() == 2)
        #expect(storedPictures().count == 2)
    }

    /// The Mac starts without a disk, which comes back later: gone from then on, it is missing
    /// since it went away the last time, not since the first.
    @Test func aDiskThatComesAndGoesIsNotForgotten() async throws {
        let folder = try temp.folder("OnADisk")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let marker = try #require(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: folder))
        let start = Date()

        // Out of reach, as far as the record can tell.
        ExtendedAttributes.remove(named: FolderImageManager.markerAttribute, at: folder)
        await manager.prune(now: start)
        // Connected: what the app does when a disk mounts.
        ExtendedAttributes.set(marker, named: FolderImageManager.markerAttribute, at: folder)
        _ = await manager.redrawOutdated()
        // Away again, more than the grace period after it first went.
        ExtendedAttributes.remove(named: FolderImageManager.markerAttribute, at: folder)
        await manager.prune(now: start.addingTimeInterval(FolderImageManager.missingGracePeriod + 60))
        #expect(await manager.managedFolderCount() == 1, "forgotten, though it was here a moment ago")
        #expect(storedPictures().count == 1)
    }

    @Test func aFolderThatCantBeLookedIntoIsNotForgotten() async throws {
        let folder = try temp.folder("Private")
        _ = await manager.apply(imageAt: picture, to: [folder])
        // chmod -R 644 on a tree does this to its folders: its own attributes can be read, what is
        // inside it can't.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        await manager.prune()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)

        #expect(await manager.managedFolderCount() == 1)
        #expect(await manager.showsOwnPicture(folder))
        #expect(storedPictures().count == 1)
    }

    @Test func lookingAtACopyThatCantBeMarkedAddsNoRecords() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = temp.url.appendingPathComponent("Locked copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: copy.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: copy.path) }

        for _ in 0..<5 { #expect(await manager.look(for: copy) == nil) }
        #expect(await manager.managedFolderCount() == 1)
    }

    // MARK: - Folders the list doesn't know

    /// What Finder does when a folder goes to another disk: a copy, then the original is gone.
    private func movedAcrossDisks(_ folder: URL, as name: String) throws -> URL {
        let moved = temp.url.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: moved)
        try FileManager.default.removeItem(at: folder)
        return moved
    }

    @Test func removeAllReachesACopyNobodyOpenedOnceItIsFound() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = temp.url.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)

        await manager.takeOn([original, copy])
        #expect(await manager.managedFolderCount() == 2)
        let outcomes = await manager.removeAll()
        #expect(outcomes.allSatisfy { $0.succeeded })
        #expect(!FolderInspector.hasCustomIcon(original))
        #expect(!FolderInspector.hasCustomIcon(copy))
        #expect(ExtendedAttributes.value(named: FolderImageManager.markerAttribute, at: copy) == nil)
    }

    @Test func aNewDefaultLookReachesAFolderMovedToAnotherDiskOnceItIsFound() async throws {
        let folder = try temp.folder("Going away")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let moved = try movedAcrossDisks(folder, as: "Over there")
        await manager.takeOn([moved])
        #expect(await manager.managedFolderCount() == 1, "the same record, not a second one")

        let before = FolderInspector.iconResource(of: moved)
        let turned = IconStyle(x: 0.1, y: 0.2, width: 0.5, height: 0.6, mode: .fit)
        let outcomes = await manager.setDefaultStyle(turned, updateExisting: true)
        #expect(outcomes.count == 1 && outcomes.allSatisfy { $0.succeeded })
        #expect(FolderInspector.iconResource(of: moved) != before)
        #expect(await manager.look(for: moved)?.style == turned)
    }

    @Test func redrawAllReachesACopyOnceItIsFound() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = temp.url.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        await manager.takeOn([copy])
        let outcomes = await manager.redrawAll()
        #expect(Set(outcomes.map(\.folder.lastPathComponent)) == ["Original", "Copy"])
    }

    @Test func takingOnAFolderTwiceChangesNothing() async throws {
        let folder = try temp.folder("Known")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let index = libraryDirectory.appendingPathComponent("Library.json")
        let saved = try Data(contentsOf: index)
        await manager.takeOn([folder, folder])
        #expect(try Data(contentsOf: index) == saved)
        #expect(await manager.managedFolderCount() == 1)
    }

    @Test func aFolderWithSomeoneElsesIconIsNotTakenOn() async throws {
        let folder = try temp.folder("Theirs")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let copy = temp.url.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: copy)
        #expect(NSWorkspace.shared.setIcon(TestImages.nsImage(red: 0, green: 1, blue: 0), forFile: copy.path, options: []))
        await manager.takeOn([copy])
        #expect(await manager.managedFolderCount() == 1)
    }

    @Test func goingThroughADiskFindsMarkedFoldersAndLeavesOutTrashAndPackages() async throws {
        let disk = try temp.folder("Disk")
        func marked(_ path: String) throws -> URL {
            let folder = disk.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: folder)
            return folder
        }
        let deep = try marked("a/b/c/Deep")
        let plain = disk.appendingPathComponent("a/Plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        _ = try marked(".Trashes/501/Thrown away")
        _ = try marked("Backups.backupdb/Mac/Latest/Kept")
        _ = try marked("Some.app/Contents/Inside")
        let found = FolderSearch.markedFolders(on: disk).map(\.lastPathComponent)
        #expect(found == [deep.lastPathComponent])
    }

    // MARK: - Pictures no folder on the list uses

    @Test func anUnusedPictureOutlivesTheGracePeriodWhileThereIsRoomForIt() async throws {
        let kept = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        let folder = try temp.folder("Folder")
        _ = await kept.apply(imageAt: picture, to: [folder])
        let copy = temp.url.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: folder, to: copy)
        _ = await kept.removeImage(from: [folder])
        #expect(await kept.managedFolderCount() == 0)

        await kept.prune(now: Date().addingTimeInterval(20 * FolderImageManager.missingGracePeriod))
        #expect(storedPictures().count == 1)
        #expect(await kept.look(for: copy) != nil, "years later, and it can still be changed")
    }

    @Test func removeAllTakesUnusedPicturesRightAway() async throws {
        let kept = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        let folder = try temp.folder("Folder")
        _ = await kept.apply(imageAt: picture, to: [folder])
        let other = try temp.folder("Other")
        let second = temp.file("second.jpg")
        TestImages.write(TestImages.solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), to: second, type: .jpeg)
        _ = await kept.apply(imageAt: second, to: [other])
        _ = await kept.removeImage(from: [folder])
        #expect(storedPictures().count == 2)
        _ = await kept.removeAll()
        #expect(storedPictures().isEmpty)
    }

    @Test func theOldestUnusedPicturesGoFirstWhenThereIsNoRoom() throws {
        let directory = try temp.folder("Allowance")
        var library = FolderLibrary(directory: directory)
        let old = try library.storePicture(Data(repeating: 1, count: 1000), fileExtension: "jpg")
        let older = try library.storePicture(Data(repeating: 2, count: 1000), fileExtension: "jpg")
        let recent = try library.storePicture(Data(repeating: 3, count: 1000), fileExtension: "jpg")
        let now = Date()
        library.retirePictureIfUnused(old, at: now.addingTimeInterval(-200))
        library.retirePictureIfUnused(older, at: now.addingTimeInterval(-300))
        library.retirePictureIfUnused(recent, at: now)
        library.upsert(FolderRecord(id: UUID(), bookmark: Data(), lastKnownPath: "/nowhere", pictureName: "none.jpg", style: nil, iconDigest: "", created: now, updated: now))

        library.collectGarbage(retiredBefore: now.addingTimeInterval(-100), allowance: 2000)
        let left = try FileManager.default.contentsOfDirectory(atPath: library.picturesDirectory.path)
        #expect(Set(left) == [old, recent], "over by one: the oldest goes")
        library.collectGarbage(retiredBefore: now.addingTimeInterval(-100), allowance: 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: library.picturesDirectory.path) == [recent], "still in its grace period")
    }

    // MARK: - What the dialogs say

    @Test func theCountsLeaveOutDeletedFolders() async throws {
        let kept = try temp.folder("Kept")
        let deleted = try temp.folder("Deleted")
        _ = await manager.apply(imageAt: picture, to: [kept, deleted])
        try FileManager.default.removeItem(at: deleted)
        #expect(await manager.managedFolderCount() == 2, "remembered for a while")
        #expect(await manager.folderCountWithPictures() == 1)
        #expect(await manager.folderCountFollowingDefault() == 1)
    }

    // MARK: - Searching while other things go on

    /// Remove All waits on the app for the original while a search takes on a copy with the same
    /// marker, whose record just went.
    @Test func aSearchLandingDuringRemoveAllDoesNotLoseACopy() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = temp.url.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        let manager = self.manager
        await manager.onIconChange { folder, change in
            if case .removed = change, folder.lastPathComponent == "Original" { await manager.takeOn([copy]) }
        }
        _ = await manager.removeAll()
        #expect(!FolderInspector.hasCustomIcon(copy))
        #expect(await manager.managedFolderCount() == 0)
        #expect(storedPictures().isEmpty)
    }

    /// May be a backup: nothing is written to it just because the app or the disk started.
    @Test func aFolderOnlyFoundIsNotDrawnAgainWithoutBeingAsked() async throws {
        let older = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard, unusedPictureAllowance: 0)
        let original = try temp.folder("Original")
        _ = await older.apply(imageAt: picture, to: [original])
        // A copy of a folder drawn by an earlier version.
        let current = try #require(ExtendedAttributes.value(named: CarriedLook.attribute, at: original))
        var fields = try #require(try JSONSerialization.jsonObject(with: current) as? [String: Any])
        fields["revision"] = 1
        ExtendedAttributes.set(try JSONSerialization.data(withJSONObject: fields), named: CarriedLook.attribute, at: original)
        let copy = temp.url.appendingPathComponent("Clone", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        ExtendedAttributes.set(current, named: CarriedLook.attribute, at: original)

        await older.takeOn([copy])
        #expect(await older.managedFolderCount() == 2)
        let before = FolderInspector.iconResource(of: copy)
        let outcomes = await older.redrawOutdated()
        #expect(outcomes.isEmpty)
        #expect(FolderInspector.iconResource(of: copy) == before)

        // Opened, it catches up.
        _ = await older.look(for: copy)
        #expect(FolderInspector.iconResource(of: copy) != before)
    }

    @Test func takingOnManyFoldersStaysQuick() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        var copies: [URL] = []
        for index in 0..<300 {
            let copy = temp.url.appendingPathComponent("Copy \(index)", isDirectory: true)
            try FileManager.default.copyItem(at: original, to: copy)
            copies.append(copy)
        }
        await manager.takeOn(copies)
        #expect(await manager.managedFolderCount() == 301)
        // All on the list on disk too.
        #expect((try libraryJSON()["records"] as? [Any])?.count == 301)
    }

    // MARK: - Refused

    /// A folder that may be written to, but not have its attributes changed.
    private func denyAttributes(on folder: URL) throws {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/chmod")
        tool.arguments = ["+a", "everyone deny writeextattr,writeattr", folder.path]
        try tool.run()
        tool.waitUntilExit()
        #expect(tool.terminationStatus == 0)
    }

    private func allowAttributes(on folder: URL) throws {
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/chmod")
        tool.arguments = ["-N", folder.path]
        try tool.run()
        tool.waitUntilExit()
    }

    @Test func aFolderThatRefusesItsMarkerKeepsWhatItShows() async throws {
        let theirs = try temp.folder("Theirs")
        #expect(NSWorkspace.shared.setIcon(TestImages.nsImage(red: 0, green: 1, blue: 0), forFile: theirs.path, options: []))
        let before = try #require(FolderInspector.iconResource(of: theirs))
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/chmod")
        tool.arguments = ["+a", "everyone deny writeextattr", theirs.path]
        try tool.run()
        tool.waitUntilExit()
        defer { try? allowAttributes(on: theirs) }
        let outcomes = await manager.apply(imageAt: picture, to: [theirs])
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(FolderInspector.iconResource(of: theirs) == before)
        #expect(await manager.managedFolderCount() == 0)
    }

    @Test func aFolderOfOursThatRefusesItsMarkerKeepsItsLook() async throws {
        let mine = try temp.folder("Mine")
        _ = await manager.apply(imageAt: picture, to: [mine])
        let turned = IconStyle(x: 0.1, y: 0.2, width: 0.5, height: 0.6, mode: .fit)
        try await manager.setStyle(turned, for: mine)
        let before = try #require(FolderInspector.iconResource(of: mine))
        let tool = Process()
        tool.executableURL = URL(fileURLWithPath: "/bin/chmod")
        tool.arguments = ["+a", "everyone deny writeextattr", mine.path]
        try tool.run()
        tool.waitUntilExit()
        let second = temp.file("second.jpg")
        TestImages.write(TestImages.solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), to: second, type: .jpeg)
        let outcomes = await manager.apply(imageAt: second, to: [mine])
        try allowAttributes(on: mine)
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(FolderInspector.iconResource(of: mine) == before)
        await manager.prune()
        #expect(await manager.managedFolderCount() == 1)
        #expect(await manager.look(for: mine)?.style == turned)
    }

    @Test func aFolderThatRefusesAttributesIsLeftAsItWas() async throws {
        let folder = try temp.folder("Refusing")
        try denyAttributes(on: folder)
        defer { try? allowAttributes(on: folder) }
        let outcomes = await manager.apply(imageAt: picture, to: [folder])
        #expect(outcomes.allSatisfy { !$0.succeeded })
        #expect(FolderInspector.hasNoIconFile(folder), "no icon file left behind")
        #expect(await manager.managedFolderCount() == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    // MARK: - An old record

    @Test func aNewPictureOnAFolderMovedAwayWithSomeoneElsesIconDropsItsOldRecord() async throws {
        let folder = try temp.folder("Going away")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let moved = try movedAcrossDisks(folder, as: "Over there")
        #expect(NSWorkspace.shared.setIcon(TestImages.nsImage(red: 0, green: 1, blue: 0), forFile: moved.path, options: []))

        let second = temp.file("second.jpg")
        TestImages.write(TestImages.solid(width: 300, height: 200, red: 0, green: 0.5, blue: 1), to: second, type: .jpeg)
        #expect(await manager.apply(imageAt: second, to: [moved]).allSatisfy { $0.succeeded })
        #expect(await manager.managedFolderCount() == 1)
    }

    // MARK: - Finding a folder again

    @Test func aFolderIsFoundAgainWhateverTakesItsOldName() throws {
        let folder = try temp.folder("Here")
        let location = try #require(FolderInspector.Location(of: folder))
        #expect(location.current?.lastPathComponent == "Here")

        let moved = temp.url.appendingPathComponent("There", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: moved)
        #expect(location.current?.lastPathComponent == "There")

        // Something new takes the old name: the bookmark alone would say this is it.
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(location.current?.lastPathComponent == "There")

        try FileManager.default.removeItem(at: moved)
        #expect(location.current?.lastPathComponent == "Here", "gone: what is at its place is all there is")
    }

    @Test func aFolderInTheTrashIsLetGoOfForWhatTakesItsName() throws {
        let trash = try temp.folder("Volume/.Trashes/501")
        let folder = try temp.folder("Volume/Project")
        let location = try #require(FolderInspector.Location(of: folder))
        try FileManager.default.moveItem(at: folder, to: trash.appendingPathComponent("Project", isDirectory: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        #expect(location.current?.path.contains(".Trashes") == false)
    }

    @Test func goingThroughADiskLeavesOutWhatBackupsAndOtherSystemsKeep() throws {
        let disk = try temp.folder("Backed")
        var kept: [String] = []
        for path in [".MobileBackups/x/F", ".Trash-1000/F", "$RECYCLE.BIN/F", ".TemporaryItems/F", "2024.previous/F", "2024.inprogress/F", "Fine/F"] {
            let folder = disk.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: folder)
            kept.append(path)
        }
        #expect(FolderSearch.markedFolders(on: disk).map { $0.deletingLastPathComponent().lastPathComponent } == ["Fine"])
    }

        @Test func anSVGThroughALinkIsKeptAsVector() async throws {
        let svg = temp.file("logo.svg")
        try TestImages.writeSVG(to: svg, width: 40, height: 40)
        let link = temp.url.appendingPathComponent("logo-link.svg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: svg)
        let folder = try temp.folder("Vector")
        _ = await manager.apply(imageAt: link, to: [folder])
        #expect(storedPictures().first?.hasSuffix(".svg") == true, "stored as \(storedPictures())")
    }

    /// An older copy of the app runs on a list a newer one wrote, can't save it, and mustn't change
    /// icons that list knows, or the newer one forgets those folders when it is back.
    @Test func anOlderCopyLeavesTheFoldersOfANewerListAlone() async throws {
        let folder = try temp.folder("Newer")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let before = try #require(FolderInspector.iconResource(of: folder))
        let index = libraryDirectory.appendingPathComponent("Library.json")
        var list = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: index)) as? [String: Any])

        list["version"] = 99
        try JSONSerialization.data(withJSONObject: list).write(to: index)
        let older = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        await #expect(throws: FolderImageError.self) {
            try await older.setStyle(IconStyle(x: 0.2, y: 0.3, width: 0.5, height: 0.4, mode: .fit), placement: .natural, for: folder)
        }
        let redrawn = await older.redrawAll()
        #expect(redrawn.count == 1)
        #expect(redrawn.allSatisfy { !$0.succeeded })
        #expect(FolderInspector.iconResource(of: folder) == before)

        list["version"] = 2
        try JSONSerialization.data(withJSONObject: list).write(to: index)
        let newer = FolderImageManager(directory: libraryDirectory, defaultStyle: .standard)
        await newer.prune()
        #expect(await newer.managedFolderCount() == 1)
    }

    @Test func aLostStoredPictureIsCalledThat() async throws {
        let folder = try temp.folder("Lost")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let look = try #require(await manager.look(for: folder))
        try FileManager.default.removeItem(at: look.pictureURL)
        do {
            try await manager.setPlacement(PicturePlacement(x: 0, y: 0), for: folder)
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription.contains("Lost"))
            #expect(!error.localizedDescription.contains(look.pictureURL.lastPathComponent))
        }
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
