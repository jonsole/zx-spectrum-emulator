"""A Filmation remake's sprite sheet: sprites.png and sprites.json, written
from the game's packed artwork and read back into its assembler.

Both games keep their artwork the same way, and until this file each had its
own copy of the code that does it -- which had already drifted, one game
writing the sheet's new shape while the other still wrote the old. What
differs between them is facts about the GAME: which sprites form which groups,
what animates, what keeps its blank rows. Those stay in each game's
sprite_sheet.py, which passes itself in here as `game`; everything else about
the sheet is here, once.

    game.HERE                   the game's own folder
    game.GRAPHIC_COUNT          how many graphic numbers it has
    game.BANDS                  the group tree the sheet is laid out in
    game.SPRITE_NAMES           graphic -> the name of the sprite it draws
    game.ANIMATIONS             tuples of graphics that animate together
    game.ANIMATION_NAMES        the sprites an animation plays -> its name
    game.WHOLE_SPRITE_GRAPHICS  graphics whose sprites keep their blank rows
    game.FIXED_NUDGES           graphic -> (x, y) the game sets from a constant
    game.BLANK_GRAPHIC          the graphic that draws nothing, or None
    game.ROTATION_BUFFERS       (label, sprite, graphics) the character keeps
    game.EXTRACTOR              the script that pulls the packed files out
    game.TITLE                  the game's name, for messages

The sheet's colours carry the two bits a Filmation pixel has -- a mask bit
that says whether the sprite covers the screen there, and a data bit that
says what it puts down if it does. sprite_blit composites a row as
`and mask : xor data`:

    black           mask 1, data 0   paper
    white           mask 1, data 1   ink
    clear           mask 0, data 0   the screen shows through
    red             mask 0, data 1   the screen is inverted there

A fifth colour is not a pixel at all: every sprite has a one-pixel magenta
frame just outside its rectangle. It shows whoever paints on the picture
where each sprite ends, and frame_check below holds the rectangles in
sprites.json to it on every build -- a rectangle that has drifted from its
picture, or artwork painted past its sprite's edge, breaks the frame, and the
build stops rather than reading the wrong pixels.
"""

import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

sys.path.insert(0, str(Path(__file__).resolve().parent))
import graphics as gfx                                          # noqa: E402

SHEET_FILE = "sprites.png"
SPRITES_FILE = "sprites.json"
GRAPHICS_FILE = "graphics.json"
# What the extraction left: which sprite each graphic number draws, by its
# index in the packed file. Read only when the sheet is made.
GRAPHIC_MAP_FILE = "graphic_map.json"
PACKED_FILE = "sprite_data.bin"

# What each pixel state looks like, and the frame. sprite_source.py reads these
# out of sprites.json rather than knowing them itself, so the sheet's colours
# can change here alone.
PALETTE = {
    "transparent": (0, 0, 0, 0),
    "paper": (0, 0, 0, 255),
    "ink": (255, 255, 255, 255),
    "stray": (255, 0, 0, 255),
    # Not a pixel state: the frame drawn round every sprite, outside its
    # rectangle, which the build checks the rectangles against.
    "border": (255, 0, 255, 255),
}
COLOUR_ORDER = ("ink", "paper", "transparent", "stray", "border")

SHEET_WIDTH = 640               # wide enough for sixteen of the widest sprite
BORDER = 1                      # the frame round each sprite, outside its rectangle
# Between one sprite and the next, and between rows and bands: a frame, a
# clear pixel and the next frame, so no two sprites ever share a line of it.
GAP = 2 * BORDER + 1
LABEL_HEIGHT = 12               # the strip a band's name is written in
LABEL_COLOUR = (96, 96, 96, 255)

# What separates a group from its parent, and from the sprite's own name. Dots
# rather than underscores because a name already has underscores in it, and
# because the path is what this is: sabreman.legs.1.
NAME_SEPARATOR = "."
NO_SPRITE = 0xFF                        # a graphic number the game does not use

# How a pixel's colour becomes the two bits the Z80 wants: does the sprite
# cover the screen here, and what does it put down if it does. The border is
# not among them -- it is never a pixel of a sprite, so one inside a rectangle
# is a colour with no meaning, and read_sheet says so.
PIXEL_BITS = {
    "transparent": (0, 0),
    "paper": (1, 0),
    "ink": (1, 1),
    "stray": (0, 1),                    # a data bit under a hole in the mask
}
OPAQUE = 128                            # alpha at or above this is a colour
BORDER_COLOUR = "border"


