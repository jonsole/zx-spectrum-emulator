"""Build listscroll: a world of rock (the $55/$AA checker) and sky, a map of
pages wrapping round, each page a tile whose edges are pieces drawn by a
display list; then assemble listscroll.s with sjasmplus.

The map is MAP, rows of pages, a tile name a page; a page is 256 pixels (32
byte columns) by 256 lines. A tile is sky, rock, or a list of hills on flat
ground that starts and ends on the ground, with sky above and rock below, so
that the landscape tiles join each other across and the sky and rock pages
above and below. Its pieces are made once, and shared by every page that
holds it.

The screen is drawn once from the world at the start (screen_start). After
that only the edges are redrawn, because the checker inside the rock and the
sky look the same after any move of 2 pixels.

Moving across, what changes is where a line goes from sky to rock or back.
Each such edge is in a piece of 8 lines (a character row as the world
starts) whose 2-byte window is placed so that every edge is 2, 4, 6 or 8
pixels into it at fine position 0:

- moving right, at fine position 6 the window's left byte has no edge in it,
  so when the window then moves on a byte the byte it leaves needs nothing;
- moving left, at fine position 0 its right byte has none, so when the
  window moves back a byte the byte it leaves needs nothing either.

That needs every edge on an even x: the slopes are staircases of 2 pixels
every 2 lines. A piece's graphic at fine position s is what its window shows
with the world moved s pixels right.

Moving up or down 2 lines, every window moves 2 lines with the world, so its
graphic stays the same; the lines it leaves must be right already. A flat
surface changes on such a move, so it has pieces too, 8 lines with the
surface in the middle, so that their top and bottom 2 lines hold no edge.

Every graphic is what the world shows in its window, so overlapping pieces
write the same bytes, and more pieces never put anything wrong on the screen:
all that matters is that after any move every byte that changed is in a
piece that is drawn. Columns 0 and 31 and rows 0 and 23 are black on black,
so only columns 1 to 30 of rows 1 to 22 show, and every piece touching that
is drawn (its window at column 0 to 30, its bottom line 9 to 189). So
coverage() checks the world alone: at each fine position and for each move,
every world byte that changes must be in some piece's window. The build
stops if one is in none, naming the tile that needs another.

    python examples/listscroll/build.py      # output/listscroll.sna
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

PAGE_W = 256            # a page's width in pixels: 32 byte columns
PAGE_H = 256            # and its height in lines: a line in the page is a byte
PAGE_COLUMNS = PAGE_W // 8
GROUND = 151            # a landscape tile's ground: rock from the line below this
PAIRS = 4               # every piece is 8 lines: 4 pairs

# The tiles: sky, rock, or a list of hills on flat ground (where the slope up
# leaves the ground, where the slope down starts, the last sky line above the
# top). Slopes climb and fall 2 pixels every 2 lines; a hill's height is a
# multiple of 8 lines, its slope up starts 2 pixels into a byte and its slope
# down where a byte starts, so that every slope piece is a character row
# (tile_pieces checks).
TILES = {
    "sky": "sky",
    "rock": "rock",
    "flat": [],
    "hill": [(66, 144, 95)],
    "wide": [(58, 168, 95)],
    "twin": [(42, 96, 119), (146, 200, 119)],
}
# The map: rows of pages, a tile a page, round the world across (8 pages: a
# world column is a byte) and stopping at the top and bottom.
MAP = [
    ["sky"] * 8,
    ["flat", "hill", "twin", "wide", "flat", "hill", "wide", "twin"],
    ["rock"] * 8,
]
MAP_COLUMNS = len(MAP[0])
MAP_ROWS = len(MAP)
WORLD_W = PAGE_W * MAP_COLUMNS
WORLD_H = PAGE_H * MAP_ROWS
COLUMNS = WORLD_W // 8
if COLUMNS != 256:
    sys.exit("the map's columns are counted in a byte, round the world: 8 pages across")
VIEW_Y_START = PAGE_H                   # the screen's top line as the world starts
VIEW_Y_MAX = WORLD_H - 192              # the lowest the view goes


def tile_surface(name: str, x: int) -> int:
    """The last sky line above the rock at x in a page of this tile (outside
    the page, the ground)."""
    hills = TILES[name]
    if hills == "sky":
        return PAGE_H - 1
    if hills == "rock":
        return -1
    for up, down, top in hills:
        rise = GROUND - top
        if up <= x < down:
            return max(top, GROUND - 2 * ((x - up) // 2 + 1))
        if down <= x < down + rise:
            return min(GROUND, top + 2 * ((x - down) // 2))
    return GROUND


def screen_offset(column: int, y: int) -> int:
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | column


# ---- the world's pixels ----------------------------------------------------------

def rock(x: int, y: int) -> bool:
    x %= WORLD_W
    if y < 0 or y >= WORLD_H:
        return y >= WORLD_H
    return y % PAGE_H > tile_surface(MAP[y // PAGE_H][x // PAGE_W], x % PAGE_W)


def pixel(x: int, y: int) -> int:
    """1 where rock shows: the checker, $55 on odd lines and $AA on even."""
    return int(rock(x, y) and (x + y) % 2 == 0)


def byte(column: int, y: int, shift: int) -> int:
    """A byte of world column `column` on world line y, with the world moved
    `shift` pixels right."""
    value = 0
    for b in range(8):
        value = value << 1 | pixel(column * 8 + b - shift, y)
    return value


def window(column: int, bottom: int, shift: int) -> tuple[int, ...]:
    """A piece's graphic as the blit reads it: each pair of lines from the
    bottom, the lower left to right, the upper right to left."""
    data = []
    for y in range(bottom, bottom - 2 * PAIRS, -2):
        data += [byte(column, y, shift), byte(column + 1, y, shift),
                 byte(column + 1, y - 1, shift), byte(column, y - 1, shift)]
    return tuple(data)


# ---- a tile's pieces: (column in the page, bottom line in the page) ---------------

def tile_pieces(name: str) -> list[tuple[int, int]]:
    """A tile's pieces, from its edges up and down (each a character row, in
    a window with every edge 2-8 pixels in) and its flat surfaces (8 lines
    with the surface in the middle: the ground every other column, the
    hilltops in their windows)."""
    hills = TILES[name]

    def surf(x: int) -> int:
        return tile_surface(name, x)

    def solid(x: int, y: int) -> bool:
        return y > surf(x)

    def window_column(x: int) -> int:
        if x % 2:
            sys.exit(f"tile {name}: an edge at odd x {x}: no 2-byte window holds it")
        return (x - 2) // 8

    out = []
    runs: dict[int, list[int]] = {}
    for bottom in range(PAGE_H - 1, 0, -2):
        found = {x for y in (bottom, bottom - 1) for x in range(PAGE_W) if solid(x, y) != solid(x - 1, y)}
        for column in {window_column(x) for x in found}:
            runs.setdefault(column, []).append(bottom)
    for column, bottoms in runs.items():
        i = 0
        while i < len(bottoms):
            n = 1
            while n < PAIRS and i + n < len(bottoms) and bottoms[i + n] == bottoms[i] - 2 * n:
                n += 1
            if n != PAIRS or bottoms[i] % 8 != 7:
                sys.exit(f"tile {name}: a piece of {2 * n} lines from line {bottoms[i]} in column "
                         f"{column}: every piece must be a character row")
            out.append((column, bottoms[i]))
            i += n
    if isinstance(hills, list):
        for column in range(0, PAGE_COLUMNS, 2):
            if any(surf(x) == GROUND for x in range(column * 8, column * 8 + 16)):
                out.append((column, GROUND + 4))
        for up, down, top in hills:
            for column in sorted({window_column(x) for x in range(0, PAGE_W, 2) if surf(x) == top}):
                out.append((column, top + 4))
    for column, bottom in out:
        if not 0 <= column < PAGE_COLUMNS or not 7 <= bottom < PAGE_H:
            sys.exit(f"tile {name}: the piece at column {column}, line {bottom} is outside its page")
    return sorted(set(out))


# ---- the check -------------------------------------------------------------------

def world_bits():
    """The world's pixels (rock showing the checker), with a screen's width
    more round the world so that any window onto it is a slice."""
    xs = np.arange(WORLD_W + 256)
    ys = np.arange(WORLD_H)
    surfaces = np.array([[tile_surface(MAP[row][(int(x) % WORLD_W) // PAGE_W], int(x) % PAGE_W) for x in xs]
                         for row in range(MAP_ROWS)])
    surf = surfaces[ys // PAGE_H]                           # each line's row of surfaces
    return (((ys % PAGE_H)[:, None] > surf) & ((xs[None, :] + ys[:, None]) % 2 == 0)).astype(np.uint8)


def screen(bits, view_x: int, view_y: int):
    """The screen's 192 lines of 32 bytes with its left edge at world x
    view_x (even) and its top at world line view_y."""
    v = view_x % WORLD_W
    return np.packbits(bits[view_y:view_y + 192, v:v + 256], axis=1)


def coverage(pieces: list) -> None:
    """After any move, every byte that changed must be in a piece that is
    drawn. Every piece touching the part of the screen that shows (columns 1
    to 30, rows 1 to 22) is drawn, so this is a check on the world alone: with
    the world's bytes cut at each fine position, every byte that differs from
    the one the move brings into its place must be in some piece's window."""
    bits = world_bits()[:, :WORLD_W]
    covered = np.zeros((WORLD_H, COLUMNS), dtype=bool)
    for column, bottom in pieces:
        covered[bottom - 7:bottom + 1, column] = True
        covered[bottom - 7:bottom + 1, (column + 1) % COLUMNS] = True

    def cut(x: int):
        """Each world byte starting at x + 8 * column."""
        return np.packbits(np.roll(bits, -x, axis=1), axis=1)

    for fine in (0, 2, 4, 6):
        now = cut(-fine)
        for move_x, move_y in ((2, 0), (-2, 0), (0, 2), (0, -2)):
            before = cut(-fine + move_x)
            changed = np.zeros_like(covered)
            if move_y > 0:
                changed[:-move_y] = now[:-move_y] != before[move_y:]
            elif move_y < 0:
                changed[-move_y:] = now[-move_y:] != before[:move_y]
            else:
                changed = now != before
            left = changed & ~covered
            if left.any():
                y, column = (int(v) for v in np.argwhere(left)[0])
                sys.exit(f"coverage: line {y % PAGE_H} of page column {column % PAGE_COLUMNS} (tile "
                         f"{MAP[y // PAGE_H][column // PAGE_COLUMNS]}) changes in no piece at fine "
                         f"position {fine}, moving {move_x}, {move_y}")


