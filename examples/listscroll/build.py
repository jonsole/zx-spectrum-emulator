"""Build listscroll: a world of rock (the $55/$AA checker) and sky, wider
than the screen and wrapping round, whose edges are pieces drawn by a display
list; then assemble listscroll.s with sjasmplus.

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
piece on the screen (column 0 to 30). Columns 0 and 31 are black on black,
so only columns 1 to 30 show: every byte there is in a window that starts in
0 to 30, so it is drawn. coverage() checks that for every
position round the world and every move from it, and adds a piece wherever a
changed byte is in none: the corners, where an edge across meets one up and
down.

The pieces are kept sorted by world column (world_pieces); listscroll.s's
table holds the run of them on the screen.

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

WORLD_W = 768           # the world's width in pixels; it wraps round
COLUMNS = WORLD_W // 8
GROUND = 151            # the ground: rock from the line below this
TOP = 95                # the hills' tops
# The hills: (where the slope up leaves the ground, where the slope down
# starts). Each slope climbs or falls 2 pixels every 2 lines, 56 lines; the
# slope up starts 2 pixels into a byte and the slope down on a byte, so that
# every slope piece is a character row (edge_pieces checks).
HILLS = [(82, 160), (338, 432), (586, 664)]
MAX_VMOVE = 24          # the most the world moves up or down, in lines
PAIRS = 4               # every piece is 8 lines: 4 pairs


def surface(x: int) -> int:
    """The last sky line above the rock at world x."""
    x %= WORLD_W
    for up, down in HILLS:
        if up <= x < down:
            return max(TOP, GROUND - 2 * ((x - up) // 2 + 1))
        if down <= x < down + (GROUND - TOP):
            return min(GROUND, TOP + 2 * ((x - down) // 2))
    return GROUND


def rock(x: int, y: int) -> bool:
    return y > surface(x)


def pixel(x: int, y: int) -> int:
    """1 where rock shows: the checker, $55 on odd lines and $AA on even."""
    return int(rock(x, y) and (x + y) % 2 == 0)


def byte(column: int, y: int, shift: int) -> int:
    """A byte of world column `column` on line y, with the world moved
    `shift` pixels right."""
    value = 0
    for b in range(8):
        value = value << 1 | pixel(column * 8 + b - shift, y)
    return value


def screen_offset(column: int, y: int) -> int:
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | column


def window(column: int, bottom: int, shift: int) -> tuple[int, ...]:
    """A piece's graphic as the blit reads it: each pair of lines from the
    bottom, the lower left to right, the upper right to left."""
    data = []
    for y in range(bottom, bottom - 2 * PAIRS, -2):
        data += [byte(column, y, shift), byte(column + 1, y, shift),
                 byte(column + 1, y - 1, shift), byte(column, y - 1, shift)]
    return tuple(data)


# ---- the pieces: (world column, bottom line as the world starts) -----------------

def edges(y: int) -> list[int]:
    """Where line y goes from sky to rock or back round the world: x of the
    first pixel past each change."""
    return [x for x in range(WORLD_W) if rock(x, y) != rock(x - 1, y)]


def window_column(x: int) -> int:
    """The window whose fine-position-0 offsets 2-8 hold an edge at x."""
    if x % 2:
        sys.exit(f"an edge at odd x {x}: no 2-byte window holds it")
    return ((x - 2) // 8) % COLUMNS


def edge_pieces() -> list[tuple[int, int]]:
    """Every edge up and down the world's lines, a pair of lines at a time
    from the bottom (an odd line, as the blit needs), in runs of PAIRS pairs
    that share a window: each a character row."""
    runs: dict[int, list[int]] = {}
    for bottom in range(191, 0, -2):
        found = set(edges(bottom)) | set(edges(bottom - 1))
        for column in {window_column(x) for x in found}:
            runs.setdefault(column, []).append(bottom)
    out = []
    for column, bottoms in runs.items():
        i = 0
        while i < len(bottoms):
            n = 1
            while n < PAIRS and i + n < len(bottoms) and bottoms[i + n] == bottoms[i] - 2 * n:
                n += 1
            if n != PAIRS or bottoms[i] % 8 != 7:
                sys.exit(f"a piece of {2 * n} lines from line {bottoms[i]} in column {column}: "
                         f"every piece must be a character row")
            out.append((column, bottoms[i]))
            i += n
    return out


def surface_pieces() -> list[tuple[int, int]]:
    """The flat surfaces, in pieces of 8 lines with the surface between
    their fourth and fifth lines: the ground's every other column where its
    window holds ground, and the hills' tops."""
    out = []
    for column in range(0, COLUMNS, 2):
        if any(surface(x) == GROUND for x in range(column * 8, column * 8 + 16)):
            out.append((column, GROUND + 4))
    for column in sorted({window_column(x) for x in range(0, WORLD_W, 2) if surface(x) == TOP}):
        out.append((column, TOP + 4))
    return out


def world_bits():
    """The world's pixels (rock showing the checker), a world and a screen
    wide so that any window onto it is a slice, MAX_VMOVE lines over and
    under."""
    xs = np.arange(WORLD_W + 256)
    ys = np.arange(-MAX_VMOVE, 192 + MAX_VMOVE)
    surfaces = np.array([surface(int(x)) for x in xs])
    return ((ys[:, None] > surfaces[None, :]) & ((xs[None, :] + ys[:, None]) % 2 == 0)).astype(np.uint8)


