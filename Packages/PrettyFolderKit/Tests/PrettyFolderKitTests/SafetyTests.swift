import AppKit
import Testing
@testable import PrettyFolderKit

/// What PrettyFolder must never do to what isn't its own: take off a custom icon somebody else gave
/// a folder, or leave a folder without the icon it had when a new one can't be written whole.
@Suite(.serialized) struct SafetyTests {
    let temp: TemporaryDirectory
    let picture: URL

    init() throws {
        temp = try TemporaryDirectory()
        picture = temp.file("photo.jpg")
        TestImages.write(TestImages.solid(width: 640, height: 480, red: 1, green: 0.5, blue: 0), to: picture, type: .jpeg)
    }

    private static func manager(_ directory: URL) -> FolderImageManager {
        FolderImageManager(directory: directory, defaultStyle: .standard, unusedPictureAllowance: 0, searcher: { _, _ in [] })
    }

    /// What Get Info (paste) or another app does: a custom icon that isn't PrettyFolder's.
    private static func giveOwnIcon(_ folder: URL) -> String? {
        #expect(IconFile.setIcon(TestImages.nsImage(red: 0.1, green: 0.2, blue: 0.9), on: folder, options: []))
        return digest(folder)
    }

    private static func digest(_ folder: URL) -> String? {
        FolderInspector.iconResource(of: folder)?.sha256
    }

    // MARK: - Remove All

    /// The marker goes on before the icon. The app stopped in between (force quit, the watchdog,
    /// power gone) leaves a folder showing its owner's icon with the marker on it, and nothing else.
    @Test func aMarkerLeftByAWriteCutShortDoesNotLetRemoveAllTakeTheOwnersIcon() async throws {
        let folder = try temp.folder("Holiday 2019")
        let own = Self.giveOwnIcon(folder)
        ExtendedAttributes.set(Data(UUID().uuidString.utf8), named: FolderImageManager.markerAttribute, at: folder)

        let manager = Self.manager(try temp.folder("Library"))
        await manager.takeOn([folder])
        #expect(await manager.folderCountWithPictures() == 0)
        _ = await manager.removeAll()
        #expect(Self.digest(folder) == own)
        #expect(FolderInspector.hasCustomIcon(folder))
    }

