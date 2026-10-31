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
        try await manager.setStyle(custom, for: folder)
        let look = try #require(await manager.look(for: folder))
        #expect(look.style == custom && !look.followsDefault)
        #expect(FolderInspector.iconResource(of: folder) != before)

        // A new picture keeps the folder's own look.
        let other = temp.file("other.png")
        TestImages.write(TestImages.solid(width: 100, height: 300, red: 0, green: 0, blue: 1), to: other, type: .png)
        _ = await manager.apply(imageAt: other, to: [folder])
        #expect(await manager.look(for: folder)?.style == custom)
        #expect(storedPictures().count == 1, "the replaced picture is cleaned up")

        try await manager.setStyle(nil, for: folder)
        #expect(await manager.look(for: folder)?.followsDefault == true)
    }

    @Test func defaultStyleCanUpdateExistingFolders() async throws {
        let follower = try temp.folder("Follower")
        let pinned = try temp.folder("Pinned")
        _ = await manager.apply(imageAt: picture, to: [follower, pinned])
        let pinnedStyle = IconStyle(x: 0, y: 0, width: 0.3, height: 0.3, mode: .fill)
        try await manager.setStyle(pinnedStyle, for: pinned)
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

    @Test func followsRenamedFolders() async throws {
        let folder = try temp.folder("Before")
        _ = await manager.apply(imageAt: picture, to: [folder])
        let renamed = temp.url.appendingPathComponent("After", isDirectory: true)
        try FileManager.default.moveItem(at: folder, to: renamed)

        try await manager.setStyle(IconStyle(x: 0.1, y: 0.1, width: 0.4, height: 0.4, mode: .fill), for: renamed)
        await manager.prune()
        #expect(await manager.managedFolderCount() == 1)
    }

    @Test func copiesBecomeTheirOwnFolders() async throws {
        let original = try temp.folder("Original")
        _ = await manager.apply(imageAt: picture, to: [original])
        let copy = temp.url.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: original, to: copy)

        let style = IconStyle(x: 0.3, y: 0.3, width: 0.3, height: 0.3, mode: .fit)
        try await manager.setStyle(style, for: copy)
        #expect(await manager.managedFolderCount() == 2)
        #expect(await manager.look(for: original)?.followsDefault == true)
        #expect(await manager.look(for: copy)?.style == style)

        // Removing the copy's picture must not forget the original.
        _ = await manager.removeImage(from: [copy])
        #expect(await manager.look(for: original) != nil)
    }

    @Test func forgetsDeletedFolders() async throws {
        let folder = try temp.folder("Doomed")
        _ = await manager.apply(imageAt: picture, to: [folder])
        try FileManager.default.removeItem(at: folder)
        await manager.prune()
        #expect(await manager.managedFolderCount() == 0)
        #expect(storedPictures().isEmpty)
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
