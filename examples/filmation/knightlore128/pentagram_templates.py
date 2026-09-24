"""Pentagram's templates, and two corners of its map, into Knight Lore 128K's
castle: run once, 2026-09-24, after pentagram_merge.py.

    python pentagram_templates.py

Every scenery and object template a Pentagram room places comes across,
renamed for what it is and drawing the graphics pentagram_merge.py numbered:

  scenery   the arch of tree trunks and the stone archway, each facing four
            ways; the back walls of trees and of stone
  objects   the block, stumps, spiky grass, thorns and the thorny bush, a cube
            and a table, water, the well, the lift, platforms, conveyors, a
            block that falls, one that sinks and one that crumbles, the dragon's
            heads, the spider and the creature

The archways go into templates.json's meta.doorways, and the walls into
meta.background, as Pentagram's rooms_source.py treats them. Not the raised
archway on its walkway, door_c, and its ledge: their opening is off the middle
of the wall, which this game's doorway test does not handle yet, so they stay
behind for now.

The templates come without their behaviour. Which object does what is
movers.s's mover_of, by template, and Pentagram's movers have not come across
yet, so everything here stands still.

Two clusters of Pentagram's own rooms come too, so the templates have
somewhere to be seen: eight in the forest round a well (Pentagram's rooms 29,
22, 12, 11, 13, 10, 14 and 9) and six of stone (95, 96, 97, 108, 82 and 98).
They take the lowest room numbers free. A doorway leading to a room in the
same cluster leads there still; one leading out of it is walled up. Neither
cluster is joined to the castle yet, which is the castle's design to decide;
till then they are reached by writing room_number.
"""

import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PENTAGRAM = HERE.parent / "pentagram"
sys.path.insert(0, str(HERE.parent))
import castle                                                   # noqa: E402
from pentagram_merge import numbering                           # noqa: E402

SIDES = ("n", "e", "s", "w")

# Pentagram's template names, which are placeholders, and ours.
SCENERY = {
    "door_a_n": "scenery_pentagram_trunk_arch_n", "door_a_e": "scenery_pentagram_trunk_arch_e",
    "door_a_s": "scenery_pentagram_trunk_arch_s", "door_a_w": "scenery_pentagram_trunk_arch_w",
    "door_b_n": "scenery_pentagram_stone_arch_n", "door_b_e": "scenery_pentagram_stone_arch_e",
    "door_b_s": "scenery_pentagram_stone_arch_s", "door_b_w": "scenery_pentagram_stone_arch_w",
    "scenery_08": "scenery_pentagram_trees_0", "scenery_09": "scenery_pentagram_trees_1",
    "scenery_10": "scenery_pentagram_trees_2", "scenery_11": "scenery_pentagram_trees_3",
    "scenery_16": "scenery_pentagram_trees_4", "scenery_17": "scenery_pentagram_trees_5",
    "scenery_12": "scenery_pentagram_stone_0", "scenery_13": "scenery_pentagram_stone_1",
    "scenery_14": "scenery_pentagram_stone_2", "scenery_15": "scenery_pentagram_stone_3",
    "scenery_20": "scenery_pentagram_stone_4",
}
DOORWAYS = {ours: SIDES["nesw".index(theirs[-1])] for theirs, ours in SCENERY.items()
            if theirs.startswith("door_")}
BACKGROUND = [ours for theirs, ours in SCENERY.items() if not theirs.startswith("door_")]

