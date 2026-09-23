"""A game's font as a sheet: font.bin -> font.png and font.json, beside it.

Both games keep their font the same way, so the whole of how a sheet is made
is here and each game's own font_sheet.py says only what its characters draw
and how they are blocked out. Run the game's, not this.

font.bin is what the game's own extractor lifts from a copy of it: 8x8
characters, eight bytes each, one bit a pixel and no mask -- all the text the
game has. This spreads them over a labelled sheet and writes font.json beside
it, an atlas in the shape the ZX Spectrum extension's graphics panel reads.

The picture is what counts from then on: font_source.py turns it back into
assembler, so editing the PNG is how the font changes. font.bin is only the
seed, and running this again overwrites those edits.
"""

import base64
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

# The game's folder, its files and its tables, which build() fills in.
HERE = PACKED = SHEET = ATLAS = None
GLYPHS = BLOCKS = ()

CELL = 8                        # a character is 8x8, one bit a pixel
BYTES_PER_CHAR = 8

# font_source.py reads these out of the atlas rather than knowing them itself.
# They are the panel's own PALETTE[15] on PALETTE[0], which is what INK and
# PAPER below ask it for, so the picture is what the panel would draw.
PALETTE = {
    "paper": (0, 0, 0, 255),
    "ink": (255, 255, 255, 255),
}
INK, PAPER = 15, 0                      # into the panel's own ULA palette
BACKDROP = (0, 0, 0, 0)                 # the gaps between the cells

GAP = 2
LABEL_HEIGHT = 12
LABEL_COLOUR = (96, 96, 96, 255)

# How the panel should read a block's bytes: no header, no mask, top row
# first, one byte to a row.
COMMON_FORMAT = {
    # "sheet" is the panel's source for a sprite whose bytes travel with it:
    # ours were drawn into a picture, not found at an address or an offset in
    # a file, so there is nowhere for the panel to read them from again.
    "source": "sheet",
    "width": 1,
    "height": CELL,
    "header": 0,
    "interleave": "none",
    "invertMask": False,
    "bottomUp": False,
    "ink": INK,
    "paper": PAPER,
}


def read_font(packed):
    """font.bin -> one list of eight row bytes a character, top row first."""
    if len(packed) % BYTES_PER_CHAR:
        raise SystemExit(f"{PACKED.name} is {len(packed)} bytes, which is not a "
                         f"whole number of {BYTES_PER_CHAR}-byte characters")
    return [list(packed[at:at + BYTES_PER_CHAR])
            for at in range(0, len(packed), BYTES_PER_CHAR)]


