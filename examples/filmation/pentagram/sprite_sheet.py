"""Pentagram's artwork as a sprite sheet: sprite_data.bin -> sprites.png
and sprites.json, beside this script.

    python sprite_sheet.py

sprite_data.bin is what pg_extract.py lifts out of a real Pentagram: 103
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

HERE = Path(__file__).resolve().parent
PACKED = HERE / "sprite_data.bin"
GRAPHIC_MAP = HERE / "graphic_map.bin"
SHEET = HERE / "sprites.png"
ATLAS = HERE / "sprites.json"

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

# Pentagram's graphic numbers, gathered into the bands the sheet is laid out
# in, and the groups the graphics panel shows. A sprite goes in the first band
# that names it and is drawn once, so the later bands hold only what the
# earlier ones left; the last one sweeps up everything no band asked for.
# Several of these are the same groupings the atlas goes on to record for the
# checks in sprite_source.py -- the knight's frames and the animations --
# because seeing an animation's frames side by side is exactly what makes a
# sheet worth having.
# None of Pentagram's groupings are known yet. Knight Lore's were worked out
# by looking at its sheet and at what its code does with each graphic; the same
# has to be done here before the sheet is worth grouping, and before any of
# this can be handed to sprite_source.py's checks. Until then the sheet lays
# every sprite out in one band, which is enough to look at them.
#
# What still has to be filled in -- ROTATION_BUFFERS is done, below:
#   ANIMATIONS            frames that must share a rotation buffer's size
#   WHOLE_SPRITE_GRAPHICS sprites drawn without asking object_update, which
#                         therefore keep their blank bottom rows
#   ROTATION_BUFFERS      the two buffers the character keeps for life, which
#                         are what CHARACTER_LARGEST and CHARACTER_TALLEST
#                         come from
#   BLANK_GRAPHIC         the graphic the game draws nothing with, if it has
#                         one; Knight Lore's is graphic 1
# Sabreman, as the original was watched wearing him: four frames a block,
# two blocks a half -- 32-35 walking away from the viewer and 36-39 towards
# it for his legs, 40-43 and 44-47 for his body. Mirroring makes the other two
# facings, so there is no third block.
SABREMAN_LEGS = tuple(range(32, 40))
SABREMAN_BODY = tuple(range(40, 48))
SABREMAN_POOF = tuple(range(64, 71))    # both halves wear the puff he dies in

# Nudges the original sets from a constant, every turn, rather than per
# graphic -- so the harvest, which reads live records, can catch a frame just
# as it changed and still wearing the last routine's pair. The puff is the
# case that shows: $C111 calls $C77A on every one of its frames, which is
# always -12, -4, but the harvest had three different pairs across 64-70 and
# the puff hopped about as it played. These override sprite_adj.s.
FIXED_NUDGES = {g: (-12, -4) for g in range(64, 72)}    # $C77A
# The crumbling blocks and the conveyors: $D2AD-$D2FF all call $C75F, -16, -8,
# every turn. 137-139 are only ever seen crumbling, so the harvest had them at
# nothing, and each crack jumped the block sixteen pixels right; 141 likewise.
FIXED_NUDGES.update({g: (-16, -8) for g in range(136, 144)})
# The quest's things likewise call $C75F: the bucket ($D0AC), the quest items
# and their done forms ($CF68), the pentagram's pieces ($CF14) and the
# collectables ($CD16). None is in a room as a new game starts but the
# collectables, and the harvest found only three of those, so the rest were
# drawn sixteen pixels right and eight low. A collectable put in its place
# becomes 152-156, whose routine ($CB4E) sets nothing: it keeps the nudge it
# had, so they have it too.
FIXED_NUDGES.update({g: (-16, -8) for g in [90] + list(range(112, 120))
                     + list(range(128, 136)) + list(range(144, 149))
                     + list(range(152, 157))})

ANIMATIONS = ()
# Drawn straight onto the screen with screen_sprite, which takes no pixel
# nudge and so cannot make up for blank rows trimmed off the bottom: the
# panel's pieces and the little Sabreman by the lives, and the game-over
# frame, whose 3 and 4 lost four rows each to the trim and drew that low.
WHOLE_SPRITE_GRAPHICS = (22, 58, 59, 60, 61, 62, 2, 3, 4, 5,
                         90, 144, 145, 146, 147, 148)    # and what he carries

# The two rotation buffers Sabreman keeps for life, sized from these sprites;
# every frame the matching half can wear has to fit, and sprite_source.py
# fails the build if one does not.
ROTATION_BUFFERS = (
    ("CHARACTER_LARGEST", 66, SABREMAN_LEGS + SABREMAN_POOF),
    ("CHARACTER_TALLEST", 61, SABREMAN_BODY + SABREMAN_POOF),
)

# Band name (a label, because the panel's groups have to be one), what it is
# called on the picture, and the graphics it claims. One sweep-up band for now.
BANDS = (
    ("sprites", "sprites", ()),
)

# Pentagram names 170 graphics; twenty-nine of them resolve to no sprite at
# all, in runs at 14-15, 22-25, 81, 87, 92-109 and 155-157. Whether one of
# those is the game's own "draw nothing" is not yet established, so nothing
# is claimed here.
BLANK_GRAPHIC = None
NO_SPRITE = 0xFF                        # what graphic_map.bin puts in the gaps


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


def bands_of(sprites, graphic_map):
    """The band each sprite belongs to, by the first one that names it."""
    bands = []                          # (label, title, [sprite index, ...])
    placed = set()
    for label, title, graphics in BANDS:
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


def build_atlas(sprites, bands, graphic_map, size):
    """The atlas the graphics panel reads, with what the build needs alongside.

    `frames` and `meta` are the panel's own shape -- see buildAtlas in the
    extension's graphics_model.js. Everything the game's build needs beyond
    that hangs off meta.zx.game, where the panel ignores it.
    """
    band_of = {n: (label, title) for label, title, members in bands for n in members}
    named = {}                          # sprite -> the graphics that name it
    for graphic, n in enumerate(graphic_map):
        if n != NO_SPRITE:
            named.setdefault(n, []).append(graphic)

    # The panel prefixes a sprite's label with its group's, so that two groups
    # can each have a "walk". The assembler label stays the plain `name`.
    def label_of(n):
        return band_of[n][0] + "_" + sprites[n]["name"]

    frames = {}
    for label, title, members in bands:  # picture order, so the file reads like it
        for n in members:
            sprite = sprites[n]
            box = {"x": sprite["x"], "y": sprite["y"],
                   "w": sprite["w"] * 8, "h": sprite["h"]}
            frames[label_of(n)] = {
                "frame": dict(box),
                "rotated": False,
                "trimmed": False,
                "spriteSourceSize": {"x": 0, "y": 0, "w": box["w"], "h": box["h"]},
                "sourceSize": {"w": box["w"], "h": box["h"]},
                "zx": {"sprite": label_of(n), "item": 0, "offset": 0, "group": label},
            }

    groups = [{"name": label,
               "sprites": [label_of(n) for n in members],
               "frames": [label_of(n) for n in members]}
              for label, title, members in bands if members]

    entries = []
    for n, sprite in enumerate(sprites):
        entry = {"name": sprite["name"], "group": band_of[n][0]}
        entry.update(SPRITE_FORMAT)
        entry.update({
            "width": sprite["w"],
            "height": sprite["h"],
            "origin": "%s +$%04X" % (PACKED.name, sprite["at"]),
            "label": label_of(n),
            "frames": [label_of(n)],
            "length": len(sprite["record"]),
            "bytes": base64.b64encode(sprite["record"]).decode("ascii"),
            # Ours, past what the panel reads: the flag the game's own width
            # byte carries, and which of its 256 graphic numbers name this
            # sprite. sprite_source.py recomputes the flag it emits, so this
            # one is here to keep `bytes` the record the game shipped.
            "flag": sprite["flag"],
            "graphics": named.get(n, []),
        })
        entries.append(entry)

    return {
        "frames": frames,
        "meta": {
            "app": "ZX Spectrum emulator graphics viewer",
            "version": "1.0",
            "image": SHEET.name,
            "format": "RGBA8888",
            "size": {"w": size[0], "h": size[1]},
            "scale": "1",
            "zx": {
                "version": 1,
                "groups": groups,
                "sprites": entries,
                "game": {
                    "_comment": "Written by sprite_sheet.py, read by "
                                "sprite_source.py; the graphics panel ignores "
                                "it. A sprite's width is in bytes, so it is "
                                "width * 8 pixels wide.",
                    "palette": {name: list(colour)
                                for name, colour in PALETTE.items()},
                    "graphicMap": [None if n == NO_SPRITE else n
                                   for n in graphic_map],
                    "blankGraphic": BLANK_GRAPHIC,
                    "wholeSpriteGraphics": list(WHOLE_SPRITE_GRAPHICS),
                    "animations": [list(frames) for frames in ANIMATIONS],
                    "fixedNudges": {str(g): list(p) for g, p in FIXED_NUDGES.items()},
                    "rotationBuffers": [
                        {"label": label, "sprite": sprite, "graphics": list(graphics)}
                        for label, sprite, graphics in ROTATION_BUFFERS
                    ],
                },
            },
        },
    }


def main():
    if not PACKED.is_file():
        raise SystemExit(f"{PACKED.name} is missing -- run pg_extract.py against "
                         "your own copy of Pentagram to produce it")
    sprites = read_sprites(PACKED.read_bytes())
    graphic_map = GRAPHIC_MAP.read_bytes()
    bands = bands_of(sprites, graphic_map)
    size = lay_out(sprites, bands)
    draw(sprites, bands, size).save(SHEET)
    ATLAS.write_text(
        json.dumps(build_atlas(sprites, bands, graphic_map, size), indent=1) + "\n",
        encoding="utf-8")
    print(f"Wrote {SHEET.name} ({size[0]}x{size[1]}, {len(sprites)} sprites) "
          f"and {ATLAS.name}")


if __name__ == "__main__":
    main()
