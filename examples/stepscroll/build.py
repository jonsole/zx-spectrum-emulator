"""Build stepscroll: listscroll's display list drawing a world of Cyberun's own
terrain steps (world.py, cyberun_steps.py); then assemble stepscroll.s with
sjasmplus.

The world is drawn as Cyberun draws its screen: rock (the $55/$AA checker)
and sky by parity, and every step's textured graphic over it. As in
listscroll, the screen is drawn once at the start (screen_start) and after
that only what a move changes is redrawn: the steps.

An entry of the display list is a step, drawn by the blitter for its shape:

- a flat step: 3 bytes by 4 rows. Its pixels shift on into the next byte at
  fine positions 2, 4 and 6, where the next step draws them; at the right
  end of a run nothing does, so the run's last step has a second entry, the
  byte after it (1 by 4);
- a 45-degree or steep slope or a wall: its 1-byte graphic and the byte its
  pixels shift into, 2 bytes by 8 or 16 rows;
- a gentle slope: 3 bytes (2 and the shift) by 8 rows.

Each entry's graphic is what the world shows in it at each of the four fine
positions, so overlapping entries write the same bytes and the table needs
no order. Every bottom line is odd (the blitters go up a row pair at a
time).

What shows is columns 1 to 30 of rows 0 to 21. Columns 0 and 31 and rows 22
and 23 are black on black. An entry partly off the left or right is drawn
with its address simply a byte or two before or after: screen memory runs on
from one character row to the next along a pixel line, so what falls off
one side lands in a hidden column at the other, at most 2 bytes. An entry
partly off the top draws into the ROM above the screen, which ignores it;
partly off the bottom it would reach the attributes, so the bottom two rows
are hidden instead (a 16-row entry ending on line 191 reaches up to 176).

A step's texture is not the same after a move, so the strip it leaves must
be repainted. Cyberun fills those strips; here entries carry them:

- moving down or up, the 2 rows above or below a step: the entry gets 2
  rows of margin there (what the world shows: sky over a floor, checker
  under it) wherever the move changes a byte no entry covers
  (with_margins). An entry over 16 rows is cut in two;
- moving left, the byte an entry leaves is its spare right byte, which at
  that moment holds only sky or ground;
- moving right as the fine position comes back to 0, the byte it leaves
  holds the step's first 2 pixels. For now blank_left_edges makes those the
  same as the 2 pixels to the step's left, which spoils Cyberun's graphics
  there; they are to be edited by hand to have 2 plain pixels at each side
  (issue #25). The left-column fill this needed is still in stepscroll.s
  (FILLS), off.

coverage() checks it: at every fine position and for every move, every
world byte that changes is in an entry.

    python examples/stepscroll/build.py      # output/stepscroll.sna
"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = HERE / "output"
sys.path.insert(0, str(HERE))
import world as WD  # noqa: E402

PAGE_W = WD.PAGE_W
PAGE_H = WD.PAGE_H
PAGE_COLUMNS = WD.PAGE_COLUMNS
SKY, CHECKER = 1, 2
FILL_NAMES = {0: "none", SKY: "sky", CHECKER: "checker"}
FILL_MOVES = ("right",)  # the column to the left, moving right to fine position 0
SLOT = 64               # bytes from one fine position's graphic to the next
MAX_ROWS = 16           # an entry's rows at most: the 2 hidden character rows at the bottom

WORLD = WD.load()
MAP = WORLD.rows
TILES = WORLD.tiles
MAP_COLUMNS = WORLD.map_columns
MAP_ROWS = WORLD.map_rows
WORLD_W = WORLD.world_w
WORLD_H = WORLD.world_h
COLUMNS = WORLD_W // 8
VIEW_Y_START = PAGE_H                   # the screen's top line as the world starts
VIEW_Y_MAX = WORLD_H - 192              # the lowest the view goes

BYTES = WORLD.bytes()                   # (lines, 256) at fine position 0
BITS = np.unpackbits(BYTES, axis=1)


def screen_offset(column: int, y: int) -> int:
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | column


def screen(view_x: int, view_y: int):
    """The screen's 192 lines of 32 bytes with its left edge at world x
    view_x (even) and its top at world line view_y."""
    v = view_x % WORLD_W
    wide = np.concatenate([BITS, BITS[:, :256]], axis=1)
    return np.packbits(wide[view_y:view_y + 192, v:v + 256], axis=1)


CUTS = {f: np.packbits(np.roll(BITS, f, axis=1), axis=1) for f in (0, 2, 4, 6)}


# ---- the entries ----------------------------------------------------------------
# An entry in its page: (column, bottom line, width, rows).

def step_entries(name: str) -> list[tuple[int, int, int, int]]:
    out = []
    for st in WORLD.steps(name):
        if st.width == 3:
            out.append((st.column, st.bottom, 3, 4))
        else:
            out.append((st.column, st.bottom, st.width + 1, st.rows))
    return out


def instances(name: str):
    for r, row in enumerate(MAP):
        for c, n in enumerate(row):
            if n == name:
                yield r, c


def footprint(entries_by_tile) -> np.ndarray:
    foot = np.zeros((WORLD_H, COLUMNS), dtype=bool)
    for r, row in enumerate(MAP):
        for c, name in enumerate(row):
            for column, bottom, width, rows in entries_by_tile[name]:
                y = r * PAGE_H + bottom
                for j in range(width):
                    foot[y - rows + 1:y + 1, (c * PAGE_COLUMNS + column + j) % COLUMNS] = True
    return foot


def tile_entries() -> dict:
    """Each tile's entries: its steps', and the byte after a flat run's last
    step wherever no entry covers it (in any page holding the tile)."""
    steps = {name: step_entries(name) for name in TILES}
    foot = footprint(steps)
    out = {}
    for name in TILES:
        entries = set(steps[name])
        for column, bottom, width, rows in steps[name]:
            if width != 3 or rows != 4:
                continue
            for r, c in instances(name):
                x = (c * PAGE_COLUMNS + column + 3) % COLUMNS
                y = r * PAGE_H + bottom
                if not foot[y - 3:y + 1, x].all():
                    if column + 3 > PAGE_COLUMNS - 1:
                        raise WD.WorldError(f"tile {name}: a flat run ends at the page's right edge "
                                            f"(column {column}); its last byte would be in the next page")
                    entries.add((column + 3, bottom, 1, 4))
        out[name] = sorted(entries)
    return out


BASE = tile_entries()
FOOT = footprint(BASE)


def world_entries():
    for r, row in enumerate(MAP):
        for c, name in enumerate(row):
            for e in ENTRIES[name]:
                column, bottom, width, rows = e
                yield name, e, c * PAGE_COLUMNS + column, r * PAGE_H + bottom


def changes():
    """By move (the Z80's names) and the fine position after it: the world
    bytes that differ from what the move brings into their place."""
    out = {}
    for move, (mx, my) in {"right": (2, 0), "left": (-2, 0), "down": (0, 2), "up": (0, -2)}.items():
        for fine in (0, 2, 4, 6):
            now = CUTS[fine]
            before = CUTS[(fine - mx) % 8]
            if mx == 2 and fine == 0:
                before = np.roll(before, -1, axis=1)
            if mx == -2 and fine == 6:
                before = np.roll(before, 1, axis=1)
            need = np.zeros_like(FOOT)
            if my > 0:
                need[:-my] = now[:-my] != before[my:]
            elif my < 0:
                need[-my:] = now[-my:] != before[:my]
            else:
                need = now != before
            out[move, fine] = need
    return out


def blank_left_edges() -> int:
    """Every piece's first 2 pixels the same as the 2 to its left, wherever
    they would otherwise be left behind: moving right to fine position 0 an
    entry jumps a byte, and the byte it leaves still shows its first 2
    pixels. Copying the sky or ground beside it there makes what is left
    behind what should be there, as the spare byte on its right already does
    moving left. Pieces whose left is another entry (a flat run's middle)
    are left alone. Returns the rows changed."""
    global BYTES, CUTS
    changed = 0
    for _ in range(4):
        now = CUTS[0]
        before = np.roll(CUTS[6], -1, axis=1)
        left = (now != before) & ~FOOT
        if not left.any():
            break
        for y, k in zip(*np.nonzero(left)):
            x = (int(k) + 1) * 8 % WORLD_W
            BITS[y, x:x + 2] = BITS[y, x - 2:x] if x >= 2 else BITS[y, WORLD_W - 2:WORLD_W]
            changed += 1
        BYTES = np.packbits(BITS, axis=1)
        CUTS = {f: np.packbits(np.roll(BITS, f, axis=1), axis=1) for f in (0, 2, 4, 6)}
    return changed


EDGES = blank_left_edges()
NEED = changes()


def with_margins() -> dict:
    """Each entry with 2 rows of margin above if moving down changes a byte
    there that no entry covers, and 2 below if moving up does: what the
    world shows there (sky over a floor, checker under it), so that drawing
    the entry where the move takes it paints over the strip it left. Then
    cut, from the bottom, into entries of at most MAX_ROWS."""
    left = {}
    for move in ("down", "up"):
        left[move] = np.zeros_like(FOOT)
        for fine in (0, 2, 4, 6):
            left[move] |= NEED[move, fine] & ~FOOT
    out = {}
    for name in TILES:
        entries = set()
        for column, bottom, width, rows in BASE[name]:
            above = below = False
            for r, c in instances(name):
                x = c * PAGE_COLUMNS + column
                y = r * PAGE_H + bottom
                xs = [(x + j) % COLUMNS for j in range(width)]
                above |= any(left["down"][yy, cx] for yy in (y - rows, y - rows - 1) if 0 <= yy < WORLD_H
                             for cx in xs)
                below |= any(left["up"][yy, cx] for yy in (y + 1, y + 2) if 0 <= yy < WORLD_H for cx in xs)
            top = bottom - rows + 1 - (2 if above else 0)
            b = bottom + (2 if below else 0)
            if b >= PAGE_H:
                raise WD.WorldError(f"tile {name}: the entry at column {column}, line {bottom} with its margin "
                                    f"below would end in the next page")
            while b >= top:
                h = min(MAX_ROWS, b - top + 1)
                entries.add((column, b, width, h))
                b -= h
        out[name] = sorted(entries)
    return out


ENTRIES = with_margins()
FOOT = footprint(ENTRIES)


def fill_cells(move: str, entry, x: int, y: int):
    """The world bytes an entry at byte column x, bottom line y fills on a
    move."""
    column, bottom, width, rows = entry
    if move == "down":
        return [(y - rows - k, (x + j) % COLUMNS) for k in (0, 1) for j in range(width)]
    if move == "up":
        return [(y + 1 + k, (x + j) % COLUMNS) for k in (0, 1) for j in range(width)]
    return [(y - k, (x - 1) % COLUMNS) for k in range(rows)]


def entry_fills(need) -> dict:
    """Each tile's entries' fill kinds by move: filled where the move changes
    a byte no entry covers, with the kind those bytes all are."""
    left = {}
    for move in FILL_MOVES:
        left[move] = np.zeros_like(FOOT)
        left[move] |= need[move, 0] & ~FOOT
    fills = {}
    for name, entry, x, y in world_entries():
        for move in FILL_MOVES:
            cells = [(cy, cx) for cy, cx in fill_cells(move, entry, x, y) if 0 <= cy < WORLD_H]
            if not any(left[move][cy, cx] for cy, cx in cells):
                continue
            kinds = {SKY if BYTES[cy, cx] == 0 else CHECKER if BYTES[cy, cx] in (0x55, 0xAA) else 0
                     for cy, cx in cells if not FOOT[cy, cx]}
            if 0 in kinds or len(kinds) != 1:
                raise WD.WorldError(f"tile {name}: entry {entry}: its {move} fill would cover "
                                    f"{sorted(FILL_NAMES[k] for k in kinds)}, not one plain kind")
            kind = kinds.pop()
            if fills.setdefault((name, entry, move), kind) != kind:
                raise WD.WorldError(f"tile {name}: entry {entry}: its {move} fill differs between pages")
    return fills


def coverage(need, fills) -> None:
    """Every byte that changes is in an entry, or (moving right to fine
    position 0) in a left-column fill."""
    for (move, fine), changed in need.items():
        covered = FOOT.copy()
        if move == "right" and fine == 0:
            for name, entry, x, y in world_entries():
                if (name, entry, move) in fills:
                    for cy, cx in fill_cells(move, entry, x, y):
                        if 0 <= cy < WORLD_H:
                            covered[cy, cx] = True
        left = changed & ~covered
        if left.any():
            y, x = (int(v) for v in np.argwhere(left)[0])
            sys.exit(f"coverage: moving {move} to fine position {fine}, line {y % PAGE_H} of page column "
                     f"{x % PAGE_COLUMNS} (tile {MAP[y // PAGE_H][x // PAGE_COLUMNS]}) changes in no entry "
                     f"or fill")


def graphic(x: int, y: int, width: int, rows: int) -> tuple:
    """An entry's graphic at the four fine positions, as its blitter reads
    it: each pair of rows from the bottom, the lower left to right, the upper
    right to left."""
    out = []
    for fine in (0, 2, 4, 6):
        c = CUTS[fine]
        data = []
        for line in range(y, y - rows, -2):
            data += [int(c[line, (x + j) % COLUMNS]) for j in range(width)]
            data += [int(c[line - 1, (x + j) % COLUMNS]) for j in reversed(range(width))]
        out.append(tuple(data))
    return tuple(out)


def pack(graphics: dict) -> list[list]:
    """The graphics in 256-byte blocks: four 64-byte slots, one a fine
    position, each graphic at the same offset in all four; several small
    ones side by side (largest first, into the first block with room)."""
    blocks: list[list] = []
    for g, label in sorted(graphics.items(), key=lambda item: -len(item[0][0])):
        size = len(g[0])
        for block in blocks:
            used = sum(len(h[0]) for h, _ in block)
            if used + size <= SLOT:
                block.append((g, label))
                break
        else:
            blocks.append([(g, label)])
    return blocks


# ---- output ---------------------------------------------------------------------

def blitters(shapes) -> str:
    """A blitter for each shape (width, rows) the entries have: the rows a
    pair at a time from the bottom, the character-row check between pairs."""
    lines = ["; Generated by build.py: a blitter for each entry shape (bytes x rows).", ""]
    for width, rows in sorted(shapes):
        pairs = rows // 2
        lines += [f"blit_{width}x{rows}:"]
        for k in range(1, pairs + 1):
            lines += [f"    PAIR{width}"]
            if k < pairs:
                lines += [f"    NEXT_PAIR .c{k}", f".b{k}:"]
        lines += ["    DONE"]
        lines += [f".c{k}: CROSS .b{k}" for k in range(1, pairs)]
        lines += [""]
    return "\n".join(lines) + "\n"


def data_s() -> str:
    need = NEED
    fills = entry_fills(need)
    coverage(need, fills)
    graphics: dict[tuple, str] = {}
    records: dict[str, list] = {}
    for name in TILES:
        found = []
        for entry in ENTRIES[name]:
            column, bottom, width, rows = entry
            fours = {graphic(c * PAGE_COLUMNS + column, r * PAGE_H + bottom, width, rows)
                     for r, c in instances(name)}
            if len(fours) > 1:
                sys.exit(f"tile {name}: the entry {entry} looks different in different places: "
                         f"it reaches into its neighbours")
            if not fours:
                continue
            label = graphics.setdefault(fours.pop(), f"gfx_{len(graphics)}")
            kinds = [fills.get((name, entry, m), 0) for m in FILL_MOVES]
            found.append((column, bottom, label, f"blit_{width}x{rows}", width << 5 | rows, kinds[0] << 4))
        records[name] = found
    names = list(TILES)
    blocks = pack(graphics)
    lines = ["; Generated by build.py.", "",
             f"MAP_COLUMNS     equ {MAP_COLUMNS}", f"MAP_ROWS        equ {MAP_ROWS}",
             f"VIEW_Y_START    equ {VIEW_Y_START}", f"VIEW_Y_MAX      equ {VIEW_Y_MAX}",
             f"GFX_SLOT        equ {SLOT}", "",
             "; The entries' graphics, in 256-byte blocks of four 64-byte slots, one a",
             "; fine position (0, 2, 4, 6): a graphic is at the same offset in each, so",
             "; the walker adds the position's offset to the low byte alone.", "gfx:"]
    for block in blocks:
        lines += ["    ALIGN 256"]
        offset = 0
        first = None
        for g, label in block:
            if first is None:
                first = label
                lines += [f"{label}:"]
            else:
                lines += [f"{label}: equ {first} + {offset}"]
            offset += len(g[0])
        for f in range(4):
            data = [v for g, _ in block for v in g[f]]
            lines += ["    db " + ", ".join(f"0x{v:02X}" for v in data)]
            if len(data) < SLOT:
                lines += [f"    ds {SLOT - len(data)}"]
    lines += ["", "; The map: a tile number a page, row by row (page = row * 8 + column).", "map:"]
    lines += ["    db " + ", ".join(str(names.index(name)) for name in row) for row in MAP]
    same: dict[str, str] = {}
    for name in names:
        same[name] = next((n for n in names if n in same.values() and records[n] == records[name]), name)
    lines += ["", "; Each tile's address.", "tile_table:", "    dw " + ", ".join(f"tile_{same[name]}" for name in names),
              "", "; Each tile: its entries' indexes and its entries twice, sorted by bottom",
              "; line and by column, numbered on from PIECES through both. An entry: its",
              "; column and bottom line in the page, its graphic, its blitter, its shape",
              "; (width * 32 + rows) and its fills (2 bits each, 0 none, 1 sky, 2",
              "; checker: bits 0-1 above it, for a move down; 2-3 below it, for a move up;",
              "; 4-5 to its left, for a move right to fine position 0). LINE_INDEX: for",
              "; each character row the number of the first entry whose bottom is in it,",
              "; and one more for the end; COLUMN_INDEX: the same for each column."]
    biggest = 0
    for name in names:
        if same[name] != name:
            continue
        by_line = sorted(records[name], key=lambda e: (e[1], e[0]))
        by_column = sorted(records[name], key=lambda e: (e[0], e[1]))
        n = len(by_line)
        biggest = max(biggest, n)
        if 2 * n > 255:
            sys.exit(f"tile {name}: {n} entries, more than an index's byte reaches")
        line_index = [sum(1 for e in by_line if e[1] < 8 * k) for k in range(PAGE_H // 8 + 1)]
        column_index = [n + sum(1 for e in by_column if e[0] < k) for k in range(PAGE_COLUMNS + 1)]
        lines += [f"tile_{name}:"]
        lines += ["    db " + ", ".join(str(v) for v in line_index[i:i + 16]) for i in range(0, len(line_index), 16)]
        lines += ["    db " + ", ".join(str(v) for v in column_index[i:i + 16]) for i in range(0, len(column_index), 16)]
        lines += [f"    db {c}, {b}\n    dw {label}, {blit}\n    db 0x{shape:02X}, 0x{fill:02X}"
                  for c, b, label, blit, shape, fill in by_line + by_column]
    lines += ["", "; The screen address of each line's first byte, from line -1 (in the ROM",
              "; above the screen, where an entry ending there draws harmlessly).", "line_table_m1:",
              "    dw 0x3F00", "line_table:"]
    lines += [f"    dw 0x{0x4000 + screen_offset(0, y):04X}" for y in range(192)]
    lines += ["", "; The screen as the world starts.", "screen_start:"]
    for offset in range(0, 6144, 32):
        third, line_in_cell, row_in_third = offset >> 11, (offset >> 8) & 7, (offset >> 5) & 7
        y = third * 64 + row_in_third * 8 + line_in_cell
        lines.append("    db " + ", ".join(f"0x{int(BYTES[VIEW_Y_START + y, c]):02X}" for c in range(32)))
    total = sum(1 for _ in world_entries())
    size = 4 * SLOT * len(blocks)
    shapes = {(w, h) for name in TILES for _, _, w, h in ENTRIES[name]}
    (OUT / "blitters.s").write_text(blitters(shapes), encoding="utf-8")
    print("shapes:", " ".join(f"{w}x{h}: {sum(1 for _ in world_entries() if _[1][2:] == (w, h))}"
                              for w, h in sorted(shapes)))
    print(f"{MAP_COLUMNS} x {MAP_ROWS} pages of {len(TILES)} tiles; {total} entries in the world, "
          f"{len(graphics)} graphics in {len(blocks)} blocks ({size} bytes); {len(fills)} fills; "
          f"at most {biggest} entries a tile")
    return "\n".join(lines) + "\n"


def sjasmplus() -> str:
    for candidate in (REPO / "tools" / "sjasmplus" / "sjasmplus.exe", REPO / ".venv-win" / "Scripts" / "sjasmplus.exe"):
        if candidate.is_file():
            return str(candidate)
    found = shutil.which("sjasmplus")
    if not found:
        sys.exit("sjasmplus not found")
    return found


def main() -> None:
    OUT.mkdir(exist_ok=True)
    (OUT / "data.s").write_text(data_s(), encoding="utf-8")
    result = subprocess.run([sjasmplus(), "--nologo", "--sym=output/stepscroll.sym", "stepscroll.s"],
                            cwd=HERE, capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode != 0 or "Errors: 0" not in result.stdout + result.stderr:
        sys.exit("sjasmplus failed")
    print(f"wrote {OUT / 'stepscroll.sna'}")


if __name__ == "__main__":
    main()
