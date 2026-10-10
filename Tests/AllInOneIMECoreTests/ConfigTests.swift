import Foundation
import Testing
@testable import AllInOneIMECore

struct AWSSharedConfigTests {
    let credentials = """
        # comment
        [default]
        aws_access_key_id = AKIADEFAULT
        aws_secret_access_key = secretdefault

        [work]
        aws_access_key_id=AKIAWORK
        aws_secret_access_key=  secret/with+chars=
        aws_session_token = tok
        ; another comment
        """

    let config = """
        [default]
        region = us-east-1

        [profile work]
        region = us-west-2
        s3 =
          max_concurrent_requests = 10
        output = json

        [profile sso]
        sso_session = corp
        region = eu-west-1

        [profile role]
        role_arn = arn:aws:iam::123456789012:role/x
        source_profile = default

        [profile inline]
        aws_access_key_id = AKIAINLINE
        aws_secret_access_key = inline
        """

    @Test func resolvesNamedProfileWithRegionFromConfig() throws {
        let r = try AWSSharedConfig.resolve(profile: "work", credentialsFile: credentials, configFile: config)
        #expect(r.credentials == AWSCredentials(
            accessKeyId: "AKIAWORK", secretAccessKey: "secret/with+chars=", sessionToken: "tok"))
        #expect(r.region == "us-west-2")
    }

    @Test func resolvesDefaultProfile() throws {
        let r = try AWSSharedConfig.resolve(profile: "default", credentialsFile: credentials, configFile: config)
        #expect(r.credentials.accessKeyId == "AKIADEFAULT")
        #expect(r.credentials.sessionToken == nil)
        #expect(r.region == "us-east-1")
    }

    @Test func keysMayLiveInConfigFile() throws {
        let r = try AWSSharedConfig.resolve(profile: "inline", credentialsFile: nil, configFile: config)
        #expect(r.credentials.accessKeyId == "AKIAINLINE")
    }

    @Test func reportsMissingAndUnsupportedProfiles() {
        #expect(throws: AWSConfigError.profileNotFound("nope")) {
            try AWSSharedConfig.resolve(profile: "nope", credentialsFile: credentials, configFile: config)
        }
        #expect(throws: AWSConfigError.unsupportedProfile(profile: "sso", kind: "SSO")) {
            try AWSSharedConfig.resolve(profile: "sso", credentialsFile: credentials, configFile: config)
        }
        #expect(throws: AWSConfigError.unsupportedProfile(profile: "role", kind: "assume-role")) {
            try AWSSharedConfig.resolve(profile: "role", credentialsFile: credentials, configFile: config)
        }
        #expect(throws: AWSConfigError.missingKeys(profile: "x")) {
            try AWSSharedConfig.resolve(profile: "x", credentialsFile: "[x]\nregion = us-east-1", configFile: nil)
        }
    }

    @Test func ignoresNestedSettings() {
        let parsed = AWSSharedConfig.parseINI(config, isConfigFile: true)
        #expect(parsed["work"]?["max_concurrent_requests"] == nil)
        #expect(parsed["work"]?["output"] == "json")
    }
}

struct ConfigTests {
    func decode(_ json: String) throws -> Config {
        try JSONDecoder().decode(Config.self, from: Data(json.utf8))
    }