OBJECTS = {
    "object_00": "object_pentagram_block",        "object_01": "object_pentagram_stump",
    "object_03": "object_pentagram_grass",        "object_04": "object_pentagram_stump_pushed",
    "object_05": "object_pentagram_thorns",       "object_06": "object_pentagram_cube_pushed",
    "object_07": "object_pentagram_table_pushed", "object_08": "object_pentagram_stump_low",
    "object_09": "object_pentagram_block_falls",  "object_10": "object_pentagram_block_sinks",
    "object_11": "object_pentagram_stone_pushed", "object_12": "object_pentagram_lift",
    "object_13": "object_pentagram_water",        "object_14": "object_pentagram_thorny_bush",
    "object_15": "object_pentagram_dragon_hops",  "object_16": "object_pentagram_platform_u",
    "object_17": "object_pentagram_platform_v",   "object_18": "object_pentagram_spider",
    "object_19": "object_pentagram_well",         "object_20": "object_pentagram_creature",
    "object_21": "object_pentagram_water_deep",   "object_23": "object_pentagram_cube",
    "object_24": "object_pentagram_block_crumbles",
    "object_25": "object_pentagram_conveyor_1",   "object_27": "object_pentagram_conveyor_3",
    "object_28": "object_pentagram_conveyor_4",
    "object_29": "object_pentagram_dragon_paces_u", "object_30": "object_pentagram_dragon_paces_v",
}

CLUSTERS = ((29, 22, 12, 11, 13, 10, 14, 9), (95, 96, 97, 108, 82, 98))


def graphic_names():
    """Pentagram's graphic name -> ours, by its number: pentagram_merge.py's
    numbering, which keeps the runs its code counts through apart."""
    theirs = json.loads((PENTAGRAM / "graphics.json").read_text(encoding="utf-8"))["graphics"]
    numbers, _top = numbering(theirs)
    return {name: numbers[entry["number"]]["name"] for name, entry in theirs.items()
            if entry["number"] in numbers}


def main():
    ours = castle.read_castle(HERE)
    if any(name in ours["sceneryTemplates"] for name in SCENERY.values()):
        sys.exit("templates.json has Pentagram's templates already")
    theirs = castle.read_castle(PENTAGRAM)
    names = graphic_names()

    def converted(pieces, whose):
        out = []
        for piece in pieces:
            piece = dict(piece)
            if piece["graphic"] not in names:
                sys.exit("%s draws Pentagram's %s, which has no number here"
                         % (whose, piece["graphic"]))
            piece["graphic"] = names[piece["graphic"]]
            out.append(piece)
        return out

    for theirs_name, ours_name in SCENERY.items():
        ours["sceneryTemplates"][ours_name] = converted(
            theirs["sceneryTemplates"][theirs_name], theirs_name)
    for theirs_name, ours_name in OBJECTS.items():
        ours["objectTemplates"][ours_name] = converted(
            theirs["objectTemplates"][theirs_name], theirs_name)
    meta = ours["templatesMeta"]
    meta["doorways"].update(DOORWAYS)
    meta["background"] = list(meta["background"]) + BACKGROUND

    # The rooms: each cluster under the lowest free numbers, in order.
    rooms = {r["number"]: r for r in theirs["rooms"]}
    taken = {r["number"] for r in ours["rooms"]}
    free = iter(n for n in range(255) if n not in taken)
    numbered = {}
    for cluster in CLUSTERS:
        for theirs_number in cluster:
            numbered[theirs_number] = next(free)
    for theirs_number, number in numbered.items():
        room = rooms[theirs_number]
        scenery = []
        for ref in room["scenery"]:
            entry = {"template": SCENERY[ref["template"]]}
            if entry["template"] in DOORWAYS:
                entry["destination"] = numbered.get(ref.get("destination"))
            scenery.append(entry)
        objects = [{"template": OBJECTS[group["template"]],
                    "positions": [dict(p) for p in group["positions"]]}
                   for group in room["objects"]]
        ours["rooms"].append({"number": number, "ink": room["ink"],
                              "dimensions": room["dimensions"],
                              "scenery": scenery, "objects": objects})
    ours["rooms"].sort(key=lambda r: r["number"])

    castle.write_castle(HERE, ours)
    print("%d scenery and %d object templates; Pentagram's rooms %s are now %s"
          % (len(SCENERY), len(OBJECTS), ", ".join(str(n) for n in numbered),
             ", ".join("$%02X" % n for n in numbered.values())))


if __name__ == "__main__":
    main()
