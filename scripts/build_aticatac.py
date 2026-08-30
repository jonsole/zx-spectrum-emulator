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
import functools
import io
import os
import re
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
# Titles, prose pages and the game's name for the HTML build. Source, like the
# annotations, and committed for the same reason.
REF = PROJECT_ROOT / "scripts" / "aticatac.ref"
ROM = PROJECT_ROOT / "roms" / "48.rom"
SJASMPLUS = PROJECT_ROOT / "tools" / "sjasmplus" / "sjasmplus.exe"

# Where the decryptor hands over, and the extent of the loaded game block:
# 0x5FFF + 30209 bytes, less the unused byte at 0x5FFF itself.
ENTRY = 0x6000
# The room-redraw entry: mark the room seen, blank the play area, draw the
# room, colour the panel. Running it with a room number in $EA91 and stopping
# at REDRAW_DONE leaves that room -- and nothing else -- on the screen.
REDRAW_ROOM = 0x9147
REDRAW_DONE = 0x9156
CURRENT_ROOM = 0xEA91
ROOM_TABLE = 0xA854
ROOM_SHAPES = 0xA982
# Rooms 0-148. The table has 151 entries, but the last two are colour $00 --
# black on black -- and entry 151 is really the first two bytes of the shape
# table. See COUNT_ROOMS_EXPLORED, whose arithmetic only works out at 149.
ROOM_COUNT = 149
# Three tables, three lengths, and they are not interchangeable. ROOM_TABLE has
# 151 entries: the 149 rooms the player walks around, and two more. Entry 150 is
# the one that matters -- it is shape $0C, the concentric squares drawn while
# the player falls through a trapdoor, which is a room as far as the drawing
# code is concerned but not one anybody walks into. Scanning only the first 149
# makes that shape look unused when it is nothing of the kind.
ROOM_TABLE_ENTRIES = 151
# The contents index is shorter: 150 entries, ending where the first list
# begins at $76A9. The fall has nothing in it.
ROOM_LIST_ENTRIES = 150
# The index of what each room holds. The lists it points at follow it and
# fill everything up to the game's entry point exactly.
ROOM_CONTENTS = 0x757D
GAME_END = 0xD600
STACK = 0x5E00  # what the game's own first instructions set SP to

TSTATES_PER_SECOND = 3500000
NEWLINE = chr(10)


def _log(message: str) -> None:
    print(message, flush=True)


# --------------------------------------------------------------------------
# Step 1: run the tape's own decryptor to get a plaintext memory image.
# --------------------------------------------------------------------------

# The snapshot is read by a dozen different steps -- the table readers, the
# block generators, the renderers, the sound capture, the round-trip check --
# so it is parsed once and handed out. game_memory returns it as a tuple to
# make it obvious that the shared copy is not to be written to; anything that
# runs code wants machine_memory, which is a fresh mutable 64K with the real
# ROM underneath so that RST and the ROM's own routines behave.
@functools.lru_cache(maxsize=None)
def _read_snapshot(path: str) -> tuple:
    from skoolkit.snapshot import Snapshot

    return tuple(Snapshot.get(path).memory)


def game_memory(snapshot: Path) -> tuple:
    """The snapshot's 64K, read once and shared. Read-only."""
    return _read_snapshot(str(snapshot))


def machine_memory(snapshot: Path) -> list:
    """A fresh, writable 64K with the ROM in place, for running the game."""
    from skoolkit import read_bin_file

    memory = list(game_memory(snapshot))
    memory[:0x4000] = read_bin_file(str(ROM))
    return memory


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


_COMMENT_RE = re.compile(r"^\s{2}\$([0-9A-F]{4})(?:,(\d+))?\s")
_SPAN_RE = re.compile(r"^;\s*span\s+\$([0-9A-F]{4}),(\d+)\s*$")

# A span is (start, end), with end exclusive, the way a Python slice reads --
# never (start, length). Both are pairs of plausible-looking integers, so the
# mistake type-checks, runs, and produces a disassembly that still reassembles
# byte-for-byte; only check_structure notices. The annotations spell it the
# other way, `; span $ADDR,LENGTH`, because a length is what a person counting
# bytes in a table actually knows -- declared_spans converts.
Span = tuple[int, int]
_BLOCK_RE = re.compile(r"^[bctwsi] \$([0-9A-F]{4})")


def declared_spans() -> list[Span]:
    """Data-block extents the annotations claim, as `; span $ADDR,LENGTH`.

    sna2ctl's heuristics happily start a new block in the middle of a table --
    ROOM_TABLE gets cut after one byte, and a stretch of ROOM_SHAPES is read as
    text. Those boundaries come from the generated control file, and a second
    control file can add boundaries but never remove them, so the only way to
    keep a table whole is to drop them before the two are merged.
    """
    if not ANNOTATIONS.exists():
        return []
    spans = []
    for line in ANNOTATIONS.read_text(encoding="utf-8").splitlines():
        match = _SPAN_RE.match(line)
        if match:
            start = int(match.group(1), 16)
            spans.append((start, start + int(match.group(2))))
    return spans


def strip_spanned_blocks(ctl_text: str, spans: list[Span]) -> str:
    """Drop generated block directives that fall strictly inside a span."""
    if not spans:
        return ctl_text
    kept = []
    for line in ctl_text.splitlines():
        match = _BLOCK_RE.match(line)
        if match:
            address = int(match.group(1), 16)
            if any(start < address < end for start, end in spans):
                continue
        kept.append(line)
    return NEWLINE.join(kept)


def check_annotations(bare_skool: str) -> None:
    """Warn about instruction comments whose length splits an instruction.

    A `  $ADDR,N` directive whose N does not land on an instruction boundary
    makes sna2skool cut an instruction in half and re-decode from the middle
    of it, which shifts every address after that point. The round-trip check
    catches the damage, but only as a byte count that is a few too many --
    this says which line caused it.
    """
    if not ANNOTATIONS.exists():
        return
    # Lines are "c$8093 ...", " $8096 ..." or "*$809A ..." -- the star marks
    # a jump target, and those are instruction boundaries just as much as
    # the rest, so the pattern has to allow it.
    boundaries = {int(m.group(1), 16)
                  for m in (re.match(r"^[bctwsi ]?\*?\$([0-9A-F]{4})\s", line)
                            for line in bare_skool.split("\n")) if m}
    problems = []
    for number, line in enumerate(ANNOTATIONS.read_text(encoding="utf-8").split("\n"), 1):
        match = _COMMENT_RE.match(line)
        if not match or match.group(2) is None:
            continue
        address = int(match.group(1), 16)
        end = address + int(match.group(2))
        if address in boundaries and end not in boundaries:
            valid = min((b for b in boundaries if b >= end), default=None)
            problems.append(f"  {ANNOTATIONS.name}:{number}: ${address:04X},"
                            f"{match.group(2)} ends mid-instruction"
                            + (f" -- try ,{valid - address}" if valid else ""))
    if problems:
        _log("Annotation lengths that split an instruction:")
        for problem in problems:
            _log(problem)


