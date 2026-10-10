import AllInOneIMECore
import Foundation

/// `@open`: files, folders and apps. A path ("~/Doc", "/Applications/") lists what is in that
/// folder; anything else is looked for with Spotlight: names first (`mdfind -name`, every keyword
/// somewhere in the path), then, when those are few, what is in the files of the home folder.
/// Runs on this Mac only.
enum FileSearch {
    /// All the Spotlight searches for one query end by then (seconds).
    static let timeLimit = 3.0

    /// The best `limit` matches for `query`, off the main thread. Cancelling the task stops the
    /// search and the mdfind processes it started.
    static func run(_ query: String, limit: Int = 8) async -> [SearchResult] {
        let spotlight = Spotlight(until: .now() + timeLimit)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let isPath = query.hasPrefix("/") || query.hasPrefix("~")
                    continuation.resume(returning: isPath ? complete(query, limit: limit) : search(query, limit: limit, with: spotlight))
                }
            }
        } onCancel: {
            spotlight.cancel()
        }
    }

    /// Entries of the folder `query` points into whose names start with its last part: folders first.
    static func complete(_ query: String, limit: Int) -> [SearchResult] {
        let expanded = (query as NSString).expandingTildeInPath
        let folder = query.hasSuffix("/") ? expanded : (expanded as NSString).deletingLastPathComponent
        let prefix = query.hasSuffix("/") ? "" : (expanded as NSString).lastPathComponent.lowercased()
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        let results = names
            .filter { !$0.hasPrefix(".") && $0.lowercased().hasPrefix(prefix) }
            .map { result(for: (folder as NSString).appendingPathComponent($0)) }
            .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
        return Array(results.prefix(limit))
    }

    /// Spotlight by name (one search per keyword, all at once), then by content in the home folder,
    /// each file with when it was last used; picked and ordered by `FileSearchRanking.search`.
    static func search(_ query: String, limit: Int, with spotlight: Spotlight) -> [SearchResult] {
        let lastUsed = ["-attr", "kMDItemLastUsedDate"]
        let found = FileSearchRanking.search(
            query, limit: limit, history: OpenHistoryStore.history, isCandidate: isCandidate,
            byName: { keywords in
                spotlight.mdfind(each: keywords.map { lastUsed + ["-name", $0] }).flatMap(FileSearchRanking.parseLastUsed)
            },
            byContent: { text in
                guard spotlight.hasTimeLeft else { return [] }
                return FileSearchRanking.parseLastUsed(spotlight.mdfind(["-onlyin", home] + lastUsed + [text]))
            })
        return found.map { result(for: $0.path, matchedContent: $0.matchedContent) }
    }

    static func result(for path: String, matchedContent: Bool = false) -> SearchResult {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return SearchResult(name: FileManager.default.displayName(atPath: path), path: path,
                            isFolder: isDirectory.boolValue && !path.hasSuffix(".app"), matchedContent: matchedContent)
    }

    /// Where users keep things they open by name; everything else (system and library folders,
    /// hidden folders, the inside of bundles, build output) is skipped.
    static func isCandidate(_ path: String) -> Bool {
        // Cheapest first: a one-letter name finds some 70,000 files.
        guard path.hasPrefix(home + "/") || path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/")
            || path.hasPrefix("/Volumes/") else { return false }
        let skipped = ["/.", ".app/", "/Library/", "/node_modules/", "/DerivedData/", "/.build/"]
        return !skipped.contains { path.range(of: $0, options: .literal) != nil }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
}

/// The mdfind processes of one `@open` search: each is stopped at the search's time limit, and all
/// of them as soon as the search is cancelled (none starts after that).
final class Spotlight: @unchecked Sendable {
    let deadline: DispatchTime
    private let lock = NSLock()
    private var running: [Process] = []
    private var cancelled = false

    init(until deadline: DispatchTime) {
        self.deadline = deadline
    }

    /// Whether a search started now still has time, and is still wanted.
    var hasTimeLeft: Bool { DispatchTime.now() < deadline && !lock.withLock { cancelled } }

    /// What `mdfind arguments` printed by the time limit (its notes on stderr are dropped); nothing
    /// once cancelled.
    func mdfind(_ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        // Started under the lock: `cancel` either finds it running or keeps it from starting.
        let started = lock.withLock { () -> Bool in
            guard !cancelled, (try? process.run()) != nil else { return false }
            running.append(process)
            return true
        }
        guard started else { return "" }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: deadline, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        lock.withLock { running.removeAll { $0 === process } }
        return String(decoding: data, as: UTF8.self)
    }

    /// What each search printed, all of them run at once.
    func mdfind(each searches: [[String]]) -> [String] {
        var outputs = [String](repeating: "", count: searches.count)
        outputs.withUnsafeMutableBufferPointer { outputs in
            // Each index is written by one iteration only.
            DispatchQueue.concurrentPerform(iterations: searches.count) { outputs[$0] = mdfind(searches[$0]) }
        }
        return outputs
    }

    /// Stops what is running, and keeps what would come next from starting.
    func cancel() {
        lock.withLock {
            cancelled = true
            for process in running where process.isRunning { process.terminate() }
        }
    }
}

/// What `@open` opened (`OpenHistory`), kept in the input method's defaults under "openHistory".
enum OpenHistoryStore {
    private static let key = "openHistory"
    private static let lock = NSLock()
    /// The self-test's own history, in memory: the user's is then neither read nor changed.
    private static var scratch: OpenHistory?

    static var history: OpenHistory { lock.withLock { scratch ?? stored } }

    /// `path` was opened through `@open` just now.
    static func record(_ path: String) {
        lock.withLock {
            var history = scratch ?? stored
            history.record(path)
            if scratch != nil {
                scratch = history
            } else if let data = try? JSONEncoder().encode(history) {
                UserDefaults.standard.set(data, forKey: key)
            }
        }
    }

    /// For the self-test: a history of its own from now on, empty at first.
    static func useScratch() {
        lock.withLock { scratch = OpenHistory() }
    }

    private static var stored: OpenHistory {
        guard let data = UserDefaults.standard.data(forKey: key),
              let history = try? JSONDecoder().decode(OpenHistory.self, from: data) else { return OpenHistory() }
        return history
    }
}
