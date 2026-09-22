"""Knight Lore's artwork as a sprite sheet: sprite_data.bin -> sprites.png
and sprites.json, beside this script.

    python sprite_sheet.py

sprite_data.bin is what kl_extract.py lifts out of a real Knight Lore: 103
sprites, each two header bytes then mask and data bytes interleaved, bottom
row first. That is a fine shape for a Z80 to draw from and a poor one to look
at or to edit, so this unpacks it once into a picture and a description:

    sprites.png     every sprite the right way up, laid out in bands of
                    related frames -- the knight, then each thing that
                    animates, then the panel, then the scenery
    sprites.json    an atlas: where each sprite sits in that picture, how its
                    bytes are arranged, and the facts about the set that the
                    assembler source is generated from

sprites.json is in the shape the ZX Spectrum extension's graphics panel
writes and reads -- TexturePacker's "JSON (Hash)" layout, which Aseprite also
writes, with everything Spectrum-shaped under `zx` keys. So the sheet opens in
"ZX Spectrum: Show Graphics" as 103 sprites in their bands, ready to be
looked at a pixel at a time. The panel reads a sprite's bytes out of the
atlas rather than out of the picture, which is why every sprite carries a
base64 copy of its own record; sprite_source.py rewrites those from the
picture whenever it builds, so the two halves never drift apart.

sprite_source.py turns the pair back into sprite_data.s, sprite_table.s and
sprite_adj_gen.s. The round trip is exact, so the pair is the artwork's home
from here on: edit the PNG, rebuild, and the game changes. sprite_data.bin is
only ever the seed, and running this again overwrites those edits.

Four colours carry the two bits a Filmation pixel has -- a mask bit that says
whether the sprite covers the screen there, and a data bit that says what it
puts down if it does. sprite_blit composites a row as `and mask : xor data`:

    black           mask 1, data 0   paper
    white           mask 1, data 1   ink
    clear           mask 0, data 0   the screen shows through
    red             mask 0, data 1   the screen is inverted there

The last of those is nine pixels across six sprites -- artwork of Ultimate's
own that the blit turns into an XOR rather than a hole -- and the graphics
panel, which knows only the three ordinary states, draws them clear. They
keep a colour of their own here so that what comes back out of the picture is
the game's own bytes to the bit.
"""

import base64
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

import sys
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import graphics as gfx                                          # noqa: E402

HERE = Path(__file__).resolve().parent
PACKED = HERE / "sprite_data.bin"
# What the extraction left: which sprite each graphic number draws. Only
# read when sprites.json is first built -- after that the atlas is the
# authoritative copy and this file is not needed again.
GRAPHIC_MAP = HERE / "graphic_map.json"
# How many graphic numbers the game has, and so how wide the table is.
GRAPHIC_COUNT = 256
SHEET = HERE / "sprites.png"
SPRITES_JSON = HERE / "sprites.json"
GRAPHICS_JSON = HERE / "graphics.json"

# Filled in by main(), for the writers that want the map by number.
GRAPHIC_MAP_CACHE = []

# What each of the four pixel states looks like. The first three are the
# graphics panel's own: PALETTE[15] on PALETTE[0], which is what INK and PAPER
# below ask it for, so three quarters of this picture is exactly what the
# panel would draw. sprite_source.py reads these out of the atlas rather than
# knowing them itself, so the sheet's colours can change here alone.
PALETTE = {
    "transparent": (0, 0, 0, 0),
    "paper": (0, 0, 0, 255),
    "ink": (255, 255, 255, 255),
    "stray": (255, 0, 0, 255),
}
INK, PAPER = 15, 0                      # into the panel's own ULA palette

SHEET_WIDTH = 640               # wide enough for sixteen of the widest sprite
GAP = 2                         # between sprites, and between bands
LABEL_HEIGHT = 12               # the strip a band's name is written in
LABEL_COLOUR = (96, 96, 96, 255)

