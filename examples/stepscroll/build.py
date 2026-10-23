"""Build stepscroll: listscroll's display list drawing a world of Cyberun's
terrain (world.py); then assemble stepscroll.s with sjasmplus.

The world is the blocks' entries, each a tile from world/tiles.json drawn
exactly as it is there, with rock (the $55/$AA checker) and sky round them
as their bottom rows say (world.py). The screen starts blank and the
world scrolls in from the bottom to its start view; after that only what a
move changes is redrawn: the entries, by the blitter for their width. (So
what no entry draws -- rock or sky that no move changes -- is never drawn,
and shows blank wherever the screen did not have it.)

The entries and their tiles are the whole of what is drawn: a tile
holds the step and whatever sky, rock, margin rows and spare bytes it needs
around it, and is edited in the stepscroll designer (vscode/). Nothing is
added here. They began as what this build used to make itself from
Cyberun's tiles -- the step, the byte its pixels shift into, 2 rows
of margin above or below where a move up or down needed them, the byte after
a flat run, and each step's first 2 pixels made the 2 to its left -- so that
with their speed of 2 pixels a move, they leave nothing behind.

Each entry's 4 versions, one a fine position (0, 2, 4, 6), are its tile
shifted 0, 2, 4 and 6 pixels right, its shift-in strip (tiles.json) coming
in on the left: made from the tile alone. The four are GFX_PAGES pages
apart, each graphic at the same place in its fine position's run. Where
entries overlap they should agree, as the table has no order. Every bottom
line is odd (the blitters go up a row pair at a time).

The play area is columns 1 to 30 of rows 3 to 21 (lines 24 to 175); rows 0
to 2 are for the score, and columns 0 and 31 and rows 22 and 23 are black on
black. An entry partly off the left or right is drawn with its address
simply a byte or two before or after: screen memory runs on from one
character row to the next along a pixel line, so what falls off one side
lands in a hidden column at the other, at most 2 bytes. An entry partly off
the top or bottom is clipped to lines 24 to 175: there is a blitter for
each width, MAX_ROWS rows tall, entered as many pairs in as the entry does
not draw at the top (blit_entry), and its graphic starts as many pairs in as
it does not draw at the bottom (stepscroll.s's store_entry and reclip).

A pass is two frames, drawn once, and moves the world up to 4 pixels across
and 4 lines up or down in one go (MOVES). coverage() checks that at every
fine position and for every such move, every world byte that changes is in
an entry: where one is not, a tile needs more room or plainer edges. The
left-column fill is still in stepscroll.s (FILLS), off.

The map and the blocks (output/blocks.s) go below $8000, in contended
memory: they are read only when entries arrive. The graphics, the code and
the table are above it.

    python examples/stepscroll/build.py      # output/stepscroll.sna
    python examples/stepscroll/build.py --jetman PATH   # Lunar Jetman's .z80, for Jetman
                                                        # (default: Downloads)
    python examples/stepscroll/build.py --unchecked   # the same, built even where
                                                      # coverage fails, to see it
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
import tileset as G  # noqa: E402
import jetman_sprite as JS  # noqa: E402

PAGE_W = WD.PAGE_W
PAGE_H = WD.PAGE_H
PAGE_COLUMNS = WD.PAGE_COLUMNS
SKY, CHECKER = 1, 2
FILL_NAMES = {0: "none", SKY: "sky", CHECKER: "checker"}
FILL_MOVES = ("right",)  # the column to the left, moving right to fine position 0
UNCHECKED = "--unchecked" in sys.argv[1:]   # build even if a move leaves something behind, to see it
MAX_ROWS = 24           # an entry's rows at most: the blitters' height (stepscroll.s's MAX_ROWS)
MAX_PAIRS = MAX_ROWS // 2
SHOWN = 176             # the screen lines that show: rows 22 and 23 are hidden

WORLD = WD.load()
MAP = WORLD.rows
BLOCKS = WORLD.blocks
MAP_COLUMNS = WORLD.map_columns
MAP_ROWS = WORLD.map_rows
WORLD_W = WORLD.world_w
WORLD_H = WORLD.world_h
COLUMNS = WORLD_W // 8
VIEW_Y_START = PAGE_H                   # the screen's top line as the world starts
VIEW_Y_MAX = WORLD_H - SHOWN            # the lowest the view goes

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

def block_entries() -> dict:
    """Each block's entries: blocks.json's, each the size of its tile."""
    out = {}
    for name in BLOCKS:
        entries = set()
        for e in WORLD.entries(name):
            width, rows = e.width, e.rows
            if rows > MAX_ROWS or width > 3:
                sys.exit(f"block {name}: tile {e.tile} is {width} bytes by {rows} rows; an entry is at most "
                         f"3 bytes by {MAX_ROWS} rows")
            entries.add((e.column, e.bottom, width, rows))
        out[name] = sorted(entries)
    return out


def instances(name: str):
    for r, row in enumerate(MAP):
        for c, n in enumerate(row):
            if n == name:
                yield r, c


def footprint(entries_by_block) -> np.ndarray:
    foot = np.zeros((WORLD_H, COLUMNS), dtype=bool)
    for r, row in enumerate(MAP):
        for c, name in enumerate(row):
            for column, bottom, width, rows in entries_by_block[name]:
                y = r * PAGE_H + bottom
                for j in range(width):
                    foot[y - rows + 1:y + 1, (c * PAGE_COLUMNS + column + j) % COLUMNS] = True
    return foot


ENTRIES = block_entries()
FOOT = footprint(ENTRIES)


def world_entries():
    for r, row in enumerate(MAP):
        for c, name in enumerate(row):
            for e in ENTRIES[name]:
                column, bottom, width, rows = e
                yield name, e, c * PAGE_COLUMNS + column, r * PAGE_H + bottom


def changes():
    """By move -- MOVES, a pass's: up to 4 pixels across and 4 lines up or
    down, in one go between two drawings -- and the fine position after it:
    the world bytes that differ from what the move brings into their place.
    The Z80's names for the moves: right is the world going right (mx > 0),
    down the world going down (my > 0)."""
    out = {}
    for mx, my in MOVES:
        move = " and ".join([f"{abs(mx)} {'right' if mx > 0 else 'left'}"] * (mx != 0) +
                            [f"{abs(my)} {'down' if my > 0 else 'up'}"] * (my != 0))
        for fine in (0, 2, 4, 6):
            now = CUTS[fine]
            # Before, the byte at k showed fine - mx pixels in from the world
            # byte grid: maybe a byte along.
            shift = fine - mx
            before = np.roll(CUTS[shift % 8], shift // 8, axis=1)
            need = np.zeros_like(FOOT)
            if my > 0:
                need[:-my] = now[:-my] != before[my:]
            elif my < 0:
                need[-my:] = now[-my:] != before[:my]
            else:
                need = now != before
            out[move, fine] = need
    return out


MOVES = [(mx, my) for mx in (-4, -2, 0, 2, 4) for my in (-4, -2, 0, 2, 4) if (mx, my) != (0, 0)]
NEED = changes()


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
    """Each block's entries' fill kinds by move: filled where the move changes
    a byte no entry covers, with the kind those bytes all are."""
    left = {}
    for move in FILL_MOVES:
        left[move] = np.zeros_like(FOOT)
        left[move] |= need["2 " + move, 0] & ~FOOT
    fills = {}
    for name, entry, x, y in world_entries():
        for move in FILL_MOVES:
            cells = [(cy, cx) for cy, cx in fill_cells(move, entry, x, y) if 0 <= cy < WORLD_H]
            if not any(left[move][cy, cx] for cy, cx in cells):
                continue
            kinds = {SKY if BYTES[cy, cx] == 0 else CHECKER if BYTES[cy, cx] in (0x55, 0xAA) else 0
                     for cy, cx in cells if not FOOT[cy, cx]}
            if 0 in kinds or len(kinds) != 1:
                raise WD.WorldError(f"block {name}: entry {entry}: its {move} fill would cover "
                                    f"{sorted(FILL_NAMES[k] for k in kinds)}, not one plain kind")
            kind = kinds.pop()
            if fills.setdefault((name, entry, move), kind) != kind:
                raise WD.WorldError(f"block {name}: entry {entry}: its {move} fill differs between pages")
    return fills


def coverage(need, fills) -> None:
    """Every byte that changes is in an entry, or (moving right to fine
    position 0) in a left-column fill."""
    for (move, fine), changed in need.items():
        covered = FOOT.copy()
        if move == "2 right" and fine == 0:
            for name, entry, x, y in world_entries():
                if (name, entry, move) in fills:
                    for cy, cx in fill_cells(move, entry, x, y):
                        if 0 <= cy < WORLD_H:
                            covered[cy, cx] = True
        left = changed & ~covered
        if left.any():
            y, x = (int(v) for v in np.argwhere(left)[0])
            message = (f"coverage: moving {move} to fine position {fine}, line {y % PAGE_H} of page column "
                       f"{x % PAGE_COLUMNS} (block {MAP[y // PAGE_H][x // PAGE_COLUMNS]}) changes in no entry "
                       f"or fill")
            if not UNCHECKED:
                sys.exit(message)
            # Built anyway, to see on screen what is left behind there.
            print(message, f"-- and {int(left.sum()) - 1} more bytes" if left.sum() > 1 else "")


def tile(e) -> tuple:
    """An entry's tile at the four fine positions, as its blitter reads
    it: each pair of rows from the bottom, the lower left to right, the upper
    right to left. At fine position f the tile is f pixels to the right:
    its last f pixels go, and the last f of its shift-in strip come in on the
    left (tiles.json) -- made from the tile alone, nothing from the world."""
    out = []
    for fine in (0, 2, 4, 6):
        lines = []
        for i in range(e.rows):
            pixels = (e.shift_in[i][G.STRIP - fine:] + e.bits[i])[:8 * e.width]
            lines.append([int("".join(map(str, pixels[8 * j:8 * j + 8])), 2) for j in range(e.width)])
        data = []
        for i in range(e.rows - 1, 0, -2):
            data += lines[i]
            data += list(reversed(lines[i - 1]))
        out.append(tuple(data))
    return tuple(out)


def pack(tiles: dict) -> tuple[list, int]:
    """The tiles one after another, as each fine position's run of them:
    (graphic, label, offset) each, and the run's length in whole pages."""
    placed = []
    offset = 0
    for g, label in tiles.items():
        placed.append((g, label, offset))
        offset += len(g[0])
    return placed, (offset + 255) // 256


