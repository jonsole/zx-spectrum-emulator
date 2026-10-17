r"""Checks probe.py, the snapshot-probe driver the examples share, on a
program small enough to work out by hand: built through the driver, then
poked, called by symbol and peeked.

    .venv-win\Scripts\python.exe examples\scripts\probe_test.py

The program is assembled from PROGRAM below by running this file with
--build, which is the build command the test hands the driver.
"""

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))

import probe  # noqa: E402
import z80file  # noqa: E402

# Adds two bytes and keeps the sum; `spin` never returns, for the timeout.
PROGRAM = """\
        DEVICE ZXSPECTRUM48
        ORG $8000
start:  di
        ld sp,$FF00
        halt
add_bytes:
        ld a,(first)
        ld hl,second
        add a,(hl)
        ld (total),a
        ld b,a
        ret
spin:   jr spin
first:  db 0
second: db 0
total:  db 0
        SAVEBIN "ram.bin",$4000,$C000
"""


def assemble(out):
    """The --build command: PROGRAM to out/probe_test.z80 and its SLD."""
    out = Path(out)
    (out / "probe_test.s").write_text(PROGRAM)
    sjasmplus = REPO / "tools" / "sjasmplus" / "sjasmplus.exe"
    subprocess.run([str(sjasmplus) if sjasmplus.is_file() else shutil.which("sjasmplus"),
                    "--nologo", "--sld=probe_test.sld", "--fullpath", "probe_test.s"],
                   cwd=out, check=True, stdout=subprocess.DEVNULL)
    sld = probe.sld_symbols(out / "probe_test.sld")
    ram = (out / "ram.bin").read_bytes()
    (out / "probe_test.z80").write_bytes(z80file.snapshot_48k(ram, sld["start"]))


def main():
    failures = []

    def check(what, expected, actual):
        if expected != actual:
            failures.append(f"{what}: expected {expected!r}, got {actual!r}")

    with tempfile.TemporaryDirectory() as out:
        out = Path(out)
        build = [sys.executable, str(Path(__file__)), "--build", str(out)]
        with probe.Probe(out / "probe_test.z80", out / "probe_test.sld", build=build) as z:
            check("the build ran", True, (out / "probe_test.z80").is_file())
            check("a symbol from the SLD", 0x8000, z.where("start"))
            try:
                z.where("nowhere")
                failures.append("a symbol the SLD lacks: no ProbeError")
            except probe.ProbeError:
                pass
            z.poke("first", [0x30])
            z.poke("second", [0x12])
            regs = z.call("add_bytes")
            check("the sum, peeked", bytes([0x42]), z.peek("total", 1))
            check("the sum, in B", 0x42, regs.bc >> 8)
            check("the sum, in A", 0x42, regs.a)
            check("no carry from $30 + $12", False, regs.carry)
            z.poke("first", [0xF0])
            check("a carry from $F0 + $12", True, z.call("add_bytes").carry)
            # LD A,(nn) 13, LD HL,nn 10, ADD A,(HL) 7, LD (nn),A 13, LD B,A 4,
            # RET 10.
            check("T-states taken", 57, regs.tstates)
            try:
                z.call("spin")
                failures.append("a routine that never returns: no ProbeError")
            except probe.ProbeError:
                pass
        check("stopped", False, z.running)
        # A second probe on the same build command does not build again.
        (out / "probe_test.z80").unlink()
        try:
            probe.Probe(out / "probe_test.z80", out / "probe_test.sld", build=build).close()
            failures.append("the build ran twice")
        except probe.ProbeError:
            pass

    for f in failures:
        print("FAIL", f)
    print("probe_test:", "ok" if not failures else f"{len(failures)} failed")
    return 1 if failures else 0


if __name__ == "__main__":
    if sys.argv[1:2] == ["--build"]:
        assemble(sys.argv[2])
    else:
        sys.exit(main())