def build_asm(snapshot: Path, code_map: Path, ctl: Path, skool: Path, asm: Path) -> None:
    from skoolkit import skool2asm, sna2ctl, sna2skool

    _log("Generating control file...")
    auto_ctl = _capture(sna2ctl.main, [
        "-m", str(code_map), "-h",
        "-s", str(ENTRY), "-e", str(GAME_END), str(snapshot),
    ])
    graphics_ctl = OUT_DIR / "aticatac-graphics.ctl"
    graphics_text, graphics_spans = graphics_blocks(snapshot)
    rooms_text, rooms_spans = room_list_blocks(snapshot)
    shapes_text, shapes_spans = shape_blocks(snapshot)
    generated = graphics_text + rooms_text + shapes_text
    graphics_ctl.write_text(generated, encoding="utf-8")
    _log(f"  {graphics_text.count('label=')} sprite graphics, "
         f"{rooms_text.count('label=')} room lists and "
         f"{shapes_text.count('label=')} outline tables located from their tables")
    # Spans are (start, end), not (start, length) -- check_structure enforces
    # that they agree with the sub-blocks, which is the only thing that would
    # notice if a generator got it wrong.
    sources = [
        ("the annotations", declared_spans()),
        ("graphics_blocks", graphics_spans),
        ("room_list_blocks", rooms_spans),
        ("shape_blocks", shapes_spans),
    ]
    check_structure(sources, generated)
    spans = [span for _, group in sources for span in group]
    kept = strip_spanned_blocks(auto_ctl, spans)
    if spans:
        dropped = auto_ctl.count(NEWLINE) - kept.count(NEWLINE)
        _log(f"  {len(spans)} declared span(s); dropped {dropped} generated "
             f"block boundar{'y' if dropped == 1 else 'ies'} inside them")
    ctl.write_text(kept, encoding="utf-8")

    _log("Generating skool file...")
    # ANNOTATIONS is layered over the generated control file: sna2skool takes
    # -c more than once and merges them, later files winning. That split is
    # what lets the code/data map be regenerated from scratch on every build
    # without throwing away the hand-written comments, which live in a file
    # this script only ever reads.
    ctls = ["-c", str(ctl), "-c", str(graphics_ctl)]
    if ANNOTATIONS.exists():
        # Disassemble once without the annotations first, purely to learn
        # where the instruction boundaries are, so misaligned comment lengths
        # can be reported by line number rather than as a byte-count mismatch
        # a hundred lines of output later.
        # The boundary pass needs the block directives -- a block forced from
        # data to code has no instruction boundaries without them, and every
        # comment inside it then looks misaligned. The titles and comments are
        # stripped so only the structure is applied.
        structure = OUT_DIR / "aticatac-structure.ctl"
        structure.write_text(NEWLINE.join(
            line.split(" ", 2)[0] + " " + line.split(" ", 2)[1]
            for line in ANNOTATIONS.read_text(encoding="utf-8").splitlines()
            if re.match(r"^[bctwsi] \$[0-9A-F]{4}", line)), encoding="utf-8")
        check_annotations(_capture(sna2skool.main,
                                   ["-H", "-c", str(ctl), "-c", str(structure),
                                    str(snapshot)]))
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


# Names for the ten outlines, read off the pictures they draw.
SHAPE_NAMES = {
    0x00: "Square hall",
    0x01: "Cave",
    0x02: "Octagonal hall",
    0x03: "Wide hall",
    0x04: "Tall hall",
    0x05: "Staircase, head-on",
    0x08: "Staircase, side-on",
    0x09: "Cavern, wide",
    0x0A: "Cavern, tall",
    0x0B: "Passage",
    # Not a room: ROOM_TABLE's last entry, drawn while the player drops through
    # a trapdoor. Twelve nested rectangles, so redrawing it with the walk
    # limits closing in reads as falling down a shaft.
    0x0C: "Trapdoor fall",
}


def read_shapes(snapshot: Path) -> list[dict]:
    """Every distinct room outline, with the data behind it.

    A shape entry is six bytes: how far the player may walk from the centre
    each way, then the address of its vertex table, then the address of its
    edge list. Neither table carries a length -- the edge list ends at a
    doubled $FF, and the vertex table is however many points it mentions.
    """

    memory = game_memory(snapshot)
    rooms_by_shape: dict[int, list[int]] = {}
    for room in range(ROOM_TABLE_ENTRIES):
        rooms_by_shape.setdefault(memory[ROOM_TABLE + room * 2 + 1], []).append(room)

    shapes = []
    for shape in sorted(rooms_by_shape):
        entry = ROOM_SHAPES + shape * 6
        vertices = memory[entry + 2] | (memory[entry + 3] << 8)
        edges = memory[entry + 4] | (memory[entry + 5] << 8)
        # Walk the edge list: a vertex begins a group, the vertices after it
        # are drawn to from it, $FF closes the group and a second $FF the list.
        address, groups, group, highest = edges, [], None, -1
        while True:
            value = memory[address]
            address += 1
            if value == 0xFF:
                if group is None:
                    break
                groups.append(group)
                group = None
                continue
            highest = max(highest, value)
            if group is None:
                group = [value]
            else:
                group.append(value)
        points = [(memory[vertices + i * 2], memory[vertices + i * 2 + 1])
                  for i in range(highest + 1)]
        shapes.append({
            "shape": shape,
            "name": SHAPE_NAMES.get(shape, "Shape $%02X" % shape),
            "half_width": memory[entry],
            "half_height": memory[entry + 1],
            "vertices": vertices,
            "edges": edges,
            "points": points,
            "lines": sum(len(g) - 1 for g in groups),
            "rooms": rooms_by_shape[shape],
        })
    return shapes


def render_shapes(snapshot: Path, shapes: list[dict], out_dir: Path) -> None:
    """Draw one room of each shape with the game's own code.

    Rather than reimplementing the vector format, this puts a room number in
    $EA91 and runs the redraw entry, so the picture is whatever the real thing
    would have drawn. Only the 24x24 cells of the play area are captured,
    which leaves the status panel out.
    """
    from skoolkit import CSimulator, read_bin_file
    from skoolkit.components import get_image_writer
    from skoolkit.graphics import Frame, scr_udgs
    from skoolkit.simulator import Simulator
    from skoolkit.simutils import T
    from skoolkit.trace import Tracer

    out_dir.mkdir(parents=True, exist_ok=True)
    memory = machine_memory(snapshot)
    simulator = (CSimulator or Simulator)(
        memory, state={"iff": 0, "im": 1, "tstates": 0})
    simulator.set_tracer(Tracer(simulator, 0, 0, 0, [0] * 16, 0, False))
    writer = get_image_writer()

    _log(f"Drawing one room of each of the {len(shapes)} outlines...")
    for entry in shapes:
        simulator.memory[CURRENT_ROOM] = entry["rooms"][0]
        simulator.registers[24] = STACK
        simulator.trace(REDRAW_ROOM, REDRAW_DONE, 0,
                        simulator.registers[T] + 20_000_000,
                        False, None, None, None, None, None)
        frame = Frame(scr_udgs(simulator.memory, 0, 0, 24, 24), 1)
        with open(out_dir / ("shape%02X.png" % entry["shape"]), "wb") as f:
            writer.write_image([frame], f)


def _and_list(items: list[str]) -> str:
    """a, b and c."""
    if len(items) < 3:
        return " and ".join(items)
    return ", ".join(items[:-1]) + " and " + items[-1]


