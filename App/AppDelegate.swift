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
    private var queuedCommands: [FolderCommand] = []
    private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "App")

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = MainMenu.make()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        quitOtherCopies()
        statusItem = StatusItemController(actions: actions, settings: settings)
        finderIntegration.start()

        isReady = true
        queuedCommands.forEach(actions.handle)
        queuedCommands.removeAll()

        if !settings.hasCompletedWelcome {
            if !LoginItem.shared.isEnabled { LoginItem.shared.setEnabled(true) }
            actions.showWelcome()
        }

        // Forget folders that were deleted or changed elsewhere while the app was not running.
        let manager = manager
        Task.detached(priority: .background) {
            await manager.prune()
        }
    }

    /// Commands from the Finder extension arrive as `prettyfolder://` URLs.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard let command = FolderCommand(url: url) else {
                log.notice("Ignoring URL \(url.absoluteString, privacy: .private)")
                continue
            }
            if isReady {
                actions.handle(command)
            } else {
                queuedCommands.append(command)
            }
        }
    }

    /// Opening the app again (from Finder, Spotlight, the Dock) shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        actions.showSettings()
        return false
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