# How the graphics panel should read a sprite's bytes: two header bytes, then
# a row at a time, mask byte then data byte, bottom row first, and a mask
# whose set bits mean "covers" where the panel's mean "hole".
SPRITE_FORMAT = {
    # "sheet" is the panel's source for a sprite whose bytes travel with it:
    # ours were drawn into a picture, not found at an address or an offset in
    # a file, so there is nowhere for the panel to read them from again.
    "source": "sheet",
    "format": "sprite",
    "count": 1,
    "columns": 1,
    "header": 2,
    "first": 32,
    "interleave": "md",
    "invertMask": True,
    "bottomUp": True,
    "ink": INK,
    "paper": PAPER,
}

# Knight Lore's graphic numbers, gathered into the bands the sheet is laid out
# in, and the groups the graphics panel shows. A sprite goes in the first band
# that names it and is drawn once, so the later bands hold only what the
# earlier ones left; the last one sweeps up everything no band asked for.
# Several of these are the same groupings the atlas goes on to record for the
# checks in sprite_source.py -- the knight's frames and the animations --
# because seeing an animation's frames side by side is exactly what makes a
# sheet worth having.
# The sparkle Sabreman dies into, and the wizard's spell -- one set of six
# sprites doing both jobs. Either half of him can be wearing it, which is why
# it used to be tacked onto the end of BOTH lists below and so ended up named
# as legs; it is neither, and has a band of its own.
SPELL = list(range(112, 128))
LEG_POSES = list(range(0, 6)) + list(range(8, 14))
SABREMAN_LEGS = [16 + k for k in LEG_POSES]
WEREWOLF_LEGS = [48 + k for k in LEG_POSES]
SABREMAN_BODY = [32 + k for k in range(16)]
WEREWOLF_BODY = [64 + k for k in range(16)]

# Everything that animates, as sprite_source.py checks it: every frame in a
# group has to rotate into a buffer sized from any other frame in it.
ANIMATIONS = (
    (176, 177), (180, 181), (86, 87),                       # fires
    (178, 179), (182, 183),                                 # balls
    (150, 151), (30, 31), (158, 159),                       # torsos, wizard's legs
    tuple(range(144, 150)) + tuple(range(152, 158)),        # a guard's legs
    (80, 81, 82, 83), (164, 165, 166, 167), (8, 9),         # ghost, spell, gate
)

# The eight kinds the wizard asks for -- SPECIAL_FIRST to SPECIAL_LIFE in
# special.s. Each bitmap is drawn by three graphics: one of these lying in a
# room, one at 104-111 and one at 168-175. The last, the extra life, is
# Sabreman's head and shares its bitmap with the panel's lives indicator, so
# this band comes after the panel's and takes seven of the eight.
# The twinkle Sabreman turns into the werewolf through, and back again --
# PLAYER_CHANGE_GFX in player.s. No room places these: the player's own code
# draws them, which is why they swept into the scenery band before.
TRANSFORM = (92, 93, 94, 95)

COLLECTABLE = tuple(range(96, 104))

# What a room is built out of. Knight Lore dresses its rooms two ways -- stone
# castle and forest -- and each has its own walls and its own doorway arch, so
# the same four jobs are done by two sets of sprites.
WALL_CASTLE = (10, 11, 12, 13, 14, 15)   # scenery_walls_0/1/2: three
                                # stones and three pillars, contiguous
WALL_FOREST = (128, 129, 130)   # scenery_trees_0/1/2
DOOR_CASTLE = (2, 3)            # scenery_arch_n/e/s/w, and the high arches
DOOR_FOREST = (4, 5)            # scenery_tree_arch_n/e/s/w

SUN = (88, 89)                  # the sun and the moon, sixteen rows in
                                # sun_place -- SUN_GFX in sun.s says so.
                                # This used to read (88, 96), which made
                                # the moon a collectable: 96 is
                                # SPECIAL_FIRST, the first of the eight.
WINDOW = (90, 186)              # the window's frame, indexed by row in sun_draw
PANEL = (134, 135, 136, 140)    # the chain, the bars, the ends, Sabreman's head
MENU = (137, 138, 139)          # the frame's corner, drawn upside down too;
                                # a run's four pixels; and the bar. MENU_SIDE_BITS
                                # and MENU_BAR_ROWS in menu.s name the last two.