def write_shapes_ref(shapes: list[dict], path: Path) -> None:
    """A generated ref file documenting each room outline.

    Generated rather than committed because every number in it is read out of
    the game's own tables; the hand-written prose lives in scripts/aticatac.ref.
    """
    shared: dict[int, list[int]] = {}
    for entry in shapes:
        shared.setdefault(entry["edges"], []).append(entry["shape"])

    # This file supplies only [Page:RoomTypes] and the content sections. The
    # page's title, header, link text and its place in the index all live in
    # scripts/aticatac.ref, because ref file sections do not merge across
    # files: when two of them declare the same section, SkoolKit keeps the one
    # it parsed first and silently ignores the other.
    lines = [
        "; Generated by scripts/build_aticatac.py -- do not edit.",
        "",
        "[Page:RoomTypes]",
        "SectionPrefix=RoomTypes",
        "",
        "[RoomTypes:intro:Ten outlines for 149 rooms]",
        "Every room in the castle is one of these ten shapes in one of six"
        " colours. A room's own entry in ROOM_TABLE is just those two bytes,"
        " and the shape number selects the geometry below -- which is what lets"
        " 149 rooms cost barely more than 300 bytes between them.",
        "Each outline is a list of points and a list of lines between them,"
        " drawn by DRAW_OUTLINE. The pictures are the game's own: a room number"
        " goes into $EA91, the redraw at $9147 runs, and the 24 by 24 cells of"
        " the play area are captured with the status panel left out.",
    ]
    for edges, group in sorted(shared.items()):
        if len(group) > 1:
            lines.append(
                "Shapes " + _and_list(["$%02X" % s for s in group])
                + " share the edge list at $%04X" % edges
                + " -- the same topology over a different set of points, which"
                " is how the wide and tall variants come for free.")

    for entry in shapes:
        shape = entry["shape"]
        rooms = entry["rooms"]
        lines += [
            "",
            "[RoomTypes:shape%02X:$%02X &mdash; %s]" % (shape, shape, entry["name"]),
            '<img src="images/shapes/shape%02X.png" width="192"'
            ' alt="room shape $%02X" style="float:right;margin-left:12px"/>'
            % (shape, shape),
            '<table class="default">',
            "<tr><th>Rooms with this outline</th><td>%d of %d</td></tr>"
            % (len(rooms), ROOM_TABLE_ENTRIES),
            "<tr><th>Player may walk from centre</th><td>%d across, %d down</td></tr>"
            % (entry["half_width"], entry["half_height"]),
            "<tr><th>Vertex table</th><td>$%04X, %d points</td></tr>"
            % (entry["vertices"], len(entry["points"])),
            "<tr><th>Edge list</th><td>$%04X, %d lines</td></tr>"
            % (entry["edges"], entry["lines"]),
            "</table>",
            "Used by rooms " + ", ".join("$%02X" % r for r in rooms) + ".",
        ]
        if len(entry["points"]) <= 16:
            lines.append("Points: "
                         + ", ".join("(%d,%d)" % p for p in entry["points"]) + ".")
        else:
            lines.append("Drawn from %d points, too many to list here."
                         % len(entry["points"]))
        lines.append('<div style="clear:both"></div>')
    lines.append("")
    path.write_text(NEWLINE.join(lines), encoding="utf-8")


# Sprite catalogue -----------------------------------------------------------
#
# Every actor is drawn from its sprite byte, and that same byte chooses its
# handler, so the two catalogues are really one: the pictures below are grouped
# by the routine that drives them.

ACTOR_HANDLERS = 0x7EE6
# Codes above $A1 are in the handler table but draw nothing recognisable --
# fragments of a few pixels rather than pictures -- so the catalogue stops
# there rather than filling itself with noise.
SPRITE_CODE_MAX = 0xA1
# Where a sprite is drawn for its portrait, and the window captured around it.
SPRITE_X, SPRITE_Y = 0x40, 0x70
SPRITE_WINDOW = (7, 7, 10, 8)      # character cells: x, y, width, height
# DRAW_TITLE_ICONS draws one record; entering at its two CALLs draws whatever
# has been put in UI_RECORD, which is how a sprite is rendered on its own.
DRAW_ONE_SPRITE = 0xA325
DRAW_ONE_SPRITE_DONE = 0xA32B
UI_RECORD = 0xA17D


def annotation_labels() -> dict:
    """Routine names from the annotations file, keyed by address."""
    labels = {}
    if ANNOTATIONS.exists():
        for line in ANNOTATIONS.read_text(encoding="utf-8").splitlines():
            match = re.match(r"^@ \$([0-9A-F]{4}) label=(\w+)", line)
            if match:
                labels[int(match.group(1), 16)] = match.group(2)
    return labels


def read_sprite_groups(snapshot: Path) -> list[dict]:
    """Sprite codes grouped by the handler ACTOR_HANDLERS sends them to."""

    memory = game_memory(snapshot)
    labels = annotation_labels()
    groups, current = [], None
    for code in range(1, SPRITE_CODE_MAX + 1):
        entry = ACTOR_HANDLERS + code * 2
        handler = memory[entry] | (memory[entry + 1] << 8)
        if current is None or handler != current["handler"]:
            current = {"handler": handler,
                       "name": labels.get(handler, "$%04X" % handler),
                       "named": handler in labels,
                       "codes": []}
            groups.append(current)
        current["codes"].append(code)
    return groups


def render_sprites(snapshot: Path, out_dir: Path,
                   required: set = frozenset()) -> set:
    """Draw each sprite on its own, with the game's own drawing code.

    The same approach as the room pictures: rather than decoding the sprite
    format, put the code into UI_RECORD and run the two calls DRAW_TITLE_ICONS
    makes, so what comes out is whatever the real thing would have drawn.
    Returns the codes that drew anything -- a handful are sound effects or
    animations with no picture of their own.
    """
    from skoolkit import CSimulator, read_bin_file
    from skoolkit.components import get_image_writer
    from skoolkit.graphics import Frame, scr_udgs
    from skoolkit.simulator import Simulator
    from skoolkit.simutils import IXh, IXl, T
    from skoolkit.trace import Tracer

    out_dir.mkdir(parents=True, exist_ok=True)
    memory = machine_memory(snapshot)
    simulator = (CSimulator or Simulator)(
        memory, state={"iff": 0, "im": 1, "tstates": 0})
    simulator.set_tracer(Tracer(simulator, 0, 0, 0, [0] * 16, 0, False))
    writer = get_image_writer()

    # Every code the graphics table has an entry for, not just the ones the
    # handler table drives: the disassembly puts a picture beside each block
    # of graphics bytes, and those run well past the last handler.
    _log(f"Drawing {GFX_TABLE_ENTRIES} sprites...")
    drawn = set()
    for code in range(1, GFX_TABLE_ENTRIES + 1):
        for address in range(0x4000, 0x5B00):
            simulator.memory[address] = 0
        for offset, value in enumerate(
                (code, 0, 0, SPRITE_X, SPRITE_Y, 0x47, 0, 0)):
            simulator.memory[UI_RECORD + offset] = value
        simulator.registers[IXl] = UI_RECORD & 0xFF
        simulator.registers[IXh] = UI_RECORD >> 8
        simulator.registers[24] = STACK
        simulator.trace(DRAW_ONE_SPRITE, DRAW_ONE_SPRITE_DONE, 0,
                        simulator.registers[T] + 5_000_000,
                        False, None, None, None, None, None)
        if not any(simulator.memory[0x4000:0x5800]):
            continue
        drawn.add(code)
        frame = Frame(scr_udgs(simulator.memory, *SPRITE_WINDOW), 1)
        with open(out_dir / ("sprite%02X.png" % code), "wb") as f:
            writer.write_image([frame], f)
    _log(f"  {len(drawn)} of {GFX_TABLE_ENTRIES} codes draw a picture")
    missing = sorted(set(required) - drawn)
    if missing:
        raise SystemExit(
            "the disassembly links %d sprite image(s) that nothing drew: %s. "
            "graphics_blocks and render_sprites disagree about which codes "
            "have a picture, and the pages would carry broken images."
            % (len(missing), ", ".join("$%02X" % c for c in missing)))
    return drawn


