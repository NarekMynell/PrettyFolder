import AppKit

// NSApplication keeps its delegate weakly, so the delegate lives here for the whole run.
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
