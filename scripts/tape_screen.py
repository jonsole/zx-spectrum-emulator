"""A loading screen out of the files the tape designer accepts as a picture.

The Python half of vscode-extension/program_info.js's programScreen (and of
tape_view.js's reading of a .scr): the tape designer shows the picture it
finds there, and build_tape.py has to put exactly that picture on the tape.
vscode-extension/tests/tape_model_test.js holds the two to each other on the
repo's own snapshots and tapes.

No third-party imports: the standard ROM scheme needs nothing else.
"""
import os

SCREEN_BYTES = 6912
BITMAP_BYTES = 6144
TYPE_CODE = 3

# A .scr with only its bitmap gets the ROM's own cleared screen for colours:
# black ink on white paper.
DEFAULT_ATTR = 0x38


def _word(data, at):
    return data[at] | (data[at + 1] << 8)


def unpack_z80(data, start, end, size):
    """A .z80 memory block's ED ED run-length compression, undone."""
    out = bytearray()
    i = start
    while i < end and len(out) < size:
        if data[i] == 0xED and i + 3 < end and data[i + 1] == 0xED:
            out.extend(bytes([data[i + 3]]) * data[i + 2])
            i += 4
        else:
            out.append(data[i])
            i += 1
    return bytes(out[:size])


def z80_screen(data):
    if len(data) < 30:
        return None
    flags = 1 if data[12] == 255 else data[12]
    if _word(data, 6) != 0:
        # Version 1: all 48K from offset 30, compressed if bit 5 says so.
        body = unpack_z80(data, 30, len(data), SCREEN_BYTES) if flags & 0x20 else data[30:30 + SCREEN_BYTES]
        return body if len(body) == SCREEN_BYTES else None
    # Versions 2 and 3: blocks of a length, a page and 16K; page 8 is $4000 on
    # a 48K and RAM page 5 -- also $4000 -- on a 128K.
    at = 30 + 2 + _word(data, 30)
    while at + 3 <= len(data):
        length = _word(data, at)
        page = data[at + 2]
        start = at + 3
        size = 16384 if length == 0xFFFF else length
        if page == 8:
            if length == 0xFFFF:
                return data[start:start + SCREEN_BYTES]
            return unpack_z80(data, start, min(start + size, len(data)), 16384)[:SCREEN_BYTES]
        at = start + size
    return None


def tape_data_blocks(data, tzx):
    """(flag, payload-without-flag-and-checksum, offset of the payload in the
    file) for each data block of a .tap, or of a .tzx's standard, turbo and
    pure-data blocks -- program_info.js's tapBlocks and tzxBlocks."""
    blocks = []

    def add(start, length):
        if length >= 2 and start + length <= len(data):
            blocks.append((data[start], data[start + 1:start + length - 1], start + 1))

    if not tzx:
        at = 0
        while at + 2 <= len(data):
            length = _word(data, at)
            add(at + 2, length)
            at += 2 + length
        return blocks

    def dword(p):
        return _word(data, p) | (_word(data, p + 2) << 16)

    def triple(p):
        return _word(data, p) | (data[p + 2] << 16)

    at = 10
    while at < len(data):
        block_id, p = data[at], at + 1
        if block_id == 0x10:
            add(p + 4, _word(data, p + 2))
            step = p + 4 + _word(data, p + 2)
        elif block_id == 0x11:
            add(p + 18, triple(p + 15))
            step = p + 18 + triple(p + 15)
        elif block_id == 0x14:
            add(p + 10, triple(p + 7))
            step = p + 10 + triple(p + 7)
        elif block_id in (0x12, 0x2A):
            step = p + 4
        elif block_id == 0x13:
            step = p + 1 + data[p] * 2
        elif block_id == 0x15:
            step = p + 8 + triple(p + 5)
        elif block_id in (0x18, 0x19):
            step = p + 4 + dword(p)
        elif block_id in (0x20, 0x23, 0x24):
            step = p + 2
        elif block_id in (0x21, 0x30):
            step = p + 1 + data[p]
        elif block_id in (0x22, 0x25, 0x27):
            step = p
        elif block_id == 0x26:
            step = p + 2 + _word(data, p) * 2
        elif block_id in (0x28, 0x32):
            step = p + 2 + _word(data, p)
        elif block_id == 0x2B:
            step = p + 5
        elif block_id == 0x31:
            step = p + 2 + data[p + 1]
        elif block_id == 0x33:
            step = p + 1 + data[p] * 3
        elif block_id == 0x35:
            step = p + 20 + dword(p + 16)
        elif block_id == 0x5A:
            step = p + 9
        else:
            step = p + 4 + dword(p)  # the TZX spec's rule for block types it doesn't know
        if step <= at:
            break
        at = step
    return blocks


def tape_screen(blocks):
    """A tape's loading screen: the block a SCREEN$ header announces, else the
    first headerless block that is 6912 bytes -- how most custom loaders
    carry theirs."""
    for i, (flag, payload, _) in enumerate(blocks):
        if (flag == 0 and len(payload) == 17 and payload[0] == TYPE_CODE
                and _word(payload, 11) == SCREEN_BYTES and _word(payload, 13) == 16384
                and i + 1 < len(blocks) and len(blocks[i + 1][1]) >= SCREEN_BYTES):
            return blocks[i + 1][1][:SCREEN_BYTES]
    for flag, payload, _ in blocks:
        if flag != 0 and len(payload) == SCREEN_BYTES:
            return payload
    return None


def screen_from_file(path):
    """The 6912-byte loading screen in a .scr, .sna, .z80, .tap or .tzx -- the
    same picture the designer shows for it."""
    with open(path, 'rb') as file:
        data = file.read()
    ext = os.path.splitext(path)[1].lower()
    screen = None
    if ext == '.scr':
        if len(data) >= BITMAP_BYTES:
            screen = (data[:SCREEN_BYTES] + bytes([DEFAULT_ATTR]) * SCREEN_BYTES)[:SCREEN_BYTES]
    elif ext == '.sna':
        if len(data) in (27 + 49152, 131103, 147487):
            screen = data[27:27 + SCREEN_BYTES]
    elif ext == '.z80':
        screen = z80_screen(data)
    elif ext in ('.tap', '.tzx'):
        screen = tape_screen(tape_data_blocks(data, ext == '.tzx'))
    if screen is None or len(screen) != SCREEN_BYTES:
        raise ValueError(f"{path}: no loading screen found in it")
    return bytes(screen)
