"""Z80 disassembler -- decodes bytes into mnemonic text.

Backs DAP's `disassemble` request (the primary code surface in v1, since
there's no source-level assembler listing/map). Implements the documented
Z80 instruction set via the standard bit-field decomposition of the
opcode byte (x/y/z/p/q -- see http://www.z80.info/decoding.htm for the
reference this follows), covering unprefixed, CB, ED, DD, FD, and the
DD CB d / FD CB d double-prefixed forms. Undocumented opcodes that don't
correspond to a documented instruction decode as a raw `DEFB` byte.

This module only decodes bytes into text -- it doesn't know about
breakpoints, PC, or the running machine; callers pass a `read(addr) ->
int` callable (typically bound to a Memory instance) and a start address.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Callable

ReadByte = Callable[[int], int]
Resolver = Callable[[int], "tuple[str, int] | None"]

R = ["B", "C", "D", "E", "H", "L", "(HL)", "A"]
RP = ["BC", "DE", "HL", "SP"]
RP2 = ["BC", "DE", "HL", "AF"]
CC = ["NZ", "Z", "NC", "C", "PO", "PE", "P", "M"]
ALU = ["ADD A,", "ADC A,", "SUB ", "SBC A,", "AND ", "XOR ", "OR ", "CP "]
ROT = ["RLC ", "RRC ", "RL ", "RR ", "SLA ", "SRA ", "SLL ", "SRL "]
IM = [0, 0, 1, 2, 0, 0, 1, 2]
BLOCK = {
    0: ["LDI", "LDD", "LDIR", "LDDR"],
    1: ["CPI", "CPD", "CPIR", "CPDR"],
    2: ["INI", "IND", "INIR", "INDR"],
    3: ["OUTI", "OUTD", "OTIR", "OTDR"],
}


@dataclass
class Instruction:
    addr: int
    length: int
    text: str
    raw: bytes


def _signed8(v: int) -> int:
    return v - 256 if v & 0x80 else v


class _Cursor:
    """Reads successive bytes starting at `addr`, tracking how many were consumed."""

    def __init__(self, read: ReadByte, addr: int) -> None:
        self._read = read
        self.start = addr
        self.pos = addr

    def byte(self) -> int:
        v = self._read(self.pos & 0xFFFF)
        self.pos += 1
        return v

    def word(self) -> int:
        lo = self.byte()
        hi = self.byte()
        return lo | (hi << 8)

    @property
    def length(self) -> int:
        return self.pos - self.start


def disassemble_one(read: ReadByte, addr: int) -> Instruction:
    c = _Cursor(read, addr)
    text = _decode(c, read, index=None)
    return Instruction(addr=addr, length=c.length, text=text, raw=bytes(read(addr + i) for i in range(c.length)))


def _decode(c: _Cursor, read: ReadByte, index: str | None) -> str:
    op = c.byte()

    if op == 0xCB:
        # Under a DD/FD prefix this is the DD CB d op / FD CB d op form --
        # `index` must carry through so _decode_cb knows to read a
        # displacement byte and target (IX+d)/(IY+d) instead of a plain r.
        return _decode_cb(c, index=index)
    if op == 0xED:
        return _decode_ed(c)
    if op == 0xDD:
        return _decode(c, read, index="IX")
    if op == 0xFD:
        return _decode(c, read, index="IY")

    x = op >> 6
    y = (op >> 3) & 0x07
    z = op & 0x07
    p = y >> 1
    q = y & 0x01

    def rp(i: int) -> str:
        if index and i == 2:
            return index
        return RP[i]

    def rr(i: int) -> str:
        # (HL) becomes (IX+d)/(IY+d) under a DD/FD prefix; H/L become the
        # undocumented IXH/IXL/IYH/IYL only when NOT the (HL) memory slot.
        if not index:
            return R[i]
        if i == 6:
            d = _signed8(c.byte())
            sign = "+" if d >= 0 else "-"
            return f"({index}{sign}{abs(d)})"
        if i == 4:
            return f"{index}H"
        if i == 5:
            return f"{index}L"
        return R[i]

    if x == 0:
        if z == 0:
            if y == 0:
                return "NOP"
            if y == 1:
                return "EX AF,AF'"
            if y == 2:
                d = _signed8(c.byte())
                return f"DJNZ ${addr_rel(c, d)}"
            if y == 3:
                d = _signed8(c.byte())
                return f"JR ${addr_rel(c, d)}"
            d = _signed8(c.byte())
            return f"JR {CC[y - 4]},${addr_rel(c, d)}"
        if z == 1:
            if q == 0:
                nn = c.word()
                return f"LD {rp(p)},0x{nn:04X}"
            return f"ADD {index or 'HL'},{rp(p)}"
        if z == 2:
            if q == 0:
                if p == 0:
                    return "LD (BC),A"
                if p == 1:
                    return "LD (DE),A"
                if p == 2:
                    nn = c.word()
                    return f"LD (0x{nn:04X}),{index or 'HL'}"
                nn = c.word()
                return f"LD (0x{nn:04X}),A"
            if p == 0:
                return "LD A,(BC)"
            if p == 1:
                return "LD A,(DE)"
            if p == 2:
                nn = c.word()
                return f"LD {index or 'HL'},(0x{nn:04X})"
            nn = c.word()
            return f"LD A,(0x{nn:04X})"
        if z == 3:
            return f"{'INC' if q == 0 else 'DEC'} {rp(p)}"
        if z == 4:
            return f"INC {rr(y)}"
        if z == 5:
            return f"DEC {rr(y)}"
        if z == 6:
            dest = rr(y)
            n = c.byte()
            return f"LD {dest},0x{n:02X}"
        # z == 7
        return ["RLCA", "RRCA", "RLA", "RRA", "DAA", "CPL", "SCF", "CCF"][y]

    if x == 1:
        if z == 6 and y == 6:
            return "HALT"
        if index and (y == 6 or z == 6):
            # A genuine (IX+d)/(IY+d) memory access is involved -- these are
            # the DOCUMENTED "LD r,(IX+d)"/"LD (IX+d),r" instructions, where
            # r=H or r=L means the REAL H/L register, not IXH/IXL. (The
            # undocumented IXH/IXL substitution only applies to *pure*
            # register-to-register moves, handled by the rr() branch below.)
            d = _signed8(c.byte())
            sign = "+" if d >= 0 else "-"
            mem = f"({index}{sign}{abs(d)})"
            return f"LD {mem},{R[z]}" if y == 6 else f"LD {R[y]},{mem}"
        dest = rr(y)  # evaluated before the source: at most one of y/z can
        return f"LD {dest},{rr(z)}"  # be 6 here (HALT is y=z=6, handled above)

    if x == 2:
        return f"{ALU[y]}{rr(z)}"

    # x == 3
    if z == 0:
        return f"RET {CC[y]}"
    if z == 1:
        if q == 0:
            return f"POP {index if p == 2 and index else RP2[p]}"
        if p == 0:
            return "RET"
        if p == 1:
            return "EXX"
        if p == 2:
            return f"JP ({index or 'HL'})"
        return f"LD SP,{index or 'HL'}"
    if z == 2:
        nn = c.word()
        return f"JP {CC[y]},0x{nn:04X}"
    if z == 3:
        if y == 0:
            nn = c.word()
            return f"JP 0x{nn:04X}"
        # y == 1 (opcode 0xCB) is unreachable here -- it's intercepted at
        # the top of _decode() before the x/y/z decomposition, since it
        # needs to consume a displacement byte first under DD/FD.
        if y == 2:
            n = c.byte()
            return f"OUT (0x{n:02X}),A"
        if y == 3:
            n = c.byte()
            return f"IN A,(0x{n:02X})"
        if y == 4:
            return f"EX (SP),{index or 'HL'}"
        if y == 5:
            return "EX DE,HL"
        if y == 6:
            return "DI"
        return "EI"
    if z == 4:
        nn = c.word()
        return f"CALL {CC[y]},0x{nn:04X}"
    if z == 5:
        if q == 0:
            return f"PUSH {index if p == 2 and index else RP2[p]}"
        if p == 0:
            nn = c.word()
            return f"CALL 0x{nn:04X}"
        if p == 1:
            return _decode(c, read, index="IX")
        if p == 2:
            return _decode_ed(c)
        return _decode(c, read, index="IY")
    if z == 6:
        n = c.byte()
        return f"{ALU[y]}0x{n:02X}"
    # z == 7
    return f"RST 0x{y * 8:02X}"


def addr_rel(c: _Cursor, displacement: int) -> str:
    return f"0x{(c.pos + displacement) & 0xFFFF:04X}"


def _decode_cb(c: _Cursor, index: str | None) -> str:
    if index:
        d = _signed8(c.byte())
        op = c.byte()
        sign = "+" if d >= 0 else "-"
        target = f"({index}{sign}{abs(d)})"
    else:
        op = c.byte()
        target = R[op & 0x07]

    x = op >> 6
    y = (op >> 3) & 0x07
    z = op & 0x07

    if x == 0:
        text = f"{ROT[y]}{target}"
    elif x == 1:
        return f"BIT {y},{target}"  # BIT never writes back, so no undoc copy form
    elif x == 2:
        text = f"RES {y},{target}"
    else:
        text = f"SET {y},{target}"

    # DD CB d/FD CB d forms where the low 3 bits aren't the (IX+d) slot
    # itself are undocumented: they also copy the result into R[z].
    if index and z != 6:
        text += f",{R[z]}"
    return text


def _decode_ed(c: _Cursor) -> str:
    op = c.byte()
    x = op >> 6
    y = (op >> 3) & 0x07
    z = op & 0x07
    p = y >> 1
    q = y & 0x01

    if x == 1:
        if z == 0:
            return "IN (C)" if y == 6 else f"IN {R[y]},(C)"
        if z == 1:
            return "OUT (C),0" if y == 6 else f"OUT (C),{R[y]}"
        if z == 2:
            return f"{'SBC' if q == 0 else 'ADC'} HL,{RP[p]}"
        if z == 3:
            nn = c.word()
            if q == 0:
                return f"LD (0x{nn:04X}),{RP[p]}"
            return f"LD {RP[p]},(0x{nn:04X})"
        if z == 4:
            return "NEG"
        if z == 5:
            return "RETI" if y == 1 else "RETN"
        if z == 6:
            return f"IM {IM[y]}"
        if z == 7:
            return ["LD I,A", "LD R,A", "LD A,I", "LD A,R", "RRD", "RLD", "NOP", "NOP"][y]

    if x == 2 and z <= 3 and y >= 4:
        return BLOCK[z][y - 4]

    return f"DEFB 0xED,0x{op:02X}"


# Every 16-bit address-shaped operand this module emits is formatted as
# exactly 4 uppercase hex digits (0x{:04X}) -- jump/call targets, (nn)
# memory operands, and 16-bit LD immediates. 8-bit immediates, I/O ports,
# and RST vectors use 2 digits and never match, which is what keeps this
# from misfiring on those. A trailing ")" is captured separately so a
# memory-indirect operand like "(0x5C0E)" gets annotated as
# "(0x5C0E) (TVDATA)" -- the label after the closing paren, not nested
# inside it.
_ADDR_RE = re.compile(r"0x([0-9A-F]{4})\b(\))?")


def annotate_symbols(text: str, resolve: Resolver) -> str:
    """Append a resolved symbol name after every 4-hex-digit address in
    `text`, e.g. "CALL 0x8000" -> "CALL 0x8000 (START)", "LD HL,0x4567" ->
    "LD HL,0x4567 (MY_TABLE+4)", "LD HL,(0x5C0E)" -> "LD HL,(0x5C0E)
    (TVDATA)". `resolve` is typically RomSource.symbol_at bound to a
    caller's active debug sources, passed as a callback so this module
    stays free of any dependency on rom_source.py."""

    def _sub(m: re.Match) -> str:
        result = resolve(int(m.group(1), 16))
        if result is None:
            return m.group(0)
        name, offset = result
        label = f"{name}+{offset}" if offset else name
        closing_paren = m.group(2) or ""
        return f"0x{m.group(1)}{closing_paren} ({label})"

    return _ADDR_RE.sub(_sub, text)


def disassemble_range(read: ReadByte, addr: int, count: int) -> list[Instruction]:
    """Decode `count` consecutive instructions starting at `addr`."""
    out: list[Instruction] = []
    a = addr
    for _ in range(count):
        inst = disassemble_one(read, a)
        out.append(inst)
        a = (a + inst.length) & 0xFFFF
    return out
