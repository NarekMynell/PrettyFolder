import Foundation
import Testing
@testable import PrettyFolderIPC

@Suite struct FolderCommandTests {
    @Test(arguments: [
        "/Users/me/Pictures",
        "/Users/me/Folder with spaces",
        "/Users/me/a&b=c+d?e#f%g",
        "/Users/me/Ünïcödé 文件夹 📁",
        "/Volumes/My Disk/100% done",
        "/tmp/line\nbreak",
    ])
    func roundTripsAnyFolderName(_ path: String) throws {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let command = FolderCommand(.adjust, folders: [folder])
        let decoded = try #require(FolderCommand(url: command.url))
        #expect(decoded.action == .adjust)
        #expect(decoded.folders.map(\.path) == [folder.standardizedFileURL.path])
    }

    @Test func keepsOrderOfSeveralFolders() throws {
        let folders = ["/a", "/b b", "/c&c"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let decoded = try #require(FolderCommand(url: FolderCommand(.adjust, folders: folders).url))
        #expect(decoded.folders.map(\.path) == ["/a", "/b b", "/c&c"])
    }

    @Test func settingsNeedsNoFolder() throws {
        let decoded = try #require(FolderCommand(url: FolderCommand(.settings).url))
        #expect(decoded.action == .settings)
        #expect(decoded.folders.isEmpty)
    }

    @Test(arguments: [
        "prettyfolder://adjust",                 // folder missing
        "prettyfolder://explode?path=/tmp",       // unknown action
        "prettyfolder://remove?path=/tmp",        // nothing changes folders from outside the app
        "prettyfolder://choose?path=/tmp",
        "https://adjust?path=/tmp",               // wrong scheme
        "prettyfolder://adjust?path=relative",    // not an absolute path
    ])
    func rejectsBadURLs(_ string: String) {
        #expect(FolderCommand(url: URL(string: string)!) == nil)
    }

    @Test func cutsOffEndlessLists() throws {
        let query = (0..<(FolderCommand.maximumFolders + 50)).map { "path=/f\($0)" }.joined(separator: "&")
        let decoded = try #require(FolderCommand(url: URL(string: "prettyfolder://adjust?" + query)!))
        #expect(decoded.folders.count == FolderCommand.maximumFolders)
    }

    @Test(arguments: [
        ("/Users/me/Pictures/", true),
        ("/Users/me/Tool.app/", false),
        ("/Users/me/Library.photoslibrary/", false),
        ("/Volumes/Disk/", false),
        ("/Volumes/Disk/Work/", true),
        ("/", false),
        ("/Users/me/file.txt", false),
    ])
    func tellsPlainFolders(_ path: String, _ plain: Bool) {
        #expect(FolderCommand.isPlainFolder(URL(fileURLWithPath: path, isDirectory: path.hasSuffix("/"))) == plain)
    }
}