def screen(bits, view: int, dy: int):
    """The screen's 192 lines of 32 bytes with the view's left edge at world
    x `view` (even) and the world moved dy lines down."""
    v = view % WORLD_W
    return np.packbits(bits[MAX_VMOVE - dy:MAX_VMOVE - dy + 192, v:v + 256], axis=1)


def on_screen(pieces, view: int, dy: int):
    """Which bytes the pieces on the screen cover: a piece's window is at
    screen column (its world column - the view's column) round the world,
    with the world's fine position view's AND 6 (left of a byte the window
    is a byte further left), drawn while that is 0 to 30."""
    cover = np.zeros((192, 32), dtype=bool)
    first = -(-view // 8)                   # the world column at screen column 0, rounding up
    for column, bottom in pieces:
        c = (column - first) % COLUMNS
        if c <= 30:
            b = bottom + dy
            cover[max(0, b - 7):b + 1, c:c + 2] = True
    return cover


def coverage(pieces: list) -> list:
    """For every position round the world (the view's x even, up and down
    within MAX_VMOVE) and every move from it, the bytes that change must be
    in a piece on the screen at the new position. A piece is added for any
    byte that is not, until none is left; the added pieces are returned."""
    bits = world_bits()
    added = []
    for dy in range(-MAX_VMOVE, MAX_VMOVE + 1, 2):
        for view in range(0, WORLD_W, 2):
            here = screen(bits, view, dy)
            for move_x, move_y in ((2, 0), (-2, 0), (0, 2), (0, -2)):
                nview, ndy = view + move_x, dy + move_y
                if abs(ndy) > MAX_VMOVE:
                    continue
                changed = here != screen(bits, nview, ndy)
                changed[:, 0] = changed[:, 31] = False      # black on black
                while True:
                    left = changed & ~on_screen(pieces, nview, ndy)
                    if not left.any():
                        break
                    y, c = (int(v) for v in np.argwhere(left)[0])
                    first = -(-nview // 8)
                    window_c = c & ~1 if c < 31 else 30         # even columns, so neighbours share
                    piece = ((window_c + first) % COLUMNS, (y - ndy + 3) | 1)
                    if piece in pieces:
                        sys.exit(f"coverage: line {y} column {c} at view {nview}, {ndy} is in no piece")
                    pieces.append(piece)
                    added.append(piece)
    for column, bottom in pieces:           # up and down, every piece stays on the screen
        if not 7 + MAX_VMOVE <= bottom <= 191 - MAX_VMOVE:
            sys.exit(f"the piece at column {column}, line {bottom} goes off the screen moving up or down")
    return added


# ---- output ---------------------------------------------------------------------

def data_s() -> str:
    pieces = edge_pieces() + surface_pieces()
    added = coverage(pieces)
    print(f"{len(pieces) - len(added)} pieces from the edges and surfaces; coverage added {len(added)}")
    pieces.sort()
    if len(pieces) > 255:
        sys.exit(f"{len(pieces)} pieces: the table counts them in a byte")
    graphics: dict[tuple, str] = {}          # four positions' graphics -> its label
    labels = []
    for column, bottom in pieces:
        four = tuple(window(column, bottom, shift) for shift in (0, 2, 4, 6))
        labels.append(graphics.setdefault(four, f"gfx_{len(graphics)}"))
    lines = ["; Generated by build.py.", "",
             f"COLUMNS         equ {COLUMNS}", f"MAX_VMOVE       equ {MAX_VMOVE}",
             f"WORLD_PIECES    equ {len(pieces)}", "",
             "; The pieces' graphics: each at fine positions 0, 2, 4, 6, 16 bytes apart,",
             "; 64 bytes on a 64-byte boundary, so that the four are in one page and the",
             "; walker adds the position's offset to the low byte alone.", "gfx:"]
    for four, label in graphics.items():
        lines += ["    ALIGN 64", f"{label}:"]
        for shift in range(4):
            lines.append("    db " + ", ".join(f"0x{v:02X}" for v in four[shift]))
    lines += ["", "; The world's pieces sorted by column: column, bottom line as the world",
              "; starts, graphic.", "world_pieces:"]
    lines += [f"    db {column}, {bottom}\n    dw {label}" for (column, bottom), label in zip(pieces, labels)]
    on = [i for i, (column, _) in enumerate(pieces) if column <= 30]
    lines += ["", "; Those on the screen as the world starts: world_pieces from FIRST_ON,",
              "; ON_COUNT of them.", f"FIRST_ON        equ {on[0]}", f"ON_COUNT        equ {len(on)}",
              "", "; The screen address of each line's first byte.", "line_table:"]
    lines += [f"    dw 0x{0x4000 + screen_offset(0, y):04X}" for y in range(192)]
    lines += ["", "; The screen as the world starts.", "screen_start:"]
    for offset in range(0, 6144, 32):
        third, line_in_cell, row_in_third = offset >> 11, (offset >> 8) & 7, (offset >> 5) & 7
        y = third * 64 + row_in_third * 8 + line_in_cell
        lines.append("    db " + ", ".join(f"0x{byte(c, y, 0):02X}" for c in range(32)))
    print(f"{len(pieces)} pieces round the world, {len(on)} on the screen at the start, "
          f"{len(graphics)} graphics")
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