# Sprites that keep their blank bottom rows, because the code that draws them
# knows its own height rather than asking object_update for it.
#
# NOT the same set as the four groups above, though it nearly is: the menu's
# corner is drawn whole, but its side and bar are drawn a fixed number of rows
# in, so whatever is under that never matters and they trim like anything
# else. What a sprite IS and how it is DRAWN are different questions.
WHOLE_SPRITE_GRAPHICS = SUN + WINDOW + PANEL + (137,)

# The knight keeps two rotation buffers for life, sized from these two
# sprites; every frame the matching half can wear has to fit.
# The sparkle is in both, though it is in neither band: a half wearing it has
# to fit the buffer it already has, and taking it out of the lists above is
# about where it is DRAWN on the sheet, not about what a buffer must hold.
ROTATION_BUFFERS = (
    ("CHARACTER_LARGEST", 30, SABREMAN_LEGS + WEREWOLF_LEGS + SPELL),
    ("CHARACTER_TALLEST", 92, SABREMAN_BODY + WEREWOLF_BODY + SPELL),
)

# The groups a sprite can be in, and what they claim.
#
# A band is (name, what it is called on the picture, the graphics it claims),
# and a fourth element makes it a parent: its children are bands in their own
# right and their names hang off its own. So the tree below names a sprite
# knight.legs.1 -- the path to its group, then which one it is within that
# group, counting from one.
#
# Nesting is only about the name and the picture's headings. Everything
# downstream sees the flattened list, in the order written here, which is the
# order the picture is laid out in and the order the atlas reads.
#
# A sprite belongs to the FIRST band that claims it, so the order matters where
# two would claim the same one -- and the last leaf sweeps up whatever no band
# asked for.
BANDS = (
    ("sabreman", "Sabreman", (), (
        ("legs", "Sabreman's legs", SABREMAN_LEGS),
        ("body", "Sabreman's body", SABREMAN_BODY),
    )),
    ("werewolf", "the werewolf", (), (
        ("legs", "the werewolf's legs", WEREWOLF_LEGS),
        ("body", "the werewolf's body", WEREWOLF_BODY),
    )),
    ("transform", "Sabreman turning into the werewolf", TRANSFORM),
    # A guard's legs are Sabreman's own -- graphics 144 to 157 name sprites
    # 55 to 62, which sabreman.legs has already taken -- so they have no band of
    # their own, and editing the knight's walk changes theirs with it.
    ("guard", "the guard's torso", (150, 151, 30, 31)),
    ("wizard", "the wizard", (158, 159)),
    ("spell", "the spell, and the sparkle Sabreman dies into", SPELL),
    ("fires", "fires", (176, 177, 180, 181, 86, 87)),
    ("balls", "balls", (178, 179, 182, 183)),
    ("ghost", "the ghost", (80, 81, 82, 83)),
    ("gate", "the portcullis", (8, 9)),
    ("sun", "the sun and the moon", SUN),
    ("window", "the sun window's frame", WINDOW),
    ("panel", "the status panel", PANEL),
    ("menu", "the menu's frame", MENU),
    ("collectable", "the things the wizard wants", COLLECTABLE),
    ("wall", "what closes a room in", (), (
        ("castle", "stone walls", WALL_CASTLE),
        ("forest", "trees", WALL_FOREST),
    )),
    ("door", "what you walk through", (), (
        ("castle", "stone arches", DOOR_CASTLE),
        ("forest", "tree arches", DOOR_FOREST),
    )),
    ("scenery", "scenery", ()),         # and the sweep-up
)

# What a sprite is CALLED, where a number will not do. The key is any graphic
# that draws it; the sprite it lands on takes the name, whatever band claims it
# and wherever it falls in that band. Everything unnamed is numbered within its
# group instead, which is all most of them need -- sabreman.legs.3 says enough.
#
# Add to this rather than editing sprites.json: the sheet is written from here.
SPRITE_NAMES = {
    23: "floor_spike",
    63: "spike_ball",
    6: "wood_block",
    22: "gargoyle",
    7: "block",
    85: "chest",
    84: "table",
    141: "cauldron",
    142: "cauldron_lid",
}

