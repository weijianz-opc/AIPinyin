import Foundation
import os

/// The mdfind processes of one `@open` search: each is stopped at the search's time limit, and all of
/// them as soon as the search is cancelled. None starts after that, and what they printed is dropped.
public final class Spotlight: @unchecked Sendable {
    public let deadline: DispatchTime
    private let executable: URL
    private let lock = NSLock()
    private var running: [Process] = []
    private var cancelled = false

    /// `executable` runs instead of mdfind (the tests use a shell).
    public init(until deadline: DispatchTime, executable: URL = URL(fileURLWithPath: "/usr/bin/mdfind")) {
        self.deadline = deadline
        self.executable = executable
    }

    public var isCancelled: Bool { lock.withLock { cancelled } }

    /// Whether a search started now still has time, and is still wanted.
    public var hasTimeLeft: Bool { DispatchTime.now() < deadline && !isCancelled }

    /// What `mdfind arguments` printed by the time limit (its notes on stderr are dropped); nil once
    /// the search is cancelled, even if it printed something before.
    public func mdfind(_ arguments: [String]) -> Data? {
        guard !isCancelled else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Launched outside the lock: `cancel` runs on the main thread, which must not wait for a launch.
        // A `cancel` that comes before the process is in `running` is seen right after.
        guard (try? process.run()) != nil else { return isCancelled ? nil : Data() }
        let wanted = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            running.append(process)
            return true
        }
        let stop = Stopper(process)
        if !wanted { stop.run() }
        let timer = DispatchWorkItem { stop.run() }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: timer)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timer.cancel()
        lock.withLock { running.removeAll { $0 === process } }
        return isCancelled ? nil : data
    }

    /// What each search printed, all of them run at once; nil once the search is cancelled.
    public func mdfind(each searches: [[String]]) -> [Data]? {
        let outputs = OSAllocatedUnfairLock(initialState: [Data](repeating: Data(), count: searches.count))
        DispatchQueue.concurrentPerform(iterations: searches.count) { index in
            let printed = mdfind(searches[index]) ?? Data()
            outputs.withLock { $0[index] = printed }
        }
        return isCancelled ? nil : outputs.withLock { $0 }
    }

    /// Stops what is running, and keeps what would come next from starting. Called on the main thread
    /// (a task's cancellation handler runs where the task is cancelled): the lock is only held to take
    /// the list, never while a process starts or stops.
    public func cancel() {
        let processes = lock.withLock { () -> [Process] in
            cancelled = true
            return running
        }
        for process in processes { Stopper(process).run() }
    }

    /// Stops one process. (A Process may be stopped from any thread; this says so to the compiler.)
    private struct Stopper: @unchecked Sendable {
        let process: Process
        init(_ process: Process) { self.process = process }
        func run() { if process.isRunning { process.terminate() } }
    }
}
