import AppKit
import PrettyFolderIPC
import PrettyFolderKit
import UniformTypeIdentifiers
import os

/// Everything the user can do, whichever way they asked: right-click menu, drop badge,
/// the buttons on folders, the menu bar or the window.
final class FolderActions {
    let manager: FolderImageManager
    let settings: AppSettings

    private let picker = PicturePicker()
    private var editor: EditorWindowController?
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Actions")

    init(manager: FolderImageManager, settings: AppSettings) {
        self.manager = manager
        self.settings = settings
    }

    /// Runs a `prettyfolder://` command. Commands that only open a window run whoever
    /// sent them; removing pictures asks first unless the Finder extension sent it.
    func handle(_ command: FolderCommand, fromOurExtension: Bool) {
        log.info("Command \(command.action.rawValue, privacy: .public) for \(command.folders.count) folder(s), from the extension: \(fromOurExtension)")
        switch command.action {
        case .chooseImage: chooseImage(for: command.folders)
        case .removeImage:
            if fromOurExtension || confirmRemovalRequestedElsewhere(command.folders) {
                removeImage(from: command.folders)
            }
        case .adjust: showEditor(for: command.folders)
        case .settings: showEditor()
        }
    }

    private func confirmRemovalRequestedElsewhere(_ folders: [URL]) -> Bool {
        let alert = NSAlert()
        alert.messageText = folders.count == 1
            ? String(localized: "Remove the picture from “\(FileManager.default.displayName(atPath: folders[0].path))”?")
            : String(localized: "Remove the pictures from \(folders.count) folders?")
        alert.informativeText = String(localized: "Another app asked PrettyFolder to do this. The folders go back to the standard icon.")
        alert.addButton(withTitle: String(localized: "Remove"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.layout()
        AppActivation.bringToFront(alert.window)
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - The window

    /// Opens the window for `folders`. Without folders it comes up as it was left, or
    /// with the default look.
    func showEditor(for folders: [URL] = []) {
        let eligible = folders.isEmpty ? [] : checked(folders)
        guard folders.isEmpty || !eligible.isEmpty else { return }
        let controller = editor ?? EditorWindowController(actions: self)
        editor = controller
        controller.show(folders: eligible)
    }

    /// Keeps the window up to date when folders it shows change some other way.
    func picturesChanged(_ folders: [URL]) {
        editor?.model.reload(ifShowing: folders)
    }

    // MARK: - Pictures

    /// Asks for a picture and puts it on `folders`. With a window, the picker is a sheet
    /// on it; without one (the buttons on a folder), focus goes back to Finder afterwards.
    func chooseImage(for folders: [URL], attachedTo window: NSWindow? = nil) {
        let eligible = checked(folders)
        guard !eligible.isEmpty else { return }
        let returnTo = window == nil ? frontmostOtherApp() : nil
        let message = eligible.count == 1
            ? String(localized: "Choose a picture for “\(FileManager.default.displayName(atPath: eligible[0].path))”.")
            : String(localized: "Choose a picture for \(eligible.count) folders.")
        picker.pick(message: message, prompt: String(localized: "Use Picture"), startingIn: settings.lastPictureFolder, attachedTo: window) { [weak self] url in
            guard let self else { return }
            guard let url else {
                giveFocusBack(to: returnTo)
                return
            }
            settings.lastPictureFolder = url.deletingLastPathComponent()
            Task {
                let outcomes = await self.manager.apply(imageAt: url, to: eligible)
                self.picturesChanged(eligible)
                self.finish(outcomes, returningTo: returnTo)
            }
        }
    }

    /// Asks for a picture to preview the default look with. Nothing on disk changes.
    func choosePreviewPicture(attachedTo window: NSWindow?, completion: @escaping (SourceImage) -> Void) {
        picker.pick(
            message: String(localized: "Preview the default look with one of your pictures."),
            prompt: String(localized: "Preview"),
            startingIn: settings.lastPictureFolder,
            attachedTo: window
        ) { url in
            guard let url, let picture = PreviewPicture.load(url) else { return }
            completion(picture)
        }
    }

    /// Puts the picture in a file on `folders`, reporting any failure.
    func apply(imageAt url: URL, to folders: [URL]) async {
        let outcomes = await manager.apply(imageAt: url, to: folders)
        picturesChanged(folders)
        report(outcomes)
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
        picturesChanged([folder])
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
        Task {
            let outcomes = await manager.removeImage(from: folders)
            picturesChanged(folders)
            report(outcomes)
        }
    }

    func confirmRemovingAll(count: Int) -> Bool {
        let alert = NSAlert()
        alert.messageText = count == 1
            ? String(localized: "Remove the picture from the folder that has one?")
            : String(localized: "Remove the pictures from all \(count) folders?")
        alert.informativeText = String(localized: "The folders go back to the standard icon. The pictures themselves are not touched.")
        alert.addButton(withTitle: count == 1 ? String(localized: "Remove the Picture") : String(localized: "Remove \(count) Pictures"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        return alert.runModal() == .alertFirstButtonReturn
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
        // File names are only known once the files arrive; the promised types are known now.
        let expected = max(receiver.fileTypes.count, 1)
        return await withCheckedContinuation { (continuation: CheckedContinuation<URL?, Never>) in
            let state = OSAllocatedUnfairLock(initialState: (finished: false, pending: expected))
            let finish: @Sendable (URL?) -> Void = { url in
                let first = state.withLock { state -> Bool in
                    defer { state.finished = true }
                    return !state.finished
                }
                if first { continuation.resume(returning: url) }
            }
            // AppKit calls this on `queue`, not the main thread. It must not inherit the
            // main-actor isolation of this file, or Swift's isolation check stops the app.
            receiver.receivePromisedFiles(atDestination: directory, options: [:], operationQueue: queue) { @Sendable url, error in
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
