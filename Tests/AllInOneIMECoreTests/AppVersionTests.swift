import Foundation
import Testing
@testable import AllInOneIMECore

struct AppVersionTests {
    /// The repository root (this file is Tests/AllInOneIMECoreTests/AppVersionTests.swift).
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static let plists = ["Resources/Info.plist", "Resources/Settings-Info.plist", "Resources/Installer-Info.plist"]

    func plist(_ path: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(path))
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The input method, the settings launcher and the installer show the same version as `--status`.
    @Test(arguments: plists)
    func infoPlistCarriesTheVersion(_ path: String) throws {
        #expect(try plist(path)["CFBundleShortVersionString"] as? String == AppVersion.string,
                "bump CFBundleShortVersionString in \(path) and AppVersion.string together")
    }

    /// One build number for the three apps of a release.
    @Test func infoPlistsShareTheBuildNumber() throws {
        let builds = try Self.plists.map { try plist($0)["CFBundleVersion"] as? String }
        #expect(builds.allSatisfy { $0 != nil && $0 == builds.first! }, "CFBundleVersion differs: \(builds)")
    }
}
