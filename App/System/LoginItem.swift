import Observation
import ServiceManagement
import os

/// "Open at Login", through the system's own login item list.
@Observable
final class LoginItem {
    static let shared = LoginItem()

    private(set) var isEnabled = SMAppService.mainApp.status == .enabled

    @ObservationIgnored private let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "LoginItem")

    private init() {}

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            log.error("Changing the login item failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func refresh() {
        let enabled = SMAppService.mainApp.status == .enabled
        if enabled != isEnabled { isEnabled = enabled }
    }
}
