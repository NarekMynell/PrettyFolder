import AppKit

#if DEBUG
// `--readme-media <folder>` renders the README's pictures instead of starting the app.
ReadmeMedia.runIfRequested()
#endif

// NSApplication keeps its delegate weakly, so the delegate lives here for the whole run.
let appDelegate = AppDelegate()
NSApplication.shared.delegate = appDelegate
NSApplication.shared.run()
