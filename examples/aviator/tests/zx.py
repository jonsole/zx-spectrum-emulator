"""Driving the Spectrum version for the tests: building it, running it in
cpp-core's snapshot_probe, and moving the game's state between it and the
Python port.

The Z80 version keeps the original's data at the BBC address + $8000
(spectrum/layout.py), so a moment of the original or of the Python port --
both on the BBC layout -- goes into the Spectrum's memory region by region,
and comes back out the same way to be compared.

    with zx.Spectrum() as z:
        z.put_state(snap.mem)            # a BBC-layout image
        z.call("set_matrices")
        state = z.get_state()            # back in the BBC layout
"""

import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
REPO = ROOT.parent.parent
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "spectrum"))

import layout  # noqa: E402
from model import names  # noqa: E402

SNAPSHOT = ROOT / "output" / "aviator.z80"
SLD = ROOT / "output" / "aviator.sld"
PROBES = [REPO / "cpp-core" / "build" / "RelWithDebInfo" / "snapshot_probe.exe",
          REPO / "cpp-core" / "build" / "Debug" / "snapshot_probe.exe"]

# The original's one piece of state kept in its code, and where the Z80
# version keeps it: (BBC address, Z80 label).
CODE_STATE = [(names.mult1 + 1, "mult1_round"),
              (names.row29_char20_4, "joystick_switch"),
              (names.row25_char13_1, "upside_down_bar")]

_built = False


def build(defines=()):
    """Assemble the Spectrum version once per test run."""
    global _built
    if not _built:
        subprocess.run([sys.executable, str(ROOT / "spectrum" / "build.py"),
                        *[f"--define={d}" for d in defines]],
                       check=True, stdout=subprocess.DEVNULL)
        _built = True


def find_probe():
    named = os.environ.get("SNAPSHOT_PROBE")
    if named:
        return Path(named)
    for p in PROBES:
        if p.is_file():
            return p
    raise RuntimeError("snapshot_probe not built: cpp-core\\build.ps1 -Release -Target snapshot_probe")


def read_symbols(sld):
    """Every label and equate in an sjasmplus SLD, local ones as parent.local."""
    out = {}
    for line in sld.read_text().splitlines():
        fields = line.split("|")
        if len(fields) < 8 or fields[6] != "L":
            continue
        parts = fields[7].split(",")
        if len(parts) > 2:
            name = parts[1] + ("." + parts[2] if parts[2] else "")
            out[name] = int(fields[5])
    return out


class ProbeError(RuntimeError):
    pass


class Spectrum:
    """One snapshot_probe running the Spectrum version's snapshot."""

    def __init__(self):
        build()
        self.symbols = read_symbols(SLD)
        self.regions = layout.regions()
        self.proc = subprocess.Popen([str(find_probe())], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, text=True, bufsize=1)
        self.request(f"load {SNAPSHOT}")

    def close(self):
        self.proc.stdin.close()
        self.proc.wait()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def address(self, where):
        return self.symbols[where] if isinstance(where, str) else where

    def request(self, line):
        self.proc.stdin.write(line + "\n")
        self.proc.stdin.flush()
        reply = self.proc.stdout.readline().strip()
        if reply.startswith("error") or reply == "timeout":
            raise ProbeError(f"{line.split()[0]}: {reply}")
        return reply

    def peek(self, where, count):
        return bytes.fromhex(self.request(f"peek {self.address(where):X} {count}"))

    def poke(self, where, data):
        self.request(f"poke {self.address(where):X} {bytes(data).hex()}")

    def call(self, where, af=0, bc=0, de=0, hl=0, ix=0, iy=0):
        reply = self.request("call %X %X %X %X %X %X %X" % (
            self.address(where), af & 0xFFFF, bc & 0xFFFF, de & 0xFFFF, hl & 0xFFFF,
            ix & 0xFFFF, iy & 0xFFFF)).split()
        v = [int(x, 16) for x in reply[:6]]
        return dict(af=v[0], a=v[0] >> 8, f=v[0] & 0xFF, carry=v[0] & 1, bc=v[1], de=v[2],
                    hl=v[3], ix=v[4], iy=v[5], t=int(reply[6]))

    # ---- the game's state ----------------------------------------------

    def put_state(self, bbc_memory):
        """Load a BBC-layout image's data regions, and the state the original
        keeps in its code, into the Spectrum's memory."""
        for lo, hi in self.regions:
            self.poke(lo + layout.OFFSET, bbc_memory[lo:hi])
        for bbc, label in CODE_STATE:
            self.poke(label, [bbc_memory[bbc]])

    def get_state(self, into):
        """Copy the Spectrum's data regions back into a BBC-layout bytearray."""
        for lo, hi in self.regions:
            into[lo:hi] = self.peek(lo + layout.OFFSET, hi - lo)
        for bbc, label in CODE_STATE:
            into[bbc] = self.peek(label, 1)[0]
        return into


def compare_state(expected, actual):
    """The bytes that differ between two BBC-layout images, inside the data
    regions and outside the scratch, as (label, expected, actual), at most
    twelve."""
    from replay import describe
    out = []
    for lo, hi in layout.regions():
        if expected[lo:hi] == actual[lo:hi]:
            continue
        for i in range(lo, hi):
            if expected[i] != actual[i] and not any(a <= i < b for a, b in layout.SCRATCH):
                out.append((describe(i), expected[i], actual[i]))
                if len(out) >= 12:
                    return out
    for bbc, label in CODE_STATE:
        if expected[bbc] != actual[bbc]:
            out.append((label, expected[bbc], actual[bbc]))
    return out


def check_recorded(z, flight, name, label, registers, python, limit=None):
    """Replay the moments recorded at routine `name` during `flight` through
    the Z80 routine `label` (called with registers(snap)) and through the
    Python port (python(snap)), and compare the whole game state after. Prints
    the T-states the Z80 routine took."""
    import statistics
    from harness import Check
    import recorder
    from model import memory
    samples = recorder.recordings(flight, [name])[name][:limit]
    c = Check(f"{label} ({flight})")
    times = []
    for snap in samples:
        z.put_state(snap.mem)
        out = z.call(label, **registers(snap))
        times.append(out["t"])
        got = z.get_state(bytearray(snap.mem))
        memory.load(snap.mem)
        python(snap)
        c.compare(f"pc &{snap.pc:04X} a={snap.a:02X} x={snap.x:02X} y={snap.y:02X}",
                  [], compare_state(memory.M, got))
    ok = c.report()
    if times:
        print(f"      {statistics.mean(times):,.0f} T-states on average, {max(times):,} at most")
    return ok
