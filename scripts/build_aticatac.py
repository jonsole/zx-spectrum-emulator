"""Disassemble Atic Atac (1983, Ultimate Play The Game) from its .tap into a
loadable .sna + .sld pair for source-level debugging.

Unlike Manic Miner and Fairlight (scripts/build_manicminer.py,
scripts/build_fairlight.py) there is no published .skool source to fetch for
this game: the disassembly is produced here from the tape itself. That makes
the pipeline longer, and two steps in it are worth explaining.

THE TAPE IS ENCRYPTED. The BASIC loader is

    10 BORDER 0: CLEAR 24574: FOR q=2 TO 6: LOAD "AticAtac"+STR$ q CODE
       : NEXT q: PRINT USR 23424

so the five CODE blocks land at 0x4000 (loading screen), 0x5FFF (the game,
30209 bytes) and three tiny ones at 0x5B80, 0x5CB0 and 0x5C78 -- and then
execution starts at 23424 (0x5B80), the printer buffer. What lives there is
not the game but an 18-byte decryptor:

    5B80: 21 FF 5F   LD HL,$5FFF
    5B83: 01 7C 00   LD BC,$007C     ; 124 x 256 = 31744 bytes
    5B86: AF         XOR A
    5B87: ED 67      RRD             ; chained nibble-rotate through A
    5B89: 23         INC HL
    5B8A: 10 FB      DJNZ $5B87
    5B8C: 0D         DEC C
    5B8D: 20 F8      JR NZ,$5B87
    5B8F: C3 00 60   JP $6000

RRD rotates a nibble out of (HL) into A and A's low nibble into (HL), so the
loop drags one nibble through the whole block -- every byte depends on its
predecessor, and the plaintext only exists in RAM. The bytes on the tape
therefore cannot be disassembled directly; they have to be run. tap2sna's
simulated load does exactly that, stopping at 0x6000 once the decryptor has
finished, and everything downstream works from that snapshot.

The 2-byte block at 0x5C78 is a second piece of the same protection. 0x5C78
is FRAMES, and the value poked in is 0x255E, which is what the decrypted code
at 0x6000 immediately checks:

    6000: F3         DI
    6001: 31 00 5E   LD SP,$5E00
    6004: 3A 79 5C   LD A,($5C79)    ; FRAMES+1
    6007: FE 25      CP $25          ; ...must be $25
    6009: C0         RET NZ          ; or fall straight back to BASIC
    600A: C3 19 7C   JP $7C19        ; real entry point

so a loader that skips the little blocks gets a game that silently refuses to
start.

SEPARATING CODE FROM DATA. Atic Atac is mostly graphics -- rooms, sprites and
masks -- and a static heuristic pass over it mis-reads a lot of that sprite
data as plausible-looking instructions. So instead this script *plays the
game* in SkoolKit's Z80 simulator (the C-accelerated one when it is
installed, ~50x real time) and records the address of every instruction
actually executed, which is a code map that cannot contain a false positive.
Random key mashing turns out to play Atic Atac perfectly well; what matters
is not that the knight survives but that the main loop, the sprite plotter
and the room-change and collision paths all get walked. See SESSIONS for why
the playthrough is repeated per character and control method.

The map is necessarily incomplete -- it can only find code that ran -- so
anything it did not reach stays marked as data. That is the safe direction to
be wrong in: unreached code shows up as DEFBs rather than as invented
instructions, and the round-trip check below still passes either way.

THE CORRECTNESS SIGNAL. There is no reference binary to diff the disassembly
against, but there is a better check than "it assembled": the .asm is fed
back through sjasmplus and the resulting bytes are compared against the
decrypted memory image the disassembly was made from. That is verified to be
byte-for-byte identical before any .sna is written, so the disassembly is
guaranteed to describe the real game and not an approximation of it.

The game code and everything built from it is copyrighted ((c) 1983 A.C.G. /
Ultimate Play The Game). Same treatment as roms/48.rom and rom_disassembly/:
built locally, gitignored, never committed. See README.md.

Requires `skoolkit` (pip install skoolkit) and sjasmplus -- this repo ships
one at tools/sjasmplus/, which is used automatically.

Usage:
    python scripts/build_aticatac.py --tape "path/to/Atic Atac.tap"
"""
from __future__ import annotations

