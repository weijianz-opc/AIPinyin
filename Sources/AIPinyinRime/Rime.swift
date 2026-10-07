import AIPinyinCore
import CRime
import Foundation

/// Process-wide librime instance (level one). Main thread only.
public final class RimeService {
    public static let shared = RimeService()

    let api: UnsafeMutablePointer<RimeApi>
    public private(set) var isStarted = false
    public private(set) var sharedDataDir: URL?
    public private(set) var userDataDir: URL?

    private init() {
        api = rime_get_api()
    }

    public var version: String {
        api.pointee.get_version().map { String(cString: $0) } ?? "?"
    }

    /// False while librime is deploying (compiling schemas); sessions cannot be created then.
    public var isReady: Bool {
        isStarted && api.pointee.is_maintenance_mode() == 0
    }

    /// Sets up librime and starts deployment in the background. Deployment is quick when the
    /// prebuilt dictionaries in `sharedDataDir/build` are current.
    public func start(sharedDataDir: URL, userDataDir: URL, logDir: URL?, fullCheck: Bool = false) throws {
        guard !isStarted else { return }
        let fm = FileManager.default
        try fm.createDirectory(at: userDataDir, withIntermediateDirectories: true)
        if let logDir { try fm.createDirectory(at: logDir, withIntermediateDirectories: true) }
        // Our schema-list patch goes into the user directory so it applies (and can be edited there).
        let patch = "default.custom.yaml"
        let userPatch = userDataDir.appendingPathComponent(patch)
        let sharedPatch = sharedDataDir.appendingPathComponent(patch)
        if !fm.fileExists(atPath: userPatch.path), fm.fileExists(atPath: sharedPatch.path) {
            try fm.copyItem(at: sharedPatch, to: userPatch)
        }

        func c(_ s: String) -> UnsafePointer<CChar> { UnsafePointer(strdup(s)!) }  // lives for the process
        var traits = RimeTraits()
        traits.data_size = Int32(MemoryLayout<RimeTraits>.size - MemoryLayout<Int32>.size)
        traits.shared_data_dir = c(sharedDataDir.path)
        traits.user_data_dir = c(userDataDir.path)
        traits.distribution_name = c("AIPinyin")
        traits.distribution_code_name = c("AIPinyin")
        traits.distribution_version = c(
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0")
        traits.app_name = c("rime.aipinyin")
        traits.min_log_level = 1  // warnings and errors only
        traits.log_dir = c(logDir?.path ?? "")
        api.pointee.setup(&traits)
        api.pointee.initialize(nil)
        _ = api.pointee.start_maintenance(fullCheck ? 1 : 0)
        self.sharedDataDir = sharedDataDir
        self.userDataDir = userDataDir
        isStarted = true
    }

    /// Re-deploys everything (e.g. after editing files in the user directory). Existing sessions are
    /// dropped first so none is used while data is rebuilt; controllers create new ones when ready.
    /// Session ids are reused by librime, so the generation marks every older session as dead.
    public func redeploy() {
        guard isStarted else { return }
        generation += 1
        api.pointee.cleanup_all_sessions()
        _ = api.pointee.start_maintenance(1)
    }

    /// Bumped by `redeploy()`; sessions from an older generation are invalid.
    public private(set) var generation = 0

    /// Blocks until deployment finishes or the timeout passes. Returns `isReady`.
    @discardableResult
    public func waitUntilReady(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !isReady && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        return isReady
    }

    public func makeSession() -> RimeSession? {
        guard isReady else { return nil }
        return RimeSession(api: api, generation: generation)
    }

    /// Schema in use for new sessions (for status output).
    public func currentSchemaName() -> String? {
        guard let session = makeSession() else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard api.pointee.get_current_schema(session.id, &buffer, buffer.count) != 0 else { return nil }
        return String(cString: buffer)
    }
}

/// One librime session per input controller.
public final class RimeSession: PinyinEngine {
    let api: UnsafeMutablePointer<RimeApi>
    public let id: RimeSessionId
    let generation: Int

    init?(api: UnsafeMutablePointer<RimeApi>, generation: Int) {
        self.api = api
        self.generation = generation
        id = api.pointee.create_session()
        guard id != 0 else { return nil }
    }

