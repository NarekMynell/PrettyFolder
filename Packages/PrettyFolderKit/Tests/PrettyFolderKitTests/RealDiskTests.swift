import AppKit
import Testing
@testable import PrettyFolderKit

/// On real disks of every kind, made from disk images: what a folder is called and numbered, and
/// what can be looked up about it, depends on the disk.
@Suite(.serialized) struct RealDiskTests {
    static let kinds = ["APFS", "HFS+", "ExFAT", "MS-DOS FAT32"]

    /// A disk mounted in /Volumes for as long as it's kept.
    final class Disk {
        let name = "PFT\(UInt16.random(in: 1000...9999))"
        let temp: TemporaryDirectory
        let image: URL
        var mount: URL { URL(fileURLWithPath: "/Volumes/\(name)", isDirectory: true) }

        /// `inFinder`: as a disk someone connected, the kind a search goes through.
        let inFinder: Bool

        init(_ kind: String, inFinder: Bool = false) throws {
            temp = try TemporaryDirectory()
            image = temp.file("\(name).dmg")
            self.inFinder = inFinder
            #expect(Self.hdiutil(["create", "-quiet", "-size", "60m", "-fs", kind, "-volname", name, image.path]))
            attach()
        }

        func attach() {
            #expect(Self.hdiutil(["attach"] + (inFinder ? [] : ["-nobrowse"]) + ["-quiet", image.path]))
            #expect(FileManager.default.fileExists(atPath: mount.path))
        }

        func detach() {
            #expect(Self.hdiutil(["detach", "-quiet", mount.path]))
        }

        func folder(_ path: String) throws -> URL {
            let folder = mount.appendingPathComponent(path, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        }

        deinit {
            if FileManager.default.fileExists(atPath: mount.path) {
                Self.hdiutil(["detach", "-force", "-quiet", mount.path])
            }
        }

        @discardableResult
        static func hdiutil(_ arguments: [String]) -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            process.arguments = arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
    }

    private func picture(in temp: TemporaryDirectory) -> URL {
        let picture = temp.file("photo.jpg")
        TestImages.write(TestImages.solid(width: 640, height: 480, red: 1, green: 0.5, blue: 0), to: picture, type: .jpeg)
        return picture
    }

    @Test(arguments: kinds) func anOpenFolderIsFollowedThroughARenameWhateverTakesItsName(kind: String) throws {
        let disk = try Disk(kind)
        let old = try disk.folder("Old")
        // Another one around: only the right one will do.
        _ = try disk.folder("Other")
        let location = try #require(FolderInspector.Location(of: old))
        let renamed = disk.mount.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: renamed)
        #expect(location.current?.lastPathComponent == "Renamed", "\(kind)")
        _ = try disk.folder("Old")
        #expect(location.current?.lastPathComponent == "Renamed", "\(kind): a new folder of the old name isn't it")
    }

    @Test(arguments: kinds) func aDeletedFolderLeavesTheNewOneOfItsName(kind: String) throws {
        let disk = try Disk(kind)
        let old = try disk.folder("Old")
        let location = try #require(FolderInspector.Location(of: old))
        try FileManager.default.removeItem(at: old)
        _ = try disk.folder("Other")
        _ = try disk.folder("Old")
        #expect(location.current?.lastPathComponent == "Old", "\(kind)")
    }

    @Test(arguments: kinds) func aDiskConnectedAgainDoesNotMixUpAnOpenFolder(kind: String) throws {
        let disk = try Disk(kind)
        _ = try disk.folder("First")
        let kept = try disk.folder("Second")
        _ = try disk.folder("Third")
        let location = try #require(FolderInspector.Location(of: kept))
        disk.detach()
        disk.attach()
        // Asked in another order than they were made in, so numbers handed out anew would differ.
        _ = FolderInspector.fileNumber(of: disk.mount.appendingPathComponent("Third"))
        #expect(location.current?.lastPathComponent == "Second", "\(kind)")
    }