# Sprite graphics -------------------------------------------------------------
#
# SPRITE_TABLE gives the address; the first byte there gives the height, and
# every sprite is two bytes -- sixteen pixels -- wide. That was not guessed:
# each code was drawn on a machine of its own with the reads into the graphics
# region logged, and all 235 that draw read exactly `1 + 2 * height` bytes,
# contiguously, starting at the address the table holds. So the extents below
# are computed from the table rather than traced, and are known to match what
# the game itself reads.

GFX_TABLE = 0xA4BE
GFX_TABLE_ENTRIES = 239
GFX_FIRST = 0xA69C
# Two formats, and which one applies is decided by the sprite code rather than
# by where the bytes are. Codes up to SPRITE_CODE_MAX are the creatures and
# objects the handler table drives: two bytes -- sixteen pixels -- wide, with a
# single byte of row count. Above it are the pieces the rooms are furnished
# with, drawn by different code, and those carry a width as well as a height.
# Read the wide ones as narrow and they come out nine bytes long instead of a
# hundred and thirty, and the rest of each looks like unreferenced artwork.
# With this rule the 194 graphics tile their region, the only gaps are the
# tables and fonts that genuinely sit among them, and the last one ends exactly
# where TAIL_PADDING begins.


# Sprite pictures are built by SkoolKit from the game's own bytes rather than
# drawn by a simulator and pasted in, so a picture and the DEFBs beside it
# cannot disagree. Taken from pobtastic's Atic Atac disassembly at
# skoolkit.arcadegeek.co.uk, which does it far more neatly than a page of <img>
# tags -- though the macro syntax below is SkoolKit 10's, where the UDG
# specifications go in brackets rather than after a semicolon as in 9.x.
SPRITE_SCALE = 4
SPRITE_ATTR = 0x47
# The game moves a walking character on every fourth frame, so a little over
# ten frames a second. #FRAMES delays are in hundredths.
FRAME_DELAY = 12
# The objects and monsters in the initial-state template, which are eight
# bytes each. The doors after them are sixteen and would not line up.
TEMPLATE_RECORDS = 0x6025
TEMPLATE_DOORS = 0x645D


def sprite_graphic(memory, code: int):
    """Where a sprite code's picture is, and how big: (address, header, width,
    rows). None if the code has no well-formed graphic."""
    if not 1 <= code <= GFX_TABLE_ENTRIES:
        return None
    entry = GFX_TABLE + (code - 1) * 2
    address = memory[entry] | (memory[entry + 1] << 8)
    if not GFX_FIRST <= address < GAME_END:
        return None
    if code > SPRITE_CODE_MAX:
        width, rows, header = memory[address], memory[address + 1], 2
    else:
        width, rows, header = 2, memory[address], 1
    if width == 0 or rows == 0 or address + header + width * rows > GAME_END:
        return None
    return address, header, width, rows


def udgarray(address: int, header: int, width: int, rows: int, name: str,
             limit: int = None, wrap: bool = True,
             attr: int = SPRITE_ATTR) -> str:
    """A #UDGARRAY that draws one graphic straight out of the snapshot.

    The bytes are row-major and `width` wide, so a UDG takes every `width`th
    byte, consecutive UDGs are one byte apart, and the next band of UDGs starts
    `width * 8` bytes on. The array always comes out a whole number of cells
    tall, so it is cropped back to the real height.
    """
    start = address + header
    end = (limit if limit is not None else address + header + width * rows) - 1
    # The rows are stored bottom up, so the array is flipped vertically. That
    # pushes the padding -- the array is always a whole number of cells tall --
    # from the bottom to the top, so the crop starts below it rather than at 0.
    top = SPRITE_SCALE * ((8 - rows % 8) % 8)
    # Wrapped in #HTML because the same comments go through skool2asm, which
    # has no way to render an image and refuses the macro outright.
    macro = "#UDGARRAY%d,%d,%d,%d,,2($%04X-$%04X-1-%d){0,%d,%d,%d}(%s)" % (
        width, attr, SPRITE_SCALE, width, start, end, width * 8,
        top, width * 8 * SPRITE_SCALE, rows * SPRITE_SCALE, name)
    return "#HTML(%s)" % macro if wrap else macro


def graphics_blocks(snapshot: Path) -> tuple[str, list[Span]]:
    """A control file naming every sprite's graphics, and the spans it covers.

    Returned rather than written into the annotations file because it is
    derived entirely from the table: 194 blocks of bytes that no one wants to
    maintain by hand.
    """

    memory = game_memory(snapshot)
    named = sprite_names()

    def depicted(code):
        for low, high, name in named:
            if low <= code <= high:
                return name
        return None

    owners = {}
    for code in range(1, GFX_TABLE_ENTRIES + 1):
        entry = GFX_TABLE + (code - 1) * 2
        address = memory[entry] | (memory[entry + 1] << 8)
        if not GFX_FIRST <= address < GAME_END:
            continue
        if code > SPRITE_CODE_MAX:
            width, rows = memory[address], memory[address + 1]
            if width == 0 or rows == 0 or address + 2 + width * rows > GAME_END:
                continue
        else:
            width, rows = 2, memory[address]
            if rows == 0 or address + 1 + rows * 2 > GAME_END:
                continue
        owners.setdefault(address, (width, rows, []))[2].append(code)

    lines = ["; Generated by scripts/build_aticatac.py -- do not edit.", ""]
    spans = []
    starts = sorted(owners)
    for index, address in enumerate(starts):
        width, rows, codes = owners[address]
        wide = codes[0] > SPRITE_CODE_MAX
        header = 2 if wide else 1
        end = address + header + width * rows
        # A few graphics overlap: $C219 is eighteen rows, but $C23A -- another
        # sprite's first byte -- falls four bytes inside it, and the traces
        # confirm the game really does read both ranges. Stop the block where
        # the next one starts, or the two would claim the same bytes and the
        # listing would silently come out shorter than the description.
        limit = starts[index + 1] if index + 1 < len(starts) else GAME_END
        shared = max(0, end - limit)
        if shared:
            end = limit
        spans.append((address, end))
        first = codes[0]
        name = depicted(first)
        shown = ", ".join("$%02X" % c for c in codes)
        title = ("%s, drawn for sprite %s" % (name, shown) if name
                 else "The graphics for sprite %s" % shown)
        lines.append("@ $%04X label=GFX_%02X" % (address, first))
        lines.append("b $%04X %s" % (address, title))
        if wide:
            lines.append("D $%04X %d rows of %d pixels. The first two bytes are "
                         "the width in bytes and the height in rows; the rest "
                         "are the rows, top down." % (address, rows, width * 8))
        else:
            lines.append("D $%04X %d rows of 16 pixels. The first byte is the "
                         "row count; the rest are the rows, two bytes each, "
                         "top down." % (address, rows))
        if len(codes) > 1:
            lines.append("D $%04X Shared by %d codes, which is how the game "
                         "gets a mirrored or repeated frame without a second "
                         "copy of the picture." % (address, len(codes)))
        if shared:
            lines.append("D $%04X The last %d byte%s of it are also the start "
                         "of the next graphic, at $%04X, which begins inside "
                         "this one. Both are real: running the game's own "
                         "drawing code for each sprite reads each range in "
                         "full. The listing below stops at $%04X so the two "
                         "blocks do not claim the same bytes, so it is %d row%s "
                         "short of the %d this graphic actually has."
                         % (address, shared, "" if shared == 1 else "s", limit,
                            limit, (shared + width - 1) // width,
                            "" if shared < width * 2 else "s", rows))
        if any(memory[address + header:end]):
            lines.append("D $%04X %s" % (address, udgarray(
                address, header, width, rows, "gfx%02X" % first, end)))
        else:
            lines.append("D $%04X Every byte is zero, so this one draws nothing "
                         "-- a blank frame in an animation." % address)
        available = end - address - header
        lines.append("B $%04X,%d,%d" % (address, header, header))
        if available >= width:
            lines.append("B $%04X,%d,%d"
                         % (address + header, available - available % width,
                            width))
        if available % width:
            lines.append("B $%04X,%d,%d"
                         % (end - available % width, available % width,
                            available % width))
        lines.append("")
    return NEWLINE.join(lines), spans


