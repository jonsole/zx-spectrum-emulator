"""Shared pieces for the tests that check the Python port against the
original game running on the 6502 in bbc/.

The original is booted once, to the top of its first main loop, so its code
has been moved into place and its tables set up; each test then restores
that state (or a recorded one), sets a routine's inputs, calls it on the
6502 and calls the Python version on the same memory, and compares.
"""

import random
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "bbc"))

import beeb  # noqa: E402
from model import memory  # noqa: E402
from model import names  # noqa: E402

_booted = None


def booted():
    """A Beeb at the top of its first main loop, restored to that state each
    time this is called, with the Python port's memory set to match."""
    global _booted
    if _booted is None:
        machine = beeb.Beeb()
        machine.boot()
        _booted = (machine, machine.snapshot())
    machine, snap = _booted
    machine.restore(snap)
    memory.load(snap.mem)
    return machine


def zp(name):
    return getattr(names, name)


def set_pair(machine, hi, lo, value):
    """Put a 16-bit value in two zero-page bytes, (hi lo)."""
    machine.mem[zp(hi)] = (value >> 8) & 0xFF
    machine.mem[zp(lo)] = value & 0xFF


def get_pair(machine, hi, lo):
    return (machine.mem[zp(hi)] << 8) | machine.mem[zp(lo)]


class Check:
    """Counts cases and keeps the first few failures for the report."""

    def __init__(self, name):
        self.name = name
        self.cases = 0
        self.failures = []

    def compare(self, inputs, expected, actual):
        self.cases += 1
        if expected != actual:
            self.failures.append((inputs, expected, actual))

    def report(self):
        if self.cases == 0:
            print(f"  {self.name:24}       0 cases  not exercised")
            return True
        if not self.failures:
            print(f"  {self.name:24} {self.cases:7,} cases  ok")
            return True
        print(f"  {self.name:24} {self.cases:7,} cases  {len(self.failures):,} FAILED")
        for inputs, expected, actual in self.failures[:5]:
            print(f"      inputs {inputs}: original {expected}, port {actual}")
        return False


def rng(seed=1983):
    return random.Random(seed)


def interesting16(r):
    """A 16-bit value: mostly random, sometimes an edge."""
    choice = r.random()
    if choice < 0.1:
        return r.choice([0, 1, 2, 0x7F, 0x80, 0xFF, 0x100, 0x7FFF, 0x8000, 0x8001, 0xFFFE, 0xFFFF])
    if choice < 0.3:
        return r.randrange(0, 0x400)
    if choice < 0.4:
        return (0x10000 - r.randrange(1, 0x400)) & 0xFFFF
    return r.randrange(0, 0x10000)


def interesting8(r):
    if r.random() < 0.15:
        return r.choice([0, 1, 2, 0x0F, 0x10, 0x7F, 0x80, 0x81, 0xFE, 0xFF])
    return r.randrange(0, 256)