# What each animation is called. Keyed by the sprites it plays, so a set of
# graphics that draws the same animation somewhere else lands on the same name.
ANIMATION_NAMES = {
    ("fires.1", "fires.2"): "fire",
    ("balls.1", "balls.2"): "ball",
    ("guard.1", "guard.2"): "guard",
    ("wizard.1", "wizard.2"): "wizard",
    ("ghost.1", "ghost.2", "ghost.3", "ghost.4"): "ghost",
    ("gate.1", "gate.1"): "gate",
    ("spell.1", "spell.2", "spell.3", "spell.2"): "spell",
    ("sabreman.legs.1", "sabreman.legs.2", "sabreman.legs.3",
     "sabreman.legs.4", "sabreman.legs.3", "sabreman.legs.2",
     "sabreman.legs.5", "sabreman.legs.6", "sabreman.legs.7",
     "sabreman.legs.8", "sabreman.legs.7", "sabreman.legs.6"): "guard_walk",
}

# Nudges the original sets from a constant rather than per graphic. Knight
# Lore has none; Pentagram does, and the two read the same way.
FIXED_NUDGES = {}

# What separates a group from its parent, and from the sprite's own name. Dots
# rather than underscores because a name already has underscores in it, and
# because the path is what this is: knight.legs.1.
NAME_SEPARATOR = "."

# Graphic 1 is Knight Lore's way of drawing nothing: its own table has no
# bitmap for it, and ours points at a sprite that covers nothing instead.
BLANK_GRAPHIC = 1
NO_SPRITE = 0xFF                        # a graphic number the game does not use


def read_sprites(packed):
    """sprite_data.bin -> one dict a sprite, the right way up.

    Each sprite is two header bytes -- a width in bytes with a flag of the
    game's own in the top bits, and a height -- then mask and data bytes
    interleaved, a row at a time, bottom row first. `record` keeps the whole
    thing as it was read, which is what the atlas hands the graphics panel.
    """
    sprites = []
    at = 0
    while at < len(packed):
        flag, height = packed[at] & ~0x1F, packed[at + 1]
        width = packed[at] & 0x1F
        count = width * height * 2
        record = packed[at:at + 2 + count]
        body = record[2:]
        rows = [body[i:i + width * 2] for i in range(0, count, width * 2)]
        mask = [row[0::2] for row in rows]
        data = [row[1::2] for row in rows]
        mask.reverse()                  # stored bottom row first, as Ultimate did
        data.reverse()
        sprites.append({
            "name": "sprite_%03d" % len(sprites),
            "w": width,
            "h": height,
            "flag": flag,
            "at": at,
            "record": record,
            "mask": mask,
            "data": data,
        })
        at += 2 + count
    return sprites


def flatten(bands, prefix=""):
    """BANDS as a flat list, each band's name being its whole path.

    Depth first and in written order, so the picture and the atlas read the way
    the tree does. A parent that claims graphics of its own keeps them, and
    comes before its children.
    """
    out = []
    for band in bands:
        name, title, graphics = band[0], band[1], band[2]
        children = band[3] if len(band) > 3 else ()
        path = prefix + name
        if graphics or not children:
            out.append((path, title, graphics))
        out.extend(flatten(children, path + NAME_SEPARATOR))
    return out


def read_graphics(path):
    """Which sprite each graphic number draws, out of the extraction.

    graphic_map.json is kl_extract.py's, written from the game's own table of
    sprite pointers at $7112. It is the ONLY place the packed sprite index
    lives -- sprites.json is in the group tree's order, which is a rearrangement
    of the packed one, so the index cannot be recovered from a name.

    Its nudges are the extraction's own and are a fallback only: the harvest
    that matters is read back out of graphics.json by read_harvest below, once
    the trims are known.
    """
    if not path.is_file():
        return {}
    said = json.loads(path.read_text(encoding="utf-8"))
    return {int(number): dict(entry)
            for number, entry in (said.get("graphics") or {}).items()}