def room_list_blocks(snapshot: Path) -> tuple[str, list[Span]]:
    """One block per room's contents list, and the spans they cover.

    ROOM_CONTENTS is only the index; the lists themselves follow it and run to
    $7C18, the byte before the game's entry point, with no gaps at all. Each is
    a run of record addresses ended by a zero, and each address is a template
    one, so it needs the same +$8A83 relocation POPULATE_ROOM applies.
    """

    memory = game_memory(snapshot)
    lines = ["", "; Room contents lists.", ""]
    spans = []
    for room in range(ROOM_LIST_ENTRIES):
        entry = ROOM_CONTENTS + room * 2
        address = memory[entry] | (memory[entry + 1] << 8)
        count = 0
        while memory[address + count * 2] | (memory[address + count * 2 + 1] << 8):
            count += 1
        length = count * 2 + 2
        spans.append((address, address + length))
        lines.append("@ $%04X label=ROOM_LIST_%02X" % (address, room))
        lines.append("b $%04X What is in room $%02X" % (address, room))
        if count:
            lines.append("D $%04X %d record%s, then a zero to end the list. "
                         "Add $8A83 to each to get where it ends up at run "
                         "time." % (address, count, "" if count == 1 else "s"))
        else:
            lines.append("D $%04X Nothing at all: just the terminator. An empty "
                         "room." % address)
        lines.append("W $%04X,%d,2" % (address, length))
        lines.append("")
    return NEWLINE.join(lines), spans


SHAPE_COUNT = 13


