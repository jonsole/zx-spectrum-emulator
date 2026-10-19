"""stepscroll's world: the map, tiles and graphics from world/*.json.

The world is a grid of pages, 8 across (round the world: a world column is a
byte) and up to 32 down, each 256 x 256 pixels and holding a tile. A tile
has:

- pieces, in Cyberun's form (cyberun_steps.py): x the left edge of the
  piece's lowest step, y that step's bottom line, a direction and its steps.
  They decide where the rock is: rock (the $55/$AA checker) and sky by
  parity down each column, sky above the world, turned at every surface
  crossed. A tile may take another's pieces, drawn mirrored or upside down,
  Cyberun's way;
- entries: graphics from steps.json, each at a byte column and a bottom line
  in the page, drawn over the rock exactly as they are -- the display list's
  entries (build.py).

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
import cyberun_steps as S  # noqa: E402
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

    def drawn(self, name: str) -> list[S.Drawn]:
        tile = self.tiles[name]
        source = tile.get("from", name)
        pieces = self.tiles[source]["pieces"]
        return [S.drawn(p, tile.get("upsideDown", False), tile.get("mirrored", False)) for p in pieces]

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

    def rock(self):
        """Rock by parity down each world column."""
        cross = np.zeros((self.world_h + 1, self.world_w), dtype=bool)
        for r, row in enumerate(self.rows):
            for c, name in enumerate(row):
                # Two pieces of the same kind over the same columns (a page's
                # last flat step laid over the run before it, to fill out 256
                # pixels with 24-pixel steps) are one surface there; a floor
                # and a ceiling meeting (a pocket's tip) still cancel.
                points = set()
                for d in self.drawn(name):
                    s = S.surface(d)
                    if s is None:
                        continue
                    kind = S.DIRECTIONS[d.direction].kind
                    for x, y in S.crossings(s):
                        if not 0 <= x < PAGE_W or not 0 <= y <= PAGE_H:
                            raise WorldError(f"tile {name}: a surface leaves the page at ({x}, {y})")
                        points.add((x, y, kind))
                for x, y, kind in points:
                    cross[r * PAGE_H + y, c * PAGE_W + x] ^= True
        return (np.cumsum(cross, axis=0, dtype=np.int32)[:self.world_h] % 2) == 1

    def bytes(self):
        """The world as screen bytes at fine position 0: (lines, 256). The
        rock, and every tile's entries over it, in order."""
        rock = self.rock()
        xs = np.arange(self.world_w)
        ys = np.arange(self.world_h)
        bits = (rock & ((xs[None, :] + ys[:, None]) % 2 == 0)).astype(np.uint8)
        for r, row in enumerate(self.rows):
            for c, name in enumerate(row):
                for e in self.entries(name):
                    top = r * PAGE_H + e.bottom - e.rows + 1
                    x = (c * PAGE_COLUMNS + e.column) * 8
                    bits[top:top + e.rows, x:x + 8 * e.width] = np.array(e.bits, dtype=np.uint8)
        return np.packbits(bits, axis=1)


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
