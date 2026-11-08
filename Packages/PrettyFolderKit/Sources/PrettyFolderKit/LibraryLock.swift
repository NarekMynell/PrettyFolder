import Foundation

/// Says that one copy of the app looks after a library. Two copies at once would each save the
/// list as they last read it, and lose what the other did, or delete a picture the other has just
/// put on a folder. The lock goes with the copy, however it ends.
public final class LibraryLock: @unchecked Sendable {
    public enum Attempt {
        case taken(LibraryLock)
        /// Another copy has it.
        case heldElsewhere
        /// It can't be had where the library is (a disk without locks, no permission): nothing
        /// says another copy is there.
        case unavailable
    }

    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit {
        close(descriptor)
    }

    /// Tries for the lock on the library in `directory`, without waiting.
    public static func take(in directory: URL) -> Attempt {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent(".lock", isDirectory: false).path
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return .unavailable }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let error = errno
            close(descriptor)
            return error == EWOULDBLOCK ? .heldElsewhere : .unavailable
        }
        return .taken(LibraryLock(descriptor: descriptor))
    }
}
