"""Build listscroll: a world of rock (the $55/$AA checker) and open space --
sky, caverns and tunnels -- a map of pages, each page a tile whose edges are
pieces drawn by a display list; then assemble listscroll.s with sjasmplus.

The world is world/map.json, rows of pages, a tile name a page; a page is 256
pixels (32 byte columns) by 256 lines. The tiles are world/tiles.json, each a
list of pieces in Cyberun's way: straight runs of identical steps, flat or
sloping gently, at 45 degrees or steeply, each a floor or a ceiling. As in
Cyberun, rock is decided down each world column: sky above the world, and
every surface crossing the column turns sky to rock or rock to open. So a
tile holds only its surfaces, and sky, solid rock and a shaft are all tiles
with no pieces. A wall is where a surface stops. Tiles meet where their
surfaces do: a tunnel leaving one page's right side at some lines enters the
next page's left side at the same lines. A piece in a page's first column
also shows the last 6 pixels of the page to its left (the world moved right),
so a tile used in more than one place needs the pages to its left to end
alike; and a tile must be the same rock wherever it is, so the pages above
it must leave the same columns rock.

The screen is drawn once from the world at the start (screen_start). After
that only the edges are redrawn, because the checker inside the rock and the
open space look the same after any move of 2 pixels: what changes is where a
line goes from open to rock or back.

Every graphic is what the world shows in its window, so overlapping pieces
write the same bytes, and more pieces never put anything wrong on the screen:
all that matters is that after any move every byte that changed is in a piece
that is drawn. Columns 0 and 31 and rows 0 and 23 are black on black, so only
columns 1 to 30 of rows 1 to 22 show, and every piece touching that is drawn
(its window at column 0 to 30, its bottom line 9 to 189). So that is a fact
about the world alone: cut the world into bytes at each fine position, and
every byte that differs from the one a move brings into its place must be in
some piece's window. A window is the same 2 bytes and 8 lines of the world at
every fine position.

So the pieces are placed by covering those bytes: for each tile, the bytes
that change in any page holding it, at any fine position and for any move,
covered from the top down, each by the window (2 columns, 8 lines ending on
an odd line, inside the page) that covers most of those still uncovered.
coverage() then checks the whole map, and the build stops if a piece's
graphic differs between two pages holding its tile.

    python examples/listscroll/build.py      # output/listscroll.sna
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = HERE / "output"
WORLD_DIR = HERE / "world"

PAGE_W = 256            # a page's width in pixels: 32 byte columns
PAGE_H = 256            # and its height in lines: a line in the page is a byte
PAGE_COLUMNS = PAGE_W // 8
PAIRS = 4               # every piece is 8 lines: 4 pairs

# Cyberun's directions (examples/jetrun/world.py has its table): a step's run
# across and its fall, down positive. Flat steps are 8 pixels here, so that a
# run can be any multiple of 8 long; Cyberun's are 24.
STEPS = {
    "": (8, 0),
    "-up-gentle": (16, -8),
    "-up": (8, -8),
    "-up-steep": (8, -16),
    "-down-gentle": (16, 8),
    "-down": (8, 8),
    "-down-steep": (8, 16),
}

TILES = json.loads((WORLD_DIR / "tiles.json").read_text(encoding="utf-8"))["tiles"]
MAP = json.loads((WORLD_DIR / "map.json").read_text(encoding="utf-8"))["rows"]
for _r, _row in enumerate(MAP):
    for _c, _name in enumerate(_row):
        if _name not in TILES:
            sys.exit(f"map.json: row {_r}, column {_c}: no tile named {_name!r}")
MAP_COLUMNS = len(MAP[0])
MAP_ROWS = len(MAP)
WORLD_W = PAGE_W * MAP_COLUMNS
WORLD_H = PAGE_H * MAP_ROWS
COLUMNS = WORLD_W // 8
if COLUMNS != 256 or any(len(row) != MAP_COLUMNS for row in MAP):
    sys.exit("map.json: the map's columns are counted in a byte, round the world: 8 pages across")
if MAP_ROWS > 32:
    sys.exit("map.json: a page's number (row * 8 + column) is a byte: at most 32 rows")
VIEW_Y_START = PAGE_H                   # the screen's top line as the world starts
VIEW_Y_MAX = WORLD_H - 192              # the lowest the view goes


def screen_offset(column: int, y: int) -> int:
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | column


# ---- the world's pixels ----------------------------------------------------------

def tile_surfaces(name: str):
    """A tile's surfaces in its page: (PAGE_H + 1) x PAGE_W, true where a
    surface crosses the column at that line (the first line it turns), and
    each step of each piece as (column, line, floor or not) at its middle,
    for the check that floors have rock below them."""
    tile = TILES[name]
    if "mirroredFrom" in tile or "upsideDownFrom" in tile:
        source = tile.get("mirroredFrom") or tile.get("upsideDownFrom")
        if source not in TILES or "pieces" not in TILES[source]:
            sys.exit(f"tile {name}: {source!r} is not a tile with pieces")
        cross, starts = tile_surfaces(source)
        if "mirroredFrom" in tile:
            return cross[:, ::-1], [(PAGE_W - 1 - c, line, floor) for c, line, floor in starts]
        return cross[::-1], [(c, PAGE_H - line, not floor) for c, line, floor in starts]
    cross = np.zeros((PAGE_H + 1, PAGE_W), dtype=bool)
    starts = []
    for k, piece in enumerate(tile["pieces"]):
        direction = piece["direction"]
        kind = "floor" if direction.startswith("floor") else "ceiling"
        dx, dy = STEPS[direction[len(kind):]]
        x, y = piece["x"], piece["y"]
        for step in range(piece["steps"]):
            for i in range(dx):
                column = x + step * dx + i
                line = y + step * dy + (dy * i) // dx
                if not 0 <= column < PAGE_W or not 1 <= line < PAGE_H:
                    sys.exit(f"tile {name}, piece {k}: leaves the page at ({column}, {line})")
                cross[line, column] ^= True
            # The step's middle column, for the check: its ends may meet
            # another surface (a pocket's tips), which cancels them there.
            i = dx // 2
            starts.append((x + step * dx + i, y + step * dy + (dy * i) // dx, kind == "floor"))
    return cross, starts


def world_rock():
    """The world's rock: down each column from sky, turned at each surface;
    and every piece's step starts in world coordinates, checked against it."""
    cross = np.zeros((WORLD_H + 1, WORLD_W), dtype=bool)
    tiles = {name: tile_surfaces(name) for name in TILES}
    for page_row, names in enumerate(MAP):
        for page_column, name in enumerate(names):
            x, y = page_column * PAGE_W, page_row * PAGE_H
            cross[y:y + PAGE_H + 1, x:x + PAGE_W] ^= tiles[name][0]
    rock = (np.cumsum(cross, axis=0, dtype=np.int32)[:WORLD_H] % 2) == 1
    for page_row, names in enumerate(MAP):
        for page_column, name in enumerate(names):
            for column, line, floor in tiles[name][1]:
                x, y = page_column * PAGE_W + column, page_row * PAGE_H + line
                if bool(rock[y, x]) != floor:
                    sys.exit(f"tile {name} at map row {page_row}, column {page_column}: the "
                             f"{'floor' if floor else 'ceiling'} at ({column}, {line}) has "
                             f"{'open' if floor else 'rock'} below it: the pages above leave "
                             f"this column the other way")
    return rock