    /// A copy made before folders carried their look, which its owner then gave an icon of their own.
    @Test func aCopyFromBeforeCarriedLooksKeepsTheIconItsOwnerGaveIt() async throws {
        let manager = Self.manager(try temp.folder("Library"))
        let original = try temp.folder("Projects")
        #expect(await manager.apply(imageAt: picture, to: [original]).allSatisfy(\.succeeded))
        let copy = temp.url.appendingPathComponent("Projects copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        CarriedLook.remove(from: copy)
        let own = Self.giveOwnIcon(copy)

        await manager.takeOn([copy])
        _ = await manager.removeAll()
        #expect(Self.digest(copy) == own)
        #expect(!FolderInspector.hasCustomIcon(original))
    }

    /// The same copy still showing PrettyFolder's picture: Remove All still takes it off.
    @Test func aCopyFromBeforeCarriedLooksShowingOurPictureLosesIt() async throws {
        let manager = Self.manager(try temp.folder("Library"))
        let original = try temp.folder("Projects")
        #expect(await manager.apply(imageAt: picture, to: [original]).allSatisfy(\.succeeded))
        let copy = temp.url.appendingPathComponent("Projects copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        CarriedLook.remove(from: copy)

        await manager.takeOn([copy])
        #expect(await manager.folderCountWithPictures() == 2)
        _ = await manager.removeAll()
        #expect(!FolderInspector.hasCustomIcon(copy))
        #expect(!FolderInspector.hasCustomIcon(original))
    }

    /// Icons written earlier are still known as PrettyFolder's once the folder has a newer one, and
    /// after the list is read again.
    @Test func iconsWrittenEarlierStayKnownAcrossALaunch() async throws {
        let library = try temp.folder("Library")
        let manager = Self.manager(library)
        let original = try temp.folder("Projects")
        #expect(await manager.apply(imageAt: picture, to: [original]).allSatisfy(\.succeeded))
        let copy = temp.url.appendingPathComponent("Projects copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        CarriedLook.remove(from: copy)
        // The original gets a new look: the copy shows an icon no record shows any more.
        try await manager.setStyle(IconStyle(x: 0.1, y: 0.2, width: 0.5, height: 0.6, mode: .fit), for: original)
        #expect(Self.digest(copy) != Self.digest(original))

        let relaunched = Self.manager(library)
        await relaunched.takeOn([copy])
        _ = await relaunched.removeAll()
        #expect(!FolderInspector.hasCustomIcon(copy))
    }

    // MARK: - A list from an earlier PrettyFolder, which didn't keep track of the icons it drew

    private static func asIfSavedByAnEarlierVersion(_ library: URL) throws {
        let file = library.appendingPathComponent("Library.json", isDirectory: false)
        var list = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        list["writtenIcons"] = nil
        list["writtenIconsSince"] = nil
        try JSONSerialization.data(withJSONObject: list).write(to: file)
    }

    /// The copies Remove All has taken off since 1.3.4: an icon drawn before the update, on a copy
    /// of a folder the list knows, whose original has been drawn again since.
    @Test func aCopyFromBeforeTheUpdateStillLosesOurPicture() async throws {
        let library = try temp.folder("Library")
        let before = Self.manager(library)
        let original = try temp.folder("Projects")
        #expect(await before.apply(imageAt: picture, to: [original]).allSatisfy(\.succeeded))
        let copy = temp.url.appendingPathComponent("Projects copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        CarriedLook.remove(from: copy)
        try await before.setStyle(IconStyle(x: 0.1, y: 0.2, width: 0.5, height: 0.6, mode: .fit), for: original)
        try Self.asIfSavedByAnEarlierVersion(library)

        let updated = Self.manager(library)
        await updated.takeOn([copy])
        #expect(await updated.folderCountWithPictures() == 2)
        _ = await updated.removeAll()
        #expect(!FolderInspector.hasCustomIcon(copy))
        #expect(!FolderInspector.hasCustomIcon(original))
    }

    /// A marker left by a write cut short before the update, on a folder with its owner's icon,
    /// however old that icon is.
    @Test func aMarkerLeftBeforeTheUpdateStillDoesNotLetRemoveAllTakeTheOwnersIcon() async throws {
        let library = try temp.folder("Library")
        let before = Self.manager(library)
        #expect(await before.apply(imageAt: picture, to: [try temp.folder("Other")]).allSatisfy(\.succeeded))
        let folder = try temp.folder("Holiday 2019")
        let own = Self.giveOwnIcon(folder)
        ExtendedAttributes.set(Data(UUID().uuidString.utf8), named: FolderImageManager.markerAttribute, at: folder)
        try Self.asIfSavedByAnEarlierVersion(library)

        let updated = Self.manager(library)
        await updated.takeOn([folder])
        _ = await updated.removeAll()
        #expect(Self.digest(folder) == own)
    }

    /// An icon its owner gives such a copy after the update.
    @Test func anIconGivenToAnOldCopyAfterTheUpdateStays() async throws {
        let library = try temp.folder("Library")
        let before = Self.manager(library)
        let original = try temp.folder("Projects")
        #expect(await before.apply(imageAt: picture, to: [original]).allSatisfy(\.succeeded))
        let copy = temp.url.appendingPathComponent("Projects copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)
        CarriedLook.remove(from: copy)
        try Self.asIfSavedByAnEarlierVersion(library)

        let updated = Self.manager(library)
        #expect(await updated.managedFolderCount() == 1)
        try await Task.sleep(for: .milliseconds(50))
        let own = Self.giveOwnIcon(copy)
        await updated.takeOn([copy])
        _ = await updated.removeAll()
        #expect(Self.digest(copy) == own)
        #expect(!FolderInspector.hasCustomIcon(original))
    }

    // MARK: - Whole icons

    @Test func aWholeIconIsToldFromOneWithNoPictureInIt() throws {
        let folder = try temp.folder("Icon")
        #expect(IconFile.setIcon(TestImages.nsImage(red: 0.3, green: 0.6, blue: 0.2), on: folder, options: []))
        let resource = try #require(FolderInspector.iconResource(of: folder))
        #expect(IconFile.isWhole(resource))
        // Cut short anywhere, or with the picture's bytes gone.
        for length in [0, 3, 16, 256, 286, resource.count / 2, resource.count - 1] {
            #expect(!IconFile.isWhole(resource.prefix(length)), "cut at \(length) of \(resource.count)")
        }
        var blank = resource
        let start = Int(resource[0..<4].reduce(0) { $0 << 8 | UInt32($1) }) + 4 + 8
        blank.replaceSubrange(start..<blank.count, with: Data(count: blank.count - start))
        #expect(!IconFile.isWhole(blank))
    }

    /// A disk all but full: a folder that had an icon keeps it whatever happens, and one that gets
    /// a new icon gets a whole one.
    @Test(arguments: RealDiskTests.kinds) func onAFullDiskFoldersKeepTheIconTheyHad(kind: String) async throws {
        let disk = try FullDisk(kind)
        defer { disk.detach() }
        let theirs = try disk.folder("Work/Client Logos")
        let theirIcon = Self.giveOwnIcon(theirs)
        let ours = try disk.folder("Work/Taxes")
        let manager = Self.manager(try temp.folder("Library-\(kind)"))
        #expect(await manager.apply(imageAt: picture, to: [ours]).allSatisfy(\.succeeded))
        let ourIcon = Self.digest(ours)
        disk.fill(leaving: 48 * 1024)

        let applied = await manager.apply(imageAt: picture, to: [theirs])
        if applied.allSatisfy(\.succeeded) {
            #expect(FolderInspector.iconResource(of: theirs).map(IconFile.isWhole) == true)
        } else {
            #expect(Self.digest(theirs) == theirIcon, "a failed write took the folder's own icon")
        }
        var restyled = true
        do {
            try await manager.setStyle(IconStyle(x: 0.1, y: 0.2, width: 0.5, height: 0.6, mode: .fit), for: ours)
        } catch {
            restyled = false
        }
        if restyled {
            #expect(FolderInspector.iconResource(of: ours).map(IconFile.isWhole) == true)
        } else {
            #expect(Self.digest(ours) == ourIcon, "a failed write took the folder's picture")
        }
        // Room again, and the tidy-up at launch: the folder still has its picture, on the list.
        disk.empty()
        await manager.prune()
        #expect(await manager.look(for: ours) != nil)
        #expect(FolderInspector.iconResource(of: ours).map(IconFile.isWhole) == true)
    }

    /// A small disk image that can be filled up.
    final class FullDisk {
        let name = "PFF\(UInt16.random(in: 1000...9999))"
        let temp: TemporaryDirectory
        var mount: URL { URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true) }

        init(_ kind: String) throws {
            temp = try TemporaryDirectory()
            let image = temp.file("\(name).dmg")
            #expect(RealDiskTests.Disk.hdiutil(["create", "-quiet", "-size", "40m", "-fs", kind, "-volname", name, image.path]))
            #expect(RealDiskTests.Disk.hdiutil(["attach", "-nobrowse", "-quiet", image.path]))
        }

        func folder(_ path: String) throws -> URL {
            let folder = mount.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        private var filler: URL { mount.appendingPathComponent("filler.bin", isDirectory: false) }

        /// Writes a file that leaves about `bytes` free.
        func fill(leaving bytes: Int) {
            let free = (try? mount.resourceValues(forKeys: [.volumeAvailableCapacityKey]))?.volumeAvailableCapacity ?? 0
            guard free > bytes, let handle = (FileManager.default.createFile(atPath: filler.path, contents: nil) ? try? FileHandle(forWritingTo: filler) : nil) else { return }
            defer { try? handle.close() }
            let chunk = Data(count: 1 << 20)
            var left = free - bytes
            while left > 0 {
                let piece = chunk.prefix(min(left, chunk.count))
                guard (try? handle.write(contentsOf: piece)) != nil else { break }
                left -= piece.count
            }
        }

        func empty() {
            try? FileManager.default.removeItem(at: filler)
        }

        func detach() {
            if !RealDiskTests.Disk.hdiutil(["detach", "-quiet", mount.path]) {
                RealDiskTests.Disk.hdiutil(["detach", "-force", "-quiet", mount.path])
            }
        }
    }

    // MARK: - One copy of the app at a time

    @Test func onlyOneCopyHasTheLibraryAtATime() throws {
        let library = try temp.folder("Library")
        var first = Self.taken(LibraryLock.take(in: library))
        #expect(first != nil)
        guard case .heldElsewhere = LibraryLock.take(in: library) else {
            Issue.record("a second copy got the lock too")
            return
        }
        // The first copy gone, however it ended: the lock goes with it.
        first = nil
        #expect(Self.taken(LibraryLock.take(in: library)) != nil)
    }

    private static func taken(_ attempt: LibraryLock.Attempt) -> LibraryLock? {
        if case .taken(let lock) = attempt { return lock }
        return nil
    }
}
