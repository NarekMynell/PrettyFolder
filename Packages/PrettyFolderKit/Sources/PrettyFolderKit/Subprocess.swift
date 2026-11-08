import Foundation
import os

/// Runs a command-line tool that asks a part of the system something, which can hang for as long
/// as that part does, and gives up on it after a while.
public enum Subprocess {
    /// The tool's exit status and what it printed, or `nil` if it couldn't start or didn't finish
    /// within `patience`, in which case it is stopped.
    public static func run(_ path: String, _ arguments: [String], within patience: TimeInterval) -> (status: Int32, output: String)? {
        // What it prints goes to a file, read once it has ended: a pipe can fill up and stop it,
        // and anything it leaves running could hold a pipe open, and its answer back, for good.
        let outputFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrettyFolder-\(UUID().uuidString).out", isDirectory: false)
        guard FileManager.default.createFile(atPath: outputFile.path, contents: nil),
              let output = try? FileHandle(forWritingTo: outputFile)
        else { return nil }
        defer {
            try? output.close()
            try? FileManager.default.removeItem(at: outputFile)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let id = UUID()
        running.withLock { $0[id] = Unchecked(process) }
        defer { running.withLock { _ = $0.removeValue(forKey: id) } }
        guard (try? process.run()) != nil else { return nil }
        guard exited.wait(timeout: .now() + patience) == .success else {
            process.terminate()
            if exited.wait(timeout: .now() + 1) != .success {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        let printed = (try? Data(contentsOf: outputFile)) ?? Data()
        return (process.terminationStatus, String(decoding: printed, as: UTF8.self))
    }

    /// Stops the tools still running, when the app is about to end: they would go on without it,
    /// one waiting on a part of the system that doesn't answer for good.
    public static func stopAll() {
        for process in running.withLock({ Array($0.values) }) where process.value.isRunning {
            process.value.terminate()
        }
    }

    private static let running = OSAllocatedUnfairLock(initialState: [UUID: Unchecked<Process>]())
}