def world_bits():
    """The world's pixels (rock showing the checker, $55 on odd lines and
    $AA on even), with a screen's width more round the world so that any
    window onto it is a slice."""
    rock = world_rock()
    xs = np.arange(WORLD_W)
    ys = np.arange(WORLD_H)
    bits = (rock & ((xs[None, :] + ys[:, None]) % 2 == 0)).astype(np.uint8)
    return np.concatenate([bits, bits[:, :256]], axis=1)


BITS = world_bits()


def byte(column: int, y: int, shift: int) -> int:
    """A byte of world column `column` on world line y, with the world moved
    `shift` pixels right."""
    x = (column * 8 - shift) % WORLD_W
    return int(np.packbits(BITS[y, x:x + 8])[0])


def window(column: int, bottom: int, shift: int) -> tuple[int, ...]:
    """A piece's graphic as the blit reads it: each pair of lines from the
    bottom, the lower left to right, the upper right to left."""
    data = []
    for y in range(bottom, bottom - 2 * PAIRS, -2):
        data += [byte(column, y, shift), byte(column + 1, y, shift),
                 byte(column + 1, y - 1, shift), byte(column, y - 1, shift)]
    return tuple(data)


def screen(bits, view_x: int, view_y: int):
    """The screen's 192 lines of 32 bytes with its left edge at world x
    view_x (even) and its top at world line view_y."""
    v = view_x % WORLD_W
    return np.packbits(bits[view_y:view_y + 192, v:v + 256], axis=1)


# ---- what changes, and the pieces that cover it -------------------------------------

