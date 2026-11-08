import AppKit
import PrettyFolderKit
import os

/// Quits the app if its main thread stops answering while one of its menus is opening or open, so
/// that the app can never keep the keyboard: every key goes to that menu. On 2026-11-06 the main
/// thread waited for good while the menu bar menu opened, and nothing could be typed anywhere for
/// an hour, until the app was killed. The crash report this leaves says where the main thread was
/// waiting.
///
/// With no menu open, nothing but the app itself waits: macOS can be slow to set up an open panel,
/// say. That is only noted in the log; quitting would lose the app for nothing.
///
/// What it can't do is end a wait on a disk that has stopped answering: the app can't quit until
/// the disk does. So the main thread never touches the disk of a folder.
///
/// The main thread is asked every second whether it's there. Only time this thread was awake to
/// count is counted: while the whole app or the Mac was stopped (asleep, in a debugger, too busy to
/// run anything) nobody was kept waiting by the app.
nonisolated final class MainThreadWatchdog: @unchecked Sendable {
    /// When a stall with no menu open is noted in the log: far longer than anything the app does on
    /// its main thread takes.
    static let limit: TimeInterval = 15
    /// While a menu of the app's is being tracked, from before it asks for its items until after it
    /// closes. It has the keyboard of every app then, and the app does nothing in that time that
    /// takes more than a moment.
    static let menuLimit: TimeInterval = 3

    private static let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Watchdog")
    private static let started = OSAllocatedUnfairLock(initialState: false)
    /// The menus being tracked, and since when the first of them has been.
    private struct Menus {
        var count = 0
        /// The menu bar menu's delegate says it is opening or open (see `menuOpening`).
        var isOpenSaysDelegate = false
        var since: TimeInterval = 0
        var isOpen: Bool { count > 0 || isOpenSaysDelegate }
    }
    private static let menus = OSAllocatedUnfairLock(initialState: Menus())

    private let limit: TimeInterval
    private let menuLimit: TimeInterval
    private let interval: TimeInterval
    private let hung: @Sendable (_ seconds: TimeInterval, _ inMenu: Bool) -> Void
    private let isAsking = OSAllocatedUnfairLock(initialState: false)

    /// Starts watching, once per run, from the main thread. `hung` is told how long the main thread
    /// has been gone, and whether a menu was being tracked: once `menuLimit` is reached with a menu,
    /// once per stall when `limit` is reached without.
    static func start(
        limit: TimeInterval = MainThreadWatchdog.limit, menuLimit: TimeInterval = MainThreadWatchdog.menuLimit,
        interval: TimeInterval = 1,
        hung: @escaping @Sendable (TimeInterval, Bool) -> Void = { seconds, inMenu in
            if inMenu { quit(after: seconds) } else { note(seconds) }
        }
    ) {
        let isFirst = started.withLock { started in
            defer { started = true }
            return !started
        }
        guard isFirst else { return }
        // Every menu of the app's, the menu bar one, the main menu and pop-ups alike: macOS posts
        // these before a menu asks its delegate for its items, and after it has closed.
        let center = NotificationCenter.default
        _ = center.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { _ in
            menus.withLock { menus in
                if !menus.isOpen { menus.since = uptime() }
                menus.count += 1
            }
        }
        _ = center.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: nil) { _ in
            menus.withLock { $0.count = max(0, $0.count - 1) }
        }
        let watchdog = MainThreadWatchdog(limit: limit, menuLimit: menuLimit, interval: interval, hung: hung)
        let thread = Thread { watchdog.watch() }
        thread.name = "com.narekmynell.PrettyFolder.watchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// From a menu's delegate as it is asked for its items, the moment the app once waited for
    /// good: macOS says it tracks the menu before that (macOS 26), but nothing promises it will.
    static func menuOpening() {
        menus.withLock { menus in
            if !menus.isOpen { menus.since = uptime() }
            menus.isOpenSaysDelegate = true
        }
    }

    /// From that delegate once the menu has closed.
    static func menuClosed() {
        menus.withLock { $0.isOpenSaysDelegate = false }
    }

    private init(limit: TimeInterval, menuLimit: TimeInterval, interval: TimeInterval, hung: @escaping @Sendable (TimeInterval, Bool) -> Void) {
        self.limit = limit
        self.menuLimit = menuLimit
        self.interval = interval
        self.hung = hung
    }

    private func watch() {
        var waited: TimeInterval = 0
        var isNoted = false
        var last = Self.uptime()
        while true {
            Thread.sleep(forTimeInterval: interval)
            let now = Self.uptime()
            let step = now - last
            last = now
            guard isAsking.withLock({ $0 }) else {
                waited = 0
                isNoted = false
                ask()
                continue
            }
            // This thread didn't get to run either, or the app is being debugged: nobody can tell
            // how long the main thread itself was gone.
            if step > interval * 3 || Self.isBeingDebugged {
                waited = 0
                continue
            }
            // A step a little late counts as one on time: the rest of it this thread may have been
            // kept from running too.
            waited += min(step, interval * 1.5)
            if Self.menus.withLock({ $0.isOpen }) {
                if waited >= menuLimit {
                    hung(waited, true)
                    waited = 0
                }
            } else if waited >= limit, !isNoted {
                hung(waited, false)
                isNoted = true
            }
        }
    }

    /// Asked with a timer due at once on the main run loop, in every mode a window or menu runs it
    /// in: whenever the loop goes round, it answers. Not through the main queue, nor a block on the
    /// loop: an alert shown from one of those runs the loop, and takes clicks and keys, while what
    /// came after it waits for it to end.
    private func ask() {
        isAsking.withLock { $0 = true }
        let main = CFRunLoopGetMain()
        let answer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent(), 0, 0, 0) { [isAsking] _ in
            isAsking.withLock { $0 = false }
            Self.forgetMenusNotTracked()
        }
        CFRunLoopAddTimer(main, answer, .commonModes)
        CFRunLoopWakeUp(main)
    }

    /// A menu is tracked with the main run loop in event-tracking mode. One said to be tracked for a
    /// while with the loop in another mode isn't (an end that never came): it mustn't shorten the
    /// limit for good.
    private static func forgetMenusNotTracked() {
        guard RunLoop.current.currentMode != .eventTracking else { return }
        let now = uptime()
        menus.withLock { menus in
            if menus.isOpen, now - menus.since > 2 {
                menus.count = 0
                menus.isOpenSaysDelegate = false
            }
        }
    }

    /// Seconds since the Mac started, not counting while it slept.
    private static func uptime() -> TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }

    private static var isBeingDebugged: Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return false }
        return info.kp_proc.p_flag & P_TRACED != 0
    }

    /// Ends the app on the spot, from this thread, which leaves a crash report with every thread
    /// in it: the main thread's shows what it was waiting for.
    private static func quit(after seconds: TimeInterval) {
        log.fault("The main thread hasn't answered for \(Int(seconds), privacy: .public) s while a menu was open; quitting, so that the app can't keep the keyboard")
        Subprocess.stopAll()
        fatalError("The main thread hasn't answered for \(Int(seconds)) s while a menu was open")
    }

    private static func note(_ seconds: TimeInterval) {
        log.fault("The main thread hasn't answered for \(Int(seconds), privacy: .public) s; no menu is open, so the app waits")
    }
}