    private var isCurrentGeneration: Bool { generation == RimeService.shared.generation }

    deinit {
        // After a redeploy librime already destroyed this session and may have reused its id.
        if isCurrentGeneration { _ = api.pointee.destroy_session(id) }
    }

    /// False after librime dropped the session (e.g. during a re-deploy).
    public var isValid: Bool { isCurrentGeneration && api.pointee.find_session(id) != 0 }

    public func processKey(_ keycode: Int32, mask: Int32) -> Bool {
        guard isCurrentGeneration else { return false }
        return api.pointee.process_key(id, keycode, mask) != 0
    }

    public func takeCommit() -> String? {
        guard isCurrentGeneration else { return nil }
        var commit = RimeCommit()
        commit.data_size = Int32(MemoryLayout<RimeCommit>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_commit(id, &commit) != 0 else { return nil }
        defer { _ = api.pointee.free_commit(&commit) }
        return commit.text.map { String(cString: $0) }
    }

    public func snapshot() -> EngineSnapshot {
        var snap = EngineSnapshot()
        guard isCurrentGeneration else { return snap }
        var status = RimeStatus()
        status.data_size = Int32(MemoryLayout<RimeStatus>.size - MemoryLayout<Int32>.size)
        if api.pointee.get_status(id, &status) != 0 {
            snap.isComposing = status.is_composing != 0
            snap.isAsciiMode = status.is_ascii_mode != 0
            _ = api.pointee.free_status(&status)
        }
        var context = RimeContext()
        context.data_size = Int32(MemoryLayout<RimeContext>.size - MemoryLayout<Int32>.size)
        guard api.pointee.get_context(id, &context) != 0 else { return snap }
        defer { _ = api.pointee.free_context(&context) }

        if let preedit = context.composition.preedit {
            let text = String(cString: preedit)
            snap.preedit = text
            snap.cursor = Self.characterOffset(utf8: Int(context.composition.cursor_pos), in: text)
        }
        let menu = context.menu
        snap.highlighted = Int(menu.highlighted_candidate_index)
        snap.pageNumber = Int(menu.page_no)
        snap.isLastPage = menu.is_last_page != 0
        let selectKeys = menu.select_keys.map { Array(String(cString: $0)) } ?? []
        if let candidates = menu.candidates {
            for i in 0..<Int(max(menu.num_candidates, 0)) {
                let candidate = candidates[i]
                let label: String
                if let labels = context.select_labels, let l = labels[i] {
                    label = String(cString: l)
                } else if i < selectKeys.count {
                    label = String(selectKeys[i])
                } else {
                    label = String((i + 1) % 10)
                }
                snap.candidates.append(EngineCandidate(
                    label: label,
                    text: candidate.text.map { String(cString: $0) } ?? "",
                    comment: candidate.comment.map { String(cString: $0) } ?? ""))
            }
        }
        if !snap.preedit.isEmpty { snap.isComposing = true }
        return snap
    }

    public func selectCandidate(onPage index: Int) -> Bool {
        guard isCurrentGeneration else { return false }
        return api.pointee.select_candidate_on_current_page(id, index) != 0
    }

    public func commitComposition() -> String? {
        guard isCurrentGeneration, api.pointee.commit_composition(id) != 0 else { return nil }
        return takeCommit()
    }

    public var rawInput: String {
        guard isCurrentGeneration else { return "" }
        return api.pointee.get_input(id).map { String(cString: $0) } ?? ""
    }

    public func clearComposition() {
        guard isCurrentGeneration else { return }
        api.pointee.clear_composition(id)
    }

    public func setAsciiMode(_ on: Bool) {
        guard isCurrentGeneration else { return }
        api.pointee.set_option(id, "ascii_mode", on ? 1 : 0)
    }

    /// librime reports positions as UTF-8 byte offsets.
    static func characterOffset(utf8 offset: Int, in text: String) -> Int {
        let bytes = Array(text.utf8)
        let clamped = max(0, min(offset, bytes.count))
        return String(decoding: bytes[..<clamped], as: UTF8.self).count
    }
}
