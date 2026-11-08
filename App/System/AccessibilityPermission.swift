import AppKit
import ApplicationServices
import Observation

/// Tracks whether PrettyFolder may use the Accessibility API, which it needs to see
/// which folder is under the pointer. Nothing else in the app depends on it.
///
/// macOS is never asked on the main thread. The first answer in a run, and the first after the
/// list of trusted apps changes, comes from the system's privacy service and takes as long as that
/// does (see `SystemQuestion`); everything on the main thread reads `isGranted` instead.
@Observable
final class AccessibilityPermission {
    static let shared = AccessibilityPermission()

    /// `nil` until macOS has said.
    private(set) var isGranted: Bool?

    @ObservationIgnored private var question: SystemQuestion!
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var pollTimer: Timer?
    @ObservationIgnored private var pollDeadline = Date.distantPast
    @ObservationIgnored private var isRequesting = false

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
                if self?.isGranted != true { self?.refresh() }
            }
        })
        // Where it is turned on or off.
        observers.append(contentsOf: SystemSettings.whenLeft { [weak self] in self?.refresh() })
        refresh()
    }

    /// Asks again; `then` gets the answer, a moment later.
    func refresh(then: ((Bool) -> Void)? = nil) {
        question.refresh(then: then)
    }

    private func update(_ granted: Bool) {
        if granted != isGranted { isGranted = granted }
        if granted { stopPolling() }
    }

    /// Shows the system prompt that leads to System Settings. On a thread of its own like every
    /// other question: the prompt goes through the same privacy service.
    func request() {
        guard !isRequesting else { return }
        isRequesting = true
        Thread {
            let granted = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let permission = AccessibilityPermission.shared
                    permission.isRequesting = false
                    if !granted { permission.startPolling() }
                    permission.refresh()
                }
            }
        }.start()
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

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
