import CryptoKit
import Foundation

/// AWS Signature Version 4 request signer (header-based, non-S3 services).
public struct SigV4Signer: Sendable {
    public let credentials: AWSCredentials
    public let region: String
    public let service: String

    public init(credentials: AWSCredentials, region: String, service: String) {
        self.credentials = credentials
        self.region = region
        self.service = service
    }

    /// Adds `X-Amz-Date`, `X-Amz-Security-Token` (when present) and `Authorization`.
    /// Every header already set on the request, plus `host`, is signed, so set all headers first.
    public func sign(_ request: inout URLRequest, body: Data, date: Date = Date()) {
        guard let url = request.url, let host = url.host else { return }
        let amzDate = Self.amzDate(date)
        request.setValue(amzDate, forHTTPHeaderField: "X-Amz-Date")
        if let token = credentials.sessionToken {
            request.setValue(token, forHTTPHeaderField: "X-Amz-Security-Token")
        }
        var headers = (request.allHTTPHeaderFields ?? [:])
            .filter { $0.key.lowercased() != "authorization" }
            .map { ($0.key, $0.value) }
        headers.append(("host", url.port.map { "\(host):\($0)" } ?? host))

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let canonical = Self.canonicalRequest(
            method: request.httpMethod ?? "GET",
            encodedPath: components?.percentEncodedPath ?? "/",
            encodedQuery: components?.percentEncodedQuery ?? "",
            headers: headers,
            payloadHash: Self.hex(SHA256.hash(data: body)))
        let scope = "\(amzDate.prefix(8))/\(region)/\(service)/aws4_request"
        let stringToSign = Self.stringToSign(amzDate: amzDate, scope: scope, canonicalRequest: canonical.request)
        let key = Self.signingKey(
            secret: credentials.secretAccessKey, date: String(amzDate.prefix(8)),
            region: region, service: service)
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        request.setValue(
            "AWS4-HMAC-SHA256 Credential=\(credentials.accessKeyId)/\(scope), "
                + "SignedHeaders=\(canonical.signedHeaders), Signature=\(signature)",
            forHTTPHeaderField: "Authorization")
    }

    // MARK: - Building blocks (internal for tests)

    static func canonicalRequest(
        method: String, encodedPath: String, encodedQuery: String,
        headers: [(String, String)], payloadHash: String
    ) -> (request: String, signedHeaders: String) {
        var merged: [String: [String]] = [:]
        for (name, value) in headers {
            merged[name.lowercased(), default: []].append(normalizeHeaderValue(value))
        }
        let names = merged.keys.sorted()
        let canonicalHeaders = names.map { "\($0):\(merged[$0]!.joined(separator: ","))\n" }.joined()
        let signedHeaders = names.joined(separator: ";")
        let request = [
            method.uppercased(),
            canonicalURI(encodedPath: encodedPath),
            canonicalQuery(encodedQuery),
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        return (request, signedHeaders)
    }

    static func stringToSign(amzDate: String, scope: String, canonicalRequest: String) -> String {
        [
            "AWS4-HMAC-SHA256",
            amzDate,
            scope,
            hex(SHA256.hash(data: Data(canonicalRequest.utf8))),
        ].joined(separator: "\n")
    }

    static func signingKey(secret: String, date: String, region: String, service: String) -> SymmetricKey {
        func hmac(_ key: SymmetricKey, _ message: String) -> SymmetricKey {
            SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)))
        }
        var key = SymmetricKey(data: Data("AWS4\(secret)".utf8))
        for part in [date, region, service, "aws4_request"] {
            key = hmac(key, part)
        }
        return key
    }

    /// Non-S3 services expect each path segment URI-encoded again on top of the
    /// encoding already present in the request path (e.g. `%3A` becomes `%253A`).
    static func canonicalURI(encodedPath: String) -> String {
        guard !encodedPath.isEmpty else { return "/" }
        return encodedPath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { uriEncode(String($0)) }
            .joined(separator: "/")
    }

    /// Query pairs are expected to be already percent-encoded; they are sorted by name, then value.
    static func canonicalQuery(_ encodedQuery: String) -> String {
        guard !encodedQuery.isEmpty else { return "" }
        var pairs: [(name: String, value: String)] = []
        for pair in encodedQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            pairs.append((String(parts[0]), parts.count > 1 ? String(parts[1]) : ""))
        }
        pairs.sort { a, b in a.name == b.name ? a.value < b.value : a.name < b.name }
        let encoded: [String] = pairs.map { pair in pair.name + "=" + pair.value }
        return encoded.joined(separator: "&")
    }

    /// RFC 3986 unreserved characters stay; everything else is %XX (uppercase hex).
    static func uriEncode(_ s: String) -> String {
        var out = ""
        for byte in s.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"),
                 UInt8(ascii: "-"), UInt8(ascii: "_"), UInt8(ascii: "."), UInt8(ascii: "~"):
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    /// Trim and collapse runs of spaces, per the SigV4 canonical header rules.
    static func normalizeHeaderValue(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    static func amzDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02dT%02d%02d%02dZ",
            c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    static func hex(_ digest: SHA256.Digest) -> String { hex(Array(digest)) }

    static func hex(_ mac: HMAC<SHA256>.MAC) -> String { hex(Array(mac)) }
}