# --- making the sheet, once, from the extraction ---------------------------

def read_sprites(packed):
    """sprite_data.bin -> one dict a sprite, the right way up.

    Each sprite is two header bytes -- a width in bytes with a flag of the
    game's own in the top bits, and a height -- then mask and data bytes
    interleaved, a row at a time, bottom row first.
    """
    sprites = []
    at = 0
    while at < len(packed):
        flag, height = packed[at] & ~0x1F, packed[at + 1]
        width = packed[at] & 0x1F
        count = width * height * 2
        body = packed[at + 2:at + 2 + count]
        rows = [body[i:i + width * 2] for i in range(0, count, width * 2)]
        mask = [row[0::2] for row in rows]
        data = [row[1::2] for row in rows]
        mask.reverse()                  # stored bottom row first, as Ultimate did
        data.reverse()
        sprites.append({"w": width, "h": height, "flag": flag,
                        "mask": mask, "data": data})
        at += 2 + count
    return sprites


def flatten(bands, prefix=""):
    """A game's BANDS as a flat list, each band's name being its whole path.

    A band is (name, what it is called on the picture, the graphics it claims),
    and a fourth element makes it a parent whose children hang their names off
    its own. Depth first and in written order, so the picture and the file read
    the way the tree does. A parent that claims graphics of its own keeps them,
    and comes before its children.
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

    graphic_map.json is the extractor's, written from the game's own table of
    sprite pointers. It is the ONLY place the packed sprite index lives --
    sprites.json is in the group tree's order, which is a rearrangement of the
    packed one, so the index cannot be recovered from a name. Its nudges are a
    fallback only: read_harvest brings back the ones graphics.json holds.
    """
    if not path.is_file():
        return {}
    said = json.loads(path.read_text(encoding="utf-8"))
    return {int(number): dict(entry)
            for number, entry in (said.get("graphics") or {}).items()}


def recorded_trims(sheet_path):
    """sprite name -> the blank rows the sheet as it stands says it lost.

    What graphics.json's nudges have folded into them is whatever sprites.json
    said beside them -- not what this run is about to trim. The two agree once
    a sheet has been made this way; a sheet from before trims were recorded
    says nothing, and its nudges are the harvest as it came off the game.
    """
    if not sheet_path.is_file():
        return {}
    sheet = json.loads(sheet_path.read_text(encoding="utf-8"))
    taken = {}

    def walk(node, path):
        for name, box in (node.get("sprites") or {}).items():
            taken[NAME_SEPARATOR.join(path + [name])] = box.get("trim", 0)
        for group, sub in (node.get("group") or {}).items():
            walk(sub, path + [group])

    walk(sheet, [])
    return taken


def read_harvest(path, sheet_path):
    """The nudges as graphics.json holds them, with the trim taken back off.

    This is the half that cannot be rebuilt: adj.py reads it out of a RUNNING
    game, and graphics.json is where it lives. The file holds each nudge for
    the sprite as the sheet holds it, blank rows gone, so the trim sprites.json
    records comes off here and graphics_json puts this run's back on. Without
    that, a second run would push every trimmed sprite down a second time.

    An absent x or y means zero, which is how the file writes one.
    """
    if not path.is_file():
        return {}
    said = json.loads(path.read_text(encoding="utf-8"))
    trims = recorded_trims(sheet_path)
    out = {}
    for entry in (said.get("graphics") or {}).values():
        taken = trims.get(entry.get("sprite"), 0)
        spot = {"x": entry.get("x", 0), "y": entry.get("y", 0) - taken}
        mirrored = entry.get("mirrored")
        if mirrored:
            spot["mirrored"] = {"x": mirrored["x"], "y": mirrored["y"] - taken}
        if entry.get("note"):
            spot["note"] = entry["note"]
        out[entry["number"]] = spot
    return out


def sprite_list(table, count):
    """The sprite half of the table as a plain list, NO_SPRITE in the gaps."""
    out = [NO_SPRITE] * count
    for number, entry in table.items():
        if 0 <= number < count and isinstance(entry.get("sprite"), int):
            out[number] = entry["sprite"]
    return out