# ---- output ---------------------------------------------------------------------

PAIR_BYTES = 5          # PAIRn: 5 bytes a column
NEXT_BYTES = 4          # NEXT_PAIR before its jump (JR 2 bytes, JP 3)
CROSS_BYTES = 15        # CROSS (CROSS_FAR 16); its JR C 6 bytes in
DONE_BYTES = 7


def blitter_layout(width: int) -> tuple:
    """Where blit_<width>'s row-cross pieces go, so that as many jumps as can
    be are JRs: the first few before the blitter (backwards), the last few
    after it, and those neither reaches after those with JP. Returns
    (before, after, far): pair numbers, each in its order in the code."""
    best = None
    crosses = list(range(1, MAX_PAIRS))
    for p in range(len(crosses) + 1):
        for q in range(p, len(crosses) + 1):
            before, far, after = crosses[:p], crosses[p:q], crosses[q:]
            # Byte offsets: the pieces before, the pairs, DONE, the near pieces after, the far.
            at = {}
            x = 0
            for k in before:
                at["c", k] = x
                x += CROSS_BYTES
            for k in range(1, MAX_PAIRS + 1):
                x += PAIR_BYTES * width
                if k < MAX_PAIRS:
                    x += NEXT_BYTES + (3 if k in far else 2)
                    at["b", k] = x
            x += DONE_BYTES
            for k in after:
                at["c", k] = x
                x += CROSS_BYTES
            ok = all(-128 <= at["c", k] - at["b", k] <= 127 and
                     -128 <= at["b", k] - (at["c", k] + 8) <= 127 for k in before + after)
            if ok and (best is None or len(far) < len(best[2])):
                best = (before, after, far)
    return best


