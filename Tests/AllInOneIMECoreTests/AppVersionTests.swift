import Foundation
import Testing
@testable import AllInOneIMECore

struct AppVersionTests {
    /// The repository root (this file is Tests/AllInOneIMECoreTests/AppVersionTests.swift).
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The input method and the settings launcher show the same version as `--status`.
    @Test(arguments: ["Resources/Info.plist", "Resources/Settings-Info.plist"])
    func infoPlistCarriesTheVersion(_ path: String) throws {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        let plist = try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["CFBundleShortVersionString"] as? String == AppVersion.string,
                "bump CFBundleShortVersionString in \(path) and AppVersion.string together")
    }
}
