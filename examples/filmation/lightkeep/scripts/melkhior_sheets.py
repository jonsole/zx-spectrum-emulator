"""Melkhior's Mansion's artwork as six Filmation sprite sheets, one for each
category its own viewer lists: Objects, Furniture, Doors, Characters, Walls
and Floors.

    python scripts/melkhior_sheets.py               convert what is not there yet
    python scripts/melkhior_sheets.py --force walls convert the walls again

Reads your own copy of the game, unpacked the way the viewer in
~/Downloads/MelkhiorsMansion has it -- viewer/data.json for each type's frame
layout, out/Graphics/<category>/*.png for the pictures -- and writes, for each
category:

    art/melkhior/<category>.png         the sheet, never committed
    metadata/melkhior/<category>.json   where each sprite is in it, which is
                                        committed: names and rectangles, no
                                        pixels

Each sprite is one frame of one of Melkhior's types, in 1-bit the way the
"Melkhior in Mono" page shows them: trimmed to its mask, with every pixel
near enough Melkhior's black as paper and the rest as ink. graphics.json
names one as its sheet, its type and its frame -- furniture:GrandfatherClockNE.2
-- and listing the sheets under "sheets" there is what lets it. Nothing here
puts a sprite in the game: a sprite costs bytes only once a graphic draws it,
which is the graphic-map editor's job.

Converted once, then yours. A sheet that is already there is left alone, since
it may be holding retouching that has no other copy; --force converts it again
over the top. The rectangles in metadata/ come out the same every time from
the same copy of the game, so a fresh tree that converts gets the same names
and places the committed file already gives.

A type that is only another one flipped -- Milky2 is Milky1 facing the other
way -- is left out and its name is written beside the one it flips on the
sheet: the engine mirrors a sprite itself, with a nudge of its own. A type
whose frames are another's exactly is left out the same way.

Frames larger than the engine draws in one go -- five bytes wide, 64 rows --
are on the sheet whole, to be seen and cut up. The build stops if a graphic
names one as it stands.
"""

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
import layout                                                   # noqa: E402
import sheet                                                    # noqa: E402

HERE = Path(__file__).resolve().parent.parent      # the game's folder
MELKHIOR = Path.home() / "Downloads" / "MelkhiorsMansion"
FOLDER = "melkhior"                 # in art/ and in metadata/ alike

# The viewer's categories, as its own folders name them, and the sheet each
# becomes: its name in graphics.json and in a sprite's, and its files' name.
CATEGORIES = ("Objects", "Furniture", "Doors", "Characters", "Walls", "Floors")

# Melkhior's sixteen colours, as its PaletteLookup.png has them. A pixel is
# taken as the nearest of these, and the two blacks are paper.
PALETTE = [(0, 0, 0), (4, 2, 132), (220, 2, 4), (228, 2, 180), (4, 210, 4),
           (4, 210, 212), (204, 206, 4), (204, 198, 204), (0, 0, 0), (4, 2, 172),
           (236, 2, 4), (252, 2, 220), (4, 238, 4), (4, 250, 252), (252, 254, 4),
           (255, 255, 255)]
BLACKS = (0, 8)
OPAQUE = 128                        # alpha at or above this is part of the frame

# What the engine draws as one sprite -- BLIT_COLUMNS in engine/sprite.s is
# one more than the widest, and redraw.s's union is sized for 64 rows -- and
# the narrowest record a blit has a routine for.
WIDEST_BYTES = 5
TALLEST_ROWS = 64
NARROWEST_BYTES = 2


def sheet_name(category):
    """What a category's sheet is called: its name in graphics.json, in a
    sprite's name, and its files'."""
    return category.lower()


def png_path(here, category):
    return layout.art(here) / FOLDER / (sheet_name(category) + ".png")


def json_path(here, category):
    return layout.metadata(here) / FOLDER / (sheet_name(category) + ".json")


_nearest = {}


def paper(rgb):
    """Whether a colour is Melkhior's black, by the nearest of its sixteen."""
    if rgb not in _nearest:
        best = min(range(len(PALETTE)),
                   key=lambda i: sum((a - b) ** 2 for a, b in zip(PALETTE[i], rgb)))
        _nearest[rgb] = best in BLACKS
    return _nearest[rgb]


