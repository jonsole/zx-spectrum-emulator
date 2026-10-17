"""Jetrun's world: the map and tiles read from world/*.json, checked, and
turned into what the game needs -- the tile records Cyberun's renderer reads,
and the crossings of the full render.

The world is a grid of pages, each 224 x 160 pixels, the size of the play
area; across, the pages wrap round. A page holds a tile, and a tile is a
list of pieces: straight runs of identical steps. The landscape is drawn by
Cyberun's own renderer (ADR 0007), and for now the world is Cyberun's own
too: its map and its 171 tiles, converted from the game.

A piece is given as Cyberun's tile record has it: x and y in Cyberun's page
coordinates (8 is the page's left edge, 24 its top) of the piece's start,
which is its lowest point; one of Cyberun's sixteen directions (DIRECTIONS);
its steps; and a flat piece's two end codes. A tile may be drawn upside down
(floors become ceilings) or mirrored left to right, Cyberun's $99 and $FF
markers; drawn() applies them the way the renderer does (load_piece_steps,
piece_ends in cyberun.s).

Whether a pixel is rock is decided down its column: each floor or ceiling
crossing the column toggles sky and rock, from sky above the world. The full
render at a life's start does that.

    python examples/jetrun/world.py      # check the world and print its size
"""
from __future__ import annotations

import bisect
import json
import sys
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
WORLD_DIR = HERE / "world"

PAGE_W = 224
PAGE_H = 160
# How far the view moves in one pass, each way: even, so that black sky and
# the checker inside rock look the same after any move.
MOVE = 2
# A page's top-left in Cyberun's page coordinates.
CYBERUN_X0 = 8
CYBERUN_Y0 = 24
# Cyberun's end code that draws only the first column of a flat run's last
# step: what ends a run on a page's edge.
FIRST_COLUMN_ONLY = 0x16
# Where a surface crosses a column, relative to the bottom line of its step:
# the full render only has to be right away from the steps (their graphics
# are drawn over it, and Cyberun's renderer scrolls down to the view after
# it), so this is the middle of a flat step's four rows.
CROSS_DY = -2
MAX_PIECES = 7          # Cyberun's collision-box list has room for seven


@dataclass(frozen=True)
class Direction:
    name: str
    kind: str          # "floor", "ceiling" or "wall"
    run: int           # a step's run across, pixels: negative climbing left, 0 a wall
    rise: int          # its climb, pixels


# In Cyberun's order: the number is the direction's nibble in a tile record.
DIRECTIONS = [
    Direction("floor", "floor", 24, 0),
    Direction("floor-up-gentle", "floor", 16, 8),
    Direction("floor-up", "floor", 8, 8),
    Direction("floor-up-steep", "floor", 8, 16),
    Direction("floor-down-gentle", "floor", -16, 8),
    Direction("floor-down", "floor", -8, 8),
    Direction("floor-down-steep", "floor", -8, 16),
    Direction("ceiling", "ceiling", 24, 0),
    Direction("ceiling-up-gentle", "ceiling", 16, 8),
    Direction("ceiling-up", "ceiling", 8, 8),
    Direction("ceiling-up-steep", "ceiling", 8, 16),
    Direction("ceiling-down-gentle", "ceiling", -16, 8),
    Direction("ceiling-down", "ceiling", -8, 8),
    Direction("ceiling-down-steep", "ceiling", -8, 16),
    Direction("wall-rock-right", "wall", 0, 16),
    Direction("wall-rock-left", "wall", 0, 16),
]
DIRECTION_NUMBER = {d.name: n for n, d in enumerate(DIRECTIONS)}
MIRRORED = [0, 4, 5, 6, 1, 2, 3, 7, 11, 12, 13, 8, 9, 10, 15, 14]     # mirror_table
UPSIDE_DOWN = [7, 8, 9, 10, 11, 12, 13, 0, 1, 2, 3, 4, 5, 6, 15, 14]  # upside_down_table

# The full render's steps: the slopes, and flat runs 8 pixels a step, all
# left to right; dy down positive.
TOGGLE_DIRECTIONS = [(8, 0), (16, -8), (8, -8), (8, -16), (16, 8), (8, 8), (8, 16)]

INKS = {"blue": 1, "red": 2, "magenta": 3, "green": 4, "cyan": 5, "yellow": 6, "white": 7}


def attribute(colour: dict) -> int:
    """An ink on black paper, bright or not, as a Spectrum attribute."""
    return INKS[colour["ink"]] | (0x40 if colour.get("bright") else 0)