def read_harvest(path, sprites, graphic_map):
    """The nudges as graphics.json holds them, with the trim taken back off.

    This is the half that cannot be rebuilt. adj.py reads it out of a RUNNING
    Knight Lore -- the game picks its nudges inside its per-graphic update
    routines rather than from a table, so these are values its own code
    produced -- and graphics.json is where they live.

    graphics_json below adds each sprite's trim to y as it writes, so the file
    holds the nudge for the sprite as WE hold it, blank rows gone. Coming back
    the other way that has to come off again, or a second run would push every
    trimmed sprite down by its trim a second time.

    An absent x or y means zero, which is how the file writes one; a graphic
    the file does not mention keeps whatever the extraction said.
    """
    if not path.is_file():
        return {}
    said = json.loads(path.read_text(encoding="utf-8"))
    out = {}
    for entry in (said.get("graphics") or {}).values():
        number = entry["number"]
        n = graphic_map[number] if number < len(graphic_map) else NO_SPRITE
        taken = sprites[n]["trim"] if n != NO_SPRITE else 0
        spot = {"x": entry.get("x", 0), "y": entry.get("y", 0) - taken}
        mirrored = entry.get("mirrored")
        if mirrored:
            spot["mirrored"] = {"x": mirrored["x"], "y": mirrored["y"] - taken}
        if entry.get("note"):
            spot["note"] = entry["note"]
        out[number] = spot
    return out


def sprite_list(table, count):
    """...and the sprite half of it as a plain list, NO_SPRITE in the gaps.

    The band logic below indexes by graphic number, so it wants a list; the
    file is keyed and leaves the unused numbers out, which is what makes it
    readable.
    """
    out = [NO_SPRITE] * count
    for number, entry in table.items():
        if 0 <= number < count and isinstance(entry.get("sprite"), int):
            out[number] = entry["sprite"]
    return out


def bands_of(sprites, graphic_map):
    """The band each sprite belongs to, by the first one that names it."""
    bands = []                          # (path, title, [sprite index, ...])
    placed = set()
    for label, title, graphics in flatten(BANDS):
        members = []
        for graphic in graphics:
            n = graphic_map[graphic]
            if n != NO_SPRITE and n not in placed:
                placed.add(n)
                members.append(n)
        bands.append((label, title, members))
    # Whatever no band asked for goes in the last one, in sprite order.
    bands[-1][2].extend(n for n in range(len(sprites)) if n not in placed)
    return bands


def trim_blank_rows(sprites, graphic_map):
    """Take the blank rows off the bottom of every sprite that may lose them.

    A sprite hangs from its bottom row, so blank rows there cost bytes in the
    image and buy nothing -- 38 of Knight Lore's 103 have some, and they are
    776 bytes. This is done HERE, as the sheet is made, so the picture and the
    rectangles in it are already the sprite the game draws. It used to happen
    later, when the sheet was assembled, which left sprites.json describing
    something the build then quietly changed.

    WHOLE_SPRITE_GRAPHICS is what may not lose them: four places draw a sprite
    without asking object_update how tall it is, so each knows its own height
    and a trim would move what it draws.

    The rows taken are kept on the sprite. Nothing downstream needs them -- the
    nudges in the graphic table are already right for the trimmed sprite -- but
    adj.py does, because it harvests against the ORIGINAL game, where the
    sprite still has them.
    """
    keep = {graphic_map[g] for g in WHOLE_SPRITE_GRAPHICS
            if graphic_map[g] != NO_SPRITE}
    for n, sprite in enumerate(sprites):
        taken = 0
        # One row always stays: a sprite of none would draw 256.
        while (n not in keep
               and len(sprite["mask"]) - taken > 1
               and not any(sprite["mask"][-1 - taken])
               and not any(sprite["data"][-1 - taken])):
            taken += 1
        if taken:
            sprite["mask"] = sprite["mask"][:-taken]
            sprite["data"] = sprite["data"][:-taken]
        sprite["trim"] = taken
        sprite["h"] = len(sprite["mask"])


def lay_out(sprites, bands):
    """Give every sprite a place on the sheet. Returns the sheet's size."""
    y = 0
    for label, title, members in bands:
        if not members:
            continue
        y += LABEL_HEIGHT
        x, tallest = 0, 0
        for n in members:
            sprite = sprites[n]
            pixels = sprite["w"] * 8
            if x and x + pixels > SHEET_WIDTH:
                x, y, tallest = 0, y + tallest + GAP, 0
            sprite["x"], sprite["y"] = x, y
            x += pixels + GAP
            tallest = max(tallest, sprite["h"])
        y += tallest + GAP
    return SHEET_WIDTH, y