    @Test(arguments: kinds) func aRenamedFolderStaysKnownWhateverTakesItsName(kind: String) async throws {
        let disk = try Disk(kind)
        let manager = FolderImageManager(directory: try disk.temp.folder("Library"), defaultStyle: .standard)
        let old = try disk.folder("Old")
        #expect(await manager.apply(imageAt: picture(in: disk.temp), to: [old]).allSatisfy { $0.succeeded })
        let renamed = disk.mount.appendingPathComponent("Renamed", isDirectory: true)
        try FileManager.default.moveItem(at: old, to: renamed)
        let newcomer = try disk.folder("Old")

        let turned = IconStyle(x: 0.1, y: 0.2, width: 0.5, height: 0.6, mode: .fit)
        #expect(await manager.setDefaultStyle(turned, updateExisting: true).allSatisfy { $0.succeeded })
        #expect(await manager.look(for: renamed)?.style == turned, "\(kind)")
        #expect(!FolderInspector.hasCustomIcon(newcomer), "\(kind)")
        #expect(await manager.managedFolderCount() == 1, "\(kind)")
        #expect(await manager.removeAll().allSatisfy { $0.succeeded })
        #expect(!FolderInspector.hasCustomIcon(renamed), "\(kind)")
    }

    @Test func aDiskWithAWholeMacOnItIsLeftAloneAndAnyOtherIsNot() async throws {
        let plain = try Disk("APFS", inFinder: true)
        let copy = try plain.folder("Work/Copy")
        ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: copy)

        let system = try Disk("APFS", inFinder: true)
        _ = try system.folder("System/Library/CoreServices")
        FileManager.default.createFile(atPath: system.mount.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist").path, contents: Data())
        let onSystem = try system.folder("Users/me/Copy")
        ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: onSystem)

        let data = try Disk("APFS", inFinder: true)
        _ = try data.folder("Library")
        let onData = try data.folder("Users/me/Copy")
        ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: onData)

        let home = try plain.temp.folder("Home")
        let found = FolderSearch.markedFolders(.everywhere, knownPaths: [], home: home).map(\.path)
        #expect(found.contains(copy.path))
        #expect(!found.contains(onSystem.path))
        #expect(!found.contains(onData.path))
    }

    @Test func aTimeMachineDiskIsLeftAlone() async throws {
        let disk = try Disk("APFS")
        var marked: [URL] = []
        for path in ["2026-11-01-120000.previous/Macintosh HD - Data/Users/me/Copy",
                     "2026-11-02-120000.inprogress/Macintosh HD - Data/Users/me/Copy",
                     ".timemachine/ABCD/2026-11-03-120000.backup/2026-11-03-120000.backup/Data/Users/me/Copy",
                     "Backups.backupdb/Mac/Latest/Macintosh HD/Users/me/Copy"] {
            let folder = try disk.folder(path)
            ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: folder)
            marked.append(folder)
        }
        let found = FolderSearch.markedFolders(in: [disk.mount])
        #expect(found.isEmpty, "\(found)")
    }

    @Test func aDiskMountedInsideAPlaceIsNotGoneThrough() throws {
        let disk = try Disk("APFS")
        let place = try disk.temp.folder("Home")
        let mountPoint = try disk.temp.folder("Home/mnt")
        #expect(Disk.hdiutil(["detach", "-quiet", disk.mount.path]))
        #expect(Disk.hdiutil(["attach", "-nobrowse", "-quiet", "-mountpoint", mountPoint.path, disk.image.path]))
        defer { Disk.hdiutil(["detach", "-force", "-quiet", mountPoint.path]) }
        let onIt = mountPoint.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.createDirectory(at: onIt, withIntermediateDirectories: true)
        ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: onIt)
        let beside = place.appendingPathComponent("Beside", isDirectory: true)
        try FileManager.default.createDirectory(at: beside, withIntermediateDirectories: true)
        ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: beside)
        #expect(FolderSearch.markedFolders(in: [place]).map(\.lastPathComponent) == ["Beside"])
        #expect(FolderSearch.placesInHome(place, knownPaths: []).map(\.lastPathComponent).contains("Beside"))
        #expect(!FolderSearch.placesInHome(place, knownPaths: []).map(\.lastPathComponent).contains("mnt"))
    }

    @Test func aFolderOnADiskIsFoundWithoutSpotlightAndTheDiskCanBeEjectedAfterwards() async throws {
        let disk = try Disk("ExFAT", inFinder: true)
        let copy = try disk.folder("Deep/Down/Copy")
        ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: copy)
        let found = FolderSearch.markedFolders(.placesWithoutSpotlight, knownPaths: [], home: try disk.temp.folder("Home")).map(\.path)
        #expect(found.contains(copy.path))
        disk.detach()
    }
}
