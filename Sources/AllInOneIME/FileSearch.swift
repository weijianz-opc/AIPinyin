import AllInOneIMECore
import Foundation

/// `@open`: files, folders and apps. A path ("~/Doc", "/Applications/") lists what is in that
/// folder; anything else is a name, found with Spotlight (`mdfind -name`). Runs on this Mac only.
enum FileSearch {
    /// The best `limit` matches for `query`, off the main thread.
    static func run(_ query: String, limit: Int = 8) async -> [SearchResult] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let isPath = query.hasPrefix("/") || query.hasPrefix("~")
                continuation.resume(returning: isPath ? complete(query, limit: limit) : search(query, limit: limit))
            }
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

    static func search(_ query: String, limit: Int) -> [SearchResult] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-name", query]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return [] }
        let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3, execute: stop)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        stop.cancel()
        let paths = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        return rank(paths, query: query).prefix(limit).map(result(for:))
    }

    static func result(for path: String) -> SearchResult {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return SearchResult(name: FileManager.default.displayName(atPath: path), path: path,
                            isFolder: isDirectory.boolValue && !path.hasSuffix(".app"))
    }

    /// Where users keep things they open by name; everything else (system and library folders,
    /// hidden folders, the inside of bundles, build output) is skipped.
    static func isCandidate(_ path: String) -> Bool {
        let skipped = ["/.", ".app/", "/Library/", "/node_modules/", "/DerivedData/", "/.build/"]
        guard !skipped.contains(where: path.contains) else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home + "/") || path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/")
            || path.hasPrefix("/Volumes/")
    }

    /// Apps first, then names that start with the query, then shallower paths and shorter names.
    static func rank(_ paths: [String], query: String) -> [String] {
        let wanted = query.lowercased()
        var seen = Set<String>()
        let scored: [(path: String, key: (Int, Int, Int, Int))] = paths.compactMap { path in
            guard isCandidate(path), seen.insert(path).inserted else { return nil }
            let name = (path as NSString).lastPathComponent.lowercased()
            let app = path.hasSuffix(".app") ? 0 : 1
            let match = name.hasPrefix(wanted) ? 0 : name.contains(wanted) ? 1 : 2
            return (path, (app, match, path.split(separator: "/").count, name.count))
        }
        return scored.sorted { $0.key < $1.key }.map(\.path)
    }
}
