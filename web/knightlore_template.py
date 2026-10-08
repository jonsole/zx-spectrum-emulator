#!/usr/bin/env python3
"""Builds the Filmation Knight Lore for the web page that remakes it from a
visitor's own copy of the original (web/knightlore.html), with the original's
font and sprites left out for the page to put back.

What the page takes from the copy, and how each lands in the image:

  The font is copied byte for byte -- kl_extract.py takes $6108-$6247 out of
  the game, and the build writes the same 320 bytes back at `font`.

  The sprites are the game's records from $728C, turned back where the game
  has mirrored them (kl_extract.py). Every row the build emits for a sprite is
  one of the record's rows: the record is stored bottom row first and the
  build writes top row first, the blank rows at the bottom are trimmed off
  (sprite_sheet.py), and the mask is inverted (sprite_source.py). So the image
  keeps each sprite's two header bytes -- its size, which is layout -- and the
  page writes the rows back from the copy. Which record is which sprite on
  the sheet comes from the copy's own graphic table at $7112: this says, for
  each sprite, one graphic number that draws it.

None of that is taken on trust. The game is built three times: as the
template, with a blank font and the carried sprite sheet; with a patterned
font; and with the sheet's ink and paper swapped. The font may change nothing
but the font, and the sheet's pixels nothing but the sprites' rows; and the
rows in the template build must be the sheet's, emitted as described, before
they are blanked.

With --reference it also writes what web/tests/knightlore_test.js checks the
page against: an original made from the carried sheet -- its sprites in a
different order from the sheet's, two of them mirrored, the patterned font --
which the real kl_extract.py and sprite_sheet.py are run on and must turn back
into the carried sprites.png, sprites.json and graphics.json; and the .z80
build.py made with the patterned font. The page given that original has to
make that .z80, byte for byte.

    python web/knightlore_template.py --out web/site --reference web/site-test

Needs sjasmplus (SJASMPLUS, or on PATH, as build.py finds it) and Pillow.
Builds in copies of examples/filmation in a temporary directory, so the
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
KNIGHTLORE = FILMATION / "knightlore"

sys.path.insert(0, str(FILMATION))
sys.path.insert(0, str(KNIGHTLORE))
import kl_extract                                               # noqa: E402
import sheet                                                    # noqa: E402
import sprite_sheet                                             # noqa: E402

RAM_START = 0x4000
FONT_SOURCE = kl_extract.FONT_START
FONT_LENGTH = kl_extract.FONT_END - kl_extract.FONT_START
# The empty records the game has among its sprites: 0 by 0, holes in its
# numbering, which kl_extract.py walks past.
EMPTY_RECORDS = 6


def copy_game(where):
    game = where / "filmation"
    shutil.copytree(FILMATION, game, ignore=shutil.ignore_patterns("output", "__pycache__"))
    knightlore = game / "knightlore"
    # A font sheet, or an extraction, already in the copy would be what the
    # scripts read rather than what is written here.
    for stale in ("font.png", "font.json", "font.s", "sprite_data.bin", "graphic_map.json"):
        (knightlore / stale).unlink(missing_ok=True)
    return knightlore


def run(folder, *args):
    done = subprocess.run([sys.executable, *args], cwd=folder, capture_output=True, text=True)
    if done.returncode != 0:
        sys.exit(" ".join(args) + " failed:\n" + done.stdout + done.stderr)
    return done.stdout


def build(where, font, swap_ink=False):
    """Builds the game in a copy at `where` with `font` as its font.bin, and
    with the sprite sheet's ink and paper swapped if asked. Returns the 48K
    image, its labels, and the .z80."""
    knightlore = copy_game(where)
    (knightlore / "font.bin").write_bytes(font)
    if swap_ink:
        swap_ink_and_paper(knightlore / "sprites.png")
    run(knightlore, "build.py")
    output = knightlore / "output"
    return ((output / "knightlore.bin").read_bytes(),
            labels(output / "knightlore.sld"),
            (output / "knightlore.z80").read_bytes())


def swap_ink_and_paper(path):
    """Every pixel a sprite covers, drawn the other colour. The mask is left
    as it is, so no row becomes blank and no trim moves: the layout stays and
    every sprite's data changes."""
    from PIL import Image
    image = Image.open(path).convert("RGBA")
    ink, paper = tuple(sheet.PALETTE["ink"]), tuple(sheet.PALETTE["paper"])
    pixels = image.load()
    for y in range(image.height):
        for x in range(image.width):
            if pixels[x, y] == ink:
                pixels[x, y] = paper
            elif pixels[x, y] == paper:
                pixels[x, y] = ink
    image.save(path)


