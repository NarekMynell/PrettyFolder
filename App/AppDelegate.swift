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
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "App")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherCopies()
        statusItem = StatusItemController(actions: actions, settings: settings)
        finderIntegration.start()
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

        // Forget folders whose icon was changed elsewhere, and pictures left over from a crash.
        // Then draw again the icons an earlier version drew differently: a fix in how a picture
        // meets the folder's edge reaches the folders that have one already.
        Task { [manager, log] in
            await manager.prune()
            let outcomes = await manager.redrawOutdated()
            guard !outcomes.isEmpty else { return }
            let failed = outcomes.filter { !$0.succeeded }.count
            log.notice("Redrew \(outcomes.count - failed) icons drawn by an earlier version, \(failed) failed")
        }

        isReady = true
        for (command, fromOurExtension) in queuedCommands {
            actions.handle(command, fromOurExtension: fromOurExtension)
        }
        queuedCommands.removeAll()

        if !settings.hasLaunchedBefore {
            // A background helper is expected to start with the Mac; the switch is behind
            // the gear for anyone who'd rather not. The window shows what still needs
            // turning on.
            settings.hasLaunchedBefore = true
            LoginItem.shared.setEnabled(true)
            actions.showEditor()
        }
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
        actions.showEditor()
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
        let asking = actions.confirmQuit { [weak self] proceed in
            guard proceed else { return NSApp.reply(toApplicationShouldTerminate: false) }
            self?.finishWriting()
        }
        if !asking { finishWriting() }
        return .terminateLater
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

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    /// Two copies running would mean two sets of badges over Finder. The copy started
    /// last wins, which is what you want right after installing an update.
    private func quitOtherCopies() {
        guard let identifier = Bundle.main.bundleIdentifier else { return }
        for other in NSRunningApplication.runningApplications(withBundleIdentifier: identifier) where other != .current {
            log.notice("Asking another running copy (pid \(other.processIdentifier)) to quit")
            other.terminate()
        }
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
