import AppKit
import FinderSync
import Observation
import PrettyFolderKit
import os

/// Whether the Finder extension (the right-click menu) is turned on, and how to turn it on.
///
/// The system is asked off the main thread (see `SystemQuestion`): `isExtensionEnabled` waits for
/// a service of Finder's for as long as it takes to answer, and once that was for good.
@Observable
final class FinderExtensionStatus {
    static let shared = FinderExtensionStatus()

    nonisolated static let extensionIdentifier = "com.narekmynell.PrettyFolder.FinderExtension"

    /// `nil` until the system has said.
    private(set) var isEnabled: Bool?

    /// Whether to offer turning it on: it is off, or the system hasn't said for a while, which
    /// leaves the user a way to System Settings. Not at once, which would flash the offer at launch.
    var needsTurningOn: Bool { isEnabled == false || (isEnabled == nil && isSlowToSay) }

    /// The system hasn't said for a few seconds after it was first asked.
    private var isSlowToSay = false

    @ObservationIgnored private var question: SystemQuestion!
    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Extension")

    private init() {
        question = SystemQuestion("finder-extension", ask: { FIFinderSyncController.isExtensionEnabled }) { [weak self] enabled in
            if self?.isEnabled != enabled { self?.isEnabled = enabled }
        }
        // Coming back from System Settings is the usual moment the answer changes.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, isEnabled == nil else { return }
            isSlowToSay = true
        }
    }

    /// Asks the system again; `then` gets its answer.
    func refresh(then: ((Bool) -> Void)? = nil) {
        question.refresh(then: then)
    }

    /// Registers the extension that ships inside this copy of the app and turns it on,
    /// the same thing the checkbox in System Settings does. Falls back to opening
    /// System Settings if that does not work.
    func enable() {
        guard !Self.isTemporaryCopy else {
            // Its extension would be gone, and Finder's menu with it, once the app quits.
            let alert = NSAlert()
            alert.messageText = String(localized: "Move PrettyFolder to Applications first")
            alert.informativeText = String(localized: "macOS is running it from a temporary place, so the Finder menu would stop working once you quit. Move PrettyFolder to the Applications folder, open it from there, and turn the menu on again.")
            alert.layout()
            AppActivation.bringToFront(alert.window)
            alert.runModal()
            return
        }
        let appex = Bundle.main.builtInPlugInsURL?.appendingPathComponent("PrettyFolderFinder.appex")
        // pluginkit asks the same part of the system, so it can hang with it: off the main
        // thread, on a thread of its own, and only for so long.
        Thread { [log] in
            var ok = true
            if let appex {
                ok = Self.runPluginKit(["-a", appex.path], log: log) && ok
            }
            ok = Self.runPluginKit(["-e", "use", "-i", Self.extensionIdentifier], log: log) && ok
            // pluginkit returns before Finder picks the change up.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                MainActor.assumeIsolated { Self.shared.showSettingsUnlessOn(pluginKitWorked: ok) }
            }
        }.start()
    }

    /// Opens the extension's page in System Settings if it is still off, or if the system
    /// doesn't say so within a few seconds.
    private func showSettingsUnlessOn(pluginKitWorked: Bool) {
        let decision = Decision()
        let decide = { (enabled: Bool) in
            guard !decision.isMade else { return }
            decision.isMade = true
            if !enabled || !pluginKitWorked { FIFinderSyncController.showExtensionManagementInterface() }
        }
        refresh(then: decide)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { decide(false) }
    }

    /// Whether this copy runs from somewhere it won't stay: the temporary place macOS uses for
    /// an app opened straight from Downloads, or a disk image.
    private static var isTemporaryCopy: Bool {
        let bundle = Bundle.main.bundleURL
        // App Translocation mounts the app read-only under an "AppTranslocation" folder.
        return bundle.path.contains("/AppTranslocation/")
            || (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true
    }

    private nonisolated static func runPluginKit(_ arguments: [String], log: Logger) -> Bool {
        guard let result = Subprocess.run("/usr/bin/pluginkit", arguments, within: 15) else {
            log.error("pluginkit \(arguments, privacy: .public) didn't finish")
            return false
        }
        return result.status == 0
    }
}

/// Made once, by whichever comes first.
private final class Decision {
    var isMade = false
}
