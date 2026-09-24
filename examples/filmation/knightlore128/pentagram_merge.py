"""Pentagram's sprites into Knight Lore 128K's sheet: run once, 2026-09-24.

This game's art is both games' art. Knight Lore's is the sheet the fork began
with; this adds every one of Pentagram's 88 sprites to it, from
../pentagram/sprites.png and sprites.json, and gives the ones the game can
draw a graphic number each.

    python pentagram_merge.py

What it does:

  sprites.png    Pentagram's picture goes underneath Knight Lore's. The two
                 sheets share a width and a palette, so its frames are kept as
                 they are, one sheet's height further down.
  sprites.json   Pentagram's sprites go in a group of their own, "pentagram",
                 named for what they are rather than numbered: the tree walls,
                 the stone archway, the well, the dragon's head. NAMES below
                 is where each came from.
  graphics.json  A number each, from 188 up -- Knight Lore's own run to 187 and
                 its code does arithmetic on them, so they stay put. Pentagram
                 gave the same sprite several numbers, one for each thing its
                 code did with it; the remake picks behaviour by template, not
                 by graphic, so one number is enough for each sprite and nudge
                 and box, for the graphics its rooms place and its code
                 draws (WANTED, below).

Some of Pentagram's art belongs to its own game and gets no number: its
Sabreman, its panel and the frame round its end screen, its collectables, the
quest's items and the pentagram's pieces. They are in the sheet all the same,
and sprite_source.py leaves a sprite no graphic draws out of the game.

It stops if the sheet has a "pentagram" group already, so running it twice
does nothing. Pentagram's sheet is only read.
"""

import json
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
PENTAGRAM = HERE.parent / "pentagram"
sys.path.insert(0, str(HERE.parent))
import graphics as gfx                                          # noqa: E402
import sheet                                                    # noqa: E402

FIRST_NUMBER = 188          # one past Knight Lore's last

# Pentagram's sprite N (its sheet names them sprites.1 to sprites.88) and what
# it is here: its path under "pentagram".
# Identified from the sheet, from the graphics that draw each, and from what
# ../pentagram's code does with those -- see its movers.s, flyers.s, quest.s,
# panel.s and gameover.s.
NAMES = {
    1: "piece.1", 2: "piece.2", 3: "piece.3", 4: "piece.4",     # the pentagram's
    5: "piece.5", 6: "piece.6", 7: "piece.7", 8: "piece.8",     # eight pieces
    9: "water.1", 10: "water.2",                                # deadly water
    11: "block.2", 12: "block.3", 13: "block.4",                # a block crumbling
    14: "dragon.1",                                             # a dragon's head
    15: "faller.1", 16: "faller.2", 17: "faller.3", 18: "faller.4",
    19: "faller.5", 20: "faller.6",                             # fall, then roam
    21: "homer.1", 22: "homer.2", 23: "homer.3", 24: "homer.4",
    25: "homer.5", 26: "homer.6", 27: "homer.7", 28: "homer.8", # fall, then home
    29: "puff.1", 30: "puff.2", 31: "puff.3", 32: "puff.4",     # what things die in
    33: "bolt.1", 34: "bolt.2", 35: "bolt.3",                   # Sabreman's bolt
    36: "stump.2",                                              # never drawn there
    37: "cube.1",                                               # a cube he can push
    38: "thorns.1",
    39: "grass.1",                                              # spiky grass, a bush
    40: "panel.1",                                              # the little Sabreman
    41: "block.1",                                              # the plain block
    42: "panel.2", 43: "panel.3", 44: "panel.4", 45: "panel.5", 46: "panel.6",
    47: "table.1",
    48: "well.1",
    49: "quest.1", 50: "quest.2",                               # the quest's items
    51: "well.2",                                               # the well's bucket
    52: "collectable.1", 53: "collectable.2", 54: "collectable.3",
    55: "collectable.4", 56: "collectable.5",
    57: "sabreman.1", 58: "sabreman.2", 59: "sabreman.3", 60: "sabreman.4",
    61: "sabreman.5", 62: "sabreman.6", 63: "sabreman.7", 64: "sabreman.8",
    65: "sabreman.9", 66: "sabreman.10", 67: "sabreman.11", 68: "sabreman.12",
    69: "frame.1", 70: "frame.2", 71: "frame.3", 72: "frame.4", # the end screen's
    73: "door.trees.1", 74: "door.trees.2",                     # an arch of trunks
    75: "stump.1",
    76: "wall.trees.1", 77: "wall.trees.2", 78: "wall.trees.3", 79: "wall.trees.4",
    80: "wall.stone.1", 81: "wall.stone.2", 82: "wall.stone.3", 83: "wall.stone.4",
    84: "wall.stone.5", 87: "wall.stone.6",
    85: "door.stone.2", 86: "door.stone.1",                     # a stone archway
    88: "creature.1",                                           # the spider and co
}

