import Foundation

/// Request body for the Bedrock Converse / ConverseStream APIs (the subset we use).
public struct ConverseRequest: Encodable, Equatable, Sendable {
    public struct Text: Encodable, Equatable, Sendable {
        public var text: String
        public init(_ text: String) { self.text = text }
    }

    public struct Message: Encodable, Equatable, Sendable {
        public var role: String
        public var content: [Text]
        public init(role: String, text: String) {
            self.role = role
            self.content = [Text(text)]
        }
    }

    public struct InferenceConfig: Encodable, Equatable, Sendable {
        public var maxTokens: Int?
        public var temperature: Double?
    }

    public var system: [Text]
    public var messages: [Message]
    public var inferenceConfig: InferenceConfig
}

public enum BedrockStreamEvent: Equatable, Sendable {
    case textDelta(String)
    case messageStop(reason: String?)
    case metadata(latencyMs: Int?, inputTokens: Int?, outputTokens: Int?)
}

public enum BedrockError: Error, LocalizedError, Equatable {
    case invalidRegion(String)
    case http(status: Int, type: String?, message: String)
    case stream(type: String, message: String)
    case invalidResponse(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRegion(r):
            return "无效的 region：\(r)"
        case let .http(status, type, message):
            return "Bedrock \(type ?? "HTTP \(status)")：\(message)"
        case let .stream(type, message):
            return "Bedrock \(type)：\(message)"
        case let .invalidResponse(detail):
            return "Bedrock 响应无法解析：\(detail)"
        }
    }
}

/// Minimal client for `POST /model/{modelId}/converse-stream` on bedrock-runtime.
public struct BedrockClient: Sendable {
    public let session: URLSession

    public init(session: URLSession = BedrockClient.makeSession()) {
        self.session = session
    }

    /// One long-lived session so the TLS connection is reused between conversions.
    public static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForResource = 120
        return URLSession(configuration: configuration)
    }

    public static func endpoint(region: String, modelId: String) throws -> URL {
        guard !region.isEmpty,
              region.unicodeScalars.allSatisfy({ CharacterSet.lowercaseLetters.contains($0) && $0.isASCII
                  || CharacterSet.decimalDigits.contains($0) && $0.isASCII || $0 == "-" })
        else {
            throw BedrockError.invalidRegion(region)
        }
        let model = SigV4Signer.uriEncode(modelId)
        guard let url = URL(string: "https://bedrock-runtime.\(region).amazonaws.com/model/\(model)/converse-stream")
        else {
            throw BedrockError.invalidRegion(region)
        }
        return url
    }

    /// Builds the signed HTTP request. Exposed so tools can capture raw responses.
    public static func makeRequest(
        _ body: ConverseRequest, modelId: String, region: String,
        credentials: AWSCredentials, timeout: TimeInterval, date: Date = Date()
    ) throws -> URLRequest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(body)
        var request = URLRequest(url: try endpoint(region: region, modelId: modelId), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/vnd.amazon.eventstream", forHTTPHeaderField: "Accept")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        SigV4Signer(credentials: credentials, region: region, service: "bedrock")
            .sign(&request, body: data, date: date)
        return request
    }

    public func converseStream(
        _ body: ConverseRequest, modelId: String, region: String,
        credentials: AWSCredentials, timeout: TimeInterval
    ) -> AsyncThrowingStream<BedrockStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let request = try Self.makeRequest(
                        body, modelId: modelId, region: region, credentials: credentials, timeout: timeout)
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        throw BedrockError.invalidResponse("not an HTTP response")
                    }
                    guard http.statusCode == 200 else {
                        var errorBody = [UInt8]()
                        for try await byte in bytes {
                            errorBody.append(byte)
                            if errorBody.count >= 64 * 1024 { break }
                        }
                        throw Self.httpError(
                            status: http.statusCode,
                            typeHeader: http.value(forHTTPHeaderField: "x-amzn-ErrorType"),
                            body: errorBody)
                    }
                    var decoder = EventStreamDecoder()
                    for try await byte in bytes {
                        decoder.append(byte)
                        while let message = try decoder.next() {
                            if let event = try Self.event(from: message) {
                                continuation.yield(event)
                            }
                        }
                    }
                    if decoder.pendingByteCount > 0 {
                        throw BedrockError.invalidResponse("stream ended mid-message")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Decoding

    private struct DeltaPayload: Decodable {
        struct Delta: Decodable { var text: String? }
        var delta: Delta?
    }

    private struct StopPayload: Decodable { var stopReason: String? }

    private struct MetadataPayload: Decodable {
        struct Usage: Decodable { var inputTokens: Int?; var outputTokens: Int? }
        struct Metrics: Decodable { var latencyMs: Int? }
        var usage: Usage?
        var metrics: Metrics?
    }

    private struct ErrorPayload: Decodable {
        var message: String?
        var Message: String?
        var __type: String?
    }

    /// Maps one event-stream message to an event; returns nil for events we ignore
    /// (messageStart, contentBlockStart/Stop). Exception messages are thrown.
    public static func event(from message: EventStreamMessage) throws -> BedrockStreamEvent? {
        let decoder = JSONDecoder()
        let payload = Data(message.payload)
        switch message.string(":message-type") {
        case "event":
            switch message.string(":event-type") {
            case "contentBlockDelta":
                let text = try? decoder.decode(DeltaPayload.self, from: payload).delta?.text
                return text.map { .textDelta($0) }
            case "messageStop":
                return .messageStop(reason: try? decoder.decode(StopPayload.self, from: payload).stopReason)
            case "metadata":
                let meta = try? decoder.decode(MetadataPayload.self, from: payload)
                return .metadata(
                    latencyMs: meta?.metrics?.latencyMs,
                    inputTokens: meta?.usage?.inputTokens,
                    outputTokens: meta?.usage?.outputTokens)
            default:
                return nil
            }
        case "exception":
            let body = try? decoder.decode(ErrorPayload.self, from: payload)
            throw BedrockError.stream(
                type: capped(message.string(":exception-type") ?? "Exception", 100),
                message: capped(body?.message ?? body?.Message ?? String(decoding: message.payload.prefix(2000), as: UTF8.self)))
        case "error":
            throw BedrockError.stream(
                type: capped(message.string(":error-code") ?? "Error", 100),
                message: capped(message.string(":error-message") ?? ""))
        default:
            throw BedrockError.invalidResponse("unknown message type \(capped(message.string(":message-type") ?? "nil", 100))")
        }
    }

    /// Server-provided text ends up in the candidate panel; keep it short.
    static func capped(_ s: String, _ limit: Int = 300) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "…"
    }

    static func httpError(status: Int, typeHeader: String?, body: [UInt8]) -> BedrockError {
        let parsed = try? JSONDecoder().decode(ErrorPayload.self, from: Data(body))
        // x-amzn-ErrorType looks like "AccessDeniedException:http://internal.amazon.com/..."
        let type = (typeHeader?.split(separator: ":").first.map(String.init))
            ?? parsed?.__type.flatMap { $0.split(separator: "#").last.map(String.init) }
        let message = parsed?.message ?? parsed?.Message
            ?? String(decoding: body.prefix(500), as: UTF8.self)
        return .http(status: status, type: type.map { capped($0, 100) }, message: capped(message))
    }
}
