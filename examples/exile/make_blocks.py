"""Draws the starting block set: blocks.png and blocks.json.

Run once, to have something to start from; after that blocks.png and
blocks.json are the source, edited by hand, and this script refuses to
overwrite them without --force. blocks.py is what reads them.

    python make_blocks.py [--force]
"""

import argparse
import json
import random
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))
import blocks  # noqa: E402

HERE = Path(__file__).resolve().parent
B = blocks.BLOCK_PX

# ---- textures: 16 x 16, repeating with the block ------------------------------

# Cobble seeds on the 16 x 16 torus the rock texture repeats on: one stone each.
STONES = [(3, 3), (11, 2), (7, 10), (14, 12)]


def _stone(x, y):
    best, best_d = 0, 1 << 30
    for i, (sx, sy) in enumerate(STONES):
        dx = min((x - sx) % B, (sx - x) % B)
        dy = min((y - sy) % B, (sy - y) % B)
        if dx * dx + dy * dy < best_d:
            best, best_d = i, dx * dx + dy * dy
    return best


def rock(x, y):
    """Mortar between stones, and a speck of shading on each."""
    me = _stone(x, y)
    if _stone((x + 1) % B, y) != me or _stone(x, (y + 1) % B) != me:
        return True
    sx, sy = STONES[me]
    return ((x - sx) % B, (y - sy) % B) in ((1, 2), (2, 1), (2, 2))


def brick(x, y):
    """Courses four pixels high, bricks eight long, staggered."""
    if y % 4 == 3:
        return True
    return (x + (4 if (y // 4) % 2 else 0)) % 8 == 7


_EARTH = random.Random(7)
_EARTH_DOTS = {(_EARTH.randrange(B), _EARTH.randrange(B)) for _ in range(40)}


def earth(x, y):
    return (x, y) in _EARTH_DOTS


def metal(x, y):
    """A plate: a frame, and a rivet in each corner."""
    if x in (0, B - 1) or y in (0, B - 1):
        return True
    return (x, y) in ((3, 3), (12, 3), (3, 12), (12, 12))


def water(x, y):
    """Ripples: drawn, not solid."""
    return (y % 6 == 1 and x % 8 in (0, 1, 2)) or (y % 6 == 4 and x % 8 in (4, 5, 6))


def grass(x, y):
    """Tufts standing on the block below: drawn, not solid."""
    tufts = {1: 3, 4: 5, 6: 2, 9: 4, 12: 6, 14: 3}
    return x in tufts and y >= B - tufts[x]


# ---- shapes: where in the block it is solid -------------------------------------

def full(x, y):
    return True


def half(side):
    return {
        "bottom": lambda x, y: y >= B // 2,
        "top": lambda x, y: y < B // 2,
        "left": lambda x, y: x < B // 2,
        "right": lambda x, y: x >= B // 2,
    }[side]


def triangle(corner, size):
    """Solid in the corner named, up to a diagonal `size` pixels in from it
    along each edge -- B for a slope that cuts the block corner to corner,
    B // 2 for a small corner piece."""
    def inside(x, y):
        cx = x if "left" in corner else B - 1 - x
        cy = y if "top" in corner else B - 1 - y
        return cx + cy < size
    return inside


def _edge(shape, x, y):
    """A solid pixel next to an open one inside the block: the cut face of a
    partial block, which gets a solid line. Faces against the next block are
    left alone -- the block cannot know what is beside it."""
    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
        xx, yy = x + dx, y + dy
        if 0 <= xx < B and 0 <= yy < B and not shape(xx, yy):
            return True
    return False


# ---- the set ---------------------------------------------------------------------

# (char, name, shape, texture, solid). Order is block number; keep empty first.
SET = [
    (" ", "empty", None, None, False),
    ("#", "rock", full, rock, True),
    ("L", "rock slope, solid lower left", triangle("bottom left", B), rock, True),
    ("J", "rock slope, solid lower right", triangle("bottom right", B), rock, True),
    ("F", "rock slope, solid upper left", triangle("top left", B), rock, True),
    ("7", "rock slope, solid upper right", triangle("top right", B), rock, True),
    ("_", "rock, bottom half", half("bottom"), rock, True),
    ("^", "rock, top half", half("top"), rock, True),
    ("[", "rock, left half", half("left"), rock, True),
    ("]", "rock, right half", half("right"), rock, True),
    ("`", "rock corner, upper left", triangle("top left", B // 2), rock, True),
    ("'", "rock corner, upper right", triangle("top right", B // 2), rock, True),
    (",", "rock corner, lower left", triangle("bottom left", B // 2), rock, True),
    (".", "rock corner, lower right", triangle("bottom right", B // 2), rock, True),
    ("=", "brick", full, brick, True),
    ("%", "earth", full, earth, True),
    ("+", "metal plate", full, metal, True),
    ("~", "water", full, water, False),
    ('"', "grass", full, grass, False),
]


def block_pixels(shape, texture, solid):
    """Each pixel's colour name, as blocks.py reads them."""
    rows = []
    for y in range(B):
        row = []
        for x in range(B):
            if shape is None or not shape(x, y):
                row.append("open")
            elif not solid:
                row.append("decor" if texture(x, y) else "open")
            elif shape is not full and _edge(shape, x, y):
                row.append("ink")
            else:
                row.append("ink" if texture(x, y) else "solid")
        rows.append(row)
    return rows


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--force", action="store_true", help="overwrite blocks.png and blocks.json")
    args = ap.parse_args()
    if not args.force and (blocks.SHEET.exists() or blocks.LEGEND.exists()):
        sys.exit("blocks.png / blocks.json exist and are the source now; --force to start again")

    sheet = blocks.blank_sheet()
    for n, (char, name, shape, texture, solid) in enumerate(SET):
        blocks.put_block(sheet, n, block_pixels(shape, texture, solid))
    sheet.save(blocks.SHEET)
    legend = [{"char": char, "name": name} for char, name, *_ in SET]
    blocks.LEGEND.write_text(json.dumps(legend, indent=2) + "\n")
    print(f"wrote {blocks.SHEET} and {blocks.LEGEND}: {len(SET)} blocks")


if __name__ == "__main__":
    main()
