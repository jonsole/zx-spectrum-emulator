"""Draws the planet without running the game, from world.py's reference rule.

    python preview.py                      # output/world.png, the whole planet at 1/4 scale
    python preview.py --at 40 34 --size 64 40   # output/detail.png, tiles at full size

--at is a tile to start at and --size how many tiles across and down. The
detail uses the game's own tile graphics, so it is what the screen shows,
less the colour.
"""

import argparse
from pathlib import Path

import tiles
import world
from png import write_png

HERE = Path(__file__).resolve().parent
OUT = HERE / "output"

INK = (205, 205, 205)
PAPER = (0, 0, 0)
SKY = (0, 0, 64)


def overview(path: Path) -> None:
    """One pixel per 4 x 4 of the planet: a tile is 4 x 4 here."""
    w = world.load_map()
    side = world.CORNERS * 4
    masks = [tiles.mask_pixels(s) for s in range(16)]
    rgb = bytearray(side * side * 3)
    for ty in range(world.CORNERS):
        for tx in range(world.CORNERS):
            m = masks[world.tile_shape(w, tx, ty)]
            sky = w[(ty >> 3) * world.MAP_W + (tx >> 3)] == world.SKY
            for y in range(4):
                for x in range(4):
                    c = INK if m[y * 4 + 2][x * 4 + 2] else (SKY if sky else PAPER)
                    o = ((ty * 4 + y) * side + tx * 4 + x) * 3
                    rgb[o:o + 3] = bytes(c)
    write_png(path, side, side, bytes(rgb))


def detail(path: Path, tx0: int, ty0: int, tw: int, th: int) -> None:
    w = world.load_map()
    pix = [tiles.tile_pixels(s) for s in range(16)]
    width, height = tw * 16, th * 16
    rgb = bytearray(width * height * 3)
    for ty in range(th):
        for tx in range(tw):
            p = pix[world.tile_shape(w, tx0 + tx & 0xFF, ty0 + ty & 0xFF)]
            for y in range(16):
                for x in range(16):
                    if p[y][x]:
                        o = ((ty * 16 + y) * width + tx * 16 + x) * 3
                        rgb[o:o + 3] = bytes(INK)
    write_png(path, width, height, bytes(rgb))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--at", nargs=2, type=int, metavar=("TX", "TY"))
    ap.add_argument("--size", nargs=2, type=int, metavar=("W", "H"), default=(64, 40))
    args = ap.parse_args()
    OUT.mkdir(exist_ok=True)
    if args.at:
        detail(OUT / "detail.png", *args.at, *args.size)
        print(f"wrote {OUT / 'detail.png'}")
    else:
        overview(OUT / "world.png")
        print(f"wrote {OUT / 'world.png'}")


if __name__ == "__main__":
    main()