    @Test func missingKeysUseDefaults() throws {
        let c = try decode(#"{"awsProfile": "work"}"#)
        #expect(c.awsProfile == "work")
        #expect(c.modelId == Config.default.modelId)
        #expect(c.temperature == 0.3)
        #expect(c.region == nil)
    }

    @Test func explicitNullTemperatureDisablesIt() throws {
        #expect(try decode(#"{"temperature": null}"#).temperature == nil)
    }

    @Test func rewriteStyles() throws {
        #expect(try decode("{}").rewriteStyles == ["润色", "简洁", "正式"])
        #expect(try decode(#"{"rewriteStyles": ["简洁", "委婉"]}"#).rewriteStyles == ["简洁", "委婉"])
        #expect(try decode(#"{"rewriteStyles": []}"#).rewriteStyles.isEmpty)
        #expect(RewriteStyle.resolve(["委婉", "nope", "CONCISE", "简洁"]).map(\.name) == ["委婉", "简洁"])
    }

    @Test func inputOutputAndVoiceSettings() throws {
        let missing = try decode("{}")
        #expect(missing.outputLanguage == .english && missing.defaultInput == .chinese)
        #expect(missing.voiceInput)
        let set = try decode(#"{"outputLanguage": "zh", "defaultInput": "en", "voiceInput": false}"#)
        #expect(set.outputLanguage == .chinese && set.defaultInput == .english)
        #expect(!set.voiceInput)
        #expect(throws: DecodingError.self) { try decode(#"{"outputLanguage": "fr"}"#) }
        #expect(Language.of("我check一下") == .chinese && Language.of("check it") == .english)
    }

    @Test func actionKey() throws {
        #expect(try decode("{}").actionKey == .enter)
        #expect(try decode(#"{"translateKey": "optionTap"}"#).actionKey == .enter)  // the old name isn't read
        #expect(try decode(#"{"actionKey": "optionSpace"}"#).actionKey == .optionSpace)
        #expect(try decode(#"{"actionKey": "space"}"#).actionKey == .space)
        #expect(throws: DecodingError.self) { try decode(#"{"actionKey": "fn"}"#) }
    }

    @Test func uiLanguage() throws {
        #expect(try decode("{}").uiLanguage == nil)
        #expect(try decode(#"{"uiLanguage": null}"#).uiLanguage == nil)
        #expect(try decode(#"{"uiLanguage": "zh"}"#).uiLanguage == .chinese)
        #expect(try decode(#"{"uiLanguage": "en"}"#).uiLanguage == .english)
    }

    /// The floating panel is off unless turned on; the key is written either way (discoverable).
    @Test func floatingPanel() throws {
        #expect(!Config.default.floatingPanel && !Config.fresh.floatingPanel)
        #expect(try !decode("{}").floatingPanel)
        #expect(try decode(#"{"floatingPanel": true}"#).floatingPanel)
        #expect(throws: DecodingError.self) { try decode(#"{"floatingPanel": "yes"}"#) }
        var c = Config.default
        let off = String(decoding: try JSONEncoder().encode(c), as: UTF8.self)
        #expect(off.contains(#""floatingPanel":false"#))
        c.floatingPanel = true
        #expect(try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(c)) == c)
    }

    @Test func fileRoundTripAndMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("allinoneime-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        // No file yet: a new user, on the hosted service once it is set up (an old file without
        // `provider` stays on Bedrock: ProviderTests.configKeepsProviderSettings).
        #expect(try Config.load(from: url) == .fresh)
        #expect(Config.fresh.provider == (HostedService.isConfigured ? .hosted : .bedrock))

        var c = Config.default
        c.awsProfile = "work"
        c.temperature = nil
        c.rewriteStyles = ["口语", "正式"]
        c.outputLanguage = .chinese
        c.defaultInput = .english
        c.voiceInput = false
        c.actionKey = .optionSpace
        c.uiLanguage = .chinese
        try c.write(to: url)
        #expect(try Config.load(from: url) == c)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"口语\""))  // stays readable, not \u escapes
        #expect(text.contains("\"outputLanguage\" : \"zh\""))
        #expect(text.contains("\"actionKey\" : \"optionSpace\""))

        try Data("{not json".utf8).write(to: url)
        #expect(throws: ConfigError.self) { try Config.load(from: url) }
    }

    /// A file from an older version still loads: a key that is gone (here the old switch for English
    /// drafts; its name is split so a search for removed settings finds only the cleanup in main.swift)
    /// is ignored, and saving doesn't write it back.
    @Test func removedKeysInAnOldFileAreIgnored() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("allinoneime-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        let removed = "english" + "AI"
        try Data(#"{"awsProfile": "work", "\#(removed)": false, "voiceInput": false, "actionKey": "space"}"#.utf8).write(to: url)
        var c = try Config.load(from: url)
        #expect(c.awsProfile == "work" && !c.voiceInput && c.actionKey == .space)
        c.outputLanguage = .chinese
        try c.write(to: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains(removed) && text.contains("\"outputLanguage\" : \"zh\""))
        #expect(try Config.load(from: url) == c)
    }
}
