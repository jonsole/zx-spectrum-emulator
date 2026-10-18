"""Cyberun's terrain steps, read from the source of its renderer in
examples/jetrun/cyberun.s (ADR 0007 there: Cyberun's code is in the repository
by the user's choice), and drawn the way that renderer draws them at fine
position 0.

A piece is a run of identical steps (see examples/jetrun/world.py). Cyberun
draws each step from a graphic: the flat floor and ceiling 3 bytes wide and 4
rows high, the slopes 1 or 2 bytes wide and as high as they rise (8 or 16
rows), the walls 1 byte wide and 16 rows. Every graphic holds three variants,
and step k of a piece uses variant column_varieties[k]. A graphic is stored as
the POP blitters read it: the bottom row left to right, the row above right to
left, and so on up. A step climbing left is its partner's graphic started one
row on, each byte's bits reversed. A flat run's first and last steps can be
end caps instead of variants (end codes with bit 4 set: cap number the low two
bits), and end code $16 draws only the last step's first column.

Checked against Cyberun's renderer itself: Jetrun's landscape_full, at 150
views of Cyberun's own world, every byte of the play area's inner part the
same (the session's stage A).

The pieces here are in a 256 x 256 page with its origin at (0, 0): x is the
left edge of the piece's lowest step, y that step's bottom line.
"""
from __future__ import annotations

import importlib.util
import re
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
JETRUN = HERE.parent / "jetrun"
# Cyberun's directions and their tables, from Jetrun's world.py, loaded under
# its own name (stepscroll has a world.py too).
_spec = importlib.util.spec_from_file_location("jetrun_world", JETRUN / "world.py")
JW = importlib.util.module_from_spec(_spec)
sys.modules["jetrun_world"] = JW
_spec.loader.exec_module(JW)

DIRECTIONS = JW.DIRECTIONS
DIRECTION_NUMBER = JW.DIRECTION_NUMBER
FIRST_COLUMN_ONLY = JW.FIRST_COLUMN_ONLY
TOGGLE_DIRECTIONS = JW.TOGGLE_DIRECTIONS
PAGE_W = 256

# Where the parity background puts a surface's crossing, relative to its
# step's bottom line, by TOGGLE_DIRECTIONS: on it, except a gentle slope one
# row lower. With these the background meets Cyberun's step graphics exactly
# (stage A: any other choice leaves stray bytes beside the steps).
CROSS_DY = [0, 1, 0, 0, 1, 0, 0]

REVERSED = [int(f"{b:08b}"[::-1], 2) for b in range(256)]


def _number(text: str) -> int:
    text = text.strip()
    return int(text[1:], 16) if text.startswith("$") else int(text)


def _read_source():
    """The bytes of Cyberun's step graphics by their address in Cyberun, and
    the tables the renderer draws them with."""
    lines = (JETRUN / "cyberun.s").read_text(encoding="utf-8").splitlines()
    memory: dict[int, int] = {}
    tables: dict[str, list[str]] = {}
    pos = None
    current = None
    for raw in lines:
        line = raw.split(";", 1)[0].rstrip()
        m = re.match(r"^([A-Za-z_][A-Za-z_0-9]*):", line)
        if m:
            label = m.group(1)
            a = re.match(r"cy_([0-9A-F]{4})$", label)
            if a:
                pos = int(a.group(1), 16)
            current = label
            tables.setdefault(label, [])
            continue
        if current is None:
            continue
        d = re.match(r"^\s+DEF([BWS])\s+(.*)$", line)
        if not d:
            continue
        kind, args = d.group(1), [x.strip() for x in d.group(2).split(",")]
        tables[current].extend(args if kind != "S" else [])
        if pos is None:
            continue
        if kind == "B":
            for x in args:
                memory[pos] = _number(x)
                pos += 1
        elif kind == "S":
            pos += _number(args[0])
        else:
            pos += 2 * len(args)
    return memory, tables


_MEMORY, _TABLES = _read_source()
VARIETIES = [_number(x) for x in _TABLES["column_varieties"]][:17]
_OFFSETS = [_number(x) for x in _TABLES["graphic_offsets"]][:54]

# The blitters at fine position 0, by the label piece_blitters_shift0 names:
# width in bytes, the column step from one step to the next, mirrored.
_BLITTERS = {
    "blit_flat_step": ("flat", 3, 3, False),
    "blit_two": ("two", 2, 2, False),
    "blit_one": ("one", 1, 1, False),
    "cy_E52B": ("mirror_two", 2, -2, True),          # blit_mirror_two one DEC L early
    "blit_mirror_one": ("mirror_one", 1, -1, True),
    "cy_E48C": ("wall", 1, 0, False),                # blit_one past its INC L
    "cy_E55C": ("wall_mirror", 1, 0, True),          # blit_mirror_one past its DEC L
}


@dataclass(frozen=True)
class Shape:
    kind: str
    width: int          # bytes
    column_step: int    # bytes from one step to the next
    mirrored: bool
    graphic: int        # Cyberun address of variant 0
    offsets: tuple      # each variant's offset into the graphic
    rows: int           # rows drawn per step