# ---- output ---------------------------------------------------------------------

def data_s() -> str:
    tiles = {name: tile_pieces(name) for name in TILES}
    world = [(page_column * PAGE_COLUMNS + column, page_row * PAGE_H + bottom)
             for page_row, names in enumerate(MAP) for page_column, name in enumerate(names)
             for column, bottom in tiles[name]]
    coverage(world)
    # Each tile's graphics, from the world: the same wherever the tile is.
    graphics: dict[tuple, str] = {}
    labels: dict[str, list[str]] = {}
    for name, pieces in tiles.items():
        found = []
        for column, bottom in pieces:
            fours = {tuple(window(page_column * PAGE_COLUMNS + column, page_row * PAGE_H + bottom, shift)
                           for shift in (0, 2, 4, 6))
                     for page_row, names in enumerate(MAP) for page_column, n in enumerate(names) if n == name}
            if len(fours) != 1:
                sys.exit(f"tile {name}: the piece at column {column}, line {bottom} looks different "
                         f"in different places: it reaches its neighbours")
            four = fours.pop()
            found.append(graphics.setdefault(four, f"gfx_{len(graphics)}"))
        labels[name] = found
    names = list(TILES)
    lines = ["; Generated by build.py.", "",
             f"MAP_COLUMNS     equ {MAP_COLUMNS}", f"MAP_ROWS        equ {MAP_ROWS}",
             f"VIEW_Y_START    equ {VIEW_Y_START}", f"VIEW_Y_MAX      equ {VIEW_Y_MAX}", "",
             "; The pieces' graphics: each at fine positions 0, 2, 4, 6, 16 bytes apart,",
             "; 64 bytes on a 64-byte boundary, so that the four are in one page and the",
             "; walker adds the position's offset to the low byte alone.", "gfx:"]
    for four, label in graphics.items():
        lines += ["    ALIGN 64", f"{label}:"]
        for shift in range(4):
            lines.append("    db " + ", ".join(f"0x{v:02X}" for v in four[shift]))
    lines += ["", "; The map: a tile number a page, row by row (page = row * 8 + column).", "map:"]
    lines += ["    db " + ", ".join(str(names.index(name)) for name in row) for row in MAP]
    # A tile with the same pieces as an earlier one (sky and rock: none) is
    # that one.
    same: dict[str, str] = {}
    for name in names:
        same[name] = next((n for n in names if n in same.values() and tiles[n] == tiles[name]), name)
    lines += ["", "; Each tile's address.", "tile_table:", "    dw " + ", ".join(f"tile_{same[name]}" for name in names),
              "", "; Each tile: its pieces' indexes and its pieces twice, sorted by bottom line",
              "; and by column, each piece its column and bottom line in the page and its",
              "; graphic. LINE_INDEX: for each odd line (n * 2 + 1), the offset from PIECES",
              "; of the first piece on it, sorted by line, and one more for the end;",
              "; COLUMN_INDEX: the same for each column, into those sorted by column."]
    for name in names:
        if same[name] != name:
            continue
        by_line = sorted(zip(tiles[name], labels[name]), key=lambda p: (p[0][1], p[0][0]))
        by_column = sorted(zip(tiles[name], labels[name]))
        n = len(by_line)
        line_index = [4 * sum(1 for (c, b), _ in by_line if b < 2 * k + 1) for k in range(PAGE_H // 2 + 1)]
        column_index = [4 * n + 4 * sum(1 for (c, b), _ in by_column if c < k) for k in range(PAGE_COLUMNS + 1)]
        if column_index[-1] > 255:
            sys.exit(f"tile {name}: {n} pieces, more than an index's byte reaches")
        lines += [f"tile_{name}:"]
        lines += ["    db " + ", ".join(str(v) for v in line_index[i:i + 16]) for i in range(0, len(line_index), 16)]
        lines += ["    db " + ", ".join(str(v) for v in column_index[i:i + 16]) for i in range(0, len(column_index), 16)]
        lines += [f"    db {column}, {bottom}\n    dw {label}" for (column, bottom), label in by_line + by_column]
    lines += ["", "; The screen address of each line's first byte.", "line_table:"]
    lines += [f"    dw 0x{0x4000 + screen_offset(0, y):04X}" for y in range(192)]
    lines += ["", "; The screen as the world starts.", "screen_start:"]
    for offset in range(0, 6144, 32):
        third, line_in_cell, row_in_third = offset >> 11, (offset >> 8) & 7, (offset >> 5) & 7
        y = third * 64 + row_in_third * 8 + line_in_cell
        lines.append("    db " + ", ".join(f"0x{byte(c, VIEW_Y_START + y, 0):02X}" for c in range(32)))
    print(f"{MAP_COLUMNS} x {MAP_ROWS} pages of {len(TILES)} tiles: "
          + ", ".join(f"{n} {len(p)} pieces" for n, p in tiles.items())
          + f"; {len(world)} in the world, {len(graphics)} graphics")
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
    result = subprocess.run([sjasmplus(), "--nologo", "--sym=output/listscroll.sym", "listscroll.s"],
                            cwd=HERE, capture_output=True, text=True)
    sys.stdout.write(result.stdout)
    sys.stderr.write(result.stderr)
    if result.returncode != 0 or "Errors: 0" not in result.stdout + result.stderr:
        sys.exit("sjasmplus failed")
    print(f"wrote {OUT / 'listscroll.sna'}")


if __name__ == "__main__":
    main()
