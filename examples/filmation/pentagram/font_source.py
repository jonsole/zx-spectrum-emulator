"""Pentagram's font sheet back into assembler: font.png and font.json ->
font.s. How that is done is ../tools/font_source.py's, and shared with Knight
Lore; what is here is what heads the file it writes.

    python font_source.py

pentagram.s INCLUDEs what comes out, where it used to INCBIN font.bin.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from tools.font_source import build         # noqa: E402  (after the path above)

# What font.s says about itself, under the "generated" line. It used to say
# Knight Lore's, which this font is not: Pentagram's characters are one run of
# codes, and its words are in menu_text.s and panel.s rather than an end.s.
HEADER = [
    "; Pentagram's forty-three 8x8 characters: the digits, seven marks and",
    "; then A to Z, in one unbroken run of codes from $30 to $5A. Eight bytes",
    "; a character, top row first, one bit a pixel and no mask.",
    ";",
    "; A character code IS its index, which is the whole of why printing a",
    "; hex digit needs no translating and why the game's own words carry the",
    "; game's own codes. The print routine maps a real space onto code $3D.",
]


if __name__ == "__main__":
    build(HERE, HEADER)
