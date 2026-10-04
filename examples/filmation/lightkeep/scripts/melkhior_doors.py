"""Doorway templates from Melkhior's Mansion's castle doors: the graphics for
the posts and the lintel, and a template for each wall.

    python scripts/melkhior_doors.py            write graphics.json and templates.json
    python scripts/melkhior_doors.py --check    only print what it would write

It reads Melkhior's own numbers from your copy of the game, as
melkhior_sheets.py does -- viewer/data.json for each piece's box and hot spot,
and the pictures for where the sheet trimmed each frame -- so the doors sheet
has to have been converted first. Running it again writes the same thing; a
room uses a door by naming its template.

Melkhior's viewer builds a castle doorway from three pieces (index.html):

    DoorSide<n> frame 0 at (x, y, h)          the near post
    DoorSide<n> frame 1 at (x + fx, y + fy, h) the far post, 13 units along
    DoorTop<n>  frame 0 at (x, y, h + 27)     the lintel over both

with n = 1 in the NW and SE walls and n = 2 -- the same pictures flipped -- in
the NE and SW ones. melkhior128's projection puts Melkhior's (X, Y, Z) at our
U = 128 + SX - 2X, V = 128 - SY + 2Y, Z + 128, pixel for pixel; in a room of
SX = SY = 64 its walls are ours at 64 and 192, and a doorway at x or y = 24
puts the posts where Knight Lore's arch leaves are -- 115 and 141 along the
wall, 196 out in the north and east. So the room builder measures these
exactly as it does an arch.
"""
import json, sys
from pathlib import Path

GAME = Path(__file__).resolve().parent.parent      # the game's folder
sys.path.insert(0, str(GAME.parent / "scripts"))
sys.path.insert(0, str(GAME / "scripts"))
import castle, graphics, layout                                 # noqa: E402
import melkhior_sheets as mm                                    # noqa: E402

META = layout.metadata(GAME)
CHECK = "--check" in sys.argv
data = json.loads((mm.MELKHIOR / "viewer" / "data.json").read_text(encoding="utf-8"))
TYPES = data["types"]
pictures = mm.Pictures(mm.MELKHIOR)

SX = SY = 64                                    # a virtual Melkhior room
U0, V0 = 128 + SX, 128 - SY
OX, OY = 128 + SX - SY, 104 + (SX + SY) // 2

# The three pieces, as the sheet names them, and the graphic numbers they get.
PIECES = {
    ("DoorSide", 0): ("doors:DoorSide1.0", "doors.DoorSide1.0", 200),
    ("DoorSide", 1): ("doors:DoorSide1.1", "doors.DoorSide1.1", 201),
    ("DoorTop", 0):  ("doors:DoorTop1.0", "doors.DoorTop1.0", 202),
}

# Our walls, as Melkhior's: its NE wall is our north (+V), SW south, NW west
# (-U), SE east. (x, y, n, fx, fy) as the viewer works them out, at along
# = 0.5 in a room of 64: 4 + trunc(0.5 * 24) + off = 24 with off 8.
WALLS = {
    "n": (24, SY, "2", 13, 0),
    "s": (24, -4, "2", 13, 0),
    "w": (SX, 24, "1", 0, 13),
    "e": (-4, 24, "1", 0, 13),
}
TEMPLATES = {          # template: (wall, height above the floor)
    "scenery_melkhior_door_n": ("n", 0),
    "scenery_melkhior_door_e": ("e", 0),
    "scenery_melkhior_door_s": ("s", 0),
    "scenery_melkhior_door_w": ("w", 0),
    # Knight Lore's two raised arches, onto a walkway 48 up.
    "scenery_melkhior_high_door_e": ("e", 48),
    "scenery_melkhior_high_door_s": ("s", 48),
}