class Pictures:
    """The category pictures, each opened once."""

    def __init__(self, root):
        self.root = root
        self.open = {}

    def get(self, img):
        if img not in self.open:
            self.open[img] = Image.open(self.root / "out" / (img + ".png")).convert("RGBA")
        return self.open[img]


def cells_of(kind, picture):
    """Where each of a type's frames is in its picture, in the type's order.

    A picture is a grid of frames, fw by fh, read across and down. Where the
    type carries its shadow in the same picture (shinc), each row of frames
    is three rows high and the frame is the top one. A range, where one is
    given, picks the type's frames out of a picture several types share.
    """
    width, height = picture.size
    fw, fh = kind["fw"], kind["fh"]
    step = fh * (3 if kind["shinc"] else 1)
    rows = max(height // step, 1)
    count = (width // fw) * rows
    low, high = kind["range"]["min"], kind["range"]["max"]
    if low < 0:
        low, high = 0, count - 1
    cells, x, y = [], 0, 0
    for i in range(count):
        if low <= i <= high:
            cells.append((x, y))
        x += fw
        if x >= width:
            x, y = 0, y + step
    return cells


def mono(frame):
    """A frame -> a sprite as sheet.py draws one, or None if it is empty.

    Trimmed to its mask, then made up to whole bytes on the right; at least
    two, since a record narrower than that has no blit.
    """
    alpha = frame.getchannel("A").point(lambda v: 255 if v >= OPAQUE else 0)
    box = alpha.getbbox()
    if not box:
        return None
    frame = frame.crop(box)
    w, h = frame.size
    width = max(NARROWEST_BYTES, (w + 7) // 8)
    pixels = frame.load()
    mask, data, look = [], [], []
    for y in range(h):
        m, d = bytearray(width), bytearray(width)
        for x in range(w):
            r, g, b, a = pixels[x, y]
            if a < OPAQUE:
                continue
            m[x >> 3] |= 0x80 >> (x & 7)
            if not paper((r, g, b)):
                d[x >> 3] |= 0x80 >> (x & 7)
        mask.append(bytes(m))
        data.append(bytes(d))
        # Each pixel as hole, paper or ink, row by row, at its own width: what
        # it looks like, and what it would look like facing the other way.
        look.append(tuple(0 if pixels[x, y][3] < OPAQUE
                          else 1 if paper(pixels[x, y][:3]) else 2 for x in range(w)))
    return {"w": width, "h": h, "mask": mask, "data": data, "trim": 0,
            "look": tuple(look), "turned": tuple(row[::-1] for row in look)}


def picture_of(sprite):
    """What a sprite looks like, to compare with another."""
    return sprite["look"]


def convert(category, kinds, pictures):
    """One category -> (sprites, bands, tree, what was left out).

    A band to a type, in the order of their names, and in it the type's
    frames by Melkhior's own frame number -- which is what a sprite is
    called, so a frame that repeats an earlier one leaves a gap in the
    numbers rather than renumbering the rest.
    """
    sprites, bands, tree = [], [], {"group": {}}
    seen = {}               # a type's frames -> the type that has them
    turned = {}             # ...and the same, facing the other way
    left_out = []
    for tid in sorted(kinds, key=str.lower):
        kind = kinds[tid]
        try:
            picture = pictures.get(kind["img"])
        except FileNotFoundError:
            left_out.append((tid, "its picture is missing"))
            continue
        frames = []
        pictured = set()
        for n, (x, y) in enumerate(cells_of(kind, picture)):
            frame = picture.crop((x, y, x + kind["fw"], y + kind["fh"]))
            if kind["flip"]:
                frame = frame.transpose(Image.FLIP_LEFT_RIGHT)
            sprite = mono(frame)
            if sprite is None or picture_of(sprite) in pictured:
                continue
            pictured.add(picture_of(sprite))
            frames.append((n, sprite))
        if not frames:
            left_out.append((tid, "it has no frame with anything in it"))
            continue
        key = tuple(picture_of(s) for _n, s in frames)
        if key in seen:
            left_out.append((tid, "it is " + seen[key]))
            continue
        if key in turned:
            left_out.append((tid, "it is " + turned[key] + " mirrored"))
            continue
        seen[key] = tid
        turned[tuple(s["turned"] for _n, s in frames)] = tid
        members = []
        group = {"sprites": {}}
        for n, sprite in frames:
            members.append(len(sprites))
            sprite["name"] = str(n)
            sprites.append(sprite)
        bands.append([tid, tid, members])
        tree["group"][tid] = group
    # The title on the picture says what each type stands in for as well.
    stands_for = {}
    for tid, why in left_out:
        if why.startswith("it is "):
            stands_for.setdefault(why[6:].split(" ")[0], []).append(tid)
    for band in bands:
        if band[0] in stands_for:
            band[1] = band[0] + "  (also " + ", ".join(stands_for[band[0]]) + ")"
    return sprites, bands, tree, left_out


def main():
    parser = argparse.ArgumentParser(
        description="Convert Melkhior's Mansion's art into one sprite sheet a category.")
    parser.add_argument("categories", nargs="*",
                        help="which to convert (default: all six): "
                             + ", ".join(sheet_name(c) for c in CATEGORIES))
    parser.add_argument("--from", dest="source", type=Path, default=MELKHIOR,
                        help="your unpacked copy of the game (default: %s)" % MELKHIOR)
    parser.add_argument("--force", action="store_true",
                        help="convert a sheet again over the one there, and any "
                             "retouching in it")
    args = parser.parse_args()

    wanted = list(CATEGORIES)
    if args.categories:
        names = {sheet_name(c): c for c in CATEGORIES}
        unknown = [c for c in args.categories if c.lower() not in names]
        if unknown:
            raise SystemExit("no such category: %s -- there are %s"
                             % (", ".join(unknown), ", ".join(names)))
        wanted = [names[c.lower()] for c in args.categories]

    data = args.source / "viewer" / "data.json"
    if not data.is_file():
        raise SystemExit("%s is missing -- point --from at your unpacked copy of "
                         "Melkhior's Mansion, the folder its viewer is in" % data)
    kinds = json.loads(data.read_text(encoding="utf-8"))["types"]
    pictures = Pictures(args.source)

    for category in wanted:
        png, described = png_path(HERE, category), json_path(HERE, category)
        if png.is_file() and not args.force:
            print("%s: %s is there already, and is left alone -- it may hold "
                  "retouching. --force converts it again over the top."
                  % (category, png.relative_to(HERE)))
            continue
        mine = {tid: k for tid, k in kinds.items() if k["img"].split("/")[1] == category}
        sprites, bands, tree, left_out = convert(category, mine, pictures)
        size = sheet.lay_out(sprites, bands)
        png.parent.mkdir(parents=True, exist_ok=True)
        described.parent.mkdir(parents=True, exist_ok=True)
        sheet.draw(sprites, bands, size).save(png)
        for tid, _title, members in bands:
            for n in members:
                s = sprites[n]
                tree["group"][tid]["sprites"][s["name"]] = {
                    "x": s["x"], "y": s["y"], "w": s["w"] * 8, "h": s["h"]}
        # The picture, relative to the description: metadata/melkhior/ to
        # art/melkhior/, or side by side in a flat folder.
        tree["sheet"] = {"file": ("" if layout.flat(HERE) else "../../" + layout.ART
                                  + "/" + FOLDER + "/") + png.name}
        described.write_text(sheet.format_sheet(tree), encoding="utf-8")
        big = sum(1 for s in sprites if s["w"] > WIDEST_BYTES or s["h"] > TALLEST_ROWS)
        print("%s: %d types, %d sprites (%d bigger than one sprite can be), %dx%d -> %s"
              % (category, len(bands), len(sprites), big, size[0], size[1],
                 png.relative_to(HERE)))
        for tid, why in left_out:
            print("   left out %s: %s" % (tid, why))


if __name__ == "__main__":
    main()
