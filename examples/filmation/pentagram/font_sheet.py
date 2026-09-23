"""Pentagram's font as a sheet: font.bin -> font.png and font.json, beside
this script. How that is done is ../tools/font_sheet.py's, and shared with
Knight Lore; what is here is what Pentagram's characters are.

    python font_sheet.py

font.bin is what pg_extract.py lifts from $6108: forty-three 8x8 characters,
eight bytes each, one bit a pixel and no mask -- all the text Pentagram has.

Editing the PNG is how the font changes -- font.bin is only the seed, and
running this again overwrites those edits.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from tools.font_sheet import build          # noqa: E402  (after the path above)

# What each character draws, by its index -- the game's own character code.
#
# Pentagram's forty-three characters are one unbroken run of codes, $30 to
# $5A, which is simpler than Knight Lore's: the digits, seven marks, then the
# letters. The print routine maps a real space ($20) onto code $3D, so that is
# the blank one; the other six marks have not been identified yet, and are
# named by their code rather than guessed at. The menu uses at least $3A, as
# the colons in "A:C:G:", and $3C for the copyright mark.
GLYPHS = ([str(d) for d in range(10)]
          + ["code_3A", "code_3B", "code_3C", "space", "code_3E", "code_3F",
             "code_40"]
          + [chr(ord("A") + n) for n in range(26)])

# The blocks the sheet is laid out in and the panel shows as sprites: a label,
# what it is called on the picture, the first character index, how many, how
# many to a row, and what the panel should make of them. A font with a `first`
# is labelled by the character it draws.
BLOCKS = (
    ("digits", "0 - 9", 0, 10, 10, {"format": "font", "first": ord("0")}),
    ("marks", "$3A - $40, the space among them", 10, 7, 7,
     {"format": "font", "first": 0x3A}),
    ("letters", "A - Z", 17, 26, 13, {"format": "font", "first": ord("A")}),
)


if __name__ == "__main__":
    build(HERE, "Pentagram", "pg_extract.py", GLYPHS, BLOCKS)
