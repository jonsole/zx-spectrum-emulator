"""Knight Lore's font as a sheet: font.bin -> font.png and font.json, beside
this script. How that is done is ../tools/font_sheet.py's, and shared with
Pentagram; what is here is what Knight Lore's characters are.

    python font_sheet.py

font.bin is what kl_extract.py lifts from $6108: forty 8x8 characters, eight
bytes each, one bit a pixel and no mask -- all the text Knight Lore has.

Editing the PNG is how the font changes -- font.bin is only the seed, and
running this again overwrites those edits.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from tools.font_sheet import build          # noqa: E402  (after the path above)

# What each character draws, by its index -- the game's own character code.
# The last four are a reading of the shapes: a full stop, the copyright sign
# the title screen wants, the space that pads every word in end.s, and the
# per-cent sign the ending's score ends with.
GLYPHS = ([str(d) for d in range(10)]
          + [chr(ord("A") + n) for n in range(26)]
          + [".", "(c)", "space", "%"])

# The blocks the sheet is laid out in and the panel shows as sprites: a label,
# what it is called on the picture, the first character index, how many, how
# many to a row, and what the panel should make of them. A font with a `first`
# is labelled by the character it draws; the marks have no run of ASCII codes
# to sit in, so they stay plain sprites labelled by number.
BLOCKS = (
    ("digits", "0 - 9", 0, 10, 10, {"format": "font", "first": ord("0")}),
    ("letters", "A - Z", 10, 26, 13, {"format": "font", "first": ord("A")}),
    ("marks", "full stop, copyright, space, per cent", 36, 4, 4,
     {"format": "sprite", "first": 32}),
)


if __name__ == "__main__":
    build(HERE, "Knight Lore", "kl_extract.py", GLYPHS, BLOCKS)