def blitters(widths) -> str:
    """A blitter for each width the entries have, MAX_PAIRS pairs of rows
    from the bottom with the character-row check between pairs; .b<k> is
    the way in after k pairs, so entering at .b<k> draws MAX_PAIRS - k.
    blit_entry: the way in for each width (32 bytes from width 1) and number
    of pairs to draw (a word each, 0 to 15)."""
    lines = ["; Generated by build.py: a blitter for each entry width, and blit_entry.",
             "; The row-cross pieces sit before and after each blitter, where its JRs",
             "; reach them; those no JR reaches from the middle use the far forms.", ""]
    for width in range(1, 4):
        if width not in widths:
            continue
        before, after, far = blitter_layout(width)
        lines += [f"blit_{width}_c{k}: CROSS blit_{width}.b{k}" for k in before]
        lines += [f"blit_{width}:", ".b0:"]
        for k in range(1, MAX_PAIRS + 1):
            lines += [f"    PAIR{width}"]
            if k < MAX_PAIRS:
                lines += [f"    NEXT_PAIR{'_FAR' if k in far else ''} blit_{width}_c{k}", f".b{k}:"]
        lines += ["    DONE"]
        lines += [f"blit_{width}_c{k}: CROSS blit_{width}.b{k}" for k in after]
        lines += [f"blit_{width}_c{k}: CROSS_FAR blit_{width}.b{k}" for k in far]
        lines += [""]
    lines += ["; Each width's way in for 0 to 15 pairs (0 for none), all in one page: an",
              "; entry keeps its place here as a low byte.",
              "    IF ($ & 0xFF) > 0x100 - 96", "    ALIGN 256", "    ENDIF", "blit_entry:"]
    for width in range(1, 4):
        ways = [f"blit_{width}.b{MAX_PAIRS - m}" if width in widths and 1 <= m <= MAX_PAIRS else "0"
                for m in range(16)]
        lines += ["    dw " + ", ".join(ways[:8]), "    dw " + ", ".join(ways[8:])]
    return "\n".join(lines) + "\n"