def labels(sld):
    """Every label's address, from the SLD -- as build.py's find_label reads one."""
    found = {}
    for line in sld.read_text(encoding="utf-8").splitlines():
        fields = line.split("|")
        if len(fields) >= 8 and fields[6] == "L":
            parts = fields[7].split(",")
            if len(parts) > 2 and parts[2] == "":
                found[parts[1]] = int(fields[5])
    return found


def read_carried_sheet():
    """The carried sheet: its sprites in sheet order with their rows, trims and
    a graphic number that draws each."""
    _tree, entries, facts = sheet.read_sheet_files(
        sprite_sheet, KNIGHTLORE / "sprites.json", KNIGHTLORE / "graphics.json")
    rows = sheet.read_sheet(KNIGHTLORE / "sprites.png", entries, facts["palette"])
    trims = {}

    def walk(node, path):
        for key, box in (node.get("sprites") or {}).items():
            trims[sheet.NAME_SEPARATOR.join(path + [key])] = box.get("trim", 0)
        for group, sub in (node.get("group") or {}).items():
            walk(sub, path + [group])

    walk(json.loads((KNIGHTLORE / "sprites.json").read_text(encoding="utf-8")), [])
    graphic_of = {}
    for graphic, n in enumerate(facts["graphicMap"]):
        if n is not None:
            graphic_of.setdefault(n, graphic)
    sprites = []
    for n, (entry, sprite) in enumerate(zip(entries, rows)):
        if n not in graphic_of:
            sys.exit(f"{entry['name']} is drawn by no graphic number, so the page "
                     "could not find it in a copy")
        sprites.append({"label": entry["asm"], "name": entry["name"],
                        "graphic": graphic_of[n], "w": sprite["w"], "h": sprite["h"],
                        "trim": trims[entry["name"]],
                        "mask": sprite["mask"], "data": sprite["data"]})
    return sprites, facts["graphicMap"]


def emitted_rows(sprite):
    """A sprite's rows as sprite_source.py emits them: top row first, each byte
    the inverted mask and then the data."""
    out = bytearray()
    for mask, data in zip(sprite["mask"], sprite["data"]):
        for m, d in zip(mask, data):
            out += bytes((255 ^ m, d))
    return bytes(out)


def differences(a, b):
    return [n for n in range(len(a)) if a[n] != b[n]]


def outside(spans, offsets):
    """The offsets in none of the (start, length) spans."""
    return [n for n in offsets if not any(s <= n < s + length for s, length in spans)]


# --- an original for the test, made from the carried sheet ------------------

def record(sprite):
    """A sprite back as the game stores it: width, height, then the rows
    bottom row first -- the blank ones the sheet trimmed off included -- each
    cell its mask and then its data."""
    w = sprite["w"]
    blank = (bytes(w), bytes(w))
    rows = [blank] * sprite["trim"] + list(zip(sprite["mask"], sprite["data"]))[::-1]
    body = bytearray()
    for mask, data in rows:
        for b in range(w):
            body += bytes((mask[b], data[b]))
    return bytes((w, len(rows))) + bytes(body)


def mirror(rec):
    """A record as the game leaves it once it has drawn the sprite the other
    way round: original.py's unmirror, the other way."""
    w, h = rec[0] & 0x1F, rec[1]
    out = bytearray(rec)
    for r in range(h):
        at = 2 + r * w * 2
        pairs = [(rec[at + 2 * c], rec[at + 2 * c + 1]) for c in range(w)]
        row = bytearray()
        for mask, data in reversed(pairs):
            row += bytes((sheet_reverse(mask), sheet_reverse(data)))
        out[at:at + w * 2] = row
    out[0] |= kl_extract.MIRRORED
    return bytes(out)


