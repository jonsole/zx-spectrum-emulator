"""The landscape, as the Z80 computes it -- the reference the game is held to.

The planet is never stored whole. What is stored is world.txt's coarse map,
32 x 32 regions, and a 256-byte permutation; everything finer is worked out
on demand from those two, the way Exile's own landscape was. The rule has two
levels:

* A *corner* lattice, 256 x 256, each corner solid or open. A corner looks up
  its region in the coarse map -- but from a point nudged a few corners off by
  a hash of where it is, so the straight edges between regions come out as
  ragged rock. Masonry and chambers are looked up without the nudge, which is
  what keeps built walls straight.

* A *tile*, 16 x 16 pixels, between every four corners. Its shape is one of
  sixteen, picked by which of its corners are solid (marching squares), so
  the cave walls run diagonally and round rather than in steps.

Every function here is written in the integer arithmetic world.s does, byte
for byte, so this file can say what the Z80 should have computed and the
preview can show the planet without running the game.
"""

from pathlib import Path

HERE = Path(__file__).resolve().parent

# The coarse map's size in regions, and a region's size in corners. world.s
# relies on both: a region index is (y >> 3) * 32 + (x >> 3).
MAP_W = 32
MAP_H = 32
REGION = 8
CORNERS = MAP_W * REGION  # 256: corner coordinates are bytes

TILE_PX = 16  # a tile's side in pixels -- two character cells

# Region kinds, as bytes in the packed map. The built kinds come last, so
# world.s can tell them apart with one compare.
SKY, CAVE, ROCK, WATER, MASONRY, CHAMBER = range(6)
KINDS = {" ": SKY, ".": CAVE, "#": ROCK, "=": MASONRY, "o": CHAMBER, "~": WATER}


def load_map(path: Path = HERE / "world.txt") -> list[int]:
    """world.txt's regions, row-major, as kind bytes."""
    rows = []
    for line in path.read_text().splitlines():
        if line.startswith("|"):
            row = line[1:line.index("|", 1)]
            if len(row) != MAP_W:
                raise ValueError(f"map row is {len(row)} regions, not {MAP_W}: {line!r}")
            rows.append([KINDS[c] for c in row])
    if len(rows) != MAP_H:
        raise ValueError(f"map has {len(rows)} rows, not {MAP_H}")
    return [k for row in rows for k in row]


def make_perm(seed: int = 0x5EED) -> list[int]:
    """A fixed shuffle of 0..255, from our own LCG so it never changes with
    the Python it is built by."""
    perm = list(range(256))
    state = seed
    for i in range(255, 0, -1):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        j = (state >> 8) % (i + 1)
        perm[i], perm[j] = perm[j], perm[i]
    return perm


PERM = make_perm()


def make_wave(seed: int = 0x3A7) -> list[int]:
    """256 nudges, -3..+4, each within one of the last and wrapping round
    smoothly: a random walk, so an edge drawn from it wanders rather than
    jumps."""
    wave = []
    v = 0
    state = seed
    for i in range(256):
        state = (state * 1103515245 + 12345) & 0x7FFFFFFF
        step = (state >> 12) % 3 - 1
        # Lean back towards the middle as the walk nears either end, and over
        # the last stretch towards where it started, so index 255 meets 0.
        if v + step > 4 or v + step < -3:
            step = -step
        if i >= 248 and abs(v + step) > 255 - i:
            step = -1 if v > 0 else 1
        v += step
        wave.append(v)
    return wave


WAVE = make_wave()


def warp(x: int, y: int) -> tuple[int, int]:
    """How far corner (x, y) looks off itself into the coarse map.

    Across: a nudge that depends on y, so an upright edge between regions
    becomes a wavy line down the screen; down: one that depends on x, for the
    flat edges. Each is read from the random walk at a place picked by the
    edge it is nearest -- x + 4 >> 3 is constant from four corners before an
    upright region edge to four after it, so both sides of the edge wave
    together -- and so no two edges wave alike. A nudge that changed freely from corner to
    corner would scatter specks of rock about the open caves instead."""
    dx = WAVE[(y + PERM[(x + 4 & 0xFF) >> 3]) & 0xFF]
    dy = WAVE[(x + PERM[((y + 4 & 0xFF) >> 3) + 0x80]) & 0xFF]
    return dx, dy


def corner_solid(world: list[int], x: int, y: int) -> int:
    """Whether corner (x, y) is rock.

    Built regions -- masonry and chambers -- are what they say, unnudged.
    Anything else takes the kind of the region its nudge lands in, unless that
    is a built one: then it keeps its own. That is what keeps a built wall
    straight from both sides -- open ground beside it does not bulge into it,
    and rock beside it does not shrink away from it and leave a gap."""
    own = world[(y >> 3) * MAP_W + (x >> 3)]
    if own == MASONRY:
        return 1
    if own == CHAMBER:
        return 0
    dx, dy = warp(x, y)
    wx = (x + dx) & 0xFF
    wy = (y + dy) & 0xFF
    kind = world[(wy >> 3) * MAP_W + (wx >> 3)]
    if kind >= MASONRY:
        kind = own
    return 1 if kind == ROCK else 0


def tile_shape(world: list[int], tx: int, ty: int) -> int:
    """Marching-squares index of tile (tx, ty): top-left corner 8, top-right
    4, bottom-right 2, bottom-left 1."""
    return (corner_solid(world, tx, ty) << 3
            | corner_solid(world, tx + 1 & 0xFF, ty) << 2
            | corner_solid(world, tx + 1 & 0xFF, ty + 1 & 0xFF) << 1
            | corner_solid(world, tx, ty + 1 & 0xFF))


def shape_field(shape: int, u: float, v: float) -> float:
    """How solid a point is within a tile of this shape: the bilinear blend
    of its four corners, 0 to 1. Solid is 0.5 and over. Bilinear rather than
    the textbook straight midpoint lines because it rounds the caves off, and
    because along a tile's edge it depends on that edge's two corners only --
    so neighbouring tiles always meet."""
    tl = shape >> 3 & 1
    tr = shape >> 2 & 1
    br = shape >> 1 & 1
    bl = shape & 1
    return (tl * (1 - u) * (1 - v) + tr * u * (1 - v)
            + bl * (1 - u) * v + br * u * v)


def shape_solid(shape: int, px: int, py: int) -> bool:
    """Whether pixel (px, py) of a tile is rock -- the collision mask."""
    return shape_field(shape, (px + 0.5) / TILE_PX, (py + 0.5) / TILE_PX) >= 0.5
