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
        let command = FolderCommand(.chooseImage, folders: [folder])
        let decoded = try #require(FolderCommand(url: command.url))
        #expect(decoded.action == .chooseImage)
        #expect(decoded.folders.map(\.path) == [folder.standardizedFileURL.path])
    }

    @Test func keepsOrderOfSeveralFolders() throws {
        let folders = ["/a", "/b b", "/c&c"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        let decoded = try #require(FolderCommand(url: FolderCommand(.removeImage, folders: folders).url))
        #expect(decoded.folders.map(\.path) == ["/a", "/b b", "/c&c"])
    }

    @Test func settingsNeedsNoFolder() throws {
        let decoded = try #require(FolderCommand(url: FolderCommand(.settings).url))
        #expect(decoded.action == .settings)
        #expect(decoded.folders.isEmpty)
    }

    @Test(arguments: [
        "prettyfolder://choose",                 // folder missing
        "prettyfolder://explode?path=/tmp",       // unknown action
        "https://choose?path=/tmp",               // wrong scheme
        "prettyfolder://choose?path=relative",    // not an absolute path
    ])
    func rejectsBadURLs(_ string: String) {
        #expect(FolderCommand(url: URL(string: string)!) == nil)
    }
}
