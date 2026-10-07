"""Lightkeep's test stairwell, and the stair tread it is built from.

Writes four files, and running it again writes the same ones:

  art/sprites.png and metadata/sprites.json
      stair.tread: one step, drawn to exactly its box -- 16 along U, 6 along V,
      6 high -- so that what the depth sort compares is what is seen. The
      bridge decks the stairs were first drawn with were 16 deep on 8-deep
      treads, overlapped one another and reached past their boxes.
  metadata/graphics.json
      graphic 204, stair.tread, with its box and the nudge that lines the
      drawing up with it, worked out from the projection rather than by eye.
  metadata/templates.json, through the room designer's own model (it keeps
  the file's layout, which castle.py's writer does not), and metadata/rooms.json
      scenery_stairs_up     the twelve treads in the room below ($83)
      scenery_hole_floor    the invisible floor round the hole above ($A7)
      scenery_hole_treads   the staircase's last five treads, in the hole

One staircase of sixteen treads, 6 high each, climbs a storey (96, storeys.s).
Treads 1 to 12 stand in the room below, up to 72 above its floor, where the way
up is; 12 to 16 stand in the hole of the room above, a storey lower, up to its
floor. It runs along V at U 100-116, in the middle of both rooms and clear of
their doorways' paths, and climbs northwards: going up is walking north. A
tread is only a slab, with nothing under it: the space under the high end of
the stairs is open, as under a real flight.

    python scripts/stairwell.py
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(HERE.parent / "scripts"))
import castle                                                   # noqa: E402

SHEET = HERE / "art" / "sprites.png"
SPRITES = HERE / "metadata" / "sprites.json"
GRAPHICS = HERE / "metadata" / "graphics.json"
ROOMS = HERE / "metadata" / "rooms.json"
TEMPLATES_JS = Path(__file__).with_name("stairwell_templates.js")

INK = (255, 255, 255, 255)
PAPER = (0, 0, 0, 255)
CLEAR = (0, 0, 0, 0)
FRAME = (255, 0, 255, 255)      # sprites.json's "border": every sprite is framed

# The tread's box: half-widths along U and V, and its height.
HALF_U, HALF_V, HEIGHT = 8, 3, 6
TREAD_GRAPHIC = 204
TREAD_NAME = "stair.tread"

# The staircase. Tread k (1-16) is 6 deep along V, from V_START, and its top is
# RISE * k above the lower room's floor.
U_MIDDLE = 108
V_START = 80
RISE = 6
STOREY = 96                     # storeys.s
FLOOR = 128
HOLE_DEPTH = 64                 # storeys.s: how far a hole room's floor is lowered
ROOM_BELOW, ROOM_ABOVE = 0x83, 0xA7
BELOW_TREADS = range(1, 13)     # up to the way up's line, 72 above the floor
ABOVE_TREADS = range(12, 17)    # the last five, a storey lower, in the hole
GAP_TREADS = range(9, 12)       # left open in the room above, to drop through

# What the stairwell replaces: the first one, against the south walls.
RETIRED = ["scenery_stairs_up_solid", "scenery_stairs_up_decks",
           "scenery_hole_solid", "scenery_hole_decks"]
OURS = ["scenery_stairs_up", "scenery_hole_floor", "scenery_hole_treads"]


def tread_v(k):
    return V_START + RISE * (k - 1) + HALF_V


def tread_top(k):
    """Its top, in the room below's heights."""
    return FLOOR + RISE * k


# --- the sprite -----------------------------------------------------------

def project(u, v, z):
    """The engine's projection, as floats: across the screen and down it."""
    return u + v, -(v - u) / 2 - z


