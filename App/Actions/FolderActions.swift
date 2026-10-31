import AppKit
import PrettyFolderIPC
import PrettyFolderKit
import UniformTypeIdentifiers
import os

/// Everything the user can do, whichever way they asked: right-click menu, drop badge,
/// tab button, menu bar or settings.
final class FolderActions {
    let manager: FolderImageManager
    let settings: AppSettings

    private let picker = PicturePicker()
    private var lookWindows: [String: FolderLookWindowController] = [:]
    private var settingsWindow: SettingsWindowController?
    private var welcomeWindow: WelcomeWindowController?
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Actions")

    init(manager: FolderImageManager, settings: AppSettings) {
        self.manager = manager
        self.settings = settings
    }

    func handle(_ command: FolderCommand) {
        log.info("Command \(command.action.rawValue, privacy: .public) for \(command.folders.count) folder(s)")
        switch command.action {
        case .chooseImage: chooseImage(for: command.folders)
        case .removeImage: removeImage(from: command.folders)
        case .adjust: command.folders.first.map(adjust)
        case .settings: showSettings()
        }
    }

    // MARK: - Pictures

    func chooseImage(for folders: [URL]) {
        let eligible = checked(folders)
        guard !eligible.isEmpty else { return }
        let returnTo = frontmostOtherApp()
        let offerRemove = eligible.contains(where: FolderInspector.hasCustomIcon)
        picker.pick(for: eligible, startingIn: settings.lastPictureFolder, offerRemove: offerRemove) { [weak self] result in
            guard let self else { return }
            switch result {
            case .picture(let url):
                self.settings.lastPictureFolder = url.deletingLastPathComponent()
                Task {
                    let outcomes = await self.manager.apply(imageAt: url, to: eligible)
                    self.finish(outcomes, returningTo: returnTo)
                }
            case .remove:
                self.removeImage(from: eligible, returningTo: returnTo)
            case .cancelled:
                self.giveFocusBack(to: returnTo)
            }
        }
    }

    /// Applies a dropped picture. Returns whether it worked, for the badge to show.
    func apply(_ picture: DroppedPicture, to folder: URL) async -> Bool {
        let outcomes: [FolderOutcome]
        switch picture {
        case .file(let url):
            outcomes = await manager.apply(imageAt: url, to: [folder])
        case .data(let data, let type):
            outcomes = await manager.apply(imageData: data, type: type, to: [folder])
        case .promise(let receiver):
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PrettyFolder-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            guard let url = await PromiseReceiving.receive(receiver, into: directory) else {
                log.error("A promised file never arrived")
                return false
            }
            outcomes = await manager.apply(imageAt: url, to: [folder])
        }
        let succeeded = outcomes.allSatisfy(\.succeeded)
        if !succeeded {
            // Let the badge show its failure first, then explain.
            Task {
                try? await Task.sleep(for: .milliseconds(900))
                self.report(outcomes)
            }
        }
        return succeeded
    }

    func removeImage(from folders: [URL]) {
        removeImage(from: folders, returningTo: nil)
    }

    private func removeImage(from folders: [URL], returningTo app: NSRunningApplication?) {
        Task {
            let outcomes = await manager.removeImage(from: folders)
            for folder in folders { lookWindows[folder.standardizedFileURL.path]?.close() }
            finish(outcomes, returningTo: app)
        }
    }

    func adjust(_ folder: URL) {
        Task {
            if let look = await manager.look(for: folder) {
                showLookWindow(for: look)
            } else if !checked([folder]).isEmpty {
                // Nothing to adjust yet: start with a picture.
                chooseImage(for: [folder])
            }
        }
    }

    // MARK: - Windows

    func showSettings() {
        let controller = settingsWindow ?? SettingsWindowController(actions: self)
        settingsWindow = controller
        controller.present()
    }

    func showWelcome() {
        let controller = welcomeWindow ?? WelcomeWindowController(actions: self)
        welcomeWindow = controller
        controller.onClose = { [weak self] in
            self?.settings.hasCompletedWelcome = true
            self?.welcomeWindow = nil
        }
        controller.present()
    }

    private func showLookWindow(for look: FolderLook) {
        let key = look.folder.standardizedFileURL.path
        if let existing = lookWindows[key] {
            existing.present()
            return
        }
        let controller = FolderLookWindowController(look: look, actions: self)
        controller.onClose = { [weak self] in self?.lookWindows[key] = nil }
        lookWindows[key] = controller
        controller.present()
    }

    // MARK: - Feedback

    private func finish(_ outcomes: [FolderOutcome], returningTo app: NSRunningApplication?) {
        if outcomes.allSatisfy(\.succeeded) {
            giveFocusBack(to: app)
        } else {
            report(outcomes)
        }
    }

    /// Validates folders up front and explains the ones that can't be used.
    private func checked(_ folders: [URL]) -> [URL] {
        var eligible: [URL] = []
        var problems: [FolderOutcome] = []
        for folder in folders {
            do {
                try FolderInspector.validate(folder)
                eligible.append(folder)
            } catch {
                problems.append(FolderOutcome(folder: folder, failure: error.localizedDescription))
            }
        }
        report(problems)
        return eligible
    }

    func report(_ outcomes: [FolderOutcome]) {
        let failures = outcomes.filter { !$0.succeeded }
        guard !failures.isEmpty else { return }
        for failure in failures {
            log.error("\(failure.folder.path, privacy: .private): \(failure.failure ?? "", privacy: .public)")
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = failures.count == 1
            ? String(localized: "Couldn't change “\(FileManager.default.displayName(atPath: failures[0].folder.path))”")
            : String(localized: "Couldn't change \(failures.count) folders")
        var details = failures.prefix(4).compactMap(\.failure)
        if failures.count > 4 { details.append(String(localized: "…and \(failures.count - 4) more.")) }
        var seen = Set<String>()
        alert.informativeText = details.filter { seen.insert($0).inserted }.joined(separator: "\n\n")
        alert.layout()
        AppActivation.bringToFront(alert.window)
        alert.runModal()
    }

    private func frontmostOtherApp() -> NSRunningApplication? {
        let app = NSWorkspace.shared.frontmostApplication
        return app == .current ? nil : app
    }

    private func giveFocusBack(to app: NSRunningApplication?) {
        guard let app, !app.isTerminated else { return }
        app.activate(from: .current, options: [])
    }
}

/// Waits for a dragged file promise (from Photos, Safari, Mail…) to be written to disk.
enum PromiseReceiving {
    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.narekmynell.PrettyFolder.promises"
        queue.qualityOfService = .userInitiated
        return queue
    }()

    /// The first received image file, or `nil` on failure or after 30 seconds.
    static func receive(_ receiver: NSFilePromiseReceiver, into directory: URL) async -> URL? {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let expected = max(receiver.fileNames.count, 1)
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let state = OSAllocatedUnfairLock(initialState: (finished: false, pending: expected))
            let finish: @Sendable (URL?) -> Void = { url in
                let first = state.withLock { state -> Bool in
                    defer { state.finished = true }
                    return !state.finished
                }
                if first { continuation.resume(returning: url) }
            }
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { url, error in
                let allArrived = state.withLock { state -> Bool in
                    state.pending -= 1
                    return state.pending <= 0
                }
                if error == nil, ImageLoader.isImageFile(url) {
                    finish(url)
                } else if allArrived {
                    finish(nil)
                }
            }
            // The source app may never deliver; don't wait forever.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) { finish(nil) }
        }
    }
}