def _shapes() -> list[Shape]:
    words = _TABLES["piece_blitters_shift0"]
    out = []
    for d in range(16):
        blitter, graphic = words[2 * d], words[2 * d + 1]
        kind, width, step, mirrored = _BLITTERS[blitter]
        g = re.match(r"cy_([0-9A-F]{4})(?:\+(\d+))?$", graphic)
        address = int(g.group(1), 16) + int(g.group(2) or 0)
        row = 7 if d == 14 else 8 if d == 15 else d % 7
        offsets = tuple(_OFFSETS[6 * row + 2 * v] for v in range(3))
        shape = DIRECTIONS[d]
        rows = 4 if shape.rise == 0 and shape.kind != "wall" else shape.rise
        out.append(Shape(kind, width, step, mirrored, address, offsets, rows))
    return out


SHAPES = _shapes()


def step_graphic(direction: int, offset: int, columns=None) -> list[list]:
    """A step's rows from the bottom up, each its bytes left to right (None
    for a column not drawn), as the blitter puts them on the screen."""
    shape = SHAPES[direction]
    p = shape.graphic + offset
    rows = []
    for r in range(shape.rows):
        row = [None] * shape.width
        order = range(shape.width) if r % 2 == 0 else range(shape.width - 1, -1, -1)
        for i in order:
            b = _MEMORY[p]
            p += 1
            if shape.mirrored:
                b = REVERSED[b]
            if columns is None or i in columns:
                row[i] = b
        rows.append(row)
    return rows


@dataclass(frozen=True)
class Step:
    column: int         # byte column of its left byte, in the page
    bottom: int         # its bottom line, in the page
    direction: int
    offset: int         # into its graphic: the variant's, or an end cap's
    columns: tuple | None   # the columns drawn, None for all


@dataclass(frozen=True)
class Drawn:
    x: int
    y: int
    direction: int
    steps: int
    ends: tuple = (0, 0)


def drawn(piece: dict, upside_down: bool, mirrored: bool) -> Drawn:
    """A piece after its tile's markers, as Cyberun's load_piece_steps and
    piece_ends make them (examples/jetrun/world.py's drawn), for a page 256
    pixels wide with its origin at 0."""
    x, y, steps = piece["x"], piece["y"], piece["steps"]
    n = DIRECTION_NUMBER[piece["direction"]]
    ends = tuple(piece.get("ends", (0, 0)))
    flat = DIRECTIONS[n].rise == 0 and DIRECTIONS[n].kind != "wall"
    if upside_down:
        n = JW.UPSIDE_DOWN[n]
        if DIRECTIONS[n].kind == "wall":
            x += 8 if n == 14 else -8
    if flat:
        if upside_down:
            y ^= 0x0C
        if mirrored:
            a, b = ends
            ends = (b ^ 2, a ^ 2) if b != FIRST_COLUMN_ONLY else (a, FIRST_COLUMN_ONLY)
        if upside_down:
            a, b = ends
            ends = (a ^ 1, b if b == FIRST_COLUMN_ONLY else b ^ 1)
    if mirrored and not (flat and ends[1] == FIRST_COLUMN_ONLY):
        step_x = 8 if DIRECTIONS[n].kind == "wall" else abs(DIRECTIONS[n].run)
        x = PAGE_W - x - step_x
        n = JW.MIRRORED[n]
        if flat:
            x -= (steps - 1) * 24
    return Drawn(x, y, n, steps, ends)


def steps_of(d: Drawn) -> list[Step]:
    """Each step of a drawn piece: where its graphic goes and which."""
    shape = SHAPES[d.direction]
    rise = DIRECTIONS[d.direction].rise
    out = []
    count = d.steps or 16
    for k in range(count):
        offset = shape.offsets[VARIETIES[k]]
        columns = None
        if shape.kind == "flat":
            last = k == count - 1
            code = d.ends[0] if k == 0 else d.ends[1] if last else 0
            if code & 0x10:
                offset = 0x24 + 12 * (code & 3)
                if last and code == FIRST_COLUMN_ONLY:
                    columns = (0,)
        out.append(Step(d.x // 8 + shape.column_step * k, d.y - rise * k, d.direction, offset, columns))
    return out


@dataclass(frozen=True)
class Surface:
    """A floor or ceiling as a line in the page, for the parity background:
    from (x, y), `steps` steps of TOGGLE_DIRECTIONS[toggle]."""
    x: int
    y: int
    toggle: int
    steps: int


def surface(d: Drawn) -> Surface | None:
    """A drawn piece's line (examples/jetrun/world.py's surface, origin 0),
    or None for a wall."""
    shape = DIRECTIONS[d.direction]
    if shape.kind == "wall":
        return None
    if shape.rise == 0:
        length = (d.steps - 1) * 24 + 8 if d.ends[1] == FIRST_COLUMN_ONLY else d.steps * 24
        return Surface(d.x, d.y, 0, length // 8)
    run = abs(shape.run)
    if shape.run > 0:
        return Surface(d.x, d.y, TOGGLE_DIRECTIONS.index((run, -shape.rise)), d.steps)
    return Surface(d.x - (d.steps - 1) * run, d.y - d.steps * shape.rise,
                   TOGGLE_DIRECTIONS.index((run, shape.rise)), d.steps)


def crossings(s: Surface):
    """(column, line) where the surface turns the column, in the page."""
    dx, dy = TOGGLE_DIRECTIONS[s.toggle]
    for k in range(s.steps):
        for i in range(dx):
            yield s.x + k * dx + i, s.y + k * dy + JW.surface_offset(dx, dy, i) + CROSS_DY[s.toggle]
