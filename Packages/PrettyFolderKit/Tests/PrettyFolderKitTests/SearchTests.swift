import AppKit
import CoreServices
import Testing
import os
@testable import PrettyFolderKit

/// Searches for folders that wait on something which doesn't answer: Spotlight, a disk, a tool.
/// On 2026-11-06 twelve searches, one for each disk connected while the Mac was locked, waited for
/// a Spotlight that never answered, each on one of the twelve threads Swift shares among all tasks,
/// and from the twelfth on no background task in the app could start.
@Suite(.serialized) struct SearchTests {
    let temp: TemporaryDirectory

    init() throws {
        temp = try TemporaryDirectory()
    }

    /// Searches that can be held up for as long as a test likes, counted.
    final class Searches: Sendable {
        private let gate = DispatchGroup()
        private let isOpen = OSAllocatedUnfairLock(initialState: false)
        private let counts = OSAllocatedUnfairLock(initialState: (started: [FolderSearchReach: Int](), running: [FolderSearchReach: Int](), mostAtOnce: 0))
        private let finds = OSAllocatedUnfairLock(initialState: [URL]())

        init() { gate.enter() }

        /// Lets the searches held up, and all after them, finish.
        func open() {
            let wasOpen = isOpen.withLock { open in
                defer { open = true }
                return open
            }
            if !wasOpen { gate.leave() }
        }

        /// What each search finds from now on.
        func find(_ folders: [URL]) { finds.withLock { $0 = folders } }

        func started(_ reach: FolderSearchReach) -> Int { counts.withLock { $0.started[reach] ?? 0 } }
        var mostAtOnce: Int { counts.withLock { $0.mostAtOnce } }

        func search(_ reach: FolderSearchReach, _ known: [String]) -> [URL] {
            counts.withLock { counts in
                counts.started[reach, default: 0] += 1
                counts.running[reach, default: 0] += 1
                counts.mostAtOnce = max(counts.mostAtOnce, counts.running.values.reduce(0, +))
            }
            gate.wait()
            counts.withLock { $0.running[reach, default: 0] -= 1 }
            return finds.withLock { $0 }
        }
    }

    private func manager(searchingWith searches: Searches) throws -> FolderImageManager {
        FolderImageManager(
            directory: try temp.folder("Library"), defaultStyle: .standard, unusedPictureAllowance: 0,
            searcher: { searches.search($0, $1) }
        )
    }

