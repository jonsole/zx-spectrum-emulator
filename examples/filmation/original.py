"""Reading your own copy of an original game, for kl_extract.py and pg_extract.py.

Nothing of Ultimate's is carried in a release's example workspaces: each one
extracts the game's artwork and tables from a copy the user supplies, and this
is what reads that copy, whatever form it is in:

  .sna   a 48K snapshot, 27 bytes of header and then RAM from $4000.
  .z80   a 48K snapshot, versions 1 to 3, compressed or not.
  .tap   a tape: each block a two-byte length, then the flag, the bytes and a
  .tzx   checksum. .tzx wraps the same blocks with IDs; the standard and turbo
         speed data blocks are the ones that carry bytes.

A snapshot has run the game, and the game mirrors its sprites in place as it
draws them, recording which way round one is now in the flags in its width
byte. unmirror() puts such a sprite back the way the tape holds it, so a
snapshot taken after the game has drawn a few things still extracts the same
bytes. What a snapshot cannot give back is anything the game has changed by
being played -- a collectable picked up, the wizard's list shuffled -- so it
wants to be from before a game is started: at the menu, say. The extractors'
own hash checks (extract.py) say so when one is not.
"""
from pathlib import Path

SNA_48K_SIZE = 27 + 0xC000
Z80_V1_HEADER = 30
# The .z80 pages a 48K machine has, and where each one sits.
Z80_PAGES_48K = {8: 0x4000, 4: 0x8000, 5: 0xC000}
# Hardware bytes (header byte 34) that are a 48K: plain, with Interface 1,
# and -- in version 3 files only -- with an M.G.T.
Z80_HARDWARE_48K_V2 = (0, 1)
Z80_HARDWARE_48K_V3 = (0, 1, 3)
TZX_SIGNATURE = b"ZXTape!\x1a"


class OriginalError(Exception):
    """A copy that cannot be read, with why -- to show the user as it is."""


def _z80_decompress(data, size):
    """ED ED n b is n copies of b; everything else is itself."""
    out = bytearray()
    at = 0
    while at < len(data) and len(out) < size:
        if data[at] == 0xED and at + 1 < len(data) and data[at + 1] == 0xED:
            out += bytes([data[at + 3]]) * data[at + 2]
            at += 4
        else:
            out.append(data[at])
            at += 1
    if len(out) != size:
        raise OriginalError(f"a .z80 page unpacked to {len(out)} bytes, not {size}")
    return out


def _load_z80(raw):
    memory = bytearray(0x10000)
    pc = raw[6] | (raw[7] << 8)
    if pc != 0:
        # Version 1: 48K only, one block from $4000, compressed if bit 5 of
        # byte 12 is set (byte 12 of 255 means 1, for old files).
        flags = raw[12] if raw[12] != 0xFF else 1
        body = raw[Z80_V1_HEADER:]
        if flags & 0x20:
            if body.endswith(b"\x00\xED\xED\x00"):
                body = body[:-4]
            body = _z80_decompress(body, 0xC000)
        elif len(body) < 0xC000:
            raise OriginalError("this .z80 is shorter than 48K of RAM")
        memory[0x4000:] = body[:0xC000]
        return memory
    extra = raw[30] | (raw[31] << 8)
    hardware = raw[34]
    allowed = Z80_HARDWARE_48K_V2 if extra == 23 else Z80_HARDWARE_48K_V3
    if hardware not in allowed:
        raise OriginalError("this .z80 is of a 128K (hardware %d): use one taken on a 48K"
                            % hardware)
    at = 32 + extra
    seen = set()
    while at + 3 <= len(raw):
        length = raw[at] | (raw[at + 1] << 8)
        page = raw[at + 2]
        at += 3
        if length == 0xFFFF:
            data = raw[at:at + 0x4000]
            at += 0x4000
        else:
            data = _z80_decompress(raw[at:at + length], 0x4000)
            at += length
        if page in Z80_PAGES_48K:
            base = Z80_PAGES_48K[page]
            memory[base:base + 0x4000] = data
            seen.add(page)
    if seen != set(Z80_PAGES_48K):
        raise OriginalError("this .z80 is missing some of a 48K's RAM")
    return memory