def draw_tread():
    """The tread as a bitmap, and where the middle of its box's base falls in
    it, as floats.

    Every point of the three faces nearer the viewer -- the top, the +U face
    and the -V face -- is projected in quarter units and its pixel marked:
    paper for a face, ink for the edges and for planks across the top, which
    is how the castle's own bridge deck is drawn."""
    cells = {}
    steps = 4

    def mark(u, v, z, ink):
        x, y = project(u, v, z)
        key = (int(x // 1), int(y // 1))
        cells[key] = cells.get(key, False) or ink

    spans_u = 2 * HALF_U * steps
    spans_v = 2 * HALF_V * steps
    for i in range(spans_u + 1):
        u = -HALF_U + i / steps
        for j in range(spans_v + 1):
            v = -HALF_V + j / steps
            edge = i in (0, spans_u) or j in (0, spans_v)
            plank = i % (2 * steps) == 0            # a plank every 2 units of U
            mark(u, v, HEIGHT, edge or plank)
    for k in range(HEIGHT * steps + 1):
        z = k / steps
        rim = k in (0, HEIGHT * steps)
        for i in range(spans_u + 1):                # the -V face
            mark(-HALF_U + i / steps, -HALF_V, z, rim or i in (0, spans_u))
        for j in range(spans_v + 1):                # the +U face
            mark(HALF_U, -HALF_V + j / steps, z, rim or j in (0, spans_v))

    xs = [x for x, _ in cells]
    ys = [y for _, y in cells]
    left, top = min(xs), min(ys)
    width = (max(xs) - left + 1 + 7) // 8 * 8       # whole bytes
    height = max(ys) - top + 1
    image = Image.new("RGBA", (width, height), CLEAR)
    for (x, y), ink in cells.items():
        image.putpixel((x - left, y - top), INK if ink else PAPER)
    return image, -left, -top


def nudge(anchor_x, anchor_y, height):
    """graphics.json's x and y for a bitmap whose anchor is at (anchor_x,
    anchor_y) in it.

    object_place puts the bitmap's left column at U + V - 128 plus the nudge's
    x, and its base -- the row just past its bottom -- at
    40 - ((V - U + 128) >> 1) - Z less the nudge's y. Every tread has V - U
    odd (V is 83 plus a multiple of 6, U is 108), so the halving drops a half
    for each alike: the anchor's true row is half a row below that formula's.
    """
    x = -int(round(anchor_x))
    y = -int(round(height - (anchor_y + 0.5)))
    return x, y


def free_spot(sheet, w, h):
    """The first place on the sheet clear of everything for a sprite and its
    frame, with a pixel to spare round that."""
    pix = sheet.load()
    sw, sh = sheet.size
    for y in range(2, sh - h - 2):
        for x in range(2, sw - w - 2):
            if all(pix[x + i, y + j][3] == 0
                   for j in range(-2, h + 2) for i in range(-2, w + 2)):
                return x, y
    sys.exit("no room on the sheet for a %d x %d sprite" % (w, h))


def write_sprite(image):
    """The tread onto the sheet, over its last drawing if it has one, and its
    rectangle into sprites.json beside the solid box's."""
    text = SPRITES.read_text(encoding="utf-8")
    said = json.loads(text)["group"].get("stair", {}).get("sprites", {}).get("tread")
    sheet = Image.open(SHEET).convert("RGBA")
    if said:                                    # its last drawing, frame and all
        for j in range(-1, said["h"] + 1):
            for i in range(-1, said["w"] + 1):
                sheet.putpixel((said["x"] + i, said["y"] + j), CLEAR)
    if said and (said["w"], said["h"]) == image.size:
        x, y = said["x"], said["y"]
    else:
        x, y = free_spot(sheet, *image.size)
    for i in range(-1, image.size[0] + 1):
        sheet.putpixel((x + i, y - 1), FRAME)
        sheet.putpixel((x + i, y + image.size[1]), FRAME)
    for j in range(image.size[1]):
        sheet.putpixel((x - 1, y + j), FRAME)
        sheet.putpixel((x + image.size[0], y + j), FRAME)
    sheet.alpha_composite(image, (x, y))
    sheet.save(SHEET)

    entry = ('  "stair": {\n   "sprites": {\n    "tread": { "x": %d, "y": %d, "w": %d, "h": %d }\n   }\n  }'
             % (x, y, image.size[0], image.size[1]))
    if '\n  "stair": {' in text:
        start = text.index('\n  "stair": {') + 1
        end = text.index("\n  }", start) + len("\n  }")
        text = text[:start] + entry + text[end:]
    else:
        start = text.index('\n  "solid": {') + 1
        end = text.index("\n  }", start) + len("\n  }")
        text = text[:end] + ",\n" + entry + text[end:]
    SPRITES.write_text(text, encoding="utf-8", newline="\n")
    return x, y


def write_graphic(x, y):
    """graphic 204 into graphics.json, just after the solid box. The line's
    columns are set again by the graphic map's own writer, in
    write_templates, so it lines up with the rest."""
    text = GRAPHICS.read_text(encoding="utf-8")
    line = ('  %-22s { "number": %3d, "sprite": %-21s, "size": { "u": %d, "v": %d, "z": %d }  , "x": %d, "y": %d },'
            % ('"%s":' % TREAD_NAME, TREAD_GRAPHIC, '"%s"' % TREAD_NAME, HALF_U, HALF_V, HEIGHT, x, y))
    lines = text.split("\n")
    lines = [l for l in lines if not l.startswith('  "%s":' % TREAD_NAME)]
    at = next(i for i, l in enumerate(lines) if l.startswith('  "solid":'))
    lines.insert(at + 1, line)
    GRAPHICS.write_text("\n".join(lines), encoding="utf-8", newline="\n")


# --- the templates and the rooms -------------------------------------------

def solid(u0, u1, v0, v1):
    base = FLOOR - HOLE_DEPTH
    return {"graphic": "solid", "u": (u0 + u1) // 2, "v": (v0 + v1) // 2, "z": base,
            "sizeU": (u1 - u0) // 2, "sizeV": (v1 - v0) // 2, "sizeZ": HOLE_DEPTH,
            "flags": {"mirrored": False, "passable": False, "rest": 16}}


def tread(k, top):
    return {"graphic": TREAD_NAME, "u": U_MIDDLE, "v": tread_v(k), "z": top - HEIGHT,
            "flags": {"mirrored": False, "passable": False, "rest": 16}}


def templates():
    lo_u, hi_u = U_MIDDLE - HALF_U, U_MIDDLE + HALF_U
    hole_lo = V_START + RISE * (min(GAP_TREADS) - 1)
    hole_hi = V_START + RISE * max(ABOVE_TREADS)
    return {
        "scenery_stairs_up": [tread(k, tread_top(k)) for k in BELOW_TREADS],
        # The floor of the room above, round the hole: wall to wall west and
        # east of it, and the strips south and north of it.
        "scenery_hole_floor": [solid(64, lo_u, 64, 192), solid(hi_u, 192, 64, 192),
                               solid(lo_u, hi_u, 64, hole_lo), solid(lo_u, hi_u, hole_hi, 192)],
        "scenery_hole_treads": [tread(k, tread_top(k) - STOREY) for k in ABOVE_TREADS],
    }


def node():
    """A node to run the designer's model with: node itself, or VS Code's."""
    found = shutil.which("node")
    if found:
        return [found], None
    code = Path(os.environ.get("LOCALAPPDATA", "")) / "Programs" / "Microsoft VS Code" / "Code.exe"
    return [str(code)], dict(os.environ, ELECTRON_RUN_AS_NODE="1")


def write_templates():
    cmd, env = node()
    payload = json.dumps({"templates": templates(), "background": ["scenery_hole_floor"],
                          "retired": RETIRED})
    done = subprocess.run(cmd + [str(TEMPLATES_JS), str(HERE), payload],
                          capture_output=True, text=True, env=env)
    if done.returncode or "written" not in done.stdout:
        sys.exit("the templates were not written:\n" + done.stdout + done.stderr)


def write_rooms():
    atlas = json.loads(ROOMS.read_text(encoding="utf-8"))
    rooms = {r["number"]: r for r in atlas["rooms"]}
    for number, names in ((ROOM_BELOW, ["scenery_stairs_up"]),
                          (ROOM_ABOVE, ["scenery_hole_floor", "scenery_hole_treads"])):
        room = rooms[number]
        room["scenery"] = [s for s in room["scenery"] if s["template"] not in RETIRED + OURS]
        room["scenery"] += [{"template": name, "destination": None} for name in names]
    ROOMS.write_text(castle.format_rooms(atlas), encoding="utf-8", newline="\n")


def main():
    image, ax, ay = draw_tread()
    x, y = write_sprite(image)
    nx, ny = nudge(ax, ay, image.size[1])
    write_graphic(nx, ny)
    write_templates()               # and graphics.json's layout
    write_rooms()
    print("%s: %d x %d at %d,%d on the sheet, graphic %d, nudge x %d y %d"
          % (TREAD_NAME, image.size[0], image.size[1], x, y, TREAD_GRAPHIC, nx, ny))


if __name__ == "__main__":
    main()