def surface_offset(dx: int, dy: int, i: int) -> int:
    """The surface's row in column i of a step, relative to its left end."""
    return (dy * i) // dx


@dataclass(frozen=True)
class Drawn:
    """A piece as the renderer draws it, after its tile's markers: Cyberun's
    page coordinates, direction number, steps, end codes (flat pieces)."""
    x: int
    y: int
    direction: int
    steps: int
    ends: tuple = (0, 0)


def drawn(piece: dict, upside_down: bool, mirrored: bool) -> Drawn:
    """What load_piece_steps and piece_ends make of a piece."""
    x, y, steps = piece["x"], piece["y"], piece["steps"]
    n = DIRECTION_NUMBER[piece["direction"]]
    ends = tuple(piece.get("ends", (0, 0)))
    flat = DIRECTIONS[n].rise == 0
    if upside_down:
        n = UPSIDE_DOWN[n]
        if DIRECTIONS[n].kind == "wall":
            # "A wall upside down: 8 pixels over", against its new direction.
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
        x = ~(x + step_x + 15) & 0xFF
        n = MIRRORED[n]
        if flat:
            x = (x - (steps - 1) * 24) & 0xFF
    return Drawn(x, y, n, steps, ends)


@dataclass(frozen=True)
class Surface:
    """A floor or ceiling as a line, page coordinates from 0, left to right:
    from (x, y), `steps` steps of TOGGLE_DIRECTIONS[toggle]."""
    x: int
    y: int
    toggle: int
    steps: int


