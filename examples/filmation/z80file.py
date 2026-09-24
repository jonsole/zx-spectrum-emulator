"""Version 3 .z80 snapshots of a Filmation game, 48K or 128K.

sjasmplus has no .z80 output of its own, and its .sna has to push PC onto the
stack -- into the bottom of the screen, for a 48K one. So a game's build saves
its RAM raw and wraps it here as a machine about to run from `start`. The
format is the one cpp-core's save_z80 writes and load_z80 reads
(cpp-core/src/snapshot.cpp).

Everything a snapshot could say beyond the RAM, PC and the paging is what
`start` sets for itself anyway: it disables interrupts and loads SP first
thing, and blacks the border.

knightlore/build.py and pentagram/build.py still carry their own copy of the
48K writer, which this one's is lifted from; knightlore128/build.py is the
first to use this module.
"""

# The 30-byte version 1 header, then the length of what follows it, then the
# 54 more bytes a version 3 header has.
Z80_V3_EXTRA = 54
HEADER_SIZE = 30 + 2 + Z80_V3_EXTRA

# 48K: page 8 is $4000, 4 is $8000 and 5 is $C000.
PAGES_48K = ((8, 0x0000), (4, 0x4000), (5, 0x8000))  # page, offset into the RAM

# Byte 34 of the header, the hardware. A 128K is 4 in a version 3 file;
# version 2 used 3, which version 3 gave to a 48K with an M.G.T. interface.
HARDWARE_48K = 0
HARDWARE_128K = 4

# 128K: pages 3 to 10 are banks 0 to 7.
PAGE_OF_BANK = 3

BANK_SIZE = 0x4000


def compress(data: bytes) -> bytes:
    """ED ED n b for a run of five or more, or of two or more EDs. A lone ED
    goes out literally along with the byte after it, so that no decoder can
    take the pair for a run marker."""
    out = bytearray()
    i = 0
    while i < len(data):
        b = data[i]
        run = 1
        while i + run < len(data) and data[i + run] == b and run < 255:
            run += 1
        if run >= 5 or (b == 0xED and run >= 2):
            out += bytes((0xED, 0xED, run, b))
            i += run
        elif b == 0xED:
            out += data[i:i + 2]
            i += 2
        else:
            out.append(b)
            i += 1
    return bytes(out)


def _header(pc: int, hardware: int) -> bytearray:
    header = bytearray(HEADER_SIZE)
    header[10] = 0x3F                  # I, as the ROM leaves it
    header[29] = 1                     # IM 1; IFF1 and IFF2 stay 0
    header[30:32] = Z80_V3_EXTRA.to_bytes(2, "little")
    header[32:34] = pc.to_bytes(2, "little")
    header[34] = hardware
    header[61] = header[62] = 0xFF     # the ROM is paged in at $0000-$3FFF
    return header


def _page(number: int, data: bytes) -> bytes:
    packed = compress(data)
    return len(packed).to_bytes(2, "little") + bytes((number,)) + packed


def snapshot_48k(ram: bytes, pc: int) -> bytes:
    """48K of RAM from $4000, as a 48K about to run from `pc`."""
    assert len(ram) == 0xC000, len(ram)
    body = bytearray()
    for page, offset in PAGES_48K:
        body += _page(page, ram[offset:offset + BANK_SIZE])
    return bytes(_header(pc, HARDWARE_48K) + body)


def snapshot_128k(banks: bytes, pc: int, port_7ffd: int) -> bytes:
    """All eight RAM banks, bank 0 first, as a 128K about to run from `pc`
    with `port_7ffd` the last value written to the paging port.

    The AY is left silent: every register zero except the mixer, register 7,
    which has all its tone and noise channels off.
    """
    assert len(banks) == 8 * BANK_SIZE, len(banks)
    assert not port_7ffd & 0x20, "the paging lock would stay set in the snapshot"
    header = _header(pc, HARDWARE_128K)
    header[35] = port_7ffd
    header[38] = 7                     # the last AY register selected
    header[39 + 7] = 0x3F              # the mixer, everything off
    body = bytearray()
    for bank in range(8):
        body += _page(PAGE_OF_BANK + bank,
                      banks[bank * BANK_SIZE:(bank + 1) * BANK_SIZE])
    return bytes(header + body)
