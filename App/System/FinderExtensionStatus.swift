import AppKit
import FinderSync
import Observation
import os

/// Whether the Finder extension (the right-click menu) is turned on, and how to turn it on.
@Observable
final class FinderExtensionStatus {
    static let shared = FinderExtensionStatus()

    nonisolated static let extensionIdentifier = "com.narekmynell.PrettyFolder.FinderExtension"

    private(set) var isEnabled = FIFinderSyncController.isExtensionEnabled

    @ObservationIgnored private var activationObserver: NSObjectProtocol?
    @ObservationIgnored private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Extension")

    private init() {
        // Coming back from System Settings is the usual moment the answer changes.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        let enabled = FIFinderSyncController.isExtensionEnabled
        if enabled != isEnabled { isEnabled = enabled }
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
        Task.detached(priority: .userInitiated) { [log] in
            var ok = true
            if let appex {
                ok = Self.runPluginKit(["-a", appex.path], log: log) && ok
            }
            ok = Self.runPluginKit(["-e", "use", "-i", Self.extensionIdentifier], log: log) && ok
            await MainActor.run {
                // pluginkit returns before Finder picks the change up.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.refresh()
                    if !(self?.isEnabled ?? false) || !ok { FIFinderSyncController.showExtensionManagementInterface() }
                }
            }
        }
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            log.error("pluginkit \(arguments, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
