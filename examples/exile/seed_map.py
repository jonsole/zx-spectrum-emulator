"""Seeds map.txt from a generated cave system, so hand-placing starts from
something rather than a blank planet.

    python seed_map.py [--force]

Run once; after that map.txt is the source, edited by hand, and this refuses
to overwrite it without --force.

The caves come from the rule the first prototype worked out on the Z80 as you
flew: seed_regions.txt is a coarse map of regions -- sky, cave, rock, water,
masonry -- and a lattice of corners takes each region's kind from a point
nudged along a smooth random walk, so the straight edges between regions come
out as wandering cave walls. Each block then takes the piece that best fits
which of its four corners are rock (marching squares): a full block, a slope,
a half, a small corner. Masonry becomes brick, water regions water, and the
open block on top of rock under the sky gets grass.

The generated planet is 256 x 256 blocks; map.txt holds a 128 x 128 stretch
of it, the sky and the caves under the landing pad.
"""

from pathlib import Path

import blocks
import planet

HERE = Path(__file__).resolve().parent

# The coarse map's size in regions, and a region's size in corners.
MAP_W = 32
MAP_H = 32
REGION = 8
CORNERS = MAP_W * REGION  # 256: corner coordinates are bytes

# Region kinds. The built kinds come last, so one compare tells them apart.
SKY, CAVE, ROCK, WATER, MASONRY, CHAMBER = range(6)
KINDS = {" ": SKY, ".": CAVE, "#": ROCK, "=": MASONRY, "o": CHAMBER, "~": WATER}


def load_map(path: Path = HERE / "seed_regions.txt") -> list[int]:
    """seed_regions.txt's regions, row-major, as kind bytes."""
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


# Marching-squares shape -> the block that stands for it. A saddle (two
# opposite corners) is filled in: the cave reads better closed than pinched.
# A single rock corner is left open -- as a block it is a sliver that reads
# as a stray line off the wall; the small corner pieces are for placing by
# hand.
SHAPE_BLOCK = {
    0: " ", 15: "#", 5: "#", 10: "#",
    14: "7", 13: "F", 11: "L", 7: "J",
    12: "^", 3: "_", 9: "[", 6: "]",
    8: " ", 4: " ", 2: " ", 1: " ",
}

# Which stretch of the generated planet map.txt holds, in blocks.
CROP_X = 32
CROP_Y = 0


def _only_masonry(world: list[int], tx: int, ty: int) -> bool:
    """Whether every rock corner of block (tx, ty) is inside masonry."""
    for x, y in ((tx, ty), (tx + 1, ty), (tx, ty + 1), (tx + 1, ty + 1)):
        x &= 0xFF
        y &= 0xFF
        if corner_solid(world, x, y) and world[(y >> 3) * MAP_W + (x >> 3)] != MASONRY:
            return False
    return True


def seeded_map(blockset) -> list[int]:
    world = load_map()
    grid = []
    for y in range(planet.MAP_H):
        row = []
        for x in range(planet.MAP_W):
            tx, ty = CROP_X + x, CROP_Y + y
            char = SHAPE_BLOCK[tile_shape(world, tx, ty)]
            kind = world[(ty >> 3) * MAP_W + (tx >> 3)]
            if char == "#" and kind == MASONRY:
                char = "="
            elif char not in " #" and _only_masonry(world, tx, ty):
                # The fringe of a built wall: the wall stops square.
                char = " "
            elif char == " " and kind == WATER:
                char = "~"
            # A rock border all round, so nothing walks off the edge.
            if x in (0, planet.MAP_W - 1) or y in (0, planet.MAP_H - 1):
                char = "#"
            row.append(char)
        grid.append(row)
    # Grass on open ground under the sky, wherever the block below is flat
    # on top.
    world_kinds = world
    for y in range(planet.MAP_H - 1):
        for x in range(planet.MAP_W):
            tx, ty = CROP_X + x, CROP_Y + y
            sky = world_kinds[(ty >> 3) * MAP_W + (tx >> 3)] == SKY
            if sky and grid[y][x] == " " and grid[y + 1][x] in "#_":
                grid[y][x] = '"'
    return [blockset.chars[c] for row in grid for c in row]


HEADER = [
    "The planet, a block a character: blocks.json says which character is",
    "which block. Each row is between two |s; lines that do not start with |",
    "are comments. 128 x 128 blocks, each 16 pixels square, top row first.",
    "Seeded by seed_map.py, then edited by hand.",
]


def main() -> None:
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--force", action="store_true", help="overwrite map.txt")
    args = ap.parse_args()
    if planet.MAP_FILE.exists() and not args.force:
        raise SystemExit("map.txt exists and is the source now; --force to seed it again")
    bs = blocks.BlockSet()
    planet.write(bs, seeded_map(bs), HEADER)
    print(f"wrote {planet.MAP_FILE}")


if __name__ == "__main__":
    main()
