import Foundation
import Testing
@testable import AIPinyinCore

func fixture(_ name: String) throws -> [UInt8] {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "bin", subdirectory: "Fixtures"))
    return Array(try Data(contentsOf: url))
}

func decodeAll(_ bytes: [UInt8], byteByByte: Bool = false) throws -> [EventStreamMessage] {
    var decoder = EventStreamDecoder()
    var messages: [EventStreamMessage] = []
    if byteByByte {
        for byte in bytes {
            decoder.append(byte)
            while let m = try decoder.next() { messages.append(m) }
        }
    } else {
        decoder.append(contentsOf: bytes)
        while let m = try decoder.next() { messages.append(m) }
    }
    #expect(decoder.pendingByteCount == 0)
    return messages
}

struct EventStreamTests {
    @Test func crc32CheckValue() {
        #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(CRC32.checksum([UInt8]()) == 0)
    }

    /// Fixture encoded by Scripts/make-eventstream-fixture.py and validated with botocore.
    @Test func decodesEveryHeaderType() throws {
        let messages = try decodeAll(try fixture("all-header-types"))
        try #require(messages.count == 2)
        let h = messages[0].headers
        #expect(h[":message-type"] == .string("event"))
        #expect(h[":event-type"] == .string("contentBlockDelta"))
        #expect(h["bool-true"] == .bool(true))
        #expect(h["bool-false"] == .bool(false))
        #expect(h["byte"] == .byte(-12))
        #expect(h["short"] == .int16(-1234))
        #expect(h["int"] == .int32(123_456_789))
        #expect(h["long"] == .int64(-1_234_567_890_123))
        #expect(h["bytes"] == .bytes([0x00, 0xFF, 0x10]))
        #expect(h["string"] == .string("你好, world"))
        #expect(h["timestamp"] == .timestamp(1_759_700_000_123))
        #expect(h["uuid"] == .uuid(UUID(uuidString: "12345678-1234-5678-9ABC-DEF012345678")!))
        #expect(try BedrockClient.event(from: messages[0]) == .textDelta("ZH: 你好"))

        #expect(throws: BedrockError.stream(
            type: "ThrottlingException", message: "Too many requests, please wait before trying again.")) {
            try BedrockClient.event(from: messages[1])
        }
    }

    @Test func byteByByteMatchesBulk() throws {
        for name in ["all-header-types", "bedrock-converse-stream"] {
            let bytes = try fixture(name)
            #expect(try decodeAll(bytes, byteByByte: true) == decodeAll(bytes))
        }
    }

    /// A real ConverseStream response captured from Bedrock with `aipinyin-cli --dump`.
    @Test func decodesRealBedrockResponse() throws {
        let messages = try decodeAll(try fixture("bedrock-converse-stream"))
        #expect(messages.count == 16)
        #expect(messages.first?.string(":event-type") == "messageStart")

        var text = ""
        var stop: String?
        var latency: Int?
        for message in messages {
            switch try BedrockClient.event(from: message) {
            case let .textDelta(t)?: text += t
            case let .messageStop(reason)?: stop = reason
            case let .metadata(ms, _, output)?:
                latency = ms
                #expect((output ?? 0) > 0)
            case nil: break
            }
        }
        #expect(stop == "end_turn")
        #expect((latency ?? 0) > 0)
        #expect(text == """
            ZH: 我今天有点不舒服
            EN: I'm feeling a bit under the weather today.
            EN: I'm not feeling great today.
            EN: I'm a little off today.
            """)
    }

    @Test func incompleteMessageWaitsForMoreBytes() throws {
        let bytes = try fixture("all-header-types")
        var decoder = EventStreamDecoder()
        decoder.append(contentsOf: bytes.prefix(100))
        #expect(try decoder.next() == nil)
        #expect(decoder.pendingByteCount == 100)
    }

    @Test func detectsCorruptedPayload() throws {
        var bytes = try fixture("all-header-types")
        bytes[200] ^= 0x01
        var decoder = EventStreamDecoder()
        decoder.append(contentsOf: bytes)
        #expect(throws: EventStreamError.messageChecksumMismatch) { try decoder.next() }
    }

    @Test func detectsCorruptedPrelude() throws {
        var bytes = try fixture("all-header-types")
        bytes[5] ^= 0x01  // headers length
        var decoder = EventStreamDecoder()
        decoder.append(contentsOf: bytes)
        #expect(throws: EventStreamError.preludeChecksumMismatch) { try decoder.next() }
    }

    @Test func detectsCorruptedTotalLength() throws {
        var bytes = try fixture("all-header-types")
        bytes[1] ^= 0x01  // total length +65536: plausible, so only the CRC can catch it
        var decoder = EventStreamDecoder()
        decoder.append(contentsOf: bytes)
        #expect(throws: EventStreamError.preludeChecksumMismatch) { try decoder.next() }
    }

    @Test func rejectsImpossibleLengths() {
        func prelude(total: UInt32, headers: UInt32) -> [UInt8] {
            func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
            let head = be(total) + be(headers)
            return head + be(CRC32.checksum(head))
        }
        for (total, headers) in [(5, 0), (32, 17), (20_000_000, 0)] as [(UInt32, UInt32)] {
            var decoder = EventStreamDecoder()
            decoder.append(contentsOf: prelude(total: total, headers: headers))
            #expect(throws: EventStreamError.invalidLength(total: total, headers: headers)) { try decoder.next() }
        }
    }
}
