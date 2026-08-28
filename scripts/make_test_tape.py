#!/usr/bin/env python3
"""Generates the tape images in tapes/, for exercising .tap/.tzx loading.

Real game tapes are copyrighted, so the repo carries a generator rather than a
tape. What it builds is a tiny autostarting BASIC program -- LOAD "" runs it
the moment the tape finishes, so a successful load is visible on the screen
rather than something you have to go and verify.

    python scripts/make_test_tape.py
"""
import os
import struct

OUT = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "tapes")

# 48K BASIC tokens.
TOK_BORDER = 0xE7
TOK_PRINT = 0xF5


def number(value):
    """A numeric constant as BASIC stores it: the digits you typed, then 0x0E
    and the five-byte binary form the interpreter actually evaluates."""
    return str(value).encode("ascii") + bytes([0x0E, 0x00, 0x00, value & 0xFF, value >> 8, 0x00])


def line(number_, body):
    """One program line: line number BIG-endian (the one big-endian field in
    the whole machine), then the body length little-endian, then the body."""
    body = body + b"\x0d"
    return struct.pack(">H", number_) + struct.pack("<H", len(body)) + body


def program():
    return (
        line(10, bytes([TOK_BORDER]) + number(6))
        + line(20, bytes([TOK_PRINT]) + b'"TAPE LOADED OK"')
    )


def header(name, data_len, autostart):
    """A Program header. LOAD "" accepts nothing else -- a CODE header is what
    LOAD ""CODE wants, and it walks straight past one it was not asked for."""
    return (
        bytes([0])
        + name.ljust(10)[:10].encode("ascii")
        + struct.pack("<HHH", data_len, autostart, data_len)
    )


def block(flag, payload):
    """Flag byte, payload, and the XOR checksum the ROM verifies."""
    body = bytes([flag]) + payload
    parity = 0
    for value in body:
        parity ^= value
    return body + bytes([parity])


def tap(blocks):
    return b"".join(struct.pack("<H", len(b)) + b for b in blocks)


def tzx(blocks, description):
    out = b"ZXTape!\x1a\x01\x14"
    out += bytes([0x30, len(description)]) + description.encode("ascii")
    for b in blocks:
        out += bytes([0x10]) + struct.pack("<HH", 1000, len(b)) + b
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    prog = program()
    blocks = [block(0x00, header("loadtest", len(prog), 10)), block(0xFF, prog)]

    for name, data in (
        ("loading-test.tap", tap(blocks)),
        ("loading-test.tzx", tzx(blocks, "Tape loading test")),
    ):
        path = os.path.join(OUT, name)
        with open(path, "wb") as f:
            f.write(data)
        print("wrote %s (%d bytes)" % (path, len(data)))


if __name__ == "__main__":
    main()
