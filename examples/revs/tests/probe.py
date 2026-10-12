"""A client for cpp-core's snapshot_probe: one Spectrum, driven a line at a
time, for tests whose expected values come from a model in Python.

Symbols come from the build's SLD, the equates among them, so a test names
what it wants -- `compose_screen`, `VERGE_R` -- rather than an address that
moves with the next change to the code.
"""

import os
import subprocess
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent.parent

PROBE_CANDIDATES = [
    REPO / "cpp-core" / "build" / "RelWithDebInfo" / "snapshot_probe.exe",
    REPO / "cpp-core" / "build" / "Debug" / "snapshot_probe.exe",
    REPO / "cpp-core" / "build" / "RelWithDebInfo" / "snapshot_probe",
    REPO / "cpp-core" / "build" / "Debug" / "snapshot_probe",
]


def find_probe(explicit: str | None = None) -> Path | None:
    """The probe named on the command line, then $SNAPSHOT_PROBE, then the
    usual build directories, Release first."""
    for candidate in (explicit, os.environ.get("SNAPSHOT_PROBE")):
        if candidate:
            return Path(candidate)
    for candidate in PROBE_CANDIDATES:
        if candidate.is_file():
            return candidate
    return None


def read_symbols(sld: Path) -> dict[str, int]:
    """Every label and equate in an sjasmplus SLD, a local label as
    `parent.local`."""
    symbols = {}
    for line in sld.read_text().splitlines():
        fields = line.split("|")
        if len(fields) < 8 or fields[6] != "L":
            continue
        parts = fields[7].split(",")
        if len(parts) > 2:
            name = parts[1] + ("." + parts[2] if parts[2] else "")
            symbols[name] = int(fields[5])
    return symbols


def signed16(v: int) -> int:
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


class ProbeError(RuntimeError):
    pass


class Probe:
    """One snapshot_probe process. Every request gets one line back."""

    def __init__(self, exe: Path, symbols: dict[str, int]):
        self.symbols = symbols
        self.proc = subprocess.Popen([str(exe)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                     text=True, bufsize=1)

    def close(self) -> None:
        self.proc.stdin.close()
        self.proc.wait()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def address(self, name_or_addr) -> int:
        return self.symbols[name_or_addr] if isinstance(name_or_addr, str) else name_or_addr

    def request(self, line: str) -> str:
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()
        reply = self.proc.stdout.readline().strip()
        if reply.startswith("error") or reply == "timeout":
            raise ProbeError(f"{line.split()[0]}: {reply}")
        return reply

    def load(self, snapshot: Path) -> None:
        self.request(f"load {snapshot}")

    def runto(self, where, max_frames: int = 50) -> None:
        self.request(f"runto {self.address(where):X} {max_frames}")

    def peek(self, where, count: int) -> bytes:
        return bytes.fromhex(self.request(f"peek {self.address(where):X} {count}"))

    def poke(self, where, data) -> None:
        self.request(f"poke {self.address(where):X} {bytes(data).hex()}")

    def byte(self, name) -> int:
        return self.peek(name, 1)[0]

    def word(self, name) -> int:
        b = self.peek(name, 2)
        return b[0] | b[1] << 8

    def set_word(self, name, value: int) -> None:
        self.poke(name, [value & 0xFF, (value >> 8) & 0xFF])

    def memory(self) -> bytes:
        """All 64K as the program sees it."""
        return self.peek(0, 0x10000)

    def restore(self, memory: bytes) -> None:
        """Puts the RAM of an earlier memory() back."""
        self.poke(0x4000, memory[0x4000:])

    def call(self, where, af=0, bc=0, de=0, hl=0, ix=0, iy=0) -> dict:
        reply = self.request("call %X %X %X %X %X %X %X" % (
            self.address(where), af & 0xFFFF, bc & 0xFFFF, de & 0xFFFF, hl & 0xFFFF,
            ix & 0xFFFF, iy & 0xFFFF)).split()
        v = [int(x, 16) for x in reply[:6]]
        return dict(af=v[0], a=v[0] >> 8, f=v[0] & 0xFF, bc=v[1], de=v[2], hl=v[3], ix=v[4],
                    iy=v[5], t=int(reply[6]))

    def beam(self, where, first_row: int, rows: int, updates: int) -> dict:
        reply = self.request(f"beam {self.address(where):X} {first_row} {rows} {updates}")
        return dict(field.split("=") for field in reply.split())

    def work(self, start, halt, updates: int, budget: int) -> dict:
        reply = self.request(
            f"work {self.address(start):X} {self.address(halt):X} {updates} {budget}")
        return {k: int(v) for k, v in (field.split("=") for field in reply.split())}
