"""How much of a 128K room page each room would need.

The 128K plan keeps every graphic in a library spread over several banks and,
on entering a room, copies what that room draws into one working bank at $C000
-- the room page. Walls and the scenery along the back of the room are drawn
once into a pre-drawn backdrop instead, and their graphics never need to be in
the page at all. This works out, room by room, which of the room's graphics are
backdrop-only and which are drawn during play, and how big each lot is.

A piece of scenery goes into the backdrop when nothing can ever get behind it:
it stands at or beyond the room's west edge (U low) or north edge (V high) --
depth is U - V + Z, so those are the far sides -- and it is not a doorway,
which something walks into. Knight Lore already marks its walls and trees
OBJ_BACKGROUND by hand (rooms.py), and this rule is checked against that.

Graphics that no room's templates name are counted as resident: the player,
collectables, and whatever the game's code puts up. That also sweeps in the
extra animation frames of movers a room places, so resident is an
overestimate and each room's own share an underestimate, but the sum is right.
For Knight Lore a mover's whole animation group is counted with the room.

Reads the gitignored files kl_extract.py and pg_extract.py produce, and
prints a report; it writes nothing.

    python room_budget.py [knightlore|pentagram] [--rooms]
"""
import json

import castle
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

PAGE = 16384
ROOM_DATA = 512                 # this room's record and expanded templates, allowed for
CENTRE = 128                    # world U and V of the middle of every room

# Doorways are walked into, so nothing in one can be backdrop.
DOOR_WORDS = ("arch", "gate", "door")
# Knight Lore's movers animate through a group of frames the room data does
# not list; see sprite_sheet.py's groups.
ANIMATED_GROUPS = ("ghost_spell_gate", "balls", "fires", "torsos_and_wizard")
# What Knight Lore marks OBJ_BACKGROUND, in rooms.py's BACKGROUND_TEMPLATES.
KL_BACKGROUND = ("scenery_walls_", "scenery_trees_")


def load_sprites(game):
    """name -> (bytes, group) from sprites.json, and the graphic -> name table."""
    frames = json.loads((HERE / game / "sprites.json").read_text())["frames"]
    sprites = {}
    for frame in frames.values():
        match = re.search(r"sprite_(\d+)$", frame["zx"]["sprite"])
        if match is None:
            continue
        width = frame["sourceSize"]["w"] // 8
        height = frame["sourceSize"]["h"]
        # Two header bytes, then a mask and a data byte per column per row.
        sprites["sprite_" + match.group(1)] = (width * height * 2 + 2, frame["zx"]["group"])

    table = []
    for line in (HERE / game / "sprite_table.s").read_text().splitlines():
        if "DW" not in line:
            continue
        for label in line.split(";")[0].split("DW")[1].split(","):
            table.append(label.strip())
    return sprites, table


def is_backdrop(block, half_u, half_v):
    u, v, z, size_u, size_v = block["bytes"][1:6]
    if u + size_u <= CENTRE - half_u:
        return True
    if v - size_v >= CENTRE + half_v:
        return True
    return False


def main():
    games = ["knightlore", "pentagram"]
    show_rooms = "--rooms" in sys.argv
    for arg in sys.argv[1:]:
        if arg in games:
            games = [arg]

    for game in games:
        sprites, table = load_sprites(game)
        rooms = castle.read_castle(HERE / game)
        shapes = {s["name"]: s for s in rooms["roomDimensions"]}
        scenery = {t["name"]: t for t in rooms["sceneryTemplates"]}
        objects = {t["name"]: t for t in rooms["objectTemplates"]}

        groups = {}
        for name, (size, group) in sprites.items():
            groups.setdefault(group, []).append(name)

        def names_of(graphics):
            found = set()
            for graphic in graphics:
                if graphic >= len(table) or table[graphic] not in sprites:
                    continue
                name = table[graphic]
                found.add(name)
                group = sprites[name][1]
                if game == "knightlore" and group in ANIMATED_GROUPS:
                    found.update(groups[group])
            return found

        def bytes_of(names):
            total = 0
            for name in names:
                total += sprites[name][0]
            return total

        # Pass one: what every room draws, to find what no room names.
        results = []
        named_anywhere = set()
        mismatches = []
        for room in rooms["rooms"]:
            half_u = shapes[room["dimensions"]]["u"]
            half_v = shapes[room["dimensions"]]["v"]
            back_graphics = set()
            play_graphics = set()
            back_pieces = 0
            pieces = 0
            for ref in room["scenery"]:
                template = scenery[ref["template"]]
                door = any(word in ref["template"] for word in DOOR_WORDS)
                for block in template["blocks"]:
                    pieces += 1
                    backdrop = not door and is_backdrop(block, half_u, half_v)
                    if game == "knightlore" and backdrop != ref["template"].startswith(KL_BACKGROUND):
                        mismatches.append((room["number"], ref["template"], block["bytes"][1:4]))
                    if backdrop:
                        back_pieces += 1
                        back_graphics.add(block["graphic"])
                    else:
                        play_graphics.add(block["graphic"])
            for ref in room["objects"]:
                for entry in objects[ref["template"]]["entries"]:
                    pieces += len(ref["positions"])
                    play_graphics.add(entry["graphic"])

            play = names_of(play_graphics)
            back_only = names_of(back_graphics) - play
            named_anywhere |= play | back_only
            results.append((room["number"], bytes_of(play), bytes_of(back_only),
                            back_pieces, pieces))

        resident = bytes_of(set(sprites) - named_anywhere)
        room_space = PAGE - resident - ROOM_DATA

        print("%s: %d graphics, %d bytes in all" % (game, len(sprites), bytes_of(set(sprites))))
        if game == "knightlore":
            if mismatches:
                print("  rule disagrees with OBJ_BACKGROUND on %d pieces, e.g. %s"
                      % (len(mismatches), mismatches[:3]))
            else:
                print("  rule matches the OBJ_BACKGROUND walls and trees exactly")
        print("  resident (named by no room): %d bytes" % resident)
        print("  room page left for a room's own graphics: %d bytes" % room_space)

        by_play = sorted(results, key=lambda r: r[1], reverse=True)
        middle = by_play[len(by_play) // 2]
        print("  drawn during play:  busiest %d bytes (room %d), median %d"
              % (by_play[0][1], by_play[0][0], middle[1]))
        by_back = sorted(results, key=lambda r: r[2], reverse=True)
        print("  backdrop only:      most %d bytes (room %d), median %d"
              % (by_back[0][2], by_back[0][0], by_back[len(by_back) // 2][2]))
        back_total = 0
        piece_total = 0
        for result in results:
            back_total += result[3]
            piece_total += result[4]
        print("  pieces into the backdrop: %d of %d (%.0f%%)"
              % (back_total, piece_total, 100.0 * back_total / piece_total))
        over = [r for r in results if r[1] > room_space]
        print("  rooms over the page: %d; headroom over the busiest: %.1fx"
              % (len(over), room_space / by_play[0][1]))

        if show_rooms:
            print("  room  play  backdrop  pieces")
            for number, play, back, back_pieces, pieces in results:
                print("  %4d  %4d  %8d  %2d/%2d" % (number, play, back, back_pieces, pieces))
        print()


if __name__ == "__main__":
    main()