def surface(d: Drawn) -> Surface | None:
    """A drawn piece's line, or None for a wall (walls cross no column)."""
    shape = DIRECTIONS[d.direction]
    x, y = d.x - CYBERUN_X0, d.y - CYBERUN_Y0
    if shape.kind == "wall":
        return None
    if shape.rise == 0:
        length = (d.steps - 1) * 24 + 8 if d.ends[1] == FIRST_COLUMN_ONLY else d.steps * 24
        return Surface(x, y, 0, length // 8)
    run = abs(shape.run)
    if shape.run > 0:
        return Surface(x, y, TOGGLE_DIRECTIONS.index((run, -shape.rise)), d.steps)
    # Climbing left: x is its lowest step's left edge; from its high left end.
    return Surface(x - (d.steps - 1) * run, y - d.steps * shape.rise,
                   TOGGLE_DIRECTIONS.index((run, shape.rise)), d.steps)


class WorldError(Exception):
    pass


class World:
    def __init__(self, tiles: dict, rows: list[list[str]], colours: dict, start: dict):
        self.tiles = tiles
        self.rows = rows
        self.height = len(rows)
        self.width = len(rows[0])
        # The rock's colours, Cyberun's way: one above cavern_row, one from it
        # down; ink on black paper.
        self.surface_attr = attribute(colours["surface"])
        self.cavern_attr = attribute(colours["caverns"])
        self.cavern_row = colours["cavernRow"]
        self.start = start
        self.world_w = self.width * PAGE_W
        self.world_h = self.height * PAGE_H
        # Tile numbers, in tiles.json's order: what the game's map holds.
        self.tile_names = list(tiles)
        self.tile_number = {name: n for n, name in enumerate(self.tile_names)}
        self._crossings = None

    def pieces(self, name: str) -> list[dict]:
        return self.tiles[name]["pieces"]

    def drawn(self, name: str) -> list[Drawn]:
        tile = self.tiles[name]
        return [drawn(p, tile.get("upsideDown", False), tile.get("mirrored", False))
                for p in tile["pieces"]]

    def surfaces(self, name: str) -> list[Surface]:
        """A tile's floors and ceilings as lines, in the page."""
        return [s for s in (surface(d) for d in self.drawn(name)) if s is not None]

    def page_surfaces(self, column: int, row: int) -> list[Surface]:
        """The surfaces of the page at (column, row), in world coordinates.
        Columns wrap; rows outside the world hold nothing."""
        if not 0 <= row < self.height:
            return []
        column %= self.width
        ox, oy = column * PAGE_W, row * PAGE_H
        return [Surface(ox + s.x, oy + s.y, s.toggle, s.steps)
                for s in self.surfaces(self.rows[row][column])]

    def all_surfaces(self) -> list[Surface]:
        return [s for row in range(self.height) for column in range(self.width)
                for s in self.page_surfaces(column, row)]

    # ---- rock and sky ------------------------------------------------------

    def crossings(self) -> dict[int, list[int]]:
        """For each world column, the sorted rows where sky and rock toggle."""
        if self._crossings is None:
            cross: dict[int, list[int]] = {}
            for s in self.all_surfaces():
                dx, dy = TOGGLE_DIRECTIONS[s.toggle]
                for k in range(s.steps):
                    for i in range(dx):
                        cross.setdefault((s.x + k * dx + i) % self.world_w, []).append(
                            s.y + k * dy + surface_offset(dx, dy, i) + CROSS_DY)
            for rows in cross.values():
                rows.sort()
            self._crossings = cross
        return self._crossings

    def is_rock(self, wx: int, wy: int) -> bool:
        """Rock if an odd number of the column's crossings lie at or above
        the row (a crossing at row r toggles rows r and below)."""
        rows = self.crossings().get(wx % self.world_w, [])
        return bisect.bisect_right(rows, wy) % 2 == 1

    # ---- Cyberun's tile records ---------------------------------------------

    def cyberun_record(self, name: str) -> bytes:
        """The tile as Cyberun's renderer reads it: $99 if upside down, $FF if
        mirrored, the count, then each piece -- x, y, direction and steps (16
        as 0), and a flat piece's two end codes."""
        tile = self.tiles[name]
        if not tile["pieces"]:
            return b"\x00"
        out = bytearray()
        if tile.get("upsideDown"):
            out.append(0x99)
        if tile.get("mirrored"):
            out.append(0xFF)
        out.append(len(tile["pieces"]))
        for piece in tile["pieces"]:
            n = DIRECTION_NUMBER[piece["direction"]]
            out += bytes([piece["x"], piece["y"], n << 4 | (piece["steps"] & 15)])
            if n in (0, 7):
                out += bytes(piece.get("ends", [0, 0]))
        return bytes(out)

    # ---- checks ------------------------------------------------------------

    def validate(self) -> list[str]:
        """Raises on problems that stop the build; returns notes on the world
        that do not."""
        problems = []
        for name, tile in self.tiles.items():
            if len(tile["pieces"]) > MAX_PIECES:
                problems.append(f"tile {name!r}: {len(tile['pieces'])} pieces, more than {MAX_PIECES}")
            for k, piece in enumerate(tile["pieces"]):
                d = DIRECTIONS[DIRECTION_NUMBER[piece["direction"]]]
                if "ends" in piece and (d.kind == "wall" or d.rise):
                    problems.append(f"tile {name!r}, piece {k}: only flat pieces have ends")
                if d.kind != "wall" and d.rise == 0 and "ends" not in piece:
                    problems.append(f"tile {name!r}, piece {k}: a flat piece needs its ends")
        if problems:
            raise WorldError("\n".join(problems))
        cross = self.crossings()
        even = sum(1 for wx in range(self.world_w) if len(cross.get(wx, [])) % 2 == 0)
        notes = []
        if even:
            notes.append(f"{even} of {self.world_w} world columns cross an even number of surfaces, "
                         f"so the full render leaves sky at the bottom of them")
        return notes


def load(directory: Path = WORLD_DIR) -> World:
    tiles = json.loads((directory / "tiles.json").read_text(encoding="utf-8"))["tiles"]
    data = json.loads((directory / "map.json").read_text(encoding="utf-8"))
    rows = data["rows"]
    if len({len(row) for row in rows}) != 1:
        raise WorldError("map.json: the rows are not all the same length")
    for r, row in enumerate(rows):
        for c, name in enumerate(row):
            if name not in tiles:
                raise WorldError(f"map.json: row {r}, column {c}: no tile named {name!r}")
    return World(tiles, rows, data["colours"], data["start"])


def check_schemas(directory: Path = WORLD_DIR) -> None:
    import jsonschema

    for name in ("tiles", "map"):
        data = json.loads((directory / f"{name}.json").read_text(encoding="utf-8"))
        schema = json.loads((directory / f"{name}.schema.json").read_text(encoding="utf-8"))
        jsonschema.validate(data, schema)


if __name__ == "__main__":
    check_schemas()
    world = load()
    try:
        notes = world.validate()
    except WorldError as e:
        sys.exit(f"world.py: the world fails its checks:\n{e}")
    count = len(world.all_surfaces())
    print(f"{world.width} x {world.height} pages, {len(world.tiles)} tiles, {count} floors and ceilings; checks pass")
    for note in notes:
        print("note:", note)
