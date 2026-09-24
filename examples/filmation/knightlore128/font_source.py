"""Knight Lore's font sheet back into assembler: font.png and font.json ->
font.s. How that is done is ../tools/font_source.py's, and shared with
Pentagram; what is here is what heads the file it writes.

    python font_source.py

knightlore128.s INCLUDEs what comes out, where it used to INCBIN font.bin.
"""

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from tools.font_source import build         # noqa: E402  (after the path above)

# What font.s says about itself, under the "generated" line.
HEADER = [
    "; Knight Lore's forty 8x8 characters: the digits, then A to Z, then a",
    "; full stop, a copyright sign, a space and a per-cent sign. Eight bytes",
    "; a character, top row first, one bit a pixel and no mask.",
    ";",
    "; A character code IS its index, which is the whole of why printing a",
    "; hex digit needs no translating and why the game's own words in end.s",
    "; carry the game's own codes.",
]


if __name__ == "__main__":
    build(HERE, HEADER)