def frame_box(tid, frame):
    """Where the sheet's trimmed sprite sits in Melkhior's frame: the frame
    unflipped, as the sheet holds it, and its width and height on the sheet."""
    kind = TYPES[tid]
    pic = pictures.get(kind["img"])
    x, y = mm.cells_of(kind, pic)[frame]
    im = pic.crop((x, y, x + kind["fw"], y + kind["fh"]))
    alpha = im.getchannel("A").point(lambda v: 255 if v >= mm.OPAQUE else 0)
    box = alpha.getbbox()
    w8 = max(mm.NARROWEST_BYTES, (box[2] - box[0] + 7) // 8) * 8
    return box, w8


def engine_nudge(u, v, z, left, bottom):
    """melkhior128's: the x, y nudge that puts a sprite's left column and the
    row below its bottom where wanted, by object_place's 8-bit arithmetic."""
    x = (u + v - 128) & 0xFF
    half = ((v - u + 128) & 0xFF) >> 1
    base = (40 - ((half + z) & 0xFF)) & 0xFF
    signed = lambda n: n - 256 if n > 127 else n
    return signed((left - x) & 0xFF), signed((base - bottom) & 0xFF)


sheet = json.loads((META / "melkhior" / "doors.json").read_text(encoding="utf-8"))
nudges = {}            # (piece, mirrored) -> nudge
sizes = {}
templates = {}
for name, (wall, h) in TEMPLATES.items():
    x, y, n, fx, fy = WALLS[wall]
    flipped = n == "2"
    parts = [("DoorSide", 0, x, y, h), ("DoorSide", 1, x + fx, y + fy, h),
             ("DoorTop", 0, x, y, h + 27)]
    pieces = []
    for base, frame, ex, ey, ez in parts:
        tid = base + n
        kind = TYPES[tid]
        (bx0, by0, bx1, by1), w8 = frame_box(base + "1", frame)
        sprite, gname, number = PIECES[(base, frame)]
        rect = sheet["group"][base + "1"]["sprites"][str(frame)]
        assert (rect["w"], rect["h"]) == (w8, by1 - by0), (sprite, rect, w8, by1 - by0)
        # Melkhior's frame top-left on our screen, then the sprite in it.
        fx0 = OX - 2 * ex + 2 * ey - kind["hx"]
        fy0 = OY - ex - ey - ez - kind["hy"]
        left = fx0 + (kind["fw"] - bx0 - w8 if flipped else bx0)
        bottom = fy0 + by1
        u = U0 - (2 * ex + kind["sx"])
        v = V0 + (2 * ey + kind["sy"])
        z = 128 + ez
        nudge = engine_nudge(u, v, z, left, bottom)
        key = (gname, flipped)
        assert nudges.get(key, nudge) == nudge, (name, gname, nudges[key], nudge)
        nudges[key] = nudge
        if not flipped:
            sizes[gname] = {"u": kind["sx"], "v": kind["sy"], "z": kind["sz"]}
        # The lintel is over the knight's head and walked under: passable,
        # as Melkhior has its physics Disabled.
        pieces.append({"graphic": gname, "u": u, "v": v, "z": z,
                       "flags": {"mirrored": flipped, "passable": base == "DoorTop", "rest": 16}})
    templates[name] = pieces
    print(name, [(p["graphic"].split(".", 1)[1], p["u"], p["v"], p["z"]) for p in pieces])

for (gname, flipped), nudge in sorted(nudges.items()):
    print("  %-20s %s nudge %s" % (gname, "mirrored" if flipped else "plain   ", nudge))

if CHECK:
    sys.exit()

# --- graphics.json ------------------------------------------------------------
gj = json.loads((META / "graphics.json").read_text(encoding="utf-8"))
table = gj["graphics"]
used = {v["number"] for v in table.values()}
for (base, frame), (sprite, gname, number) in PIECES.items():
    assert gname not in table or table[gname]["number"] == number, gname
    assert gname in table or number not in used, (gname, number)
    plain, mirrored = nudges[(gname, False)], nudges[(gname, True)]
    entry = {"number": number, "sprite": sprite, "size": sizes[gname],
             "x": plain[0], "y": plain[1]}
    if mirrored != plain:
        entry["mirrored"] = {"x": mirrored[0], "y": mirrored[1]}
    table[gname] = entry
(META / "graphics.json").write_text(
    graphics.format_table(table, gj.get("sprites", "sprites.json"), gj.get("sheets")), encoding="utf-8")

# --- templates.json -------------------------------------------------------------
c = castle.read_castle(GAME)
scenery = c["sceneryTemplates"]
for name, pieces in templates.items():
    scenery[name] = pieces
    c["templatesMeta"]["doorways"][name] = TEMPLATES[name][0]
castle.write_castle(GAME, c)
print("written")