import argparse
import contextlib
import io
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from zxspectrum.core.memory import RAM_SIZE
from zxspectrum.core.snapshot import write_sna
from zxspectrum.core.z80 import Registers

PROJECT_ROOT = Path(__file__).resolve().parent.parent
OUT_DIR = PROJECT_ROOT / "game_disassembly" / "aticatac"
# Hand-written comments, layered over the generated control file. Unlike
# everything in OUT_DIR this is source, not output: it contains no game bytes,
# only addresses and prose, so it is committed rather than gitignored.
ANNOTATIONS = PROJECT_ROOT / "scripts" / "aticatac_annotations.ctl"
ROM = PROJECT_ROOT / "roms" / "48.rom"
SJASMPLUS = PROJECT_ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"

# Where the decryptor hands over, and the extent of the loaded game block:
# 0x5FFF + 30209 bytes, less the unused byte at 0x5FFF itself.
ENTRY = 0x6000
GAME_END = 0xD600
STACK = 0x5E00  # what the game's own first instructions set SP to

TSTATES_PER_SECOND = 3500000


def _log(message: str) -> None:
    print(message, flush=True)


# --------------------------------------------------------------------------
# Step 1: run the tape's own decryptor to get a plaintext memory image.
# --------------------------------------------------------------------------

def make_snapshot(tape: Path, out: Path) -> None:
    """Simulate the real LOAD, stopping once the decryptor reaches 0x6000."""
    from skoolkit import tap2sna

    _log(f"Loading {tape.name} (simulated LOAD + on-tape decryptor)...")
    # tap2sna resolves its input as a URL, so a Windows path like C:\... is
    # read as scheme "c" and rejected. as_uri() gives it a file:// URL it
    # understands, with spaces and parentheses escaped.
    with contextlib.redirect_stdout(io.StringIO()):
        tap2sna.main(["--start", str(ENTRY), tape.resolve().as_uri(), str(out)])
    if not out.exists():
        sys.exit(f"error: tap2sna did not write {out}")


# --------------------------------------------------------------------------
# Step 2: play the game to find out which addresses are code.
# --------------------------------------------------------------------------

# The title screen is a menu: 1-3 pick the control method, 4-6 the character,
# 0 starts. Each character and each input method has its own movement and
# sprite handling, so a session per combination reaches routines the others
# never touch -- worth the few seconds each one costs.
SESSIONS = [
    ("1", "4", "keyboard/knight"),
    ("1", "5", "keyboard/wizard"),
    ("1", "6", "keyboard/serf"),
    ("3", "4", "cursor/knight"),
    ("2", "4", "kempston/knight"),
]

# Every key the game might read. Mashing the lot in turn is a blunt
# instrument, but it demonstrably plays: test runs reach a score in the
# thousands and wander through many rooms.
PLAY_KEYS = [
    "q", "w", "e", "r", "t", "y", "u", "i", "o", "p",
    "a", "s", "d", "f", "g", "h", "j", "k", "l", "ENTER",
    "CS", "z", "x", "c", "v", "b", "n", "m", "SS", "SPACE",
]


def _key_tracer_class():
    from skoolkit.kbtracer import KEY_BITS
    from skoolkit.trace import Tracer

    class KeyTracer(Tracer):
        """A Tracer whose read_port reports a set of held-down keys."""

        def __init__(self, simulator):
            super().__init__(simulator, 0, 0, 0, [0] * 16, 0, False)
            self.keys = set()

        def read_port(self, registers, port):
            if port == 0x1F:        # Kempston joystick: nothing pressed
                return 0
            if port & 1:            # not the ULA
                return 0xFF
            result = 0xFF
            for key in self.keys:
                half_row, bits = KEY_BITS[key]
                if port & half_row == 0:
                    result &= bits
            return result

    return KeyTracer


def _session_script(cycles: int, control: str, character: str):
    """(keys-held, seconds) steps for one playthrough, from the title screen."""
    script = [
        ([], 3.0), ([control], 0.3), ([], 0.5),
        ([character], 0.3), ([], 0.5),
        (["0"], 0.3), ([], 2.0),
    ]
    for cycle in range(cycles):
        # Alternate taps with long holds: a held direction walks the player
        # across a room and out through a door into the next one.
        hold = (0.4, 1.6)[cycle % 2]
        for key in PLAY_KEYS:
            script.append(([key], hold))
            script.append(([], 0.25))
        script.append(([], 4.0))    # let the world run between bursts
    return script


