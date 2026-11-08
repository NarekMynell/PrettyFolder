import AppKit
import ApplicationServices
import os

/// Brings PrettyFolder to the front for a window the user just asked for.
///
/// Requests from the Finder menu arrive while Finder is the active app. macOS 14+
/// cooperative activation may decline a background app's request to come forward, and
/// Finder can take activation back while its menu closes; either way the picker would
/// sit hidden behind Finder. So: ask nicely first; if that didn't stick and PrettyFolder
/// has Accessibility access (the drop badge and the buttons on folders need it anyway), become
/// frontmost the way assistive apps do; failing both, float the window above Finder so
/// it is at least visible. The first click on it then activates the app as usual.
enum AppActivation {
    private static let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Activation")

    static func bringToFront(_ window: NSWindow? = nil) {
        if !NSApp.isActive {
            NSApp.activate()
        }
        window?.makeKeyAndOrderFront(nil)

        // Activation is asynchronous; see how it went a moment later. A window that has been
        // closed meanwhile needs nothing more.
        let forWindow = window != nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak window] in
            guard !NSApp.isActive, !forWindow || window?.isVisible == true else { return }
            log.info("Not in front after asking; trying harder")
            // The permission as last heard: asking macOS again could wait on its privacy service.
            // (Asking the app's own element, as below, is answered in the app and doesn't wait.)
            if AccessibilityPermission.shared.isGranted == true {
                let app = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
                AXUIElementSetAttributeValue(app, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
                window?.makeKeyAndOrderFront(nil)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak window] in
                guard !NSApp.isActive, let window, window.isVisible else { return }
                log.info("Still not in front; floating the window")
                // AppDelegate makes it a normal window again once the app is active.
                window.level = .floating
                window.orderFrontRegardless()
            }
        }
    }
}
