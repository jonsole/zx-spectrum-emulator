""".sna snapshot loading (48K, fixed 49179-byte layout).

.SNA has no PC field -- the format represents a machine paused as if by a
RETN, so PC lives on top of the stack at [SP] and must be popped (SP += 2)
during load.
"""
from __future__ import annotations

from dataclasses import dataclass

from zxspectrum.core.memory import RAM_SIZE
from zxspectrum.core.z80 import Registers

HEADER_SIZE = 27
SNA_48K_SIZE = HEADER_SIZE + RAM_SIZE


@dataclass
class SnaImage:
    regs: Registers
    border: int
    ram: bytes  # 49152 bytes covering 0x4000-0xFFFF


def _word(lo: int, hi: int) -> int:
    return lo | (hi << 8)


def parse_sna(data: bytes) -> SnaImage:
    if len(data) != SNA_48K_SIZE:
        raise ValueError(f".sna must be exactly {SNA_48K_SIZE} bytes (48K, no header), got {len(data)}")

    h = data[:HEADER_SIZE]
    ram = bytearray(data[HEADER_SIZE:])

    regs = Registers(
        ir=_word(h[20], h[0]),
        hl2=_word(h[1], h[2]),
        de2=_word(h[3], h[4]),
        bc2=_word(h[5], h[6]),
        af2=_word(h[7], h[8]),
        hl=_word(h[9], h[10]),
        de=_word(h[11], h[12]),
        bc=_word(h[13], h[14]),
        iy=_word(h[15], h[16]),
        ix=_word(h[17], h[18]),
        iff1=bool(h[19] & 0x04),
        iff2=bool(h[19] & 0x04),
        af=_word(h[21], h[22]),
        sp=_word(h[23], h[24]),
        im=h[25],
    )
    border = h[26] & 0x07

    # Pop PC off the stack (the defining quirk of .sna).
    sp = regs.sp
    stack_offset = sp - 0x4000
    if not (0 <= stack_offset < len(ram) - 1):
        raise ValueError(f".sna SP=0x{sp:04X} does not point into RAM; can't pop PC")
    pc = ram[stack_offset] | (ram[stack_offset + 1] << 8)
    regs.pc = pc
    regs.sp = (sp + 2) & 0xFFFF

    return SnaImage(regs=regs, border=border, ram=bytes(ram))


def _lohi(word: int) -> tuple[int, int]:
    return word & 0xFF, (word >> 8) & 0xFF


def write_sna(regs: Registers, ram: bytes, border: int = 0) -> bytes:
    """Serialize registers + 48K RAM into .sna bytes -- the exact inverse of
    parse_sna(), field for field. PC isn't stored directly (the format's
    defining quirk): it's pushed onto the stack at regs.sp - 2, which is
    what the header's SP field ends up holding, mirroring exactly what
    parse_sna() expects to pop back off on load."""
    if len(ram) != RAM_SIZE:
        raise ValueError(f"ram must be exactly {RAM_SIZE} bytes, got {len(ram)}")

    ram = bytearray(ram)
    header_sp = (regs.sp - 2) & 0xFFFF
    stack_offset = header_sp - 0x4000
    if not (0 <= stack_offset < len(ram) - 1):
        raise ValueError(f".sna SP=0x{regs.sp:04X} would not point into RAM after pushing PC")
    ram[stack_offset] = regs.pc & 0xFF
    ram[stack_offset + 1] = (regs.pc >> 8) & 0xFF

    h = bytearray(HEADER_SIZE)
    h[20], h[0] = _lohi(regs.ir)
    h[1], h[2] = _lohi(regs.hl2)
    h[3], h[4] = _lohi(regs.de2)
    h[5], h[6] = _lohi(regs.bc2)
    h[7], h[8] = _lohi(regs.af2)
    h[9], h[10] = _lohi(regs.hl)
    h[11], h[12] = _lohi(regs.de)
    h[13], h[14] = _lohi(regs.bc)
    h[15], h[16] = _lohi(regs.iy)
    h[17], h[18] = _lohi(regs.ix)
    h[19] = 0x04 if regs.iff1 else 0x00
    h[21], h[22] = _lohi(regs.af)
    h[23], h[24] = _lohi(header_sp)
    h[25] = regs.im & 0xFF
    h[26] = border & 0x07

    return bytes(h) + bytes(ram)
