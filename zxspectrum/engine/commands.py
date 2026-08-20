"""Command/Event dataclasses exchanged with the engine.

Commands are requests: put on the engine's queue, answered via a future.
Events are broadcasts: fanned out to every subscriber, no reply expected.
"""
from __future__ import annotations

from dataclasses import dataclass

from zxspectrum.core.z80 import Registers

# -- commands ----------------------------------------------------------------


@dataclass
class Step:
    pass


@dataclass
class Run:
    pass


@dataclass
class Reset:
    pass


@dataclass
class SetBreakpoint:
    addr: int


@dataclass
class ClearBreakpoint:
    addr: int


@dataclass
class ReadMemory:
    addr: int
    length: int = 1


@dataclass
class WriteMemory:
    addr: int
    data: bytes


@dataclass
class GetRegisters:
    pass


@dataclass
class SetRegisters:
    regs: Registers


@dataclass
class KeyDown:
    key: str


@dataclass
class KeyUp:
    key: str


@dataclass
class GetScreen:
    pass


@dataclass
class GetState:
    pass


@dataclass
class LoadRom:
    data: bytes


@dataclass
class LoadSnapshot:
    data: bytes


# -- events --------------------------------------------------------------


@dataclass
class Stopped:
    reason: str  # "step" | "breakpoint" | "pause" | "entry"
    pc: int


@dataclass
class Continued:
    pass


@dataclass
class ResetEvent:
    pass


@dataclass
class State:
    pc: int
    registers: Registers
    breakpoints: frozenset[int]
    running: bool
    border: int