def draw(sprites, bands, size):
    sheet = Image.new("RGBA", size, PALETTE["transparent"])
    pixels = sheet.load()
    for sprite in sprites:
        for row, (mask, data) in enumerate(zip(sprite["mask"], sprite["data"])):
            for byte in range(sprite["w"]):
                m, d = mask[byte], data[byte]
                for bit in range(8):
                    covers = m & (0x80 >> bit)
                    set_bit = d & (0x80 >> bit)
                    if covers:
                        colour = PALETTE["ink"] if set_bit else PALETTE["paper"]
                    elif set_bit:
                        colour = PALETTE["stray"]
                    else:
                        continue
                    pixels[sprite["x"] + byte * 8 + bit, sprite["y"] + row] = colour
    # The band names sit in the strip above each band, clear of every sprite.
    # Nothing reads them back -- both the atlas and the panel go by the
    # rectangles -- they are there for whoever opens the picture to paint on.
    pen = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for label, title, members in bands:
        if members:
            top = min(sprites[n]["y"] for n in members)
            pen.text((0, top - LABEL_HEIGHT), title, font=font, fill=LABEL_COLOUR)
    return sheet


# A graphic's NAME, which rooms.json refers to it by.
#
# It is seeded from the sprite that draws it -- with the graphic number added
# when several graphics share one bitmap, because they are not interchangeable
# -- and then it is STORED. That is the whole point: once written it belongs to
# the graphic, not to the mapping, so re-pointing a graphic at a different
# sprite changes what it draws and leaves every castle that names it alone.
#
# Derived names were the alternative and they do not work. A castle names
# graphics; if the name is recomputed from the map, then moving one graphic
# renames it and every room that placed it dangles, for a change that was only
# ever meant to say "draw this with a different bitmap".
def named_graphics(table, label_of, named):
    out = {}
    for number in sorted(table):
        entry = dict(table[number])
        if not entry:
            continue
        if "name" not in entry:
            n = entry.get("sprite")
            if isinstance(n, int):
                entry["name"] = (label_of(n) if len(named.get(n, ())) == 1
                                 else "%s.g%d" % (label_of(n), number))
        # Name first, because it is what a reader wants first.
        out[str(number)] = {key: entry[key] for key in
                            ("name", "sprite", "x", "y", "mirrored", "note")
                            if key in entry}
    return out


def label_map(sprites, bands):
    """Every sprite's name: the path to its group, then what it is called there.

    A sprite with no name of its own is numbered within its group, counting
    from one -- within the group rather than across the sheet, so adding one
    does not renumber everything after it.
    """
    band_of = {n: label for label, _title, members in bands for n in members}
    within = {}
    for _label, _title, members in bands:
        for i, n in enumerate(members):
            within[n] = i + 1

    called = {}
    for graphic, name in SPRITE_NAMES.items():
        n = GRAPHIC_MAP_CACHE[graphic]
        if n == NO_SPRITE:
            raise SystemExit("SPRITE_NAMES calls graphic %d %r, and no sprite "
                             "draws that graphic" % (graphic, name))
        called[n] = name

    return {n: band_of[n] + NAME_SEPARATOR + called.get(n, str(within[n]))
            for n in range(len(sprites))}


