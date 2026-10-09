import Foundation

/// CRC-32 (IEEE 802.3, the zlib polynomial) as used by the AWS event-stream framing.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

public struct EventStreamMessage: Equatable, Sendable {
    public enum HeaderValue: Equatable, Sendable {
        case bool(Bool)
        case byte(Int8)
        case int16(Int16)
        case int32(Int32)
        case int64(Int64)
        case bytes([UInt8])
        case string(String)
        /// Milliseconds since the Unix epoch.
        case timestamp(Int64)
        case uuid(UUID)
    }

    public var headers: [String: HeaderValue]
    public var payload: [UInt8]

    public func string(_ name: String) -> String? {
        if case let .string(s)? = headers[name] { return s }
        return nil
    }
}

public enum EventStreamError: Error, Equatable {
    case invalidLength(total: UInt32, headers: UInt32)
    case preludeChecksumMismatch
    case messageChecksumMismatch
    case malformedHeaders
}

/// Incremental decoder for `application/vnd.amazon.eventstream`.
///
///     [total length u32][headers length u32][prelude CRC u32][headers][payload][message CRC u32]
///
/// Feed bytes as they arrive with `append`, then drain complete messages with `next()`.
public struct EventStreamDecoder: Sendable {
    static let preludeLength = 12
    static let minimumLength = 16
    static let maximumLength = 16 * 1024 * 1024

    private var buffer: [UInt8] = []
    private var start = 0

    public init() {}

    public mutating func append(_ byte: UInt8) { buffer.append(byte) }

    public mutating func append<S: Sequence>(contentsOf bytes: S) where S.Element == UInt8 {
        buffer.append(contentsOf: bytes)
    }

    /// Bytes received but not yet returned as part of a message.
    public var pendingByteCount: Int { buffer.count - start }

    /// Returns the next complete message, or nil when more bytes are needed. O(1) when incomplete.
    public mutating func next() throws -> EventStreamMessage? {
        guard pendingByteCount >= Self.preludeLength else { return nil }
        // Check the prelude CRC before trusting the lengths: a corrupted length could otherwise
        // make us wait for bytes that never arrive.
        guard CRC32.checksum(buffer[start..<(start + 8)]) == readUInt32(at: start + 8) else {
            throw EventStreamError.preludeChecksumMismatch
        }
        let total = readUInt32(at: start)
        let headersLength = readUInt32(at: start + 4)
        guard total >= Self.minimumLength, total <= Self.maximumLength,
              Int(headersLength) <= Int(total) - Self.minimumLength
        else {
            throw EventStreamError.invalidLength(total: total, headers: headersLength)
        }
        guard pendingByteCount >= Int(total) else { return nil }

        let end = start + Int(total)
        guard CRC32.checksum(buffer[start..<(end - 4)]) == readUInt32(at: end - 4) else {
            throw EventStreamError.messageChecksumMismatch
        }
        let headersStart = start + Self.preludeLength
        let payloadStart = headersStart + Int(headersLength)
        let headers = try Self.parseHeaders(buffer[headersStart..<payloadStart])
        let payload = Array(buffer[payloadStart..<(end - 4)])

        start = end
        if start == buffer.count {
            buffer.removeAll(keepingCapacity: true)
            start = 0
        } else if start > 64 * 1024 {
            buffer.removeFirst(start)
            start = 0
        }
        return EventStreamMessage(headers: headers, payload: payload)
    }

    private func readUInt32(at i: Int) -> UInt32 {
        UInt32(buffer[i]) << 24 | UInt32(buffer[i + 1]) << 16 | UInt32(buffer[i + 2]) << 8 | UInt32(buffer[i + 3])
    }

    static func parseHeaders(_ bytes: ArraySlice<UInt8>) throws -> [String: EventStreamMessage.HeaderValue] {
        var headers: [String: EventStreamMessage.HeaderValue] = [:]
        var i = bytes.startIndex
        let end = bytes.endIndex

        func take(_ n: Int) throws -> ArraySlice<UInt8> {
            guard n >= 0, end - i >= n else { throw EventStreamError.malformedHeaders }
            defer { i += n }
            return bytes[i..<(i + n)]
        }
        func integer(_ n: Int) throws -> UInt64 {
            try take(n).reduce(0) { $0 << 8 | UInt64($1) }
        }

        while i < end {
            let nameLength = Int(try take(1).first!)
            guard let name = String(bytes: try take(nameLength), encoding: .utf8) else {
                throw EventStreamError.malformedHeaders
            }
            let type = try take(1).first!
            let value: EventStreamMessage.HeaderValue
            switch type {
            case 0: value = .bool(true)
            case 1: value = .bool(false)
            case 2: value = .byte(Int8(bitPattern: UInt8(try integer(1))))
            case 3: value = .int16(Int16(bitPattern: UInt16(try integer(2))))
            case 4: value = .int32(Int32(bitPattern: UInt32(try integer(4))))
            case 5: value = .int64(Int64(bitPattern: try integer(8)))
            case 6: value = .bytes(Array(try take(Int(try integer(2)))))
            case 7:
                guard let s = String(bytes: try take(Int(try integer(2))), encoding: .utf8) else {
                    throw EventStreamError.malformedHeaders
                }
                value = .string(s)
            case 8: value = .timestamp(Int64(bitPattern: try integer(8)))
            case 9:
                let b = Array(try take(16))
                value = .uuid(UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                                          b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])))
            default:
                throw EventStreamError.malformedHeaders
            }
            headers[name] = value
        }
        return headers
    }
}
