import AppKit
import PrettyFolderIPC
import PrettyFolderKit
import os

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = AppSettings.shared
    private lazy var manager = FolderImageManager(directory: FolderImageManager.standardDirectory, defaultStyle: settings.defaultStyle)
    private lazy var actions = FolderActions(manager: manager, settings: settings)
    private lazy var finderIntegration = FinderIntegration(actions: actions, settings: settings)
    private var statusItem: StatusItemController?
    private var isReady = false
    private var queuedCommands: [(FolderCommand, fromOurExtension: Bool)] = []
    /// Asked for the window before the app was ready.
    private var isEditorAskedFor = false
    /// Held for as long as the app runs (see `LibraryLock`).
    private var libraryLock: LibraryLock?
    private var mountObserver: NSObjectProtocol?
    private var spotlightWatch: FolderSpotlightWatch?
    /// Quitting was asked for and is waiting for an answer, or for the last writes.
    private var isQuitting = false
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "App")

    func applicationWillFinishLaunching(_ notification: Notification) {
        MainThreadWatchdog.start()
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherCopies()
        // A copy that was running looks after the folders until it has quit: it may be finishing
        // a write, or asking whether to keep a new default look. Only then does this one start.
        whenAlone { [weak self] in self?.start() }
    }

    /// Calls `start` once no other copy runs and the library's lock is this copy's. A copy that is
    /// still there after a couple of minutes was kept by its user (they cancelled its question about
    /// the default look) or can't quit: then this one quits instead, rather than turn up whenever
    /// that one goes.
    private func whenAlone(_ start: @escaping @MainActor () -> Void) {
        if takeLibraryIfAlone() { return start() }
        log.notice("Waiting for the other copy to quit")
        Task { [weak self] in
            let deadline = ContinuousClock.now + .seconds(120)
            while ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self else { return }
                if self.takeLibraryIfAlone() { return start() }
            }
            self?.log.notice("The other copy is still running; this one quits")
            NSApp.terminate(nil)
        }
    }

    private func takeLibraryIfAlone() -> Bool {
        guard otherCopies().isEmpty else { return false }
        switch LibraryLock.take(in: FolderImageManager.standardDirectory) {
        case .taken(let lock):
            libraryLock = lock
            return true
        case .heldElsewhere:
            return false
        case .unavailable:
            log.error("The library can't be locked; going ahead")
            return true
        }
    }

    private func start() {
        statusItem = StatusItemController(actions: actions, settings: settings)
        finderIntegration.start()
        // Asks whether the Finder menu is on, off the main thread, so that the menu bar menu
        // knows by the time it opens.
        _ = FinderExtensionStatus.shared
        Task { [manager, actions, finderIntegration] in
            await manager.onIconChange { folder, change in
                switch change {
                case .written(let icon):
                    await MainActor.run { actions.iconWritten(folder, icon: icon) }
                    await finderIntegration.cover(folder, with: icon)
                case .removed:
                    await finderIntegration.uncover(folder)
                }
            }
        }

        // Find copies and moved folders that are new to the list, forget folders whose icon was
        // changed elsewhere, and pictures left over from a crash.
        Task {
            await manager.findFolders(patience: .seconds(30))
            await manager.prune()
            await redrawOutdatedIcons()
            // Last: on a big disk without Spotlight this takes as long as it takes.
            await manager.findFolders(.placesWithoutSpotlight)
        }
        // Folders on a disk that wasn't connected catch up as soon as it is.
        mountObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didMountNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.redrawOutdatedIcons()
                await self?.manager.findFolders(.placesWithoutSpotlight)
            }
        }
        // Spotlight may take a while over a disk it hasn't seen before. It says when it knows more.
        spotlightWatch = FolderSpotlightWatch { [manager] iconFiles in
            Task { await manager.takeOn(iconFiles: iconFiles) }
        }

        isReady = true
        for (command, fromOurExtension) in queuedCommands {
            actions.handle(command, fromOurExtension: fromOurExtension)
        }
        queuedCommands.removeAll()
        if isEditorAskedFor { actions.showEditor() }

        if !settings.hasLaunchedBefore {
            // A background helper is expected to start with the Mac; the switch is behind
            // the gear for anyone who'd rather not. The window shows what still needs
            // turning on.
            settings.hasLaunchedBefore = true
            LoginItem.shared.setEnabled(true)
            actions.showEditor()
        }
    }

    /// Draws again the icons that are behind: those an earlier version drew differently, so that
    /// a fix in how a picture meets the folder's edge reaches the folders that have one already,
    /// and those a new default look couldn't reach.
    private func redrawOutdatedIcons() async {
        let outcomes = await manager.redrawOutdated()
        guard !outcomes.isEmpty else { return }
        let failed = outcomes.filter { !$0.succeeded }.count
        log.notice("Redrew \(outcomes.count - failed) icons that were behind, \(failed) failed")
    }

    /// Commands from the Finder extension arrive as `prettyfolder://` URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        let fromOurExtension = Self.requestCameFromOurExtension()
        for url in urls {
            guard let command = FolderCommand(url: url) else {
                log.notice("Ignoring URL \(url.absoluteString, privacy: .private)")
                continue
            }
            if isReady {
                actions.handle(command, fromOurExtension: fromOurExtension)
            } else {
                queuedCommands.append((command, fromOurExtension))
            }
        }
    }

    /// Whether the URL being handled was sent by PrettyFolder's own Finder extension, as
    /// opposed to any other app or a web page (the URL scheme is public). Decided by the
    /// sending process, which the system attaches to the event and which can't be faked.
    private static func requestCameFromOurExtension() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value,
              let sender = NSRunningApplication(processIdentifier: pid)?.bundleURL?.standardizedFileURL.path,
              let plugIns = Bundle.main.builtInPlugInsURL?.standardizedFileURL.path
        else { return false }
        return sender.hasPrefix(plugIns + "/")
    }

    /// Opening the app again (from Finder, Spotlight, the Dock) shows the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if isReady { actions.showEditor() } else { isEditorAskedFor = true }
        return false
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // Windows floated above Finder while the app couldn't come forward (see AppActivation).
        for window in NSApp.windows where window.level == .floating && !(window is OverlayPanel) {
            window.level = .normal
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Quitting waits for a new default look to be saved or discarded, then for the window's
    /// last change to be written, and lets the folder being written finish: nothing is cut off
    /// halfway. Long runs (Redraw All, Remove All) stop at the next folder.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Still waiting for another copy: nothing started, nothing to finish.
        guard isReady else { return .terminateNow }
        isQuitting = true
        let asking = actions.confirmQuit { [weak self] proceed in
            guard proceed else {
                self?.isQuitting = false
                return NSApp.reply(toApplicationShouldTerminate: false)
            }
            self?.finishWriting()
        }
        if !asking { finishWriting() }
        return .terminateLater
    }

    /// Quits, for the buttons and menu items that do. Unless it is on its way already: asked again
    /// meanwhile, AppKit quits on the spot, whatever is being asked or written.
    static func quit() {
        guard (NSApp.delegate as? AppDelegate)?.isQuitting != true else { return }
        NSApp.terminate(nil)
    }

    private func finishWriting() {
        let finished = OneTimeReply()
        Task { [actions, manager] in
            await actions.finishEditing()
            await manager.stop()
            finished.reply()
        }
        // A folder on a disk that stopped answering mustn't keep the app from quitting.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finished.reply() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        Subprocess.stopAll()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Two copies running would mean two sets of badges over Finder. The copy started
    /// last wins, which is what you want right after installing an update.
    private func quitOtherCopies() {
        for other in otherCopies() {
            log.notice("Asking another running copy (pid \(other.processIdentifier)) to quit")
            other.terminate()
        }
    }

    private func otherCopies() -> [NSRunningApplication] {
        guard let identifier = Bundle.main.bundleIdentifier else { return [] }
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier).filter { $0 != .current && !$0.isTerminated }
    }
}

/// Tells AppKit once that quitting can go ahead, whichever is first: the work being done or
/// the time running out.
private final class OneTimeReply {
    private var replied = false

    func reply() {
        guard !replied else { return }
        replied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
