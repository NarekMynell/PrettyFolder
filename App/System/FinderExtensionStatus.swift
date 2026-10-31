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

    func openSystemSettings() {
        FIFinderSyncController.showExtensionManagementInterface()
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