def sprites_json(sprites, bands, labels, size):
    """The sheet: what the picture means, and where every sprite is in it.

    A group tree, because a sprite's name IS its path through it -- nothing
    here carries a dotted name. One sprite a line, so the file reads like the
    table it is.
    """
    order = [n for _label, _title, members in bands for n in members]

    tree = {"group": {}, "sprites": {}}

    def child(node, name):
        node["group"].setdefault(name, {"group": {}, "sprites": {}})
        return node["group"][name]

    for n in order:
        path = labels[n].split(NAME_SEPARATOR)
        node = tree
        for part in path[:-1]:
            node = child(node, part)
        s = sprites[n]
        # trim is how many blank rows came off the bottom. It is kept because
        # the nudge in graphics.json has it folded in: adj.py harvests raw
        # nudges from a running game and has to add the same number back, and
        # without this it would need the packed sprite data to work it out.
        node["sprites"][path[-1]] = {"x": s["x"], "y": s["y"],
                                     "w": s["w"] * 8, "h": s["h"],
                                     "trim": s["trim"]}

    def widths(node):
        out = {"name": 0, "x": 1, "y": 1, "w": 1, "h": 1, "trim": 1}
        for name, box in node["sprites"].items():
            out["name"] = max(out["name"], len(name))
            for k in ("x", "y", "w", "h", "trim"):
                out[k] = max(out[k], len(str(box[k])))
        return out

    def emit(node, depth, lines):
        pad, inner = " " * depth, " " * (depth + 1)
        if node["sprites"]:
            width = widths(node)
            lines.append('%s"sprites": {' % pad)
            rows = list(node["sprites"].items())
            for i, (name, box) in enumerate(rows):
                # A sprite that lost nothing says nothing, which is most of
                # them: 38 of Knight Lore's 103 have a trim at all.
                keys = ["x", "y", "w", "h"]
                if any(b["trim"] for _n, b in rows):
                    keys.append("trim")
                cells = ", ".join('"%s": %*d' % (k, width[k], box[k])
                                  for k in keys)
                lines.append('%s%-*s { %s }%s'
                             % (inner, width["name"] + 3, '"%s":' % name, cells,
                                "," if i < len(rows) - 1 else ""))
            lines.append("%s}%s" % (pad, "," if node["group"] else ""))
        if node["group"]:
            lines.append('%s"group": {' % pad)
            names = list(node["group"])
            for i, name in enumerate(names):
                lines.append('%s"%s": {' % (inner, name))
                emit(node["group"][name], depth + 2, lines)
                lines.append("%s}%s" % (inner, "," if i < len(names) - 1 else ""))
            lines.append("%s}" % pad)

    colours = ["ink", "paper", "transparent", "stray"]
    pad = max(len(c) for c in colours) + 3
    lines = ["{", ' "sheet": {', '  "file": "%s",' % SHEET.name, '  "colours": {']
    for i, name in enumerate(colours):
        lines.append('   %-*s [ %s ]%s'
                     % (pad, '"%s":' % name,
                        ", ".join("%3d" % v for v in PALETTE[name]),
                        "," if i < len(colours) - 1 else ""))
    lines += ["  }", " },", ' "bytes": {',
              '  "header":      ["width", "height"],',
              '  "rows":        "bottom-up",',
              '  "interleaved": true,',
              '  "first":       "mask",',
              '  "maskBit":     "covers"',
              " },"]
    emit(tree, 1, lines)

    if ANIMATIONS:
        seen = []
        for frames in ANIMATIONS:
            names = tuple(labels[GRAPHIC_MAP_CACHE[g]] for g in frames)
            if names not in seen:       # the same animation, drawn elsewhere
                seen.append(names)
        width = max(len(ANIMATION_NAMES[s]) for s in seen)
        lines[-1] += ","
        lines.append(' "animations": {')
        for i, names in enumerate(seen):
            comma = "," if i < len(seen) - 1 else ""
            one = '  %-*s [ %s ]%s' % (width + 3, '"%s":' % ANIMATION_NAMES[names],
                                       ", ".join('"%s"' % n for n in names), comma)
            if len(one) <= 96:
                lines.append(one)
                continue
            lines.append('  "%s": [' % ANIMATION_NAMES[names])
            for j, n in enumerate(names):
                lines.append('   "%s"%s' % (n, "," if j < len(names) - 1 else ""))
            lines.append("  ]%s" % comma)
        lines.append(" }")

    lines.append("}")
    return "\n".join(lines) + "\n"


