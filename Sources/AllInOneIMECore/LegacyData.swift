import Foundation

/// Data written under the input method's first name, AIPinyin: settings, the Rime user data
/// (learned words) and logs. Each folder is moved to its AllInOneIME location once, and a symlink is
/// left at the old path, so whatever still points there (a `jargonFile` setting, an older build)
/// keeps working.
public enum LegacyData {
    /// (old, new) folders, relative to the home directory.
    public static let folders = [
        (".config/aipinyin", ".config/allinoneime"),
        ("Library/Application Support/AIPinyin", "Library/Application Support/AllInOneIME"),
        ("Library/Logs/AIPinyin", "Library/Logs/AllInOneIME"),
    ]

    public enum Outcome: Equatable, Sendable {
        /// Moved, with a symlink at the old path.
        case moved
        /// No old folder, or it is already the symlink.
        case nothingToMove
        /// The new folder exists too: both are left as they are (the new one is used).
        case keptBoth
        case failed(String)
    }

    /// Moves every old folder that is still a real folder, if its new place is free. Cheap when
    /// there is nothing to do, so every entry point calls it before touching any data.
    @discardableResult
    public static func migrate(home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [(path: String, outcome: Outcome)] {
        folders.map { old, new in
            ("~/" + new, move(from: home.appendingPathComponent(old), to: home.appendingPathComponent(new)))
        }
    }

    static func move(from old: URL, to new: URL) -> Outcome {
        let fm = FileManager.default
        // attributesOfItem doesn't follow symlinks: a link here means the folder was moved before.
        guard let type = (try? fm.attributesOfItem(atPath: old.path))?[.type] as? FileAttributeType,
              type == .typeDirectory
        else { return .nothingToMove }
        guard (try? fm.attributesOfItem(atPath: new.path)) == nil else { return .keptBoth }
        do {
            try fm.createDirectory(at: new.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: old, to: new)  // a rename: atomic, and open files stay valid
        } catch {
            return .failed(error.localizedDescription)
        }
        // Relative when both are in the same folder, so the link survives a moved home directory.
        let sameParent = old.deletingLastPathComponent().standardizedFileURL == new.deletingLastPathComponent().standardizedFileURL
        try? fm.createSymbolicLink(atPath: old.path, withDestinationPath: sameParent ? new.lastPathComponent : new.path)
        return .moved
    }
}
