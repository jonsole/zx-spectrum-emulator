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
                 draws (WANTED, below) -- except where its code counts
                 through a run of numbers or reads their bits (RUNS), which
                 keep a number each and their place mod 8.

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

# Runs of Pentagram's graphic numbers that its code, and the engine's movers
# it shares, count through or read the low bits of -- so each keeps a number
# of its own, in order, starting at the same value as Pentagram's modulo the
# alignment its code needs. Everything else shares a number with whatever
# draws the same sprite with the same nudge and box.
RUNS = (
    ((48, 49, 50, 51), 4),              # a homer: mover_homer ORs its frame into
    (tuple(range(160, 168)), 4),        # ...the bottom two bits
    ((140, 141, 142, 143), 4),          # conveyors: the way in the bottom two bits
    ((168, 169, 170, 171), 4),          # the four-frame faller: its axis in bits 0-1
    ((16, 17), 2),                      # the creature: along U or V in bit 0
    ((80, 81), 2),                      # the faller: its axis is bit 0
    (tuple(range(64, 71)), 1),          # the puff, counted through by mover_poof
    ((136, 137, 138, 139), 1),          # a block, then its cracks: mover_crumbles
    ((149, 150, 151), 1),               # the bolt, counted down
)


def numbering(said, first=FIRST_NUMBER):
    """Pentagram's graphic numbers -> (our name, our number, its entry), for
    every graphic WANTED: RUNS a number each, the rest one a kind."""
    by_number = {}
    for name, entry in said.items():
        sprite = entry.get("sprite")
        if sprite is None or entry["number"] not in WANTED:
            continue
        ours = "pentagram." + NAMES[int(sprite.split(".")[1])]
        if ours.split(".")[1] not in NOT_DRAWN:
            by_number[entry["number"]] = (ours, entry)
    in_run = {n: (run, align) for run, align in RUNS for n in run}

    def kind(pg):
        ours, entry = by_number[pg]
        return (ours, entry.get("x", 0), entry.get("y", 0),
                json.dumps(entry.get("mirrored")), json.dumps(entry.get("size")))

    # Which numbers become one: a graphic in a run is its own; the rest group
    # by what they draw. The runs come first, the most aligned first, so that
    # none has to be padded out to its boundary.
    groups, seen = [], {}
    for run, align in RUNS:
        groups.append((align, [[n] for n in run if n in by_number]))
    for pg in sorted(by_number):
        if pg in in_run:
            continue
        k = kind(pg)
        if k in seen:
            seen[k].append(pg)
        else:
            seen[k] = [pg]
            groups.append((1, [seen[k]]))

    out, number = {}, first
    uses = {}
    for align, members in groups:
        start = members[0][0]
        while number % align != start % align:
            number += 1
        for pgs in members:
            ours, entry = by_number[pgs[0]]
            uses[ours] = uses.get(ours, 0) + 1
            for pg in pgs:
                out[pg] = {"name": ours, "sprite": ours, "number": number, "entry": entry}
            number += 1
    # A sprite drawn by one number is named after the sprite; by several, each
    # carries its number, as graphics.json names Knight Lore's.
    for said in out.values():
        if uses[said["sprite"]] > 1:
            said["name"] = "%s.g%d" % (said["sprite"], said["number"])
    return out, number


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

    # The numbers.
    said = json.loads((PENTAGRAM / "graphics.json").read_text(encoding="utf-8"))["graphics"]
    table = json.loads(table_path.read_text(encoding="utf-8"))["graphics"]
    numbers, number = numbering(said)
    if number > 256:
        sys.exit("Pentagram's graphics need numbers up to %d, and a number is a byte" % (number - 1))
    add_numbers(table, numbers)

    merged.save(sheet_path)
    atlas_path.write_text(sheet.format_sheet(ours, ours.get("animations")), encoding="utf-8")
    table_path.write_text(gfx.format_table(table), encoding="utf-8")
    print("merged %d sprites below row %d; %d graphics numbered %d to %d"
          % (len(boxes), below, number - FIRST_NUMBER, FIRST_NUMBER, number - 1))


def add_numbers(table, numbers):
    """numbering()'s graphics into graphics.json's table, one entry a number."""
    done = set()
    for said in sorted(numbers.values(), key=lambda s: s["number"]):
        if said["number"] in done:
            continue
        done.add(said["number"])
        if said["name"] in table:
            sys.exit("graphics.json has a %s already" % said["name"])
        new = {"number": said["number"], "sprite": said["sprite"]}
        for field in ("size", "x", "y", "mirrored"):
            if said["entry"].get(field) is not None:
                new[field] = said["entry"][field]
        table[said["name"]] = new


if __name__ == "__main__":
    main()