def load_snapshot(path):
    """The 64K address space from a 48K .sna or .z80 (the ROM left as zeros)."""
    raw = Path(path).read_bytes()
    suffix = Path(path).suffix.lower()
    if suffix == ".sna":
        if len(raw) != SNA_48K_SIZE:
            raise OriginalError("%s is %d bytes; a 48K .sna is %d" % (path, len(raw), SNA_48K_SIZE))
        memory = bytearray(0x10000)
        memory[0x4000:] = raw[27:]
        return memory
    if suffix == ".z80":
        return _load_z80(raw)
    raise OriginalError(f"{path} is not a snapshot (.sna or .z80)")


def tape_blocks(path):
    """A .tap's or .tzx's data blocks, flag and checksum included.

    Only the .tzx block types that carry bytes, or that the tapes of these
    games are known to hold alongside them, are understood; anything else
    stops the walk, so a tape that is not the expected one fails loudly
    instead of yielding half a game.
    """
    raw = Path(path).read_bytes()
    blocks = []
    if Path(path).suffix.lower() == ".tap":
        at = 0
        while at + 2 <= len(raw):
            length = raw[at] | (raw[at + 1] << 8)
            blocks.append(raw[at + 2:at + 2 + length])
            at += 2 + length
        return blocks
    if raw[:8] != TZX_SIGNATURE:
        raise OriginalError(f"{path} is not a TZX file")
    at = 10                     # 8-byte signature, then major/minor version
    while at < len(raw):
        block_id = raw[at]
        at += 1
        if block_id == 0x10:                    # standard speed data
            length = raw[at + 2] | (raw[at + 3] << 8)
            blocks.append(raw[at + 4:at + 4 + length])
            at += 4 + length
        elif block_id == 0x11:                  # turbo speed data
            length = raw[at + 0x0F] | (raw[at + 0x10] << 8) | (raw[at + 0x11] << 16)
            blocks.append(raw[at + 0x12:at + 0x12 + length])
            at += 0x12 + length
        elif block_id == 0x30:                  # text description
            at += 1 + raw[at]
        elif block_id == 0x32:                  # archive info
            at += 2 + (raw[at] | (raw[at + 1] << 8))
        else:
            raise OriginalError("%s: unexpected TZX block $%02X at %d" % (path, block_id, at - 1))
    return blocks


def reverse_bits(byte):
    out = 0
    for bit in range(8):
        if byte & (1 << bit):
            out |= 0x80 >> bit
    return out


def unmirror(memory, at, left_right, upside_down=0):
    """Turns the sprite record at `at` back the way the tape holds it, if the
    game has flipped it. `left_right` and `upside_down` are the width-byte bits
    the game sets as it does each (0 for a flip that game never makes).

    Each row is its cells' (mask, bitmap) pairs. A left-right mirror reverses
    their order and the bits in every byte; an upside-down one reverses the
    order of the rows and leaves the bytes alone. Either, done again, undoes
    itself, and the two are independent. Returns whether it was flipped."""
    flags = memory[at] & (left_right | upside_down)
    if not flags:
        return False
    width = memory[at] & 0x1F
    height = memory[at + 1]
    stride = 2 * width
    rows = [bytearray(memory[at + 2 + r * stride:at + 2 + (r + 1) * stride]) for r in range(height)]
    if flags & left_right:
        for n, row in enumerate(rows):
            pairs = [(row[2 * c], row[2 * c + 1]) for c in range(width)]
            rows[n] = bytearray(b for mask, bitmap in reversed(pairs)
                                for b in (reverse_bits(mask), reverse_bits(bitmap)))
    if flags & upside_down:
        rows.reverse()
    memory[at + 2:at + 2 + height * stride] = b"".join(rows)
    memory[at] &= ~flags & 0xFF
    return True