def data_s() -> str:
    need = NEED
    fills = entry_fills(need)
    coverage(need, fills)
    tiles: dict[tuple, str] = {}
    records: dict[str, list] = {}
    for name in BLOCKS:
        found = []
        for entry in ENTRIES[name]:
            column, bottom, width, rows = entry
            fours = {tile(e) for e in WORLD.entries(name)
                     if (e.column, e.bottom, e.width, e.rows) == entry} if any(instances(name)) else set()
            if len(fours) > 1:
                sys.exit(f"block {name}: two entries at {entry} draw different tiles")
            if not fours:
                continue
            label = tiles.setdefault(fours.pop(), f"gfx_{len(tiles)}")
            kinds = [fills.get((name, entry, m), 0) for m in FILL_MOVES]
            found.append((column, bottom, label, width << 5 | rows, kinds[0] << 4, bottom - rows + 1))
        records[name] = found
    names = list(BLOCKS)
    placed, pages = pack(tiles)
    lines = ["; Generated by build.py.", "",
             f"MAP_COLUMNS     equ {MAP_COLUMNS}", f"MAP_ROWS        equ {MAP_ROWS}",
             f"VIEW_Y_START    equ {VIEW_Y_START}", f"VIEW_Y_MAX      equ {VIEW_Y_MAX}",
             f"GFX_PAGES       equ {pages}", "",
             "; The entries' tiles, one after another, four times: one run of them a",
             "; fine position (0, 2, 4, 6), GFX_PAGES pages apart, so the walker adds",
             "; the position's offset to the high byte alone.", "gfx:"]
    lines += [f"{label}: equ gfx + {offset}" for _, label, offset in placed]
    for f in range(4):
        data = [v for g, _, _ in placed for v in g[f]]
        for i in range(0, len(data), 32):
            lines += ["    db " + ", ".join(f"0x{v:02X}" for v in data[i:i + 32])]
        if len(data) < 256 * pages:
            lines += [f"    ds {256 * pages - len(data)}"]
    data = lines
    lines = ["; Generated by build.py: the map and the blocks, below $8000.", "",
             "; The map: a block number a page, row by row (page = row * 8 + column).", "map:"]
    lines += ["    db " + ", ".join(str(names.index(name)) for name in row) for row in MAP]
    same: dict[str, str] = {}
    for name in names:
        same[name] = next((n for n in names if n in same.values() and records[n] == records[name]), name)
    lines += ["", "; Each tile's address.", "tile_table:", "    dw " + ", ".join(f"tile_{same[name]}" for name in names),
              "", "; Each tile: its entries' indexes, its column and top lists' addresses and",
              "; its entries, sorted by bottom line, numbered from 0 at PIECES; then the",
              "; lists, their numbers sorted by column and by top line. An entry: its",
              "; column and bottom line in the page, its tile,",
              "; its shape (width * 32 + rows), its fills (2 bits each, 0 none, 1 sky, 2",
              "; checker: bits 0-1 above it, for a move down; 2-3 below it, for a move up;",
              "; 4-5 to its left, for a move right to fine position 0), its top line and",
              "; a spare byte. LINE_INDEX: for each character row the number of the first",
              "; entry whose bottom is in it, and one more for the end; COLUMN_INDEX: for",
              "; each column the place in the column list of the first in it; TOP_INDEX:",
              "; for each character row the place in the top list of the first whose top",
              "; is in it."]
    biggest = 0
    for name in names:
        if same[name] != name:
            continue
        by_line = sorted(records[name], key=lambda e: (e[1], e[0]))
        by_column = sorted(range(len(by_line)), key=lambda k: (by_line[k][0], by_line[k][1]))
        by_top = sorted(range(len(by_line)), key=lambda k: (by_line[k][5], by_line[k][0]))
        n = len(by_line)
        biggest = max(biggest, n)
        if n > 255:
            sys.exit(f"block {name}: {n} entries, more than an index's byte reaches")
        line_index = [sum(1 for e in by_line if e[1] < 8 * k) for k in range(PAGE_H // 8 + 1)]
        column_index = [sum(1 for e in by_line if e[0] < k) for k in range(PAGE_COLUMNS + 1)]
        top_index = [sum(1 for e in by_line if e[5] < 8 * k) for k in range(PAGE_H // 8 + 1)]
        lines += [f"tile_{name}:"]
        lines += ["    db " + ", ".join(str(v) for v in line_index[i:i + 16]) for i in range(0, len(line_index), 16)]
        lines += ["    db " + ", ".join(str(v) for v in column_index[i:i + 16]) for i in range(0, len(column_index), 16)]
        lines += ["    db " + ", ".join(str(v) for v in top_index[i:i + 16]) for i in range(0, len(top_index), 16)]
        lines += [f"    dw columns_{name}, tops_{name}"]
        lines += [f"    db {c}, {b}\n    dw {label}\n    db 0x{shape:02X}, 0x{fill:02X}, {top}, 0"
                  for c, b, label, shape, fill, top in by_line]
        lines += [f"columns_{name}:"]
        lines += ["    db " + ", ".join(str(v) for v in by_column[i:i + 16]) for i in range(0, n, 16)]
        lines += [f"tops_{name}:"]
        lines += ["    db " + ", ".join(str(v) for v in by_top[i:i + 16]) for i in range(0, n, 16)]
    (OUT / "blocks.s").write_text("\n".join(lines) + "\n", encoding="utf-8")
    lines = data
    lines += ["", "; The screen address of each line's first byte, from line -1 (in the ROM",
              "; above the screen, where an entry ending there draws harmlessly).", "line_table_m1:",
              "    dw 0x3F00", "line_table:"]
    lines += [f"    dw 0x{0x4000 + screen_offset(0, y):04X}" for y in range(192)]
    total = sum(1 for _ in world_entries())
    size = 4 * 256 * pages
    shapes = {(w, h) for name in BLOCKS for _, _, w, h in ENTRIES[name]}
    (OUT / "blitters.s").write_text(blitters({w for w, _ in shapes}), encoding="utf-8")
    print("shapes:", " ".join(f"{w}x{h}: {sum(1 for _ in world_entries() if _[1][2:] == (w, h))}"
                              for w, h in sorted(shapes)))
    print(f"{MAP_COLUMNS} x {MAP_ROWS} pages of {len(BLOCKS)} blocks; {total} entries in the world, "
          f"{len(tiles)} tiles in {pages} pages a fine position ({size} bytes); {len(fills)} fills; "
          f"at most {biggest} entries a block")
    return "\n".join(lines) + "\n"


def sjasmplus() -> str:
    for candidate in (REPO / "tools" / "sjasmplus" / "sjasmplus.exe", REPO / ".venv-win" / "Scripts" / "sjasmplus.exe"):
        if candidate.is_file():
            return str(candidate)
    found = shutil.which("sjasmplus")
    if not found:
        sys.exit("sjasmplus not found")
    return found


def jetman() -> None:
    """output/jetman.inc and jetman_data.s: Jetman's frames from the player's
    Lunar Jetman (--jetman PATH, or jetman_sprite.DEFAULT), or JETMAN 0 and
    no Jetman without it."""
    args = sys.argv[1:]
    path = Path(args[args.index("--jetman") + 1]) if "--jetman" in args else JS.DEFAULT
    if not path.is_file():
        print(f"no Lunar Jetman at {path}: built without Jetman (--jetman PATH to give it)")
        (OUT / "jetman.inc").write_text("JETMAN equ 0\n", encoding="utf-8")
        return
    found = JS.frames(path)
    lines = ["; Generated by build.py from the player's own Lunar Jetman (jetman_sprite.py):",
             "; not in the repository.", "jet_frames:", "    dw " + ", ".join(f"jet_{name}" for name, _ in found)]
    for name, rows in found:
        lines += [f"jet_{name}:", f"    db {len(rows)}"]
        lines += ["    db " + ", ".join(f"0x{left:02X}, 0x{right:02X}" for left, right in rows[i:i + 8])
                  for i in range(0, len(rows), 8)]
    (OUT / "jetman_data.s").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (OUT / "jetman.inc").write_text("JETMAN equ 1\n", encoding="utf-8")
    print(f"Jetman: {len(found)} frames from {path}")


def main() -> None:
    OUT.mkdir(exist_ok=True)
    jetman()
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
