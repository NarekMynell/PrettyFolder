import Foundation
import Observation
import ServiceManagement
import os

/// "Open at Login", through the system's own login item list.
///
/// Every call to it is a round trip to the system's ServiceManagement service with no time limit,
/// so none is made on the main thread (see `SystemQuestion`): its state is asked on a thread of
/// its own, and changes go through a queue of their own, one after another.
@Observable
final class LoginItem {
    static let shared = LoginItem(system: .serviceManagement)

    /// What is asked of macOS; stood in for in tests.
    struct System: Sendable {
        /// Whether the app opens at login.
        var isEnabled: @Sendable () -> Bool
        /// Turns it on or off; opens System Settings when only the user can allow it, there.
        var change: @Sendable (_ enabled: Bool) -> Void

        static let serviceManagement = System(
            isEnabled: { SMAppService.mainApp.status == .enabled },
            change: { enabled in
                let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "LoginItem")
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    log.error("Changing the login item failed: \(error.localizedDescription, privacy: .public)")
                }
                // Turned off under Login Items in System Settings before: only the user can allow
                // it again, there.
                if enabled, SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        )
    }

    /// `nil` until macOS has said.
    private(set) var isEnabled: Bool?

    @ObservationIgnored private let system: System
    @ObservationIgnored private var question: SystemQuestion!
    @ObservationIgnored private let changes = DispatchQueue(label: "com.narekmynell.PrettyFolder.login-item", qos: .userInitiated)
    /// Changes asked for and not yet followed by a fresh answer: until then the switch stays where
    /// it was put, whatever an answer to an earlier question says.
    @ObservationIgnored private var changing = 0

    init(system: System) {
        self.system = system
        question = SystemQuestion("login-item", ask: system.isEnabled) { [weak self] enabled in
            guard let self, changing == 0, isEnabled != enabled else { return }
            isEnabled = enabled
        }
        refresh()
    }

    /// Asks again; the answer comes a moment later.
    func refresh() {
        question.refresh()
    }

    func setEnabled(_ enabled: Bool) {
        changing += 1
        if isEnabled != enabled { isEnabled = enabled }
        changes.async { [system, weak self] in
            system.change(enabled)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.changed() }
            }
        }
    }

    /// A change went through, or failed: the switch shows what macOS says from now on.
    private func changed() {
        question.refresh { [weak self] enabled in
            guard let self else { return }
            changing -= 1
            if changing == 0, isEnabled != enabled { isEnabled = enabled }
        }
    }
}