def sheet_reverse(byte):
    return int("{:08b}".format(byte)[::-1], 2)


def test_original(sprites, graphic_map, font):
    """A 48K .sna holding `font` and the carried sheet's sprites, laid out as
    the game lays its own out but in another order, with two mirrored.

    The order is the sheet's reversed, except for the last band: the sprites no
    band claims are put there in the game's own order, so theirs has to stay
    as it was for the sheet to come out the same."""
    ram = bytearray(0xC000)
    ram[FONT_SOURCE - RAM_START:FONT_SOURCE - RAM_START + len(font)] = font
    last = sprites[-1]["name"].split(sheet.NAME_SEPARATOR)[0]
    tail = [n for n, s in enumerate(sprites) if s["name"].split(sheet.NAME_SEPARATOR)[0] == last]
    order = [n for n in reversed(range(len(sprites))) if n not in tail] + tail
    at = kl_extract.SPRITES_START
    address = {}
    for i, n in enumerate(order):
        rec = record(sprites[n])
        if i < 2:
            rec = mirror(rec)
        address[n] = at
        ram[at - RAM_START:at - RAM_START + len(rec)] = rec
        at += len(rec)
    at += 2 * EMPTY_RECORDS                     # 0 by 0, already zero
    if at != kl_extract.SPRITES_END:
        sys.exit("the carried sheet's sprites come to $%04X, not $%04X" % (at, kl_extract.SPRITES_END))
    for graphic, n in enumerate(graphic_map):
        pointer = kl_extract.SPRITE_TBL + 2 * graphic
        # The game's table runs on into the sprites themselves; the graphics
        # it uses all come before that.
        if pointer + 2 > kl_extract.SPRITES_START:
            if n is not None:
                sys.exit("graphic %d's pointer would be inside the sprites" % graphic)
            continue
        target = address[n] if n is not None else 0
        ram[pointer - RAM_START] = target & 0xFF
        ram[pointer - RAM_START + 1] = target >> 8
    return bytes(27) + bytes(ram)


