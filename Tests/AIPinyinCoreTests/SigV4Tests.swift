import Foundation
import Testing
@testable import AIPinyinCore

/// Vectors come from the AWS SigV4 documentation and from botocore's SigV4Auth
/// (generated with fixed example credentials and timestamps).
struct SigV4Tests {
    let exampleCredentials = AWSCredentials(
        accessKeyId: "AKIDEXAMPLE", secretAccessKey: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")

    func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    @Test func signingKeyMatchesAWSDocumentation() {
        let key = SigV4Signer.signingKey(
            secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", date: "20120215",
            region: "us-east-1", service: "iam")
        let hex = key.withUnsafeBytes { SigV4Signer.hex(Array($0)) }
        #expect(hex == "f4780e2d9f65fa895f9c67b32ce1baf0b0d8a43505a000a1a9e090d414db404d")
    }

    @Test func iamListUsersVector() throws {
        var request = URLRequest(url: URL(string: "https://iam.amazonaws.com/?Action=ListUsers&Version=2010-05-08")!)
        request.httpMethod = "GET"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        SigV4Signer(credentials: exampleCredentials, region: "us-east-1", service: "iam")
            .sign(&request, body: Data(), date: date("2015-08-30T12:36:00Z"))

        #expect(request.value(forHTTPHeaderField: "X-Amz-Date") == "20150830T123600Z")
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/iam/aws4_request, "
            + "SignedHeaders=content-type;host;x-amz-date, "
            + "Signature=5d672d79c15b13162d9279b0855cfba6789a8edb4c82c400e06b5924a6f2b5d7")
    }

    @Test func iamCanonicalRequestAndStringToSign() {
        let canonical = SigV4Signer.canonicalRequest(
            method: "GET", encodedPath: "/", encodedQuery: "Version=2010-05-08&Action=ListUsers",
            headers: [
                ("Content-Type", "application/x-www-form-urlencoded; charset=utf-8"),
                ("host", "iam.amazonaws.com"),
                ("X-Amz-Date", "20150830T123600Z"),
            ],
            payloadHash: "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(canonical.request == """
            GET
            /
            Action=ListUsers&Version=2010-05-08
            content-type:application/x-www-form-urlencoded; charset=utf-8
            host:iam.amazonaws.com
            x-amz-date:20150830T123600Z

            content-type;host;x-amz-date
            e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
            """)
        let sts = SigV4Signer.stringToSign(
            amzDate: "20150830T123600Z", scope: "20150830/us-east-1/iam/aws4_request",
            canonicalRequest: canonical.request)
        #expect(sts.hasSuffix("f536975d06c0309214f805bb90ccff089219ecd68b2577efef23edd43b7e1a59"))
    }

    /// botocore: POST converse-stream with a model ID containing ':' (double-encoded in the canonical URI).
    @Test(arguments: [
        (nil, "cbf66891f52a7d9a144e8c419460fb2eaefee84dba6b9dd102b8828d8ca9954d",
         "accept;content-type;host;x-amz-date"),
        ("EXAMPLESESSIONTOKEN/abc+def=", "b1c539cc074c033f61430ffb5ada294ad262748af5b79abe6fa545ddb4d110a7",
         "accept;content-type;host;x-amz-date;x-amz-security-token"),
    ] as [(String?, String, String)])
    func bedrockConverseStreamVector(token: String?, signature: String, signedHeaders: String) throws {
        let url = try BedrockClient.endpoint(
            region: "us-west-2", modelId: "us.anthropic.claude-haiku-4-5-20251001-v1:0")
        #expect(url.absoluteString ==
            "https://bedrock-runtime.us-west-2.amazonaws.com/model/us.anthropic.claude-haiku-4-5-20251001-v1%3A0/converse-stream")

        var credentials = exampleCredentials
        credentials.sessionToken = token
        let body = Data(#"{"messages":[]}"#.utf8)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "Accept")
        SigV4Signer(credentials: credentials, region: "us-west-2", service: "bedrock")
            .sign(&request, body: body, date: date("2026-10-05T12:00:00Z"))

        #expect(request.value(forHTTPHeaderField: "X-Amz-Security-Token") == token)
        #expect(request.value(forHTTPHeaderField: "Authorization") ==
            "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20261005/us-west-2/bedrock/aws4_request, "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)")
    }

    @Test func canonicalURIEncodesSegmentsAgain() {
        #expect(SigV4Signer.canonicalURI(encodedPath: "/model/a%3Ab/converse-stream") == "/model/a%253Ab/converse-stream")
        #expect(SigV4Signer.canonicalURI(encodedPath: "") == "/")
        #expect(SigV4Signer.canonicalURI(encodedPath: "/a b~c") == "/a%20b~c")
    }

    @Test func headerValuesAreTrimmedAndCollapsed() {
        #expect(SigV4Signer.normalizeHeaderValue("  a   b  c ") == "a b c")
    }

    @Test func amzDateIsUTC() {
        #expect(SigV4Signer.amzDate(date("2026-01-02T03:04:05Z")) == "20260102T030405Z")
    }

    @Test func endpointRejectsSuspiciousRegions() {
        #expect(throws: BedrockError.invalidRegion("us-west-2.evil.com/x")) {
            try BedrockClient.endpoint(region: "us-west-2.evil.com/x", modelId: "m")
        }
        #expect(throws: BedrockError.invalidRegion("")) {
            try BedrockClient.endpoint(region: "", modelId: "m")
        }
    }
}