def shape_blocks(snapshot: Path) -> tuple[str, list[Span]]:
    """The vertex tables and edge lists behind every room outline.

    Neither carries a length. An edge list ends at a doubled $FF, and a vertex
    table holds one point for every index the edge list mentions -- which is
    exactly right, because with those lengths the thirteen shapes' tables tile
    their region without leaving a byte over.
    """

    memory = game_memory(snapshot)
    used = set()
    for room in range(ROOM_TABLE_ENTRIES):
        used.add(memory[ROOM_TABLE + room * 2 + 1])

    regions = {}
    for shape in range(SHAPE_COUNT):
        entry = ROOM_SHAPES + shape * 6
        vertices = memory[entry + 2] | (memory[entry + 3] << 8)
        edges = memory[entry + 4] | (memory[entry + 5] << 8)
        address, in_group, highest = edges, False, -1
        while True:
            value = memory[address]
            address += 1
            if value == 0xFF:
                if not in_group:
                    break
                in_group = False
                continue
            highest = max(highest, value)
            in_group = True
        regions.setdefault(("edges", edges), [address - edges, []])[1].append(shape)
        regions.setdefault(("vertices", vertices),
                           [(highest + 1) * 2, []])[1].append(shape)

    lines = ["", "; Room outlines.", ""]
    spans = []
    for (kind, address), (length, shapes) in sorted(regions.items(),
                                                    key=lambda kv: kv[0][1]):
        spans.append((address, address + length))
        shown = ", ".join("$%02X" % s for s in shapes)
        unused = [s for s in shapes if s not in used]
        lines.append("@ $%04X label=SHAPE_%s_%02X"
                     % (address, kind.upper()[:5], shapes[0]))
        if kind == "edges":
            lines.append("b $%04X Which corners to join up, for shape %s"
                         % (address, shown))
            lines.append("D $%04X Groups of vertex numbers, each closed by an "
                         "$FF, and a second $FF ends the list. DRAW_OUTLINE "
                         "draws from the first number in a group to each of "
                         "the others in turn." % address)
        else:
            lines.append("b $%04X The corners of shape %s" % (address, shown))
            lines.append("D $%04X %d points, x then y, indexed by the numbers "
                         "in the edge list." % (address, length // 2))
        if len(shapes) > 1:
            lines.append("D $%04X Shared by %d shapes, which is how a room and "
                         "its mirror image are drawn from one description."
                         % (address, len(shapes)))
        if unused:
            lines.append("D $%04X Nothing in ROOM_TABLE uses shape %s. That is "
                         "not the same as never drawn -- the table's last entry "
                         "is the trapdoor fall rather than a room -- but for "
                         "these there is no entry at all."
                         % (address, ", ".join("$%02X" % s for s in unused)))
        lines.append("B $%04X,%d,%d" % (address, length,
                                        2 if kind == "vertices" else 8))
        lines.append("")
    return NEWLINE.join(lines), spans


_SUBBLOCK_RE = re.compile(r"^([BWT]) \$([0-9A-F]{4}),(\d+)")


def check_structure(sources: list, generated_ctl: str) -> None:
    """Fail the build if the spans and sub-blocks do not describe one layout.

    The round-trip check cannot see any of this. A table sliced into pieces, a
    block whose sub-blocks stop short of its span, two blocks claiming the same
    bytes -- all of them still reassemble byte-for-byte, because the bytes are
    all there and in order. The only symptom is that the disassembly quietly
    describes less than it did before, which is how a span returned as
    (start, length) rather than (start, end) went unnoticed while it undid
    about seven per cent of the coverage.
    """
    problems = []

    ordered = sorted((start, end, name)
                     for name, spans in sources for start, end in spans)
    for (start, end, name), (next_start, _, next_name) in zip(ordered,
                                                              ordered[1:]):
        if next_start < end:
            problems.append(
                "$%04X-$%04X from %s overlaps $%04X from %s by %d byte(s)"
                % (start, end - 1, name, next_start, next_name,
                   end - next_start))

    lengths = {start: end - start
               for name, spans in sources for start, end in spans}
    block, covered = None, 0
    for line in generated_ctl.splitlines() + ["b $0000 end"]:
        match = _BLOCK_RE.match(line)
        if match:
            if block is not None and covered != lengths.get(block, covered):
                problems.append(
                    "the block at $%04X covers %d byte(s) but its span is %d"
                    % (block, covered, lengths[block]))
            block, covered = int(match.group(1), 16), 0
            continue
        match = _SUBBLOCK_RE.match(line)
        if match and block is not None:
            start, length = int(match.group(2), 16), int(match.group(3))
            if start != block + covered:
                problems.append(
                    "the sub-block at $%04X in the block at $%04X should start "
                    "at $%04X" % (start, block, block + covered))
            covered += length

    if problems:
        for problem in problems:
            _log(f"  STRUCTURE: {problem}")
        raise SystemExit(
            f"{len(problems)} structural problem(s) in the generated control "
            f"file -- see above. Nothing is wrong with the bytes; the "
            f"disassembly would still reassemble. What is wrong is what it "
            f"claims about them.")
    _log(f"  {len(ordered)} spans, no overlaps, every sub-block accounted for")


def linked_sprite_codes(ctl: Path) -> set:
    """The sprite codes the generated blocks put a picture beside.

    graphics_blocks decides from the bytes -- a graphic that is all zeros draws
    nothing, so it gets a sentence instead of an image. render_sprites decides
    by running the game and seeing whether anything landed on the screen. Two
    rules for one question, and if they ever disagree the disassembly links an
    image that was never rendered. Reading the codes back out of the control
    file makes the published pages the authority, and lets render_sprites check
    it drew everything they ask for.
    """
    return {int(code, 16) for code in
            re.findall(r"images/sprites/sprite([0-9A-F]{2})\.png",
                       ctl.read_text(encoding="utf-8"))}


def entry_addresses(ctl: Path) -> set:
    """Addresses that begin a disassembly entry.

    #R only resolves against those. Several handlers in the table are entered
    part-way into a routine, and pointing #R at one of them fails the whole
    build, so those are written as plain addresses instead.
    """
    entries = set()
    for line in ctl.read_text(encoding="utf-8").splitlines():
        match = re.match(r"^[bctwsi] \$([0-9A-F]{4})", line)
        if match:
            entries.add(int(match.group(1), 16))
    return entries


def sprite_names() -> list:
    """What each run of sprite codes actually depicts.

    Declared in the annotations file as `; sprite $4C-$4D Pumpkin`. They are
    kept separate from the routine labels because the two do not line up: one
    handler often drives several creatures -- MOVE_ACTOR is both the pumpkin
    and the spider -- and one group of codes can hold two pictures, as the
    keyboard and joystick icons do.
    """
    names = []
    if ANNOTATIONS.exists():
        for line in ANNOTATIONS.read_text(encoding="utf-8").splitlines():
            match = re.match(
                r"^;\s*sprite\s+\$([0-9A-F]{2})(?:-\$([0-9A-F]{2}))?\s+(.+?)\s*$",
                line)
            if match:
                low = int(match.group(1), 16)
                high = int(match.group(2), 16) if match.group(2) else low
                names.append((low, high, match.group(3)))
    return names


def walk_cycles(codes: list, addresses: dict) -> list:
    """Split a run of frames into the separate headings it holds.

    A creature that walks has one set of frames per heading, laid out one after
    another, and each set is a cycle whose fourth frame reuses the second's
    picture -- there are only three drawings in a four-frame walk. Where that
    pattern holds all the way through, the run is split on it; where it does
    not, the run is left as one row.
    """
    if len(codes) < 8 or len(codes) % 4:
        return [codes]
    groups = [codes[i:i + 4] for i in range(0, len(codes), 4)]
    for group in groups:
        if addresses[group[1]] != addresses[group[3]]:
            return [codes]
    return groups


def sprite_attributes(memory) -> dict:
    """The colour the game gives each creature, read out of INITIAL_STATE.

    An actor record's +$05 is its attribute, and the objects and monsters in
    the template are eight bytes each, so the colour of anything that starts
    the game somewhere can simply be read off. They come out as bright ink on
    black paper, $42 to $47, which is the palette PAINT_PANEL works in: the
    mummy white, Frankenstein red, the devil magenta, Dracula green.

    Only where every record agrees. Anything else -- the player, whose colour
    comes from the character chosen, and anything not placed at the start --
    keeps the default.
    """
    found = {}
    for address in range(TEMPLATE_RECORDS, TEMPLATE_DOORS, 8):
        code, attr = memory[address], memory[address + 5]
        if code and attr:
            found.setdefault(code, set()).add(attr)
    return {code: attrs.pop() for code, attrs in found.items()
            if len(attrs) == 1}


def write_sprites_ref(groups: list[dict], snapshot: Path, entries: set,
                      path: Path) -> None:
    """A generated ref file cataloguing the sprites, grouped by handler.

    Every picture on the page is a #UDGARRAY over the game's own bytes, and a
    run of frames also gets a #FRAMES animation at the pace the game plays it,
    so the creatures walk.
    """
    memory = game_memory(snapshot)
    colours = sprite_attributes(memory)
    named_ranges = sprite_names()

    def picture(code):
        graphic = sprite_graphic(memory, code)
        if graphic is None:
            return None
        address, header, width, rows = graphic
        if not any(memory[address + header:address + header + width * rows]):
            return None
        return graphic

    drawn = {c for c in range(1, SPRITE_CODE_MAX + 1) if picture(c)}

    def depicted(code):
        for low, high, name in named_ranges:
            if low <= code <= high:
                return name
        return None

    lines = [
        "; Generated by scripts/build_aticatac.py -- do not edit.",
        "",
        "[Page:Sprites]",
        "SectionPrefix=Sprites",
        "",
        "[Sprites:intro:One byte, two jobs]",
        "An actor's +$00 is both what it looks like and what it does: it"
        " indexes ACTOR_HANDLERS to find the routine that drives it, and it"
        " selects the picture drawn for it. So the sprites are catalogued here"
        " in the order the handler table groups them, which is why the frames"
        " of one creature sit together.",
        "Every picture here is drawn by SkoolKit straight out of the game's"
        " own bytes, so a sprite and the DEFBs listed for it cannot disagree."
        " Where a run of frames is a walk, each heading gets its own row and"
        " an animation at the pace the game plays it -- a step every fourth"
        " frame. A four-frame walk holds only three drawings: the fourth"
        " frame points at the second one's picture rather than a copy of it.",
        "Codes $01 to $%02X are the pictures; %d of them draw something, and"
        " the rest are entries whose handler is a sound effect, or an"
        " animation that draws itself -- $66 and $67, the sinking and rising"
        " the player does on dying, have no picture of their own. Codes above"
        " $%02X are the pieces the rooms are furnished with, drawn by"
        " different code from a format that carries a width as well; those are"
        " listed with the data rather than here." % (SPRITE_CODE_MAX,
                                                     len(drawn),
                                                     SPRITE_CODE_MAX),
    ]
    for group in groups:
        shown = [c for c in group["codes"] if c in drawn]
        if not shown:
            continue
        # One handler can drive several creatures, and one run of codes can
        # hold more than one picture, so split the run wherever the name does.
        runs, current = [], None
        for code in shown:
            name = depicted(code)
            if current is None or name != current[0]:
                current = (name, [code])
                runs.append(current)
            else:
                current[1].append(code)
        handler = group["handler"]
        for name, codes in runs:
            first, last = codes[0], codes[-1]
            span = "$%02X" % first if first == last else "$%02X-$%02X" % (first, last)
            title = "%s &mdash; %s" % (span, name) if name else \
                    "%s &mdash; %s" % (span, group["name"])
            lines += ["", "[Sprites:s%02X:%s]" % (first, title)]
            if handler not in entries:
                lines.append("Driven from part-way into the routine at $%04X."
                             % handler)
            elif group["named"]:
                lines.append("Driven by #R$%04X." % handler)
            else:
                lines.append("Driven by #R$%04X, which has not been named yet."
                             % handler)
            if name and len(codes) > 1 and len(
                    walk_cycles(codes, {c: picture(c)[0] for c in codes})) == 1:
                lines.append("%d frames." % len(codes))
            cycles = walk_cycles(codes, {c: picture(c)[0] for c in codes})
            if len(cycles) > 1:
                lines.append("%d headings of %d frames."
                             % (len(cycles), len(cycles[0])))
            columns = max(len(cycle) for cycle in cycles)
            lines.append("#UDGTABLE")
            lines.append("{ " + " | ".join(
                "=h Frame %d" % (i + 1) for i in range(columns))
                + " | =h Animated }")
            for cycle in cycles:
                row = []
                for code in cycle:
                    address, header, width, rows = picture(code)
                    # Drawing the frame here both puts it in the cell and names
                    # it, so #FRAMES can pick it up. The animation is the last
                    # column because its frames have to exist by then.
                    row.append("%s<div style=\"font-size:11px\">$%02X</div>"
                               % (udgarray(address, header, width, rows,
                                           "sprite%02X*f%02X" % (code, code),
                                           wrap=False,
                                           attr=colours.get(code, SPRITE_ATTR)),
                                  code))
                row += [""] * (columns - len(row))
                # #FRAMES needs every frame the same size, and a few runs mix
                # heights, so those get their stills and no animation.
                if len(cycle) > 1 and len({picture(c)[2:] for c in cycle}) == 1:
                    row.append("#FRAMES(%s)(anim%02X)" % (
                        ";".join("f%02X,%d" % (c, FRAME_DELAY) for c in cycle),
                        cycle[0]))
                else:
                    row.append("")
                lines.append("{ " + " | ".join(x or "&nbsp;" for x in row) + " }")
            lines.append("UDGTABLE#")
    lines.append("")
    path.write_text(NEWLINE.join(lines), encoding="utf-8")


# Sound effects ---------------------------------------------------------------
#
# Recorded by running the routine and capturing the writes to bit 4 of port
# $FE, which is the only way a 48K makes a noise. Everything here is the
# game's own code making its own sound; nothing is synthesised.

FRAME_TSTATES = 69888
# Somewhere harmless to leave a return address, so a forced call has something
# to come back to and the capture knows when the routine has finished.
SOUND_SENTINEL = 0x0008
SOUND_STACK = 0x5DFC

# (file, entry, B, C, title, description). B and C are None where the routine
# sets them itself.
SOUND_EFFECTS = [
    ("footstep_low", 0xA3AA, 0x60, 0x04, "Footstep, the low one",
     "$6004 -- four cycles of half-period $60, from the branch at $A3DB."),
    ("footstep_high", 0xA3AA, 0x40, 0x04, "Footstep, the high one",
     "$4004, from the branch at $A3D3. SOUND_FOOTSTEP alternates the two."),
    ("bonus", 0xA3E0, None, None, "The bonus note",
     "Played by FLASH_SCORE every sixteenth step of its countdown."),
    ("spell_A445", 0xA445, None, None, "The wizard's spell",
     "Its starting pitch comes from $5E25, the number of actors in the room,"
     " so it is never quite the same twice."),
    ("spell_A4B0", 0xA4B0, None, None, "The spell's second sound",
     "The other of the two SPIN_SPELL makes."),
    ("sweep_up", 0xA427, None, None, "A rising sweep",
     "Sixteen calls to BEEP with the pitch walked upwards."),
    ("sweep_down", 0xA438, None, None, "A falling blip",
     "Eight steps with the pitch complemented, so it falls."),
    ("sweep_A41B", 0xA41B, None, None, "The sweep at $A41B", "Reached from $8134."),
    ("noise_burst", 0xA46E, None, None, "A rasp",
     "119 edges in eight milliseconds with the gaps swinging wildly -- not a"
     " note at all. Reached from $917D."),
    ("beep_one_cycle", 0xA3A8, 0x40, 0x01, "One cycle of BEEP",
     "The smallest sound the game can make: a single square wave."),
]


def _capture_sound(sim, tracer, entry, b, c, seconds=3.0):
    """Run one routine from a clean machine and return its beeper edges."""
    from skoolkit.simutils import B, C, T

    tracer.audio_log.clear()
    sim.memory[SOUND_STACK] = SOUND_SENTINEL & 0xFF
    sim.memory[SOUND_STACK + 1] = SOUND_SENTINEL >> 8
    sim.registers[24] = SOUND_STACK
    if b is not None:
        sim.registers[B], sim.registers[C] = b, c
    start = sim.registers[T]
    sim.trace(entry, SOUND_SENTINEL, 0, start + int(seconds * TSTATES_PER_SECOND),
              False, None, None, None, None, None)
    return tracer.get_delays(), sim.registers[T] - start


def record_sounds(snapshot: Path, out_dir: Path) -> list[dict]:
    """Write a WAV of every sound effect, plus the footstep at its real pace.

    Each is captured on a machine of its own. Running them one after another on
    a shared one lets each inherit whatever the last left behind, which is how
    an eight-millisecond rasp was once measured as a full second of sweep.
    """
    from skoolkit import CSimulator, read_bin_file
    from skoolkit.audio import BeeperOptions
    from skoolkit.components import get_audio_writer
    from skoolkit.simulator import Simulator
    from skoolkit.trace import Tracer

    out_dir.mkdir(parents=True, exist_ok=True)
    rom = read_bin_file(str(ROM))
    writer = get_audio_writer()
    options = BeeperOptions(100, False, False, 0, False)
    base = game_memory(snapshot)
    recorded, tones = [], {}

    _log(f"Recording {len(SOUND_EFFECTS)} sound effects...")
    for name, entry, b, c, title, description in SOUND_EFFECTS:
        memory = list(base)
        memory[:0x4000] = rom
        simulator = (CSimulator or Simulator)(
            memory, state={"iff": 0, "im": 1, "tstates": 0})
        tracer = Tracer(simulator, 0, 0, 0, [0] * 16, 0, True)  # port_fe: log the beeper
        simulator.set_tracer(tracer)
        delays, ran = _capture_sound(simulator, tracer, entry, b, c)
        if not delays:
            continue
        tones[name] = delays
        with open(out_dir / (name + ".wav"), "wb") as f:
            writer.write_audio(f, delays, options)
        sounding = sum(delays)
        recorded.append({
            "file": name + ".wav", "title": title, "description": description,
            "entry": entry, "edges": len(delays) + 1,
            "ms": sounding / (TSTATES_PER_SECOND / 1000.0),
            "low": TSTATES_PER_SECOND / (2 * max(delays)),
            "high": TSTATES_PER_SECOND / (2 * min(delays)),
        })

    # The footstep as it is actually heard. SOUND_FOOTSTEP is called from the
    # every-fourth-frame branch of the character handlers and its counter
    # silences every other call, so a step lands every eight frames.
    low, high = tones.get("footstep_low"), tones.get("footstep_high")
    if low and high:
        period = FRAME_TSTATES * 8
        sequence, total, step = [], 0, 0
        while total + period <= TSTATES_PER_SECOND:
            tone = low if step % 2 == 0 else high
            sequence += tone + [period - sum(tone)]
            total += period
            step += 1
        with open(out_dir / "footstep.wav", "wb") as f:
            writer.write_audio(f, sequence, options)
        recorded.insert(0, {
            "file": "footstep.wav", "title": "Walking",
            "description": "The two tones at the pace they are really played:"
                           " a step every eight frames, %d ms apart, alternating"
                           " low and high. Almost all of it is silence, which is"
                           " what makes it read as footsteps rather than a tone."
                           % (period / (TSTATES_PER_SECOND / 1000.0)),
            "entry": 0xA3C7, "edges": len(sequence) + 1,
            "ms": total / (TSTATES_PER_SECOND / 1000.0), "low": 0, "high": 0,
        })
    return recorded


def write_sounds_ref(sounds: list[dict], entries: set, path: Path) -> None:
    """A generated ref file with a player for each effect."""
    lines = [
        "; Generated by scripts/build_aticatac.py -- do not edit.",
        "",
        "[Page:Sounds]",
        "SectionPrefix=Sounds",
        "",
        "[Sounds:intro:Everything the beeper does]",
        "A 48K has one bit of sound hardware -- bit 4 of port $FE -- and every"
        " noise in the game is made by toggling it and counting. BEEP does the"
        " toggling; the routines below choose the pitch and how long to hold it.",
        "These recordings are the game's own code running: each routine was"
        " called on a machine of its own and the writes to port $FE captured."
        " Nothing here is synthesised or approximated.",
        "There are two ways a sound gets started. Most are called directly and"
        " run to completion inside the call, which is why they are all a few"
        " milliseconds long -- the game is not doing anything else while they"
        " play. The rest are spawned as actors and glide over many frames; see"
        " the note on the architecture page.",
    ]
    for sound in sounds:
        lines += [
            "",
            "[Sounds:%s:%s]" % (sound["file"].replace(".wav", ""), sound["title"]),
            sound["description"],
            '<audio controls preload="none" src="audio/%s">'
            '<a href="audio/%s">%s</a></audio>' % (sound["file"], sound["file"],
                                                   sound["file"]),
        ]
        detail = "%.1f ms, %d edges" % (sound["ms"], sound["edges"])
        if sound["low"]:
            if round(sound["low"]) == round(sound["high"]):
                detail += ", %.0f Hz" % sound["low"]
            else:
                detail += ", %.0f to %.0f Hz" % (sound["low"], sound["high"])
        if sound["entry"] in entries:
            detail += " &mdash; #R$%04X" % sound["entry"]
        else:
            detail += " &mdash; $%04X" % sound["entry"]
        lines.append(detail + ".")
    lines.append("")
    path.write_text(NEWLINE.join(lines), encoding="utf-8")


# The one real bug -------------------------------------------------------------
#
# $971F holds $D4 -- "T" with the end marker set -- where it should hold $D3,
# so the screen shown to a player who escapes reads CONGRATULATIONT. Both
# screens below are drawn by running the game's own end-of-game routine; the
# only difference between them is that one byte.

VICTORY_SCREEN = 0x96EC
TYPO_ADDRESS = 0x971F
TYPO_SHIPPED = 0xD4
TYPO_FIXED = 0xD3


def render_victory_screens(snapshot: Path, out_dir: Path) -> None:
    """Draw the end-of-game screen as it ships, and with the typo corrected."""
    from skoolkit.components import get_image_writer
    from skoolkit.graphics import Frame, scr_udgs
    from skoolkit.simulator import Simulator
    from skoolkit.simutils import PC
    from skoolkit.trace import Tracer

    out_dir.mkdir(parents=True, exist_ok=True)
    writer = get_image_writer()
    _log("Drawing the end-of-game screen, as it ships and corrected...")
    for name, byte in (("shipped", TYPO_SHIPPED), ("fixed", TYPO_FIXED)):
        memory = machine_memory(snapshot)
        memory[TYPO_ADDRESS] = byte
        simulator = (Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
        simulator.set_tracer(Tracer(simulator, 0, 0, 0, [0] * 16, 0, False))
        for address in range(0x4000, 0x5B00):
            simulator.memory[address] = 0
        simulator.memory[SOUND_STACK] = SOUND_SENTINEL & 0xFF
        simulator.memory[SOUND_STACK + 1] = SOUND_SENTINEL >> 8
        simulator.registers[24] = SOUND_STACK
        simulator.registers[PC] = VICTORY_SCREEN
        for _ in range(3_000_000):
            simulator.run()
            if simulator.registers[PC] == SOUND_SENTINEL:
                break
        frame = Frame(scr_udgs(simulator.memory, 4, 2, 24, 5), 2)
        with open(out_dir / ("congratulations-%s.png" % name), "wb") as f:
            writer.write_image([frame], f)


def build_html(skool: Path, out: Path) -> None:
    """Render the skool file as a browsable HTML disassembly.

    -a makes the pages use the labels from the annotations file rather than
    bare addresses, so a call reads as CALL PLOT_TILE there too, and the #R
    macros in the ref file's prose resolve to links with those same names.
    """
    from skoolkit import skool2html

    _log("Writing HTML disassembly...")
    snapshot = OUT_DIR / "aticatac.z80"
    shapes = read_shapes(snapshot)
    shapes_ref = OUT_DIR / "aticatac-rooms.ref"
    write_shapes_ref(shapes, shapes_ref)
    args = ["-H", "-a", "-d", str(out), str(skool)]
    if REF.exists():
        args.append(str(REF))
    else:
        _log(f"  (no ref file at {REF} -- pages will be untitled)")
    args.append(str(shapes_ref))
    sprites_ref = OUT_DIR / "aticatac-sprites.ref"
    groups = read_sprite_groups(snapshot)
    write_sprites_ref(groups, snapshot,
                      entry_addresses(OUT_DIR / "aticatac.ctl"), sprites_ref)
    args.append(str(sprites_ref))
    sounds_ref = OUT_DIR / "aticatac-sounds.ref"
    sounds = record_sounds(snapshot, out / "aticatac" / "audio")
    write_sounds_ref(sounds, entry_addresses(OUT_DIR / "aticatac.ctl"), sounds_ref)
    args.append(str(sounds_ref))
    _capture(skool2html.main, args)
    render_shapes(snapshot, shapes, out / "aticatac" / "images" / "shapes")
    render_victory_screens(snapshot, out / "aticatac" / "images" / "bugs")


def verify(game_bytes: bytes, snapshot: Path) -> None:

    reference = bytes(game_memory(snapshot)[ENTRY:GAME_END])
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
    memory = list(game_memory(snapshot))
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
    parser.add_argument("--html", action="store_true",
                        help="also write a browsable HTML disassembly under "
                             "game_disassembly/aticatac/html/")
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
    if args.html:
        build_html(skool, OUT_DIR / "html")

    _log("")
    _log(f"Entry point: 0x{ENTRY:04X} (the game's own entry is 0x7C19)")
    _log(f"Wrote {asm}, {sld}, and {sna}")
    if args.html:
        _log(f"HTML disassembly: {OUT_DIR / 'html' / 'aticatac' / 'index.html'}")
    _log("Load roms/48.rom first (write_sna doesn't touch it), then this .sna + .sld.")


if __name__ == "__main__":
    main()