def build_code_map(snapshot_path: Path, out: Path, cycles: int) -> None:
    from skoolkit import CSimulator, read_bin_file
    from skoolkit.simulator import Simulator
    from skoolkit.simutils import PC, T
    from skoolkit.snapshot import Snapshot

    key_tracer_class = _key_tracer_class()
    snapshot = Snapshot.get(str(snapshot_path))
    rom_data = read_bin_file(str(ROM))
    if CSimulator is None:
        _log("  (no C simulator installed -- this will be slow)")

    executed: set[int] = set()
    for control, character, label in SESSIONS:
        # A fresh machine per session: the game has to be re-entered from the
        # title screen anyway, and a dead run would otherwise poison the next.
        memory = list(snapshot.memory)
        memory[:0x4000] = rom_data
        simulator = (CSimulator or Simulator)(
            memory, state={"iff": 0, "im": 1, "tstates": 0})
        tracer = key_tracer_class(simulator)
        simulator.set_tracer(tracer)

        before = len(executed)
        pc = ENTRY
        for keys, seconds in _session_script(cycles, control, character):
            tracer.keys = set(keys)
            simulator.trace(pc, 0, 0,
                            simulator.registers[T] + int(seconds * TSTATES_PER_SECOND),
                            True, None, executed, None, None, None)
            pc = simulator.registers[PC]
        _log(f"  {label}: +{len(executed) - before} addresses")

    # SkoolKit reads a 65536-byte map as one byte per address, bit 0 set.
    data = bytearray(65536)
    for address in executed:
        data[address] = 1
    out.write_bytes(bytes(data))

    reached = sum(1 for a in range(ENTRY, GAME_END) if data[a])
    _log(f"  {len(executed)} addresses executed; {reached} instruction starts "
         f"in the game block")


# --------------------------------------------------------------------------
# Step 3: map -> control file -> skool -> asm.
# --------------------------------------------------------------------------

def _capture(func, args) -> str:
    buf = io.StringIO()
    with contextlib.redirect_stdout(buf):
        func(args)
    return buf.getvalue()


def build_asm(snapshot: Path, code_map: Path, ctl: Path, skool: Path, asm: Path) -> None:
    from skoolkit import skool2asm, sna2ctl, sna2skool

    _log("Generating control file...")
    ctl.write_text(_capture(sna2ctl.main, [
        "-m", str(code_map), "-h",
        "-s", str(ENTRY), "-e", str(GAME_END), str(snapshot),
    ]), encoding="utf-8")

    _log("Generating skool file...")
    # ANNOTATIONS is layered over the generated control file: sna2skool takes
    # -c more than once and merges them, later files winning. That split is
    # what lets the code/data map be regenerated from scratch on every build
    # without throwing away the hand-written comments, which live in a file
    # this script only ever reads.
    ctls = ["-c", str(ctl)]
    if ANNOTATIONS.exists():
        ctls += ["-c", str(ANNOTATIONS)]
    else:
        _log(f"  (no annotations file at {ANNOTATIONS} -- output will be bare)")
    skool.write_text(_capture(sna2skool.main, [
        "-H", *ctls, str(snapshot),
    ]), encoding="utf-8")

    _log("Generating assembly...")
    # -c invents a label for every entry point and jump target, so the
    # listing reads as `JP L7C19` rather than `JP 31769`.
    text = _capture(skool2asm.main, ["-H", "-c", str(skool)])
    # sjasmplus needs a DEVICE directive to know the memory layout, and
    # skool2asm has no reason to emit one. It goes into the .asm itself
    # rather than a build-only copy so that the .sld sjasmplus produces
    # refers to this file, at these line numbers -- which is what makes
    # source-level debugging against it work.
    asm.write_text("    DEVICE ZXSPECTRUM48\n" + text, encoding="utf-8")


# --------------------------------------------------------------------------
# Step 4: assemble it back and prove it round-trips.
# --------------------------------------------------------------------------