def bands_of(game, sprites, graphic_map):
    """The band each sprite belongs to, by the first one that names it.

    Whatever no band asked for goes in the last one, in sprite order.
    """
    bands = []                          # (path, title, [sprite index, ...])
    placed = set()
    for label, title, graphics in flatten(game.BANDS):
        members = []
        for graphic in graphics:
            n = graphic_map[graphic]
            if n != NO_SPRITE and n not in placed:
                placed.add(n)
                members.append(n)
        bands.append((label, title, members))
    bands[-1][2].extend(n for n in range(len(sprites)) if n not in placed)
    return bands


def trim_blank_rows(game, sprites, graphic_map):
    """Take the blank rows off the bottom of every sprite that may lose them.

    A sprite hangs from its bottom row, so blank rows there cost bytes and buy
    nothing. This is done as the sheet is made, so the picture and its
    rectangles are already the sprite the game draws. WHOLE_SPRITE_GRAPHICS is
    what may not lose them: the code that draws those knows its own height
    rather than asking object_update, and a trim would move what it draws.

    The rows taken are kept on the sprite, and written into sprites.json:
    graphics.json's nudges have them folded in, and adj.py, which harvests
    against the ORIGINAL game, has to fold them the same way.
    """
    keep = {graphic_map[g] for g in game.WHOLE_SPRITE_GRAPHICS
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
    """Give every sprite a place on the sheet. Returns the sheet's size.

    Every place is BORDER in from where the last thing ended, so the frame
    round the sprite has room above it and to its left.
    """
    y = 0
    for _label, _title, members in bands:
        if not members:
            continue
        y += LABEL_HEIGHT + BORDER
        x, tallest = BORDER, 0
        for n in members:
            sprite = sprites[n]
            pixels = sprite["w"] * 8
            if x > BORDER and x + pixels + BORDER > SHEET_WIDTH:
                x, y, tallest = BORDER, y + tallest + GAP, 0
            sprite["x"], sprite["y"] = x, y
            x += pixels + GAP
            tallest = max(tallest, sprite["h"])
        y += tallest + GAP
    return SHEET_WIDTH, y


def draw(sprites, bands, size):
    sheet = Image.new("RGBA", size, PALETTE["transparent"])
    pixels = sheet.load()
    for sprite in sprites:
        # The frame, just outside the rectangle.
        left, top = sprite["x"] - BORDER, sprite["y"] - BORDER
        right, bottom = sprite["x"] + sprite["w"] * 8, sprite["y"] + sprite["h"]
        for x in range(left, right + 1):
            pixels[x, top] = PALETTE["border"]
            pixels[x, bottom] = PALETTE["border"]
        for y in range(top, bottom + 1):
            pixels[left, y] = PALETTE["border"]
            pixels[right, y] = PALETTE["border"]
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
    # The band names sit in the strip above each band, clear of every frame.
    # Nothing reads them back -- they are there for whoever opens the picture
    # to paint on.
    pen = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for _label, title, members in bands:
        if members:
            top = min(sprites[n]["y"] for n in members) - BORDER
            pen.text((0, top - LABEL_HEIGHT), title, font=font, fill=LABEL_COLOUR)
    return sheet


def label_map(game, sprites, bands, graphic_map):
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
    for graphic, name in game.SPRITE_NAMES.items():
        n = graphic_map[graphic]
        if n == NO_SPRITE:
            raise SystemExit("SPRITE_NAMES calls graphic %d %r, and no sprite "
                             "draws that graphic" % (graphic, name))
        called[n] = name

    return {n: band_of[n] + NAME_SEPARATOR + called.get(n, str(within[n]))
            for n in range(len(sprites))}


def sprites_json(game, sprites, bands, labels, graphic_map):
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
                # them.
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

    pad = max(len(c) for c in COLOUR_ORDER) + 3
    lines = ["{", ' "sheet": {', '  "file": "%s",' % SHEET_FILE, '  "colours": {']
    for i, name in enumerate(COLOUR_ORDER):
        lines.append('   %-*s [ %s ]%s'
                     % (pad, '"%s":' % name,
                        ", ".join("%3d" % v for v in PALETTE[name]),
                        "," if i < len(COLOUR_ORDER) - 1 else ""))
    lines += ["  }", " },", ' "bytes": {',
              '  "header":      ["width", "height"],',
              '  "rows":        "bottom-up",',
              '  "interleaved": true,',
              '  "first":       "mask",',
              '  "maskBit":     "covers"',
              " },"]
    emit(tree, 1, lines)

    if game.ANIMATIONS:
        seen = []
        for frames in game.ANIMATIONS:
            names = tuple(labels[graphic_map[g]] for g in frames)
            if names not in seen:       # the same animation, drawn elsewhere
                seen.append(names)
        width = max(len(game.ANIMATION_NAMES[s]) for s in seen)
        lines[-1] += ","
        lines.append(' "animations": {')
        for i, names in enumerate(seen):
            comma = "," if i < len(seen) - 1 else ""
            one = '  %-*s [ %s ]%s' % (width + 3, '"%s":' % game.ANIMATION_NAMES[names],
                                       ", ".join('"%s"' % n for n in names), comma)
            if len(one) <= 96:
                lines.append(one)
                continue
            lines.append('  "%s": [' % game.ANIMATION_NAMES[names])
            for j, n in enumerate(names):
                lines.append('   "%s"%s' % (n, "," if j < len(names) - 1 else ""))
            lines.append("  ]%s" % comma)
        lines.append(" }")

    lines.append("}")
    return "\n".join(lines) + "\n"


def graphics_json(game, sprites, labels, table, graphic_map):
    """Which sprite each graphic number draws, and the nudge it wants.

    The nudge harvested from the original game is for the sprite as the game
    holds it, blank rows and all. Ours has them trimmed off, which lets it fall
    by that many rows, so the trim goes back into the nudge here -- once, as
    the sheet is made, rather than on every build. A nudge the game sets from a
    constant (FIXED_NUDGES) is written as that constant, whatever was harvested.

    The names and the boxes are the file's own once it exists and are carried
    over: remaking the sheet is about the artwork, and must not rename a graphic
    every castle refers to, nor drop a box only re-extracting the castle would
    bring back.
    """
    path = game.HERE / GRAPHICS_FILE
    was = {}
    if path.is_file():
        said = json.loads(path.read_text(encoding="utf-8"))
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
        if number in game.FIXED_NUDGES:
            # The original sets these from a constant every turn, so a harvest
            # that read a live record can have caught the last routine's pair.
            x, y = game.FIXED_NUDGES[number]
            mirrored = None
        else:
            x, y = entry.get("x", 0), entry.get("y", 0)
            m = entry.get("mirrored")
            mirrored = (m["x"], m["y"]) if m else None
        said["x"], said["y"] = x, y + taken
        if mirrored:
            said["mirrored"] = {"x": mirrored[0], "y": mirrored[1] + taken}
        if entry.get("note"):
            said["note"] = entry["note"]
        entries[was[number]["graphic"] if number in was
                else seeds.get(number, "gfx_%02X" % number)] = said

    return gfx.format_table(entries, SPRITES_FILE)


def make(game):
    """The whole of a game's sprite_sheet.py: the extraction -> the sheet.

    Remakes sprites.png, sprites.json and graphics.json. Safe to run again: the
    names and boxes graphics.json holds are kept, and so is the harvest -- the
    one thing a re-extraction could not replace.
    """
    here = game.HERE
    packed, graphic_map_file = here / PACKED_FILE, here / GRAPHIC_MAP_FILE
    # Both halves of the extraction or neither. graphic_map.json is the only
    # place the graphic -> packed sprite index lives, so without it every
    # graphic would resolve to no sprite and this would cheerfully write out an
    # empty sheet over the real one.
    for missing in (packed, graphic_map_file):
        if not missing.is_file():
            raise SystemExit(
                f"{missing.name} is missing -- run {game.EXTRACTOR} against your "
                f"own copy of {game.TITLE} to produce it.\n"
                "Neither file is carried in the repository, and neither is "
                "needed to BUILD the game: they are only wanted to remake the "
                "sheet. The nudges are safe either way -- they live in "
                f"{GRAPHICS_FILE} and are read back from there.")
    sprites = read_sprites(packed.read_bytes())
    table = read_graphics(graphic_map_file)
    graphic_map = sprite_list(table, game.GRAPHIC_COUNT)

    trim_blank_rows(game, sprites, graphic_map)

    # The harvest comes back out of graphics.json and wins over whatever the
    # extraction file happened to say.
    for number, spot in read_harvest(here / GRAPHICS_FILE, here / SPRITES_FILE).items():
        entry = table.setdefault(number, {})
        for key in ("x", "y", "mirrored", "note"):
            if key in spot:
                entry[key] = spot[key]
            else:
                entry.pop(key, None)

    bands = bands_of(game, sprites, graphic_map)
    size = lay_out(sprites, bands)
    draw(sprites, bands, size).save(here / SHEET_FILE)

    labels = label_map(game, sprites, bands, graphic_map)
    (here / SPRITES_FILE).write_text(
        sprites_json(game, sprites, bands, labels, graphic_map), encoding="utf-8")
    (here / GRAPHICS_FILE).write_text(
        graphics_json(game, sprites, labels, table, graphic_map), encoding="utf-8")
    print(f"Wrote {SHEET_FILE} ({size[0]}x{size[1]}, {len(sprites)} sprites), "
          f"{SPRITES_FILE} and {GRAPHICS_FILE}")


# --- reading it back, every build -------------------------------------------

def read_sheet_files(game, sprites_path, graphics_path):
    """sprites.json + graphics.json -> the sprites in sheet order, and the facts.

    A sprite is named by where it sits in the group tree, so the name is built
    walking it; the order that walk produces is the order the sheet lays them
    out, and so the order they are emitted in. `asm` is the assembler label
    the game's own sources call it by, made from the name.

    graphics.json is keyed by the graphic's NAME and carries the number the
    game knows it by; `graphics` here is keyed by that number, as an int.

    The engine's own facts -- what animates, what keeps its blank rows, the
    rotation buffers -- are not in either file. They are hand-written constants
    about the game, and come from its sprite_sheet.py.
    """
    sheet = json.loads(sprites_path.read_text(encoding="utf-8"))
    said = json.loads(graphics_path.read_text(encoding="utf-8"))

    entries, by_name = [], {}

    def walk(node, path):
        for key, box in (node.get("sprites") or {}).items():
            name = NAME_SEPARATOR.join(path + [key])
            by_name[name] = len(entries)
            entries.append({
                "name": name,
                "asm": "sprite_" + name.replace(NAME_SEPARATOR, "_"),
                "x": box["x"], "y": box["y"],
                "width": box["w"] // 8, "height": box["h"],
            })
        for group, sub in (node.get("group") or {}).items():
            walk(sub, path + [group])

    walk(sheet, [])
    if not entries:
        raise SystemExit(f"{sprites_path.name} has no sprites in it")

    gmap = [None] * game.GRAPHIC_COUNT
    nudge = {}
    for graphic, entry in (said.get("graphics") or {}).items():
        number = entry["number"]
        if not 0 <= number < game.GRAPHIC_COUNT:
            continue
        name = entry.get("sprite")
        if name is not None:
            if name not in by_name:
                raise SystemExit(
                    f"{graphics_path.name}: {graphic} names the sprite "
                    f"{name!r}, which {sprites_path.name} does not have")
            gmap[number] = by_name[name]
        nudge[number] = dict(entry, graphic=graphic)

    facts = {
        "graphicMap": gmap,
        "graphics": nudge,
        "palette": {name: rgba for name, rgba
                    in (sheet.get("sheet") or {}).get("colours", {}).items()},
        "blankGraphic": game.BLANK_GRAPHIC,
        "wholeSpriteGraphics": game.WHOLE_SPRITE_GRAPHICS,
        "animations": game.ANIMATIONS,
        "rotationBuffers": [{"label": label, "sprite": sprite,
                             "graphics": list(graphics)}
                            for label, sprite, graphics in game.ROTATION_BUFFERS],
    }
    return sheet, entries, facts


def frame_check(entry, pixels, border, sheet):
    """Stop unless the one-pixel frame round the sprite's rectangle is whole.

    make() draws the frame just outside every rectangle it writes to
    sprites.json. So a rectangle that no longer sits on its own picture -- an
    edited x or y, a sheet repainted out of step -- or artwork that has spread
    past its sprite's edge shows up here as a frame pixel of another colour,
    rather than as the game quietly getting the wrong bytes.
    """
    left, top = entry["x"] - 1, entry["y"] - 1
    right, bottom = entry["x"] + entry["width"] * 8, entry["y"] + entry["height"]
    ring = ([(x, top) for x in range(left, right + 1)]
            + [(x, bottom) for x in range(left, right + 1)]
            + [(left, y) for y in range(top + 1, bottom)]
            + [(right, y) for y in range(top + 1, bottom)])
    for x, y in ring:
        if tuple(pixels[x, y]) != border:
            r, g, b, a = pixels[x, y]
            raise SystemExit(
                f"{entry['name']}: {sheet.name} at ({x}, {y}) should be its frame "
                f"but is #{r:02X}{g:02X}{b:02X} (alpha {a}) -- its rectangle in "
                f"sprites.json ({entry['x']}, {entry['y']}, {entry['width'] * 8}x"
                f"{entry['height']}) and the picture disagree, or its artwork "
                f"runs past its edge")


def read_sheet(sheet, entries, palette):
    """The sheet's pixels, as (mask, data) byte rows a sprite, top row first."""
    image = Image.open(sheet).convert("RGBA")
    # Only the colours that are actually drawn, keyed by RGB. "paper" and
    # "transparent" are both black and differ only in their alpha, so a map
    # keyed by RGB alone would have one quietly overwrite the other -- and
    # which one won would depend on the order the palette happened to list
    # them. Everything see-through is handled by the alpha test below, so the
    # see-through colours are left out of this and black means paper.
    colours = {tuple(rgba[:3]): PIXEL_BITS[name] for name, rgba in palette.items()
               if name in PIXEL_BITS and (len(rgba) < 4 or rgba[3] >= OPAQUE)}
    if BORDER_COLOUR not in palette:
        raise SystemExit(f"{SPRITES_FILE} names no {BORDER_COLOUR!r} colour, so the "
                         f"frame round each sprite cannot be checked -- "
                         f"regenerate the sheet with sprite_sheet.py")
    border = tuple(palette[BORDER_COLOUR])
    pixels = image.load()

    sprites = []
    for entry in entries:
        width, height = entry["width"], entry["height"]
        box = entry
        if (box["x"] < 1 or box["y"] < 1 or box["x"] + width * 8 + 1 > image.width
                or box["y"] + height + 1 > image.height):
            raise SystemExit(f"{entry['name']} and its frame run off {sheet.name}, "
                             f"which is {image.width}x{image.height}")
        frame_check(entry, pixels, border, sheet)
        mask_rows, data_rows = [], []
        for row in range(height):
            mask, data = bytearray(width), bytearray(width)
            for byte in range(width):
                for bit in range(8):
                    r, g, b, a = pixels[box["x"] + byte * 8 + bit, box["y"] + row]
                    if a < OPAQUE:
                        continue        # anything see-through is a hole
                    if (r, g, b) not in colours:
                        raise SystemExit(
                            f"{entry['name']} has a colour the sheet has no "
                            f"meaning for at ({byte * 8 + bit}, {row}): "
                            f"#{r:02X}{g:02X}{b:02X}")
                    m, d = colours[(r, g, b)]
                    mask[byte] |= m << (7 - bit)
                    data[byte] |= d << (7 - bit)
            mask_rows.append(mask)
            data_rows.append(data)
        sprites.append({
            "name": entry["asm"],
            "w": width,
            "h": height,
            "mask": mask_rows,
            "data": data_rows,
        })
    return sprites


def trim(sprites, whole):
    """Take the blank bottom rows off every sprite that can spare them.

    The sheet is trimmed already -- make() does it as it draws -- so on a sheet
    it made this finds nothing to take. It stays as the check that that is
    true, and to record the rows each sprite ended up with. At least one row
    always stays: a sprite of none would draw 256.
    """
    for n, sprite in enumerate(sprites):
        taken = 0
        while (n not in whole
               and len(sprite["mask"]) - taken > 1
               and not any(sprite["mask"][-1 - taken])
               and not any(sprite["data"][-1 - taken])):
            taken += 1
        if taken:
            sprite["mask"] = sprite["mask"][:-taken]
            sprite["data"] = sprite["data"][:-taken]
        sprite["trim"] = taken
        sprite["h"] = len(sprite["mask"])
