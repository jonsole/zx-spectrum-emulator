"""Draws map.txt with blocks.png's blocks, without running the game.

    python preview.py                  # output/map.png: the whole planet, full size
    python preview.py --scale 4        # a quarter the size, to see it all at once
    python preview.py --grid           # with a line every block, to count by

The landscape is cyan, as in the game; things drawn but not solid (grass,
water) are green here to tell them apart, though the game draws them in the
landscape's one colour. Where the astronaut starts is outlined in yellow.
"""

import argparse
import sys
from pathlib import Path

from PIL import Image, ImageDraw

sys.path.insert(0, str(Path(__file__).resolve().parent))
import blocks  # noqa: E402
import planet  # noqa: E402

HERE = Path(__file__).resolve().parent
OUT = HERE / "output"

CYAN = (0, 205, 205)
GREEN = (0, 205, 0)
GRID = (40, 40, 40)
START = (255, 255, 0)


def start_position():
    """START_X and START_Y, read out of player.s so they cannot disagree."""
    values = {}
    for line in (HERE / "player.s").read_text().splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0] in ("START_X", "START_Y") and parts[1] == "equ":
            values[parts[0]] = int(parts[2], 0)
    return values.get("START_X"), values.get("START_Y")


def render(grid: bool) -> Image.Image:
    bs = blocks.BlockSet()
    world = planet.read(bs)
    side = blocks.BLOCK_PX
    image = Image.new("RGB", (planet.MAP_W * side, planet.MAP_H * side))
    tiles = []
    for n in range(len(bs.legend)):
        tile = Image.new("RGB", (side, side))
        for y, row in enumerate(bs.pixels[n]):
            for x, p in enumerate(row):
                if p == "ink":
                    tile.putpixel((x, y), CYAN)
                elif p == "decor":
                    tile.putpixel((x, y), GREEN)
        tiles.append(tile)
    for ty in range(planet.MAP_H):
        for tx in range(planet.MAP_W):
            n = world[ty * planet.MAP_W + tx]
            if n:
                image.paste(tiles[n], (tx * side, ty * side))
    pen = ImageDraw.Draw(image)
    if grid:
        for i in range(planet.MAP_W + 1):
            pen.line([(i * side, 0), (i * side, image.height)], fill=GRID)
        for i in range(planet.MAP_H + 1):
            pen.line([(0, i * side), (image.width, i * side)], fill=GRID)
    sx, sy = start_position()
    if sx is not None and sy is not None:
        pen.rectangle([sx + 4, sy + 1, sx + 11, sy + 15], outline=START)
    return image


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--scale", type=int, default=1, help="shrink by this much")
    ap.add_argument("--grid", action="store_true", help="draw the block grid")
    args = ap.parse_args()
    try:
        image = render(args.grid)
    except ValueError as e:
        sys.exit(f"error: {e}")
    if args.scale > 1:
        image = image.resize((image.width // args.scale, image.height // args.scale), Image.BOX)
    OUT.mkdir(exist_ok=True)
    image.save(OUT / "map.png")
    print(f"wrote {OUT / 'map.png'}")


if __name__ == "__main__":
    main()
