import AppKit
import ApplicationServices
import Observation

/// Tracks whether PrettyFolder may use the Accessibility API, which it needs to see
/// which folder is under the pointer. Nothing else in the app depends on it.
@Observable
final class AccessibilityPermission {
    static let shared = AccessibilityPermission()

    private(set) var isGranted = AXIsProcessTrusted()

    @ObservationIgnored private var question: SystemQuestion!
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?

    private init() {
        question = SystemQuestion("accessibility", ask: { AXIsProcessTrusted() }) { [weak self] granted in
            self?.update(granted)
        }
        // Posted whenever the list of trusted apps changes. The new state is applied a
        // moment later, so check again after a short delay.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.accessibility.api"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self?.refresh() }
            }
        })
        // That notification can be missed (or the answer can lag right after an update),
        // so look again whenever Finder comes to the front, which is when it matters.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.apple.finder" else { return }
            MainActor.assumeIsolated {
                if self?.isGranted == false { self?.refresh() }
            }
        })
    }

    /// Asks again, off the main thread: the answer can come from the system's privacy service,
    /// and the menu that asks while it opens mustn't wait for that (see `SystemQuestion`).
    func refresh() {
        question.refresh()
    }

    private func update(_ granted: Bool) {
        if granted != isGranted { isGranted = granted }
        if granted { stopPolling() }
    }

    /// Shows the system prompt that leads to System Settings.
    func request() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        isGranted = AXIsProcessTrustedWithOptions(options)
        if !isGranted { startPolling() }
    }

    /// The notification is not always delivered, so poll while the user is on their way to grant it.
    private func startPolling() {
        pollDeadline = Date().addingTimeInterval(180)
        guard pollTimer == nil else { return }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refresh()
                if Date() > self.pollDeadline { self.stopPolling() }
            }
        }
    }

    @ObservationIgnored private var pollDeadline = Date.distantPast

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
