import AppKit

/// System Settings, where the Finder menu and the Accessibility permission are turned on or off.
enum SystemSettings {
    /// Calls `left` whenever the user leaves System Settings, for another app or by quitting it:
    /// the moment what they did there is worth asking about.
    static func whenLeft(_ left: @escaping @MainActor () -> Void) -> [NSObjectProtocol] {
        let center = NSWorkspace.shared.notificationCenter
        return [NSWorkspace.didDeactivateApplicationNotification, NSWorkspace.didTerminateApplicationNotification].map { name in
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard app?.bundleIdentifier == "com.apple.systempreferences" else { return }
                MainActor.assumeIsolated { left() }
            }
        }
    }
}
