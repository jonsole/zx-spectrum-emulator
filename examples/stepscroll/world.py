"""stepscroll's world: the map, tiles and graphics from world/*.json.

The world is a grid of pages, 8 across (round the world: a world column is a
byte) and up to 32 down, each 256 x 256 pixels and holding a tile. A tile is
its entries: graphics from steps.json, each at a byte column and a bottom
line in the page, drawn exactly as they are -- the display list's entries
(build.py).

Between and under the graphics is sky or rock (the $55/$AA checker), worked
out from the graphics themselves: down each pixel column, sky from the top
of the world, and below each graphic whatever its bottom row shows there --
rock if that row is the checker (the pixel of the pair on an even x + y
set), sky if not. A floor graphic ends in rock, so the rock runs on under
it; a ceiling ends in sky.

    python examples/stepscroll/world.py      # output/world.png
"""
from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import step_graphics as G  # noqa: E402

WORLD_DIR = HERE / "world"
OUT = HERE / "output"
PAGE_W = 256
PAGE_H = 256
PAGE_COLUMNS = PAGE_W // 8


class WorldError(Exception):
    pass


@dataclass(frozen=True)
class Entry:
    """A graphic in its page."""
    graphic: str        # its name in steps.json
    column: int         # byte column of its left byte in the page
    bottom: int         # its bottom line in the page
    width: int          # bytes
    rows: int
    bits: tuple         # rows from the top, each a tuple of 0/1
    shift_in: tuple     # what shifting brings in on the left (step_graphics.py)


class World:
    def __init__(self, tiles: dict, rows: list[list[str]], graphics: G.Graphics):
        self.tiles = tiles
        self.graphics = graphics
        self.rows = rows
        self.map_rows = len(rows)
        self.map_columns = len(rows[0])
        if self.map_columns != 8 or any(len(r) != 8 for r in rows):
            raise WorldError("map.json: 8 pages across (a world column is a byte, round the world)")
        if self.map_rows > 32:
            raise WorldError("map.json: at most 32 rows (a page's number, row * 8 + column, is a byte)")
        for r, row in enumerate(rows):
            for c, name in enumerate(row):
                if name not in tiles:
                    raise WorldError(f"map.json: row {r}, column {c}: no tile named {name!r}")
        self.world_w = PAGE_W * self.map_columns
        self.world_h = PAGE_H * self.map_rows
        self.names = list(tiles)

    def entries(self, name: str) -> list[Entry]:
        """A tile's entries, each with its graphic, checked to be in the page
        with an odd bottom line."""
        out = []
        for k, e in enumerate(self.tiles[name].get("entries", [])):
            g = self.graphics.graphics.get(e["graphic"])
            if g is None:
                raise WorldError(f"tile {name}, entry {k}: no graphic {e['graphic']!r} in steps.json")
            if e["bottom"] % 2 == 0:
                raise WorldError(f"tile {name}, entry {k}: bottom line {e['bottom']} is even; the blitters "
                                 f"go up a row pair at a time from an odd line")
            if not (0 <= e["column"] and e["column"] + g.width <= PAGE_COLUMNS
                    and 0 <= e["bottom"] - g.height + 1 and e["bottom"] < PAGE_H):
                raise WorldError(f"tile {name}, entry {k}: {g.name} at column {e['column']}, line "
                                 f"{e['bottom']} leaves the page")
            out.append(Entry(g.name, e["column"], e["bottom"], g.width, g.height, g.bits, g.shift_in))
        return out

    def bytes(self):
        """The world as screen bytes at fine position 0: (lines, 256). Every
        tile's entries in order, and sky or rock round them as their bottom
        rows say."""
        h, w = self.world_h, self.world_w
        drawn = np.zeros((h, w), np.uint8)
        covered = np.zeros((h, w), bool)
        for r, row in enumerate(self.rows):
            for c, name in enumerate(row):
                for e in self.entries(name):
                    top = r * PAGE_H + e.bottom - e.rows + 1
                    x = (c * PAGE_COLUMNS + e.column) * 8
                    drawn[top:top + e.rows, x:x + 8 * e.width] = np.array(e.bits, dtype=np.uint8)
                    covered[top:top + e.rows, x:x + 8 * e.width] = True
        ys, xs = np.mgrid[0:h, 0:w]
        even = (xs + ys) % 2 == 0
        # Whether a drawn pixel is rock: the pixel of its pair that the
        # checker sets, on an even x + y.
        partner = drawn.copy()
        partner[:, 0::2], partner[:, 1::2] = drawn[:, 1::2], drawn[:, 0::2]
        rock_here = np.where(even, drawn, partner) == 1
        # Below a graphic, what its last row above says: the last covered row
        # above each pixel, or none (sky, from the top of the world).
        last = np.maximum.accumulate(np.where(covered, ys, -1), axis=0)
        rock = (last >= 0) & rock_here[np.maximum(last, 0), xs]
        bits = np.where(covered, drawn, (rock & even).astype(np.uint8))
        return np.packbits(bits.astype(np.uint8), axis=1)


def load(directory: Path = WORLD_DIR) -> World:
    tiles = json.loads((directory / "tiles.json").read_text(encoding="utf-8"))["tiles"]
    rows = json.loads((directory / "map.json").read_text(encoding="utf-8"))["rows"]
    return World(tiles, rows, G.load(directory / "steps.json"))


if __name__ == "__main__":
    from PIL import Image
    w = load()
    b = w.bytes()
    bits = np.unpackbits(b, axis=1)
    OUT.mkdir(exist_ok=True)
    Image.fromarray(((1 - bits) * 255).astype(np.uint8)).save(OUT / "world.png")
    print(f"{w.map_columns} x {w.map_rows} pages; wrote {OUT / 'world.png'}")
