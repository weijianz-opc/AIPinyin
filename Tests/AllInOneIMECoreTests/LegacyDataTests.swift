import Foundation
import Testing
@testable import AllInOneIMECore

struct LegacyDataTests {
    /// A throw-away home directory.
    func home() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("allinoneime-legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func read(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    func isLink(_ url: URL) -> Bool {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    @Test func movesTheOldFoldersAndLeavesLinks() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try write(#"{"awsProfile": "work"}"#, to: home.appendingPathComponent(".config/aipinyin/config.json"))
        try write("bandwidth：精力", to: home.appendingPathComponent(".config/aipinyin/jargon.txt"))
        try write("learned", to: home.appendingPathComponent("Library/Application Support/AIPinyin/Rime/rime_ice.userdb/LOG"))

        let outcomes = LegacyData.migrate(home: home)
        #expect(outcomes.map(\.outcome) == [.moved, .moved, .nothingToMove])  // there were no logs
        #expect(outcomes.first?.path == "~/.config/allinoneime")
        // The data is in the new place, and the old paths still lead to it.
        #expect(read(home.appendingPathComponent(".config/allinoneime/config.json")) == #"{"awsProfile": "work"}"#)
        #expect(read(home.appendingPathComponent("Library/Application Support/AllInOneIME/Rime/rime_ice.userdb/LOG")) == "learned")
        #expect(isLink(home.appendingPathComponent(".config/aipinyin")))
        #expect(read(home.appendingPathComponent(".config/aipinyin/jargon.txt")) == "bandwidth：精力")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: home.appendingPathComponent(".config/aipinyin").path)
                == "allinoneime")  // relative
        // Config.load reads the new place.
        #expect(try Config.load(from: home.appendingPathComponent(".config/allinoneime/config.json")).awsProfile == "work")

        // Once is enough.
        #expect(LegacyData.migrate(home: home).map(\.outcome) == [.nothingToMove, .nothingToMove, .nothingToMove])
    }

    @Test func neverMergesIntoAnExistingNewFolder() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        try write("old", to: home.appendingPathComponent(".config/aipinyin/config.json"))
        try write("new", to: home.appendingPathComponent(".config/allinoneime/config.json"))
        #expect(LegacyData.migrate(home: home).first?.outcome == .keptBoth)
        #expect(read(home.appendingPathComponent(".config/aipinyin/config.json")) == "old")
        #expect(read(home.appendingPathComponent(".config/allinoneime/config.json")) == "new")
        #expect(!isLink(home.appendingPathComponent(".config/aipinyin")))
    }

    @Test func nothingToDoOnAFreshMac() throws {
        let home = try home()
        defer { try? FileManager.default.removeItem(at: home) }
        #expect(LegacyData.migrate(home: home).allSatisfy { $0.outcome == .nothingToMove })
        #expect((try? FileManager.default.contentsOfDirectory(atPath: home.path))?.isEmpty == true)
    }
}