    /// Whether `work` is done within `seconds`. It isn't waited for any longer, so a test that
    /// would hang fails instead.
    private func isDone(within seconds: Double, _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let once = Once(continuation)
            Task { await work(); once.resume(returning: true) }
            Task {
                try? await Task.sleep(for: .seconds(seconds))
                once.resume(returning: false)
            }
        }
    }

    private func eventually(within seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() {
            guard Date() < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: - Searches that don't end

    @Test func searchesAskedForWhileOneHangsDontPileUpAndTheAppGoesOn() async throws {
        let searches = Searches()
        let manager = try manager(searchingWith: searches)
        defer { searches.open() }
        // One for each disk connected that night.
        let mounts = (0..<12).map { _ in Task { await manager.findFolders(.placesWithoutSpotlight) } }
        #expect(await eventually { searches.started(.placesWithoutSpotlight) == 1 })
        try await Task.sleep(for: .milliseconds(300))
        #expect(searches.started(.placesWithoutSpotlight) == 1, "one search, however many were asked for")

        // What waits for nobody's search still gets done...
        #expect(await isDone(within: 2) { _ = await manager.managedFolderCount() })
        // ...and background tasks still start: there were as many stuck searches as the Mac has cores.
        let cores = ProcessInfo.processInfo.activeProcessorCount
        for _ in 0..<cores {
            #expect(await isDone(within: 2) { await Task.detached(priority: .background) {}.value })
        }
        // Someone waiting for what Spotlight knows isn't kept waiting past their patience.
        #expect(await isDone(within: 2) { await manager.findFolders(.spotlight, patience: .milliseconds(300)) })
        #expect(searches.mostAtOnce == 2, "one search of each reach")

        // Once the disk answers, those asked for meanwhile are one more search.
        searches.open()
        for mount in mounts {
            #expect(await isDone(within: 5) { await mount.value })
        }
        #expect(searches.started(.placesWithoutSpotlight) <= 2)
        #expect(searches.started(.spotlight) == 1)
    }

    @Test func aSearchAskedForWhileOneIsUnderWayWaitsForOneThatBeganAfterIt() async throws {
        let first = Searches()
        let manager = try manager(searchingWith: first)
        defer { first.open() }
        let early = Task { await manager.findFolders() }
        #expect(await eventually { first.started(.spotlight) == 1 })
        let late = Task { await manager.findFolders() }
        try await Task.sleep(for: .milliseconds(100))
        first.open()
        #expect(await isDone(within: 5) { await early.value })
        #expect(await isDone(within: 5) { await late.value })
        // The one asked for while the first went on came after it: a folder made in between is in it.
        #expect(first.started(.spotlight) == 2)
    }

    @Test func whatASearchFindsComesOnTheListAfterNobodyWaitsForItAnyLonger() async throws {
        let searches = Searches()
        let manager = try manager(searchingWith: searches)
        defer { searches.open() }
        let picture = temp.file("photo.jpg")
        TestImages.write(TestImages.solid(width: 64, height: 48, red: 0, green: 0, blue: 1), to: picture, type: .png)
        let lost = try await oldCopy(named: "Lost", in: temp, of: picture, drawnBy: manager)
        searches.find([lost])

        await manager.findFolders(patience: .milliseconds(200))
        #expect(await manager.folderCountWithPictures() == 0, "still being looked for")
        searches.open()
        #expect(await isDone(within: 5) { await manager.findFolders() })
        #expect(await manager.folderCountWithPictures() == 1)
    }

    // MARK: - Spotlight

    /// What Spotlight's own API says, waiting as long as it takes: what the search's answer
    /// should be.
    private func iconFilesSpotlightKnows() -> Set<String> {
        guard let query = MDQueryCreate(kCFAllocatorDefault, "kMDItemFSName == \"Icon\r\"" as CFString, nil, nil),
              MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue))
        else { return [] }
        return Set((0..<MDQueryGetResultCount(query)).compactMap { index in
            guard let raw = MDQueryGetResultAtIndex(query, index) else { return nil }
            return MDItemCopyAttribute(Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue(), kMDItemPath) as? String
        })
    }

    @Test func spotlightIsAskedWhatItsOwnAPIWouldSay() throws {
        let expected = iconFilesSpotlightKnows()
        let answer = try #require(FolderSearch.indexedIconFiles())
        #expect(Set(answer.map(\.path)) == expected)
        #expect(answer.allSatisfy { $0.lastPathComponent == "Icon\r" })
    }

    @Test func spotlightNotAnsweringInTimeIsGivenUpOnAndAskedAgainNextTime() throws {
        for _ in 0..<5 {
            let started = Date()
            #expect(FolderSearch.indexedIconFiles(within: 0.01) == nil)
            #expect(Date().timeIntervalSince(started) < 2)
        }
        // However often it didn't answer before, the next search asks it again.
        #expect(FolderSearch.indexedIconFiles() != nil)
    }

    @Test func searchesAskingSpotlightAtOnceAllGetItsAnswer() throws {
        let answers = OSAllocatedUnfairLock(initialState: [Set<String>?]())
        let done = DispatchGroup()
        for _ in 0..<3 {
            done.enter()
            Thread.detachNewThread {
                let answer = FolderSearch.indexedIconFiles().map { Set($0.map(\.path)) }
                answers.withLock { $0.append(answer) }
                done.leave()
            }
        }
        #expect(done.wait(timeout: .now() + 30) == .success)
        let all = answers.withLock { $0 }
        #expect(all.count == 3 && all.allSatisfy { $0 != nil && $0 == all[0] })
    }

    @Test func disksSpotlightDoesntIndexAreStillGoneThroughWhileItIsAway() async throws {
        let disk = try RealDiskTests.Disk("ExFAT", inFinder: true)
        let copy = try disk.folder("Deep/Down/Copy")
        ExtendedAttributes.set(Data("x".utf8), named: FolderImageManager.markerAttribute, at: copy)
        let found = FolderSearch.markedFolders(.placesWithoutSpotlight, knownPaths: [], home: try disk.temp.folder("Home"), spotlight: { nil })
        #expect(found.map(\.path).contains(copy.path))
    }

    @MainActor @Test func theLiveWatchStartsOffTheMainThreadAndStillHearsAboutNewIconFiles() async throws {
        let disk = try RealDiskTests.Disk("APFS", inFinder: true)
        #expect(Subprocess.run("/usr/bin/mdutil", ["-i", "on", disk.mount.path], within: 30)?.status == 0)
        let heard = OSAllocatedUnfairLock(initialState: [URL]())
        let started = Date()
        let watch = FolderSpotlightWatch { files in heard.withLock { $0 += files } }
        #expect(Date().timeIntervalSince(started) < 0.2, "the main thread didn't wait for Spotlight")
        try await Task.sleep(for: .seconds(2))
        let folder = try disk.folder("Copy")
        FileManager.default.createFile(atPath: FolderInspector.iconFileURL(for: folder).path, contents: Data())
        let iconFile = FolderInspector.iconFileURL(for: folder).resolvingSymlinksInPath().path
        let deadline = Date().addingTimeInterval(60)
        var isHeard = false
        while !isHeard, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            isHeard = heard.withLock { $0 }.contains { $0.resolvingSymlinksInPath().path == iconFile }
        }
        #expect(isHeard, "after \(Int(Date().timeIntervalSince(started))) s")
        withExtendedLifetime(watch) {}
    }

    // MARK: - Tools

    @Test func aToolsAnswerIsRead() {
        let result = Subprocess.run("/bin/echo", ["hello"], within: 5)
        #expect(result?.status == 0)
        #expect(result?.output == "hello\n")
    }

    @Test func aToolsAnswerIsReadWhateverItLeavesRunning() {
        // Something it started keeps what the tool printed to open after the tool has ended.
        let started = Date()
        let result = Subprocess.run("/bin/sh", ["-c", "echo answer; sleep 20 &"], within: 5)
        #expect(result?.status == 0)
        #expect(result?.output == "answer\n")
        #expect(Date().timeIntervalSince(started) < 1)
    }

    @Test func aToolThatHangsIsStoppedInTime() throws {
        let started = Date()
        #expect(Subprocess.run("/bin/sleep", ["30"], within: 0.3) == nil)
        #expect(Date().timeIntervalSince(started) < 2)

        // Even one that won't be asked to stop.
        let pidFile = temp.file("pid")
        let stubborn = "open(F, '>', '\(pidFile.path)'); print F $$; close F; $SIG{TERM} = 'IGNORE'; sleep 30"
        let again = Date()
        #expect(Subprocess.run("/usr/bin/perl", ["-e", stubborn], within: 0.3) == nil)
        #expect(Date().timeIntervalSince(again) < 3)
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        Thread.sleep(forTimeInterval: 0.3)
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "stopped for good")
    }
}

/// Resumes a continuation once, whoever comes first.
private final class Once<Value: Sendable>: Sendable {
    private let continuation: OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = OSAllocatedUnfairLock(initialState: continuation)
    }

    func resume(returning value: Value) {
        continuation.withLock { continuation in
            defer { continuation = nil }
            return continuation
        }?.resume(returning: value)
    }
}
