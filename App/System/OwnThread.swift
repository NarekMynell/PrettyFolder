import Foundation

/// Does work that waits on a disk outside the threads Swift's tasks share, and waits for it: the
/// disk may be a network disk that has stopped answering. Those threads are as many as the Mac has
/// cores, and a task waiting on a disk keeps one for as long as the disk takes; twelve searches
/// waiting on Spotlight once kept them all. The work goes to the system's pool of threads instead,
/// which grows when one waits (up to 64), and nothing that must not wait uses that pool.
nonisolated func onOwnThread<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async {
            continuation.resume(returning: work())
        }
    }
}

/// The same for something worth asking a disk but not worth waiting long for, like the name to
/// show for a folder: `fallback` if `work` takes longer than `limit`. Work that is late goes on by
/// itself and its answer is dropped.
nonisolated func onOwnThread<T: Sendable>(within limit: TimeInterval, otherwise fallback: T, _ work: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { continuation in
        let answer = OneAnswer(continuation)
        // A thread of its own for the work, and the time kept on the main queue: other reads waiting
        // on a disk can use up the system's pool, and neither may depend on it.
        let thread = Thread { answer.give(work()) }
        thread.qualityOfService = .userInitiated
        thread.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + limit) { answer.give(fallback) }
    }
}

/// Gives a continuation the first answer it gets, whichever side that comes from.
nonisolated final class OneAnswer<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    var isAnswered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return continuation == nil
    }

    func give(_ value: Value) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(returning: value)
    }
}

/// Does `work` on the main thread once no menu is being tracked, at once if none is. For work
/// that opens a window or a panel, or takes a while: a menu that is open has the keyboard of every
/// app, and what the main thread does meanwhile keeps it waiting. Work that was waiting for a disk
/// or a search can come back just then. (A menu runs the main loop in its own mode; this waits for
/// the default one.)
func outsideMenus(_ work: @escaping @MainActor () -> Void) {
    RunLoop.main.perform(inModes: [.default]) {
        MainActor.assumeIsolated { work() }
    }
}
