import Foundation
import os

/// Runs a command-line tool that asks a part of the system something, which can hang for as long
/// as that part does, and gives up on it after a while.
public enum Subprocess {
    /// The tool's exit status and what it printed, or `nil` if it couldn't start, didn't finish
    /// within `patience` (it is stopped then), or the app is quitting.
    public static func run(_ path: String, _ arguments: [String], within patience: TimeInterval) -> (status: Int32, output: String)? {
        // What it prints goes to a file, read once it has ended: a pipe can fill up and stop it,
        // and anything it leaves running could hold a pipe open, and its answer back, for good.
        // The file has no name from the start, so nothing is left behind whatever happens.
        guard let output = unnamedFile() else { return nil }
        defer { try? output.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path, isDirectory: false)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let id = UUID()
        // Not one more once the app is quitting: a search woken by its tool being stopped would
        // otherwise start the next one, which nothing would stop.
        guard state.withLock({ state -> Bool in
            guard !state.isStopping else { return false }
            state.running[id] = Unchecked(process)
            return true
        }) else { return nil }
        defer { state.withLock { _ = $0.running.removeValue(forKey: id) } }
        guard (try? process.run()) != nil else { return nil }
        // `stopAll` may have looked at the list just before this one started.
        if state.withLock({ $0.isStopping }) { stop(process) }
        guard exited.wait(timeout: .now() + patience) == .success else {
            stop(process)
            return nil
        }
        // Stopped because the app is quitting: what it printed is cut short.
        if state.withLock({ $0.isStopping }) { return nil }
        guard (try? output.seek(toOffset: 0)) != nil, let printed = try? output.readToEnd() ?? Data() else { return nil }
        return (process.terminationStatus, String(decoding: printed, as: UTF8.self))
    }

    /// Stops the tools still running, and any asked for from now on, when the app is about to end:
    /// they would go on without it, one waiting on a part of the system that doesn't answer for good.
    /// Waits a moment for them to go, then makes sure they do.
    public static func stopAll() {
        let running = state.withLock { state in
            state.isStopping = true
            return Array(state.running.values)
        }
        for process in running where process.value.isRunning {
            process.value.terminate()
        }
        let deadline = Date().addingTimeInterval(0.2)
        while running.contains(where: { $0.value.isRunning }), Date() < deadline {
            usleep(10_000)
        }
        for process in running where process.value.isRunning {
            kill(process.value.processIdentifier, SIGKILL)
        }
    }

    /// Asks `process` to end, and makes it if it doesn't within a second.
    private static func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    /// A file open for reading and writing whose name is already gone.
    private static func unnamedFile() -> FileHandle? {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrettyFolder-\(UUID().uuidString).out", isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let handle = try? FileHandle(forUpdating: url)
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        return handle
    }

    private static let state = OSAllocatedUnfairLock(initialState: (running: [UUID: Unchecked<Process>](), isStopping: false))
}