def check_test_original(where, original):
    """The real extraction of the test original must give back the carried
    sheet. Returns the hashes of what it extracted, for the test to pin."""
    from PIL import Image
    knightlore = copy_game(where)
    path = where / "original.sna"
    path.write_bytes(original)
    run(knightlore, "kl_extract.py", str(path))
    run(knightlore, "sprite_sheet.py")
    made = Image.open(knightlore / "sprites.png").convert("RGBA")
    carried = Image.open(KNIGHTLORE / "sprites.png").convert("RGBA")
    if made.size != carried.size or made.tobytes() != carried.tobytes():
        sys.exit("the test original does not extract to the carried sprites.png")
    for name in ("sprites.json", "graphics.json"):
        if (json.loads((knightlore / name).read_text(encoding="utf-8"))
                != json.loads((KNIGHTLORE / name).read_text(encoding="utf-8"))):
            sys.exit(f"the test original does not extract to the carried {name}")
    return {name: hashlib.sha256((knightlore / name).read_bytes()).hexdigest()
            for name in ("font.bin", "sprite_data.bin")}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=str(WEB / "site"),
                        help="the site to write knightlore/ into (default web/site)")
    parser.add_argument("--reference",
                        help="where to write what web/tests/knightlore_test.js checks against")
    args = parser.parse_args()

    blank = bytes(FONT_LENGTH)
    # Every byte different from the blank font and from its neighbours, so a
    # byte that moved or was dropped shows up.
    pattern = bytes((n * 7 + 1) & 0xFF for n in range(FONT_LENGTH))
    sprites, graphic_map = read_carried_sheet()

    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        for name in ("a", "b", "c", "d"):
            (temp / name).mkdir()
        ram, found, _ = build(temp / "a", blank)
        ram_b, found_b, z80_b = build(temp / "b", pattern)
        ram_c, found_c, _ = build(temp / "c", blank, swap_ink=True)
        if found != found_b or found != found_c:
            sys.exit("the three builds put their labels in different places")

        # The font: only its own bytes, and byte for byte.
        font_at = found["font"]
        font_span = (font_at - RAM_START, FONT_LENGTH)
        stray = outside([font_span], differences(ram, ram_b))
        if stray:
            sys.exit("the font changes more of the image than its own bytes, first at $%04X"
                     % (stray[0] + RAM_START))
        if ram_b[font_span[0]:font_span[0] + FONT_LENGTH] != pattern:
            sys.exit("the font is not at `font` byte for byte")

        # The sprites: each one's rows where its label says, as the sheet has
        # them; and the sheet's pixels change nothing else.
        image = bytearray(ram)
        image[font_span[0]:font_span[0] + FONT_LENGTH] = bytes(FONT_LENGTH)
        spans, layout = [], []
        for sprite in sprites:
            at = found.get(sprite["label"])
            if at is None:
                sys.exit(f"no label {sprite['label']} in the build")
            offset = at - RAM_START
            if image[offset + 1] != sprite["h"] or (image[offset] & 0x7F) != ((sprite["w"] - 2) * 16) & 0x7F:
                sys.exit(f"{sprite['label']}'s header is not its size")
            rows = emitted_rows(sprite)
            if image[offset + 2:offset + 2 + len(rows)] != rows:
                sys.exit(f"{sprite['label']}'s rows are not the sheet's, as the page "
                         "would write them")
            image[offset + 2:offset + 2 + len(rows)] = bytes(len(rows))
            spans.append((offset + 2, len(rows)))
            layout.append({"graphic": sprite["graphic"], "at": at + 2,
                           "w": sprite["w"], "h": sprite["h"], "trim": sprite["trim"]})
        changed = differences(ram, ram_c)
        stray = outside(spans, changed)
        if stray:
            sys.exit("the sprites' pixels change more of the image than their rows, first "
                     "at $%04X" % (stray[0] + RAM_START))
        if not changed:
            sys.exit("swapping the sheet's ink and paper changed nothing")

        if args.reference:
            original = test_original(sprites, graphic_map, pattern)
            pins = check_test_original(temp / "d", original)

    extracted = json.loads((KNIGHTLORE / "original.json").read_text(encoding="utf-8"))["extracted"]
    out = Path(args.out) / "knightlore"
    out.mkdir(parents=True, exist_ok=True)
    (out / "template.bin").write_bytes(bytes(image))
    (out / "template.json").write_text(json.dumps({
        "_what": "web/knightlore_template.py: the Filmation Knight Lore's 48K image "
                 "from $4000, its font and sprite rows blank, and where to put the "
                 "original's",
        "start": found["start"],
        "font_at": font_at,
        "font_source": FONT_SOURCE,
        "font_length": FONT_LENGTH,
        "font_sha256": extracted["font.bin"],
        "sprites_start": kl_extract.SPRITES_START,
        "sprites_end": kl_extract.SPRITES_END,
        "sprite_table": kl_extract.SPRITE_TBL,
        "mirrored": kl_extract.MIRRORED,
        "sprite_data_sha256": extracted["sprite_data.bin"],
        "template_sha256": hashlib.sha256(bytes(image)).hexdigest(),
        "sprites": layout,
    }, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {out}: start ${found['start']:04X}, the font at ${font_at:04X} and "
          f"{len(layout)} sprites to come from the original")

    if args.reference:
        reference = Path(args.reference)
        reference.mkdir(parents=True, exist_ok=True)
        (reference / "original.sna").write_bytes(original)
        (reference / "pins.json").write_text(json.dumps(pins, indent=1) + "\n", encoding="utf-8")
        (reference / "knightlore.z80").write_bytes(z80_b)
        print(f"wrote {reference}: a test original, what it extracts to, and the .z80 "
              "build.py made from the same")
    return 0


if __name__ == "__main__":
    sys.exit(main())
