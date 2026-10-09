import Foundation
import Testing
@testable import AllInOneIMECore

struct InputSourceListTests {
    let ours = "com.aipinyin.inputmethod.AIPinyin"

    /// The list as macOS had it on a Mac where AllInOneIME was enabled but missing from it.
    let system: [[String: Any]] = [
        ["InputSourceKind": "Keyboard Layout", "KeyboardLayout ID": 0, "KeyboardLayout Name": "U.S."],
        ["Bundle ID": "com.apple.CharacterPaletteIM", "InputSourceKind": "Non Keyboard Input Method"],
        ["Bundle ID": "com.apple.inputmethod.SCIM", "Input Mode": "com.apple.inputmethod.SCIM.ITABC",
         "InputSourceKind": "Input Mode"],
        ["Bundle ID": "com.apple.PressAndHold", "InputSourceKind": "Non Keyboard Input Method"],
    ]

    func bundleIDs(_ list: [[String: Any]]) -> [String] { list.map { $0["Bundle ID"] as? String ?? "-" } }

    @Test func addsOurEntryAtTheEndAndKeepsTheRest() throws {
        let added = try #require(InputSourceList.adding(ours, to: system))
        #expect(added.count == system.count + 1)
        // The existing entries are unchanged, including the keyboard layout (which has no Bundle ID).
        #expect(NSArray(array: Array(added.dropLast())).isEqual(to: system))
        #expect(NSDictionary(dictionary: try #require(added.last))
            .isEqual(to: ["Bundle ID": ours, "InputSourceKind": "Keyboard Input Method"]))
        #expect(InputSourceList.contains(added, bundleID: ours))
        #expect(!InputSourceList.contains(system, bundleID: ours))
    }

    @Test func addingTwiceWritesNothing() throws {
        let added = try #require(InputSourceList.adding(ours, to: system))
        #expect(InputSourceList.adding(ours, to: added) == nil)
    }

    @Test func noListIsLeftAlone() {
        // Creating the list with only our entry would drop the keyboard layout.
        #expect(InputSourceList.adding(ours, to: nil) == nil)
        #expect(InputSourceList.removing(ours, from: nil) == nil)
    }

    @Test func otherBuildsHaveTheirOwnEntries() throws {
        let beta = ours + "Beta"
        let withBeta = try #require(InputSourceList.adding(beta, to: system))
        #expect(!InputSourceList.contains(withBeta, bundleID: ours))
        let both = try #require(InputSourceList.adding(ours, to: withBeta))
        #expect(bundleIDs(both).suffix(2) == [beta, ours])
    }

    @Test func removingTakesOnlyOurEntries() throws {
        let beta = ours + "Beta"
        let list = system + [InputSourceList.entry(bundleID: ours), InputSourceList.entry(bundleID: beta),
                             InputSourceList.entry(bundleID: ours)]
        let removed = try #require(InputSourceList.removing(ours, from: list))
        #expect(bundleIDs(removed) == bundleIDs(system) + [beta])
        #expect(NSArray(array: Array(removed.prefix(system.count))).isEqual(to: system))
        #expect(InputSourceList.removing(ours, from: system) == nil)
    }
}