def assemble(asm: Path, sld: Path) -> bytes:
    sjasmplus = str(SJASMPLUS) if SJASMPLUS.exists() else "sjasmplus"
    raw = OUT_DIR / "aticatac.rawbin"
    _log("Assembling with sjasmplus...")
    result = subprocess.run(
        [sjasmplus, asm.name, f"--sld={sld.name}", "--fullpath", f"--raw={raw.name}"],
        cwd=OUT_DIR, text=True, capture_output=True)
    if result.returncode != 0:
        sys.exit(f"error: sjasmplus failed:\n{result.stdout}\n{result.stderr}")
    game_bytes = raw.read_bytes()
    raw.unlink()
    return game_bytes


def verify(game_bytes: bytes, snapshot: Path) -> None:
    from skoolkit.snapshot import Snapshot

    reference = bytes(Snapshot.get(str(snapshot)).memory[ENTRY:GAME_END])
    if len(game_bytes) != len(reference):
        sys.exit(f"error: assembled {len(game_bytes)} bytes, expected {len(reference)}")
    if game_bytes != reference:
        differing = sum(1 for a, b in zip(game_bytes, reference) if a != b)
        sys.exit(f"error: assembled output differs from the decrypted game in "
                 f"{differing} bytes -- the disassembly is not faithful")
    _log(f"Verified: {len(game_bytes)} bytes reassemble byte-for-byte")


# --------------------------------------------------------------------------
# Step 5: wrap it back up as a .sna.
# --------------------------------------------------------------------------

def write_snapshot(game_bytes: bytes, snapshot: Path, out: Path) -> None:
    """Splice the assembled bytes into the decrypted RAM image.

    Starting from the real post-load image rather than a blank one keeps the
    things the game needs but the disassembly does not contain: the loading
    screen at 0x4000, and the system variables the little tape blocks set --
    including FRAMES, without which the check at 0x6000 drops straight back
    to BASIC.
    """
    from skoolkit.snapshot import Snapshot

    memory = list(Snapshot.get(str(snapshot)).memory)
    memory[ENTRY:GAME_END] = game_bytes
    ram = bytes(bytearray(memory[0x4000:0x4000 + RAM_SIZE]))

    # The game DIs and sets its own SP as its first two instructions; SP here
    # only has to be somewhere harmless for write_sna to push PC onto, and
    # 0x5E00 is the game's own stack area.
    regs = Registers(pc=ENTRY, sp=STACK, im=1)
    out.write_bytes(write_sna(regs, ram, border=0))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tape", required=True, type=Path,
                        help="the Atic Atac .tap file to disassemble")
    parser.add_argument("--cycles", type=int, default=10,
                        help="key-mashing cycles per playthrough session "
                             "(default 10; coverage saturates around 8)")
    args = parser.parse_args()

    if not args.tape.exists():
        sys.exit(f"error: {args.tape} not found")
    if not ROM.exists():
        sys.exit(f"error: {ROM} not found -- see README.md for where to get it")
    try:
        import skoolkit  # noqa: F401
    except ImportError:
        sys.exit("error: skoolkit not installed.\nInstall with: pip install skoolkit")

    OUT_DIR.mkdir(parents=True, exist_ok=True)
    snapshot = OUT_DIR / "aticatac.z80"
    code_map = OUT_DIR / "aticatac.map"
    ctl = OUT_DIR / "aticatac.ctl"
    skool = OUT_DIR / "aticatac.skool"
    asm = OUT_DIR / "aticatac.asm"
    sld = OUT_DIR / "aticatac.sld"
    sna = OUT_DIR / "aticatac.sna"

    make_snapshot(args.tape, snapshot)
    _log("Playing the game to map out which addresses are code...")
    build_code_map(snapshot, code_map, args.cycles)
    build_asm(snapshot, code_map, ctl, skool, asm)
    game_bytes = assemble(asm, sld)
    verify(game_bytes, snapshot)
    write_snapshot(game_bytes, snapshot, sna)

    _log("")
    _log(f"Entry point: 0x{ENTRY:04X} (the game's own entry is 0x7C19)")
    _log(f"Wrote {asm}, {sld}, and {sna}")
    _log("Load roms/48.rom first (write_sna doesn't touch it), then this .sna + .sld.")


if __name__ == "__main__":
    main()