def changes():
    """Every world byte (line, column) that, at some fine position, differs
    from the one some move of 2 pixels or 2 lines brings into its place."""
    bits = BITS[:, :WORLD_W]
    need = np.zeros((WORLD_H, COLUMNS), dtype=bool)

    def cut(x: int):
        """Each world byte starting at x + 8 * column."""
        return np.packbits(np.roll(bits, -x, axis=1), axis=1)

    for fine in (0, 2, 4, 6):
        now = cut(-fine)
        for move_x, move_y in ((2, 0), (-2, 0), (0, 2), (0, -2)):
            before = cut(-fine + move_x)
            if move_y > 0:
                need[:-move_y] |= now[:-move_y] != before[move_y:]
            elif move_y < 0:
                need[-move_y:] |= now[-move_y:] != before[:move_y]
            else:
                need |= now != before
    return need


def tile_pieces(name: str, need) -> list[tuple[int, int]]:
    """A tile's pieces (column, bottom line in the page), covering the bytes
    that change in every page holding it: from the top down, each byte not
    yet covered gets the window over it that covers most of those that are
    not, inside the page (columns 0 to 30, bottom lines 7 to 255, odd)."""
    mine = np.zeros((PAGE_H, PAGE_COLUMNS), dtype=bool)
    for page_row, names in enumerate(MAP):
        for page_column, n in enumerate(names):
            if n == name:
                mine |= need[page_row * PAGE_H:(page_row + 1) * PAGE_H,
                             page_column * PAGE_COLUMNS:(page_column + 1) * PAGE_COLUMNS]
    left = {(int(y), int(k)) for y, k in zip(*np.nonzero(mine))}
    pieces = []
    for y, k in sorted(left):
        if (y, k) not in left:
            continue
        best = None
        for column in (k - 1, k):
            if not 0 <= column <= PAGE_COLUMNS - 2:
                continue
            for bottom in range(y | 1, y + 8, 2):
                if not 7 <= bottom < PAGE_H:
                    continue
                got = sum((line, c) in left for line in range(bottom - 7, bottom + 1) for c in (column, column + 1))
                if best is None or got >= best[0]:
                    best = (got, column, bottom)
        _, column, bottom = best
        pieces.append((column, bottom))
        left -= {(line, c) for line in range(bottom - 7, bottom + 1) for c in (column, column + 1)}
    return sorted(pieces)


def coverage(pieces: list, need) -> None:
    """Every byte that changes is in some piece's window."""
    covered = np.zeros_like(need)
    for column, bottom in pieces:
        covered[bottom - 7:bottom + 1, column] = True
        covered[bottom - 7:bottom + 1, (column + 1) % COLUMNS] = True
    left = need & ~covered
    if left.any():
        y, column = (int(v) for v in np.argwhere(left)[0])
        sys.exit(f"coverage: line {y % PAGE_H} of page column {column % PAGE_COLUMNS} (tile "
                 f"{MAP[y // PAGE_H][column // PAGE_COLUMNS]}) changes in no piece")


# ---- output ---------------------------------------------------------------------

def data_s() -> str:
    need = changes()
    tiles = {name: tile_pieces(name, need) for name in TILES}
    world = [(page_column * PAGE_COLUMNS + column, page_row * PAGE_H + bottom)
             for page_row, names in enumerate(MAP) for page_column, name in enumerate(names)
             for column, bottom in tiles[name]]
    coverage(world, need)
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
        same[name] = next((n for n in names if n in same.values() and tiles[n] == tiles[name]
                           and labels[n] == labels[name]), name)
    lines += ["", "; Each tile's address.", "tile_table:", "    dw " + ", ".join(f"tile_{same[name]}" for name in names),
              "", "; Each tile: its pieces' indexes and its pieces twice, sorted by bottom line",
              "; and by column, each piece its column and bottom line in the page and its",
              "; graphic, numbered on from PIECES through both. LINE_INDEX: for each",
              "; character row (8 lines), the number of the first piece whose bottom is in",
              "; it, sorted by line, and one more for the end; COLUMN_INDEX: the same for",
              "; each column, into those sorted by column."]
    for name in names:
        if same[name] != name:
            continue
        by_line = sorted(zip(tiles[name], labels[name]), key=lambda p: (p[0][1], p[0][0]))
        by_column = sorted(zip(tiles[name], labels[name]))
        n = len(by_line)
        if 2 * n > 255:
            sys.exit(f"tile {name}: {n} pieces, more than an index's byte reaches")
        line_index = [sum(1 for (c, b), _ in by_line if b < 8 * k) for k in range(PAGE_H // 8 + 1)]
        column_index = [n + sum(1 for (c, b), _ in by_column if c < k) for k in range(PAGE_COLUMNS + 1)]
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
          + ", ".join(f"{n} {len(p)}" for n, p in tiles.items())
          + f" pieces; {len(world)} in the world, {len(graphics)} graphics")
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
