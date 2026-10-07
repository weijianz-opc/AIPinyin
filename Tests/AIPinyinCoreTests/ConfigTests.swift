import Foundation
import Testing
@testable import AIPinyinCore

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

    @Test func fileRoundTripAndMissingFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aipinyin-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        #expect(try Config.load(from: url) == .default)

        var c = Config.default
        c.awsProfile = "work"
        c.temperature = nil
        c.rewriteStyles = ["口语", "正式"]
        try c.write(to: url)
        #expect(try Config.load(from: url) == c)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("\"口语\""))  // stays readable, not \u escapes

        try Data("{not json".utf8).write(to: url)
        #expect(throws: ConfigError.self) { try Config.load(from: url) }
    }
}