# The groups of the above that belong to Pentagram's own game: in the sheet,
# never given a number.
NOT_DRAWN = ("piece", "panel", "quest", "collectable", "sabreman", "frame")

# Pentagram's graphic numbers that are worth one here: every graphic a template
# some room places draws, and the ones its code puts up itself -- the
# creature's second frame (17), the things that fall from the sky and home in
# or roam (48-51, 80, 81, 160-171), the puff things die in (64-71), the well's
# bucket (90), a block's cracks as it crumbles (137-139), the one conveyor
# direction no room places (141) and the bolt (149-151). The rest of its table
# is graphics nothing draws, and one of those decodes to a box 106 by 155 by
# 172: not worth a number.
PLACED = (6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 23, 28, 30, 52, 53, 54, 55, 56,
          57, 63, 72, 73, 74, 75, 76, 78, 79, 82, 84, 86, 87, 88, 89, 91, 92, 93,
          120, 136, 140, 142, 143)
DRAWN_BY_CODE = ((17, 90, 141) + tuple(range(48, 52)) + tuple(range(64, 72))
                 + (80, 81) + tuple(range(137, 140)) + tuple(range(149, 152))
                 + tuple(range(160, 172)))
WANTED = set(PLACED) | set(DRAWN_BY_CODE)


def main():
    atlas_path, sheet_path = HERE / "sprites.json", HERE / "sprites.png"
    table_path = HERE / "graphics.json"
    ours = json.loads(atlas_path.read_text(encoding="utf-8"))
    if "pentagram" in (ours.get("group") or {}):
        sys.exit("sprites.json has Pentagram's sprites already")
    theirs = json.loads((PENTAGRAM / "sprites.json").read_text(encoding="utf-8"))
    if theirs["sheet"]["colours"] != ours["sheet"]["colours"] or theirs["bytes"] != ours["bytes"]:
        sys.exit("the two sheets do not share a palette and a byte layout")

    # The picture: theirs under ours.
    mine, other = Image.open(sheet_path).convert("RGBA"), \
        Image.open(PENTAGRAM / "sprites.png").convert("RGBA")
    if mine.width != other.width:
        sys.exit("the two sheets are not the same width")
    below = mine.height
    merged = Image.new("RGBA", (mine.width, mine.height + other.height), (0, 0, 0, 0))
    merged.paste(mine, (0, 0))
    merged.paste(other, (0, below))

    # The tree: every sprite, under its name.
    boxes = theirs["group"]["sprites"]["sprites"]
    if sorted(int(k) for k in boxes) != sorted(NAMES):
        sys.exit("Pentagram's sheet is not the 88 sprites NAMES describes")
    group = {"group": {}}
    for key in sorted(boxes, key=int):
        path = NAMES[int(key)].split(".")
        node = group
        for part in path[:-1]:
            node = node.setdefault("group", {}).setdefault(part, {})
        box = dict(boxes[key])
        box["y"] += below
        node.setdefault("sprites", {})[path[-1]] = box
    ours["group"]["pentagram"] = group

    # The numbers: one for each sprite, nudge and box a drawn graphic has.
    said = json.loads((PENTAGRAM / "graphics.json").read_text(encoding="utf-8"))["graphics"]
    table = json.loads(table_path.read_text(encoding="utf-8"))["graphics"]
    kinds = {}
    for name, entry in sorted(said.items(), key=lambda kv: kv[1]["number"]):
        sprite = entry.get("sprite")
        if sprite is None or entry["number"] not in WANTED:
            continue
        ours_name = "pentagram." + NAMES[int(sprite.split(".")[1])]
        if ours_name.split(".")[1] in NOT_DRAWN:
            continue
        kind = (ours_name, entry.get("x", 0), entry.get("y", 0),
                json.dumps(entry.get("mirrored")), json.dumps(entry.get("size")))
        kinds.setdefault(kind, []).append(entry)
    per_sprite = {}
    for kind in kinds:
        per_sprite[kind[0]] = per_sprite.get(kind[0], 0) + 1
    number = FIRST_NUMBER
    for kind, entries in kinds.items():
        sprite, first = kind[0], entries[0]
        name = sprite if per_sprite[sprite] == 1 else "%s.g%d" % (sprite, number)
        if name in table:
            sys.exit("graphics.json has a %s already" % name)
        new = {"number": number, "sprite": sprite}
        for field in ("size", "x", "y", "mirrored"):
            if first.get(field) is not None:
                new[field] = first[field]
        table[name] = new
        number += 1
    if number > 256:
        sys.exit("Pentagram's graphics need numbers up to %d, and a number is a byte" % (number - 1))

    merged.save(sheet_path)
    atlas_path.write_text(sheet.format_sheet(ours, ours.get("animations")), encoding="utf-8")
    table_path.write_text(gfx.format_table(table), encoding="utf-8")
    print("merged %d sprites below row %d; %d graphics numbered %d to %d"
          % (len(boxes), below, number - FIRST_NUMBER, FIRST_NUMBER, number - 1))


if __name__ == "__main__":
    main()
