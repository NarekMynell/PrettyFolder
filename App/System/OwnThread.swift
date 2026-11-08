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
