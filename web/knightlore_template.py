#!/usr/bin/env python3
"""Builds the Filmation Knight Lore for the web page that remakes it from a
visitor's own copy of the original (web/knightlore.html).

Of everything the remake is built from, the repository carries all but the
font: the sprite sheet, the rooms, the templates and the collectables are
here, and the font is the one thing examples/filmation/extract.py still has
to take from an original. It is copied byte for byte -- kl_extract.py takes
$6108-$6247 out of the game's RAM, and font_source.py writes the same bytes
back at the label `font`. So the remake is this build with a blank font, and
the page fills the hole from the visitor's copy.

That holds only while the font is the one thing in the image that depends on
it, so it is checked rather than trusted: the game is built twice, with a
blank font and with a patterned one, and the two images must differ only
where `font` is. The patterned build is kept as well, so that
web/tests/knightlore_test.js can check the page's own .z80 against what
build.py wrote for the same font, byte for byte.

    python web/knightlore_template.py --out web/site --reference web/site-test

Needs sjasmplus (SJASMPLUS, or on PATH, as build.py finds it) and Pillow.
Builds in a copy of examples/filmation in a temporary directory, so the
working tree is left as it was.
"""
import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

WEB = Path(__file__).resolve().parent
ROOT = WEB.parent
FILMATION = ROOT / "examples" / "filmation"

# Where kl_extract.py takes the font from in the original (FONT_START and
# FONT_END there), and how long it is: forty 8x8 characters.
FONT_SOURCE = 0x6108
FONT_LENGTH = 320

RAM_START = 0x4000


def build(where, font):
    """Builds the game in a copy at `where` with `font` as its font.bin.
    Returns the 48K image, and the addresses of `start` and `font`."""
    game = where / "filmation"
    shutil.copytree(FILMATION, game, ignore=shutil.ignore_patterns("output", "__pycache__"))
    knightlore = game / "knightlore"
    # A font sheet already in the copy would be the one the build reads, not
    # the font.bin written here -- build.py unpacks one only when there is none.
    for stale in ("font.png", "font.json", "font.s"):
        (knightlore / stale).unlink(missing_ok=True)
    (knightlore / "font.bin").write_bytes(font)
    done = subprocess.run([sys.executable, "build.py"], cwd=knightlore,
                          capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit("build.py failed:\n" + done.stdout + done.stderr)
    output = knightlore / "output"
    return ((output / "knightlore.bin").read_bytes(),
            label(output / "knightlore.sld", "start"),
            label(output / "knightlore.sld", "font"),
            (output / "knightlore.z80").read_bytes())


def label(sld, name):
    """A label's address from the SLD -- as build.py's find_label reads it."""
    for line in sld.read_text(encoding="utf-8").splitlines():
        fields = line.split("|")
        if len(fields) >= 8 and fields[6] == "L":
            parts = fields[7].split(",")
            if len(parts) > 2 and parts[1] == name and parts[2] == "":
                return int(fields[5])
    sys.exit(f"no label {name} in {sld}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=str(WEB / "site"),
                        help="the site to write knightlore/ into (default web/site)")
    parser.add_argument("--reference",
                        help="where to keep the patterned build for web/tests/knightlore_test.js")
    args = parser.parse_args()

    blank = bytes(FONT_LENGTH)
    # Every byte different from the blank font and from its neighbours, so a
    # byte that moved or was dropped shows up.
    pattern = bytes((n * 7 + 1) & 0xFF for n in range(FONT_LENGTH))

    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        (temp / "a").mkdir()
        (temp / "b").mkdir()
        ram, start, font_at, _ = build(temp / "a", blank)
        ram_b, start_b, font_at_b, z80_b = build(temp / "b", pattern)

    if (start, font_at) != (start_b, font_at_b):
        sys.exit("the two builds put start or font in different places")
    offset = font_at - RAM_START
    differ = [n for n in range(len(ram)) if ram[n] != ram_b[n]]
    outside = [n for n in differ if not offset <= n < offset + FONT_LENGTH]
    if outside:
        sys.exit("the font changes more of the image than its own bytes, first at $%04X: "
                 "a page that fills in only the font would not make the same game"
                 % (outside[0] + RAM_START))
    if ram_b[offset:offset + FONT_LENGTH] != pattern:
        sys.exit("the font is not at `font` byte for byte")

    pins = json.loads((FILMATION / "knightlore" / "original.json").read_text(encoding="utf-8"))
    out = Path(args.out) / "knightlore"
    out.mkdir(parents=True, exist_ok=True)
    (out / "template.bin").write_bytes(ram)
    (out / "template.json").write_text(json.dumps({
        "_what": "web/knightlore_template.py: the Filmation Knight Lore's 48K image "
                 "from $4000 with a blank font, and where to put the original's",
        "start": start,
        "font_at": font_at,
        "font_source": FONT_SOURCE,
        "font_length": FONT_LENGTH,
        "font_sha256": pins["extracted"]["font.bin"],
        "template_sha256": hashlib.sha256(ram).hexdigest(),
    }, indent=2) + "\n", encoding="utf-8")
    print(f"wrote {out}: start ${start:04X}, font ${font_at:04X} from the original's "
          f"${FONT_SOURCE:04X}")

    if args.reference:
        reference = Path(args.reference)
        reference.mkdir(parents=True, exist_ok=True)
        (reference / "font.bin").write_bytes(pattern)
        (reference / "knightlore.z80").write_bytes(z80_b)
        print(f"wrote {reference}: the patterned font and the .z80 build.py made with it")
    return 0


if __name__ == "__main__":
    sys.exit(main())