def graphics_json(sprites, labels, table, graphic_map):
    """Which sprite each graphic number draws, and the nudge it wants.

    The nudge harvested from the original game is for the sprite as the game
    holds it, blank rows and all. Ours has them trimmed off, which lets it fall
    by that many rows, so the trim goes back into the nudge here -- once, as
    the sheet is made, rather than on every build.

    The box a graphic occupies is rooms.py's half of this file, and is carried
    over from whatever is already there rather than dropped: remaking the sheet
    is about the artwork, and a size thrown out here would only come back by
    re-extracting the castle.
    """
    # What the file already says, by number: the boxes rooms.py folded in, and
    # the NAMES, which are the file's own once it exists. They are seeded from
    # the sprites the first time and are an edit after that, so remaking the
    # sheet must not rename a graphic every castle refers to.
    was = {}
    if GRAPHICS_JSON.is_file():
        said = json.loads(GRAPHICS_JSON.read_text(encoding="utf-8"))
        was = {e["number"]: dict(e, graphic=n)
               for n, e in (said.get("graphics") or {}).items()}

    seeds = gfx.seeded_names(
        {n: labels[graphic_map[n]] for n in sorted(table)
         if n < len(graphic_map) and graphic_map[n] != NO_SPRITE},
        set(labels))

    entries = {}
    for number in sorted(table):
        entry = table[number]
        n = graphic_map[number] if number < len(graphic_map) else NO_SPRITE
        taken = sprites[n]["trim"] if n != NO_SPRITE else 0
        said = {}
        if n != NO_SPRITE:
            said["sprite"] = labels[n]
        size = was.get(number, {}).get("size")
        if size is not None:
            said["size"] = size
        said["number"] = number
        if number in FIXED_NUDGES:
            # The original sets these from a constant every turn, so a harvest
            # that read a live record can have caught the last routine's pair.
            x, y = FIXED_NUDGES[number]
            mirrored = None
        else:
            x, y = entry.get("x", 0), entry.get("y", 0)
            m = entry.get("mirrored")
            mirrored = (m["x"], m["y"]) if m else None
        said["x"], said["y"] = x, y + taken
        if mirrored:
            said["mirrored"] = {"x": mirrored[0], "y": mirrored[1] + taken}
        entries[was[number]["graphic"] if number in was
                else seeds.get(number, "gfx_%02X" % number)] = said

    return gfx.format_table(entries, SPRITES_JSON.name)


def main():
    # Both halves of the extraction or neither. graphic_map.json is the only
    # place the graphic -> packed sprite index lives -- sprites.json is in the
    # group tree's order, which is a rearrangement of the packed one -- so
    # without it every graphic would resolve to no sprite and this would
    # cheerfully write out an empty sheet over the real one.
    for missing in (PACKED, GRAPHIC_MAP):
        if not missing.is_file():
            raise SystemExit(
                f"{missing.name} is missing -- run kl_extract.py against your "
                "own copy of Knight Lore to produce it.\n"
                "Neither file is carried in the repository, and neither is "
                "needed to BUILD the game: they are only wanted to remake the "
                "sheet. The nudges are safe either way -- they live in "
                f"{GRAPHICS_JSON.name} and are read back from there.")
    sprites = read_sprites(PACKED.read_bytes())
    table = read_graphics(GRAPHIC_MAP)
    graphic_map = sprite_list(table, GRAPHIC_COUNT)

    # The map is wanted by name_map and graphics_json below, and threading it
    # through four calls buys nothing: this runs once, from the top.
    global GRAPHIC_MAP_CACHE
    GRAPHIC_MAP_CACHE = graphic_map

    trim_blank_rows(sprites, graphic_map)

    # Now the trims are known, the harvest can come back out of graphics.json
    # and win over whatever the extraction file happened to say. This is what
    # makes running this twice safe: it remakes the picture and the layout
    # without throwing away the one thing a re-extraction could not replace.
    for number, spot in read_harvest(GRAPHICS_JSON, sprites, graphic_map).items():
        entry = table.setdefault(number, {})
        for key in ("x", "y", "mirrored", "note"):
            if key in spot:
                entry[key] = spot[key]
            else:
                entry.pop(key, None)

    bands = bands_of(sprites, graphic_map)
    size = lay_out(sprites, bands)
    draw(sprites, bands, size).save(SHEET)

    labels = label_map(sprites, bands)
    SPRITES_JSON.write_text(sprites_json(sprites, bands, labels, size),
                            encoding="utf-8")
    GRAPHICS_JSON.write_text(graphics_json(sprites, labels, table, graphic_map),
                             encoding="utf-8")
    print(f"Wrote {SHEET.name} ({size[0]}x{size[1]}, {len(sprites)} sprites), "
          f"{SPRITES_JSON.name} and {GRAPHICS_JSON.name}")


if __name__ == "__main__":
    main()