def lay_out(characters):
    """Where every character sits on the sheet. Returns the places and the size.

    The font is forty 8x8 cells, so the blocks are narrower than the names
    written above them; the sheet is widened to whichever is wider, or the
    last name would run off the edge.
    """
    pen = ImageDraw.Draw(Image.new("RGBA", (1, 1)))
    font = ImageFont.load_default()
    places = [None] * len(characters)
    width, y = 0, 0
    for name, title, first, count, columns, cfg in BLOCKS:
        y += LABEL_HEIGHT
        for n in range(count):
            row, column = divmod(n, columns)
            places[first + n] = (column * (CELL + GAP), y + row * (CELL + GAP))
        rows = -(-count // columns)
        width = max(width, columns * (CELL + GAP) - GAP,
                    pen.textbbox((0, 0), title, font=font)[2])
        y += rows * (CELL + GAP) - GAP + GAP
    return places, (width, y)


def draw(characters, places, size):
    sheet = Image.new("RGBA", size, BACKDROP)
    pixels = sheet.load()
    for rows, (x, y) in zip(characters, places):
        for row, byte in enumerate(rows):
            for bit in range(CELL):
                pixels[x + bit, y + row] = (PALETTE["ink"] if byte & (0x80 >> bit)
                                            else PALETTE["paper"])
    # The block names sit in the strip above each block, clear of every cell.
    pen = ImageDraw.Draw(sheet)
    font = ImageFont.load_default()
    for name, title, first, count, columns, cfg in BLOCKS:
        pen.text((0, places[first][1] - LABEL_HEIGHT), title,
                 font=font, fill=LABEL_COLOUR)
    return sheet


def frame_name(base, cfg, first, n):
    """What the panel calls one item of a block -- see frameName in the model."""
    if cfg["format"] == "font":
        return "%s_%d" % (base, (cfg["first"] + n) & 0xFF)
    return "%s_%d" % (base, n)


def build_atlas(characters, places, size):
    """The atlas the graphics panel reads, with what font_source.py needs too."""
    frames, entries = {}, []
    for name, title, first, count, columns, cfg in BLOCKS:
        label = "font_" + name
        names = [frame_name(label, cfg, first, n) for n in range(count)]
        for n, frame in enumerate(names):
            x, y = places[first + n]
            box = {"x": x, "y": y, "w": CELL, "h": CELL}
            frames[frame] = {
                "frame": dict(box),
                "rotated": False,
                "trimmed": False,
                "spriteSourceSize": {"x": 0, "y": 0, "w": CELL, "h": CELL},
                "sourceSize": {"w": CELL, "h": CELL},
                "zx": {"sprite": label, "item": n,
                       "offset": n * BYTES_PER_CHAR, "group": "font"},
            }
        packed = bytes(byte for rows in characters[first:first + count]
                       for byte in rows)
        entry = {"name": name, "group": "font"}
        entry.update(COMMON_FORMAT)
        entry.update(cfg)
        entry.update({
            "count": count,
            "columns": columns,
            "origin": "%s +$%04X" % (PACKED.name, first * BYTES_PER_CHAR),
            "label": label,
            "frames": names,
            "length": len(packed),
            "bytes": base64.b64encode(packed).decode("ascii"),
            # Ours, past what the panel reads: where this block starts in the
            # font and what its characters draw, so that font_source.py can
            # put the forty back in order and comment them.
            "firstIndex": first,
            "glyphs": GLYPHS[first:first + count],
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
                "groups": [{"name": "font",
                            "sprites": [e["label"] for e in entries],
                            "frames": [f for e in entries for f in e["frames"]]}],
                "sprites": entries,
                "font": {
                    "_comment": "Written by font_sheet.py, read by "
                                "font_source.py; the graphics panel ignores it. "
                                "A character's index IS its code in the game's "
                                "own text -- see end.s.",
                    "palette": {name: list(colour)
                                for name, colour in PALETTE.items()},
                    "cell": CELL,
                    "glyphs": GLYPHS,
                },
            },
        },
    }


def build(here, game, extractor, glyphs, blocks):
    """One game's sheet and atlas, from the font.bin in its own folder."""
    global HERE, PACKED, SHEET, ATLAS, GLYPHS, BLOCKS
    HERE = here
    PACKED, SHEET, ATLAS = (here / "font.bin", here / "font.png",
                            here / "font.json")
    GLYPHS, BLOCKS = glyphs, blocks
    if not PACKED.is_file():
        raise SystemExit(f"{PACKED.name} is missing -- run {extractor} against "
                         f"your own copy of {game} to produce it")
    characters = read_font(PACKED.read_bytes())
    if len(characters) != len(GLYPHS):
        raise SystemExit(f"{PACKED.name} holds {len(characters)} characters, but "
                         f"this knows what {len(GLYPHS)} of them draw")
    places, size = lay_out(characters)
    draw(characters, places, size).save(SHEET)
    ATLAS.write_text(
        json.dumps(build_atlas(characters, places, size), indent=1) + "\n",
        encoding="utf-8")
    print(f"Wrote {SHEET.name} ({size[0]}x{size[1]}, {len(characters)} characters) "
          f"and {ATLAS.name}")

