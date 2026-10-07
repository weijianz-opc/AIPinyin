#!/usr/bin/env python3
"""Builds Tests/AIPinyinCoreTests/Fixtures/all-header-types.bin.

Two AWS event-stream messages encoded independently of the Swift code (struct + zlib.crc32):
  1. an event using every header value type, with a contentBlockDelta payload
  2. a ThrottlingException
Both are round-tripped through botocore's decoder before writing, so the fixture is known-good.
"""
import struct
import sys
import uuid
import zlib

from botocore.eventstream import EventStreamBuffer


def header(name, type_id, value=b""):
    n = name.encode()
    return struct.pack(">B", len(n)) + n + struct.pack(">B", type_id) + value


def string_value(s):
    b = s.encode()
    return struct.pack(">H", len(b)) + b


def message(headers, payload):
    total = 12 + len(headers) + len(payload) + 4
    prelude = struct.pack(">II", total, len(headers))
    prelude += struct.pack(">I", zlib.crc32(prelude) & 0xFFFFFFFF)
    body = prelude + headers + payload
    return body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


event = message(
    b"".join([
        header(":message-type", 7, string_value("event")),
        header(":event-type", 7, string_value("contentBlockDelta")),
        header(":content-type", 7, string_value("application/json")),
        header("bool-true", 0),
        header("bool-false", 1),
        header("byte", 2, struct.pack(">b", -12)),
        header("short", 3, struct.pack(">h", -1234)),
        header("int", 4, struct.pack(">i", 123456789)),
        header("long", 5, struct.pack(">q", -1234567890123)),
        header("bytes", 6, struct.pack(">H", 3) + b"\x00\xff\x10"),
        header("string", 7, string_value("你好, world")),
        header("timestamp", 8, struct.pack(">q", 1759700000123)),
        header("uuid", 9, uuid.UUID("12345678-1234-5678-9abc-def012345678").bytes),
    ]),
    '{"contentBlockIndex":0,"delta":{"text":"ZH: 你好"},"p":"abc"}'.encode(),
)

exception = message(
    b"".join([
        header(":message-type", 7, string_value("exception")),
        header(":exception-type", 7, string_value("ThrottlingException")),
        header(":content-type", 7, string_value("application/json")),
    ]),
    b'{"message":"Too many requests, please wait before trying again."}',
)

data = event + exception
buf = EventStreamBuffer()
buf.add_data(data)
decoded = list(buf)
assert len(decoded) == 2, decoded
assert decoded[0].headers[":event-type"] == "contentBlockDelta"
assert decoded[0].headers["short"] == -1234 and decoded[0].headers["long"] == -1234567890123
assert decoded[1].headers[":exception-type"] == "ThrottlingException"
for m in decoded:
    print({k: v for k, v in m.headers.items()}, m.payload)

out = sys.argv[1] if len(sys.argv) > 1 else "Tests/AIPinyinCoreTests/Fixtures/all-header-types.bin"
with open(out, "wb") as f:
    f.write(data)
print(f"wrote {out} ({len(data)} bytes; event={len(event)}, exception={len(exception)})")
