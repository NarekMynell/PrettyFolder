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
