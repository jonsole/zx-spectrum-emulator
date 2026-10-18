"""stepscroll's world: the map and tiles from world/*.json, drawn with
Cyberun's own terrain steps (cyberun_steps.py).

The world is a grid of pages, 8 across (round the world: a world column is a
byte) and up to 32 down, each 256 x 256 pixels and holding a tile. A tile is
a list of pieces in Cyberun's form: x the left edge of the piece's lowest
step, y that step's bottom line (odd: the blitters start a row pair on an odd
line), a direction, its steps, and a flat piece's end codes; a tile may be
another drawn upside down or mirrored, Cyberun's way.

The world's pixels are made as Cyberun's screen is: rock (the $55/$AA
checker) and sky by parity down each column -- sky above the world, turned
at every surface crossed -- and then every step's graphic drawn over it at
its place, page by page, piece by piece, step by step.

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

WORLD_DIR = HERE / "world"
OUT = HERE / "output"
PAGE_W = 256
PAGE_H = 256
PAGE_COLUMNS = PAGE_W // 8


class WorldError(Exception):
    pass


@dataclass(frozen=True)
class PlacedStep:
    """A step in its page: what draws it and where."""
    column: int         # byte column of its left byte in the page
    bottom: int         # bottom line in the page
    direction: int
    offset: int         # into the direction's graphic
    columns: tuple | None
    rows: int
    width: int


class World:
    def __init__(self, tiles: dict, rows: list[list[str]]):
        self.tiles = tiles
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

    def steps(self, name: str) -> list[PlacedStep]:
        """Every step of a tile, in drawing order."""
        out = []
        for k, d in enumerate(self.drawn(name)):
            if d.y % 2 == 0:
                raise WorldError(f"tile {name}, piece {k}: y {d.y} is even; a step's bottom line is odd")
            for s in S.steps_of(d):
                shape = S.SHAPES[s.direction]
                top = s.bottom - shape.rows + 1
                if not (0 <= s.column and s.column + shape.width <= PAGE_COLUMNS and 0 <= top and s.bottom < PAGE_H):
                    raise WorldError(f"tile {name}, piece {k}: a step at column {s.column}, line {s.bottom} "
                                     f"leaves the page")
                out.append(PlacedStep(s.column, s.bottom, s.direction, s.offset, s.columns, shape.rows, shape.width))
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
        """The world as screen bytes at fine position 0: (lines, 256)."""
        rock = self.rock()
        xs = np.arange(self.world_w)
        ys = np.arange(self.world_h)
        bits = (rock & ((xs[None, :] + ys[:, None]) % 2 == 0)).astype(np.uint8)
        out = np.packbits(bits, axis=1)
        for r, row in enumerate(self.rows):
            for c, name in enumerate(row):
                for st in self.steps(name):
                    rows = S.step_graphic(st.direction, st.offset, st.columns)
                    for i, row_bytes in enumerate(rows):
                        y = r * PAGE_H + st.bottom - i
                        for j, b in enumerate(row_bytes):
                            if b is not None:
                                out[y, (c * PAGE_COLUMNS + st.column + j) % 256] = b
        return out


def load(directory: Path = WORLD_DIR) -> World:
    tiles = json.loads((directory / "tiles.json").read_text(encoding="utf-8"))["tiles"]
    rows = json.loads((directory / "map.json").read_text(encoding="utf-8"))["rows"]
    return World(tiles, rows)


if __name__ == "__main__":
    from PIL import Image
    w = load()
    b = w.bytes()
    bits = np.unpackbits(b, axis=1)
    OUT.mkdir(exist_ok=True)
    Image.fromarray(((1 - bits) * 255).astype(np.uint8)).save(OUT / "world.png")
    print(f"{w.map_columns} x {w.map_rows} pages; wrote {OUT / 'world.png'}")
