"""Pythonic wrapper around the cffi-bound floooh/chips z80.h core.

Pin layout (from vendor/chips/z80.h): A0-A15 = bits 0-15, D0-D7 = bits
16-23, control lines from bit 24 up. Callers drive the CPU one T-state at
a time via tick(), inspecting/setting the returned pin mask to service
memory and IO requests -- see z80.h's HOWTO doc comment for the pattern.
"""
from __future__ import annotations

from dataclasses import dataclass

from zxspectrum._native._z80 import ffi, lib

PIN_A0 = 0
PIN_D0 = 16
PIN_M1 = 24
PIN_MREQ = 25
PIN_IORQ = 26
PIN_RD = 27
PIN_WR = 28
PIN_HALT = 29
PIN_INT = 30
PIN_RES = 31
PIN_NMI = 32
PIN_WAIT = 33
PIN_RFSH = 34

M1 = 1 << PIN_M1
MREQ = 1 << PIN_MREQ
IORQ = 1 << PIN_IORQ
RD = 1 << PIN_RD
WR = 1 << PIN_WR
HALT = 1 << PIN_HALT
INT = 1 << PIN_INT
RES = 1 << PIN_RES
NMI = 1 << PIN_NMI
WAIT = 1 << PIN_WAIT
RFSH = 1 << PIN_RFSH

PIN_MASK = (1 << 40) - 1


def get_addr(pins: int) -> int:
    return pins & 0xFFFF


def set_addr(pins: int, addr: int) -> int:
    return (pins & ~0xFFFF) | (addr & 0xFFFF)


def get_data(pins: int) -> int:
    return (pins >> 16) & 0xFF


def set_data(pins: int, data: int) -> int:
    return (pins & ~0xFF0000) | ((data << 16) & 0xFF0000)


@dataclass
class Registers:
    pc: int = 0
    sp: int = 0
    af: int = 0
    bc: int = 0
    de: int = 0
    hl: int = 0
    ix: int = 0
    iy: int = 0
    ir: int = 0
    wz: int = 0
    af2: int = 0
    bc2: int = 0
    de2: int = 0
    hl2: int = 0
    im: int = 0
    iff1: bool = False
    iff2: bool = False


class Z80:
    """Owns one native zx_cpu_t and exposes it as a Python object."""

    def __init__(self) -> None:
        self._c = lib.zx_alloc()
        if self._c == ffi.NULL:
            raise MemoryError("failed to allocate native Z80 CPU")
        self.pins = lib.zx_init(self._c)

    def close(self) -> None:
        if self._c is not None:
            lib.zx_free(self._c)
            self._c = None

    def __del__(self) -> None:
        self.close()

    def reset(self) -> int:
        self.pins = lib.zx_reset(self._c)
        return self.pins

    def tick(self, pins: int | None = None) -> int:
        if pins is not None:
            self.pins = pins
        self.pins = lib.zx_tick(self._c, self.pins)
        return self.pins

    def prefetch(self, new_pc: int) -> int:
        self.pins = lib.zx_prefetch(self._c, new_pc)
        return self.pins

    @property
    def opdone(self) -> bool:
        return bool(lib.zx_opdone(self._c))

    def get_regs(self) -> Registers:
        out = ffi.new("zx_regs_t*")
        lib.zx_get_regs(self._c, out)
        return Registers(
            pc=out.pc, sp=out.sp, af=out.af, bc=out.bc, de=out.de, hl=out.hl,
            ix=out.ix, iy=out.iy, ir=out.ir, wz=out.wz,
            af2=out.af2, bc2=out.bc2, de2=out.de2, hl2=out.hl2,
            im=out.im, iff1=bool(out.iff1), iff2=bool(out.iff2),
        )

    def set_regs(self, regs: Registers) -> None:
        c_regs = ffi.new("zx_regs_t*", {
            "pc": regs.pc, "sp": regs.sp, "af": regs.af, "bc": regs.bc,
            "de": regs.de, "hl": regs.hl, "ix": regs.ix, "iy": regs.iy,
            "ir": regs.ir, "wz": regs.wz,
            "af2": regs.af2, "bc2": regs.bc2, "de2": regs.de2, "hl2": regs.hl2,
            "im": regs.im, "iff1": regs.iff1, "iff2": regs.iff2,
        })
        lib.zx_set_regs(self._c, c_regs)
