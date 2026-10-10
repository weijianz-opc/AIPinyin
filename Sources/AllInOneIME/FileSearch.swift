import AllInOneIMECore
import Foundation

/// `@open`: files, folders and apps. A path ("~/Doc", "/Applications/") lists what is in that
/// folder; anything else is looked for by name: in the app index (`AppIndex`: every name an app goes
/// by, 计算器 too) and with Spotlight (`mdfind -name`, every keyword somewhere in the path); then, when
/// that finds hardly anything and no app, in what the files of the home folder contain.
/// Runs on this Mac only.
enum FileSearch {
    /// All the Spotlight searches for one query end by then (seconds).
    static let timeLimit = 3.0

    /// The best `limit` matches for `query`, off the main thread; what `@open` opened (`history`) first.
    /// Cancelling the task stops the search and the mdfind processes it started; it then returns nothing.
    static func run(_ query: String, history: OpenHistory, limit: Int = 8) async -> [SearchResult] {
        // A web address comes first (opened in the browser); "https://…" is nothing else.
        if let web = SearchResult.web(query) {
            if query.contains("://") { return [web] }
            return [web] + (await files(query, history: history, limit: limit - 1)).filter { $0.path != web.path }
        }
        return await files(query, history: history, limit: limit)
    }

    /// Files, folders and apps for `query` (`run` without the web address).
    private static func files(_ query: String, history: OpenHistory, limit: Int) async -> [SearchResult] {
        let spotlight = Spotlight(until: .now() + timeLimit)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let isPath = query.hasPrefix("/") || query.hasPrefix("~")
                    let results = isPath ? complete(query, limit: limit) : search(query, limit: limit, history: history, with: spotlight)
                    continuation.resume(returning: spotlight.isCancelled ? [] : results)
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

    /// The app index and Spotlight by name (one search per keyword, all at once), then Spotlight by
    /// content in the home folder, each file with when it was last used and changed; picked and ordered by
    /// `FileSearchRanking.search`. Nothing once cancelled: what was printed until then isn't even read.
    static func search(_ query: String, limit: Int, history: OpenHistory, with spotlight: Spotlight) -> [SearchResult] {
        let index = AppIndex.shared.apps()
        let keywords = FileSearchRanking.keywords(in: query)
        let apps = index.map { app in
            let found = FileSearchRanking.Found(path: app.path, names: app.names)
            return FileSearchRanking.matches(app.path, names: app.names, keywords: keywords) ? dated(found) : found
        }
        let found = FileSearchRanking.search(
            query, limit: limit, history: history, apps: apps, isCandidate: isCandidate,
            byName: { keywords in
                let outputs = spotlight.mdfind(each: keywords.map { FileSearchRanking.attributes + ["-name", $0] }) ?? []
                return outputs.flatMap(FileSearchRanking.parse)
            },
            byContent: { predicate in
                guard spotlight.hasTimeLeft,
                      let output = spotlight.mdfind(["-onlyin", home] + FileSearchRanking.attributes + [predicate]) else { return [] }
                return FileSearchRanking.parse(output)
            })
        guard !spotlight.isCancelled else { return [] }
        let byPath = Dictionary(index.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return found.map { result(for: $0.path, matchedContent: $0.matchedContent, app: byPath[$0.path]) }
    }

    /// `app` with when it was last used and changed, as Spotlight keeps them. Its name search knows an app
    /// by its file name and its name in the system language only: an app matched by another of its names
    /// (计算器 on an English system) gets no dates from there.
    static func dated(_ app: FileSearchRanking.Found) -> FileSearchRanking.Found {
        guard let item = NSMetadataItem(url: URL(fileURLWithPath: app.path)) else { return app }
        var app = app
        app.lastUsed = item.value(forAttribute: "kMDItemLastUsedDate") as? Date
        app.modified = item.value(forAttribute: "kMDItemContentModificationDate") as? Date
        return app
    }

    /// An app of the index is shown under its names from there (`SearchResult.chineseName` in a Chinese
    /// interface), anything else as Finder names it.
    static func result(for path: String, matchedContent: Bool = false, app: AppIndex.App? = nil) -> SearchResult {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return SearchResult(name: app?.english ?? FileManager.default.displayName(atPath: path), path: path,
                            isFolder: isDirectory.boolValue && !path.hasSuffix(".app"), matchedContent: matchedContent,
                            chineseName: app?.chinese)
    }

    /// Where users keep things they open by name; everything else (system and library folders,
    /// hidden folders, the inside of bundles, build output) is skipped.
    static func isCandidate(_ path: String) -> Bool {
        // Cheapest first: a one-letter name finds some 66,000 files.
        guard path.hasPrefix(homePrefix) || path.hasPrefix("/Applications/") || path.hasPrefix("/System/Applications/")
            || path.hasPrefix("/Volumes/") else { return false }
        return !skipped.contains { path.range(of: $0, options: .literal) != nil }
    }

    private static let skipped = ["/Library/", "/.", ".app/", "/node_modules/", "/DerivedData/", "/.build/"]
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    private static let homePrefix = home + "/"
}

/// What `@open` opened (`OpenHistory`), kept in the input method's defaults under "openHistory". Main
/// thread only: the controller reads it for each search and records what is opened (the self-test
/// supplies a history of its own instead, `loadOpenHistory` / `recordOpen`).
enum OpenHistoryStore {
    static let key = "openHistory"

    static var history: OpenHistory = {
        guard let data = UserDefaults.standard.data(forKey: key),
              let history = try? JSONDecoder().decode(OpenHistory.self, from: data) else { return OpenHistory() }
        return history
    }()

    /// `path` was opened through `@open` just now.
    static func record(_ path: String) {
        history.record(path)
        if let data = try? JSONEncoder().encode(history) { UserDefaults.standard.set(data, forKey: key) }
    }
}
