r"""cpp-core's snapshot_probe, driven from Python: for checking a Z80
program against a model of it, by loading the program's snapshot, setting
memory, calling its routines and reading back what they left.

    from probe import Probe

    with Probe(OUT / "game.z80", OUT / "game.sld",
               build=[sys.executable, "build.py"]) as z:
        z.poke("speed", [40])
        after = z.call("step", hl=0x1234)    # Registers, and the T-states taken
        state = z.peek("state", 64)

Places are named by the program's own labels and equates, read from its
sjasmplus SLD, or given as addresses. `build`, if given, is the program's
build command, run before the first Probe on it in a Python process and not
again. The probe's protocol is in the header of
cpp-core/tests/snapshot_probe.cpp: one command a line, one reply a line.
Build the probe with `cpp-core\build.ps1 -Release -Target snapshot_probe`,
or name one in $SNAPSHOT_PROBE.

A program a check calls into must return from what it is called at: `call`
pushes a return address and runs, with interrupts off, until it comes back.

It lives in examples/scripts/ for any example that checks its Z80 against a
model; Cub's frame-by-frame check is the first.
"""

import os
import subprocess
from dataclasses import dataclass
from pathlib import Path

CPP_CORE = Path(__file__).resolve().parent.parent.parent / "cpp-core"
BUILT_PROBES = [CPP_CORE / "build" / "RelWithDebInfo" / "snapshot_probe.exe",
                CPP_CORE / "build" / "Debug" / "snapshot_probe.exe"]

# The build commands this process has run, so that each runs once.
_already_built = set()


class ProbeError(RuntimeError):
    """The probe said no: an error, or a timeout."""


@dataclass(frozen=True)
class Registers:
    """What `call` leaves: the register pairs, and the T-states the routine
    took."""
    af: int
    bc: int
    de: int
    hl: int
    ix: int
    iy: int
    tstates: int

    @property
    def a(self) -> int:
        return self.af >> 8

    @property
    def carry(self) -> bool:
        return bool(self.af & 1)


def probe_path() -> Path:
    if os.environ.get("SNAPSHOT_PROBE"):
        return Path(os.environ["SNAPSHOT_PROBE"])
    for path in BUILT_PROBES:
        if path.is_file():
            return path
    raise ProbeError(r"no snapshot_probe: cpp-core\build.ps1 -Release -Target snapshot_probe")


def sld_symbols(sld) -> dict:
    """The labels and equates an sjasmplus SLD records, {name: value}; a
    local label is `parent.local`. A label's record is
    `file|line|file|line|page|value|L|module,name,local,...`."""
    symbols = {}
    for record in Path(sld).read_text(encoding="utf-8").splitlines():
        fields = record.split("|")
        if len(fields) < 8 or fields[6] != "L":
            continue
        names = fields[7].split(",")
        if len(names) < 3:
            continue
        symbols[f"{names[1]}.{names[2]}" if names[2] else names[1]] = int(fields[5])
    return symbols


def build_once(command) -> None:
    """Run a build command, unless this process already has."""
    key = tuple(str(part) for part in command)
    if key in _already_built:
        return
    subprocess.run(key, check=True, stdout=subprocess.DEVNULL)
    _already_built.add(key)


class Probe:
    """One snapshot_probe, with one program's snapshot loaded. Close it, or
    use it in a `with`, to end the probe."""

    def __init__(self, snapshot, sld=None, build=None):
        if build:
            build_once(build)
        self.symbols = sld_symbols(sld) if sld else {}
        self._process = subprocess.Popen([str(probe_path())], stdin=subprocess.PIPE,
                                         stdout=subprocess.PIPE, text=True, bufsize=1)
        try:
            self._ask(f"load {snapshot}")
        except ProbeError:
            self.close()
            raise

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()

    def close(self) -> None:
        if self._process.poll() is None:
            self._process.stdin.close()
            self._process.wait()

    @property
    def running(self) -> bool:
        return self._process.poll() is None

    def where(self, place) -> int:
        """A label's or an equate's value, or an address as it is."""
        if isinstance(place, int):
            return place
        if place not in self.symbols:
            raise ProbeError(f"no symbol {place} in the program's SLD")
        return self.symbols[place]

    def peek(self, place, count: int) -> bytes:
        return bytes.fromhex(self._ask(f"peek {self.where(place):X} {count}"))

    def poke(self, place, data) -> None:
        self._ask(f"poke {self.where(place):X} {bytes(data).hex()}")

    def call(self, place, af=0, bc=0, de=0, hl=0, ix=0, iy=0) -> Registers:
        """Call a routine with these registers and interrupts off; what it
        left, when it returns."""
        pairs = [v & 0xFFFF for v in (af, bc, de, hl, ix, iy)]
        reply = self._ask(f"call {self.where(place):X} " + " ".join(f"{v:X}" for v in pairs)).split()
        return Registers(*(int(v, 16) for v in reply[:6]), tstates=int(reply[6]))

    def _ask(self, command: str) -> str:
        self._process.stdin.write(command + "\n")
        self._process.stdin.flush()
        reply = self._process.stdout.readline().strip()
        if reply == "timeout" or reply.startswith("error"):
            raise ProbeError(f"{command.split()[0]}: {reply}")
        return reply
