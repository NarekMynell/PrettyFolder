import Foundation
import PrettyFolderKit
import os

/// Quits the app if its main thread stops answering for long, so that the app can never keep the
/// keyboard. While a menu of the app's is opening or open, every key goes to it; on 2026-11-06 the
/// main thread waited for good while the menu bar menu opened, and nothing could be typed anywhere
/// for an hour, until the app was killed. The crash report this leaves says where the main thread
/// was waiting.
///
/// The main thread is asked every second whether it's there. Only time this thread was awake to
/// count is counted: while the whole app or the Mac was stopped (asleep, in a debugger, too busy to
/// run anything) nobody was kept waiting by the app.
nonisolated final class MainThreadWatchdog: @unchecked Sendable {
    /// Far longer than anything the app does on its main thread takes: a menu opens at once, the
    /// window draws in a fraction of a second, and everything that can wait on the system or a
    /// disk is done elsewhere.
    static let limit: TimeInterval = 15

    private static let log = Logger(subsystem: "com.narekmynell.PrettyFolder", category: "Watchdog")
    private static let started = OSAllocatedUnfairLock(initialState: false)

    private let limit: TimeInterval
    private let interval: TimeInterval
    private let hung: @Sendable (TimeInterval) -> Void
    private let isAsking = OSAllocatedUnfairLock(initialState: false)

    /// Starts watching, once per run. `hung` is told how long the main thread has been gone.
    static func start(
        limit: TimeInterval = MainThreadWatchdog.limit, interval: TimeInterval = 1,
        hung: @escaping @Sendable (TimeInterval) -> Void = { quit(after: $0) }
    ) {
        let isFirst = started.withLock { started in
            defer { started = true }
            return !started
        }
        guard isFirst else { return }
        let watchdog = MainThreadWatchdog(limit: limit, interval: interval, hung: hung)
        let thread = Thread { watchdog.watch() }
        thread.name = "com.narekmynell.PrettyFolder.watchdog"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    private init(limit: TimeInterval, interval: TimeInterval, hung: @escaping @Sendable (TimeInterval) -> Void) {
        self.limit = limit
        self.interval = interval
        self.hung = hung
    }

    private func watch() {
        var waited: TimeInterval = 0
        var last = Self.uptime()
        while true {
            Thread.sleep(forTimeInterval: interval)
            let now = Self.uptime()
            let step = now - last
            last = now
            guard isAsking.withLock({ $0 }) else {
                waited = 0
                ask()
                continue
            }
            // This thread didn't get to run either, or the app is being debugged: nobody can tell
            // how long the main thread itself was gone.
            if step > interval * 3 || Self.isBeingDebugged {
                waited = 0
                continue
            }
            waited += step
            if waited >= limit {
                hung(waited)
                waited = 0
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
        }
        CFRunLoopAddTimer(main, answer, .commonModes)
        CFRunLoopWakeUp(main)
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
        log.fault("The main thread hasn't answered for \(Int(seconds), privacy: .public) s; quitting, so that the app can't keep the keyboard")
        Subprocess.stopAll()
        fatalError("The main thread hasn't answered for \(Int(seconds)) s")
    }
}
