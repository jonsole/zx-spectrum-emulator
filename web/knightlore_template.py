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

The "DAY" over the day count is the third: panel_data.s copies its four
characters from the game's day_font at $BCEC, and the page takes them from
there too.

The castle is the fourth. rooms.py decodes the game's room tables
($6248-$6FF1) into rooms.json and templates.json, and rooms_source.py
encodes those again in the remake's own layout -- room_data.s, from
room_size_tbl to the panel data after it. remake.js does the same from the
copy's tables, and the image keeps none of it: this gives the page only
what the remake decides for itself -- the flag a template's name adds, and
the constants the encoder writes with. The collectables, the fifth, are four
bytes of each of the 32 rows at $6FF2 and the wizard's list at $C27D,
copied as they are (specials_source.py).

None of that is taken on trust. The game is built four times: as the
template, with a blank font and the carried sprite sheet; with a patterned
font; with the sheet's ink and paper swapped; and with every position in the
castle and of the collectables moved. The font may change nothing but the
font, the sheet's pixels nothing but the sprites' rows, and the positions
nothing but the castle and the collectables; and the rows in the template
build must be the sheet's, emitted as described, before they are blanked.

With --reference it also writes what web/tests/knightlore_test.js checks the
page against: an original made from the carried files -- its sprites in a
different order from the sheet's, two of them mirrored, its templates laid
out in another order than the game's, the patterned font -- which the real
kl_extract.py, rooms.py and sprite_sheet.py are run on and must turn back
into the carried sprites.png, sprites.json, graphics.json, rooms.json,
templates.json and specials.json; and the .z80 build.py made with the
patterned font. The page given that original has to make that .z80, byte for
byte.

    python web/knightlore_template.py --out web/site --reference web/site-test

Needs sjasmplus (SJASMPLUS, or on PATH, as build.py finds it) and Pillow.
Builds in copies of examples/filmation in a temporary directory, so the
working tree is left as it was.
"""
import argparse
import hashlib
import json
import shutil
import sys
import tempfile
from pathlib import Path

WEB = Path(__file__).resolve().parent
ROOT = WEB.parent
FILMATION = ROOT / "examples" / "filmation"
KNIGHTLORE = FILMATION / "knightlore"

sys.path.insert(0, str(WEB))
sys.path.insert(0, str(FILMATION))
sys.path.insert(0, str(KNIGHTLORE))
from filmation_common import (differences, edited, emitted_rows,   # noqa: E402
                              labels, outside, run)
import castle                                                   # noqa: E402
import kl_extract                                               # noqa: E402
import rooms as rooms_py                                        # noqa: E402
import rooms_source                                             # noqa: E402
import sheet                                                    # noqa: E402
import sprite_sheet                                             # noqa: E402

RAM_START = 0x4000
FONT_SOURCE = kl_extract.FONT_START
FONT_LENGTH = kl_extract.FONT_END - kl_extract.FONT_START
# The menu frame's corner. The game turns it upside down in place as it draws
# the frame and, unlike a left-right mirror, records that nowhere -- so a copy
# saved at the menu can hold it either way up, and the page tries both.
MENU_CORNER_GRAPHIC = sprite_sheet.MENU[0]
# The "DAY" over the day count: four 8x8 characters panel_data.s spells out as
# panel_word, copied from the game's day_font at $BCEC.
DAY_SOURCE = 0xBCEC
DAY_LENGTH = 32
# A collectable's row in special_objs_tbl: nine bytes, of which the second to
# fifth are its U, V, Z and room (kl_extract.py's write_specials).
SPECIALS_STRIDE = 9
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




def build(where, font, swap_ink=False, move_things=False):
    """Builds the game in a copy at `where` with `font` as its font.bin, with
    the sprite sheet's ink and paper swapped and every position in the castle
    and of the collectables moved, if asked. Returns the 48K image, its
    labels, and the .z80."""
    knightlore = copy_game(where)
    (knightlore / "font.bin").write_bytes(font)
    if swap_ink:
        swap_ink_and_paper(knightlore / "sprites.png")
    if move_things:
        move_positions(knightlore)
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


def move_positions(knightlore):
    """Every object in every room, and every collectable, a cell along in U:
    nothing the castle's shape or counts depend on changes, and everything
    that is a position does."""
    path = knightlore / "rooms.json"
    said = json.loads(path.read_text(encoding="utf-8"))
    for room in said["rooms"]:
        for group in room["objects"]:
            for spot in group["positions"]:
                spot["u"] ^= 1
    path.write_text(json.dumps(said, indent=1) + "\n", encoding="utf-8")
    path = knightlore / "specials.json"
    said = json.loads(path.read_text(encoding="utf-8"))
    for place in said["collectables"]:
        place["u"] ^= 1
    path.write_text(json.dumps(said, indent=1) + "\n", encoding="utf-8")


def castle_policy():
    """What the remake decides about the castle for itself, for remake.js:
    the flag bits each template's name adds -- background, shared shift --
    in the game's table order, and the bits the encoder writes with."""
    atlas = castle.read_castle(KNIGHTLORE)
    plain = {"graphic": 0, "flags": {"mirrored": False, "passable": False, "rest": 0}}

    def extras(templates):
        return [rooms_source.our_flags(plain, {}, rooms_source.label_of(name))
                for name in templates]

    return {
        "scenery_extra": extras(atlas["sceneryTemplates"]),
        "object_extra": extras(atlas["objectTemplates"]),
        "flags": {"game_mirror": rooms_source.GAME_MIRROR,
                  "game_passable": rooms_source.GAME_PASSABLE,
                  "flip": rooms_source.FLIP_FLAG,
                  "passable": rooms_source.PASSABLE_FLAG,
                  "cache": rooms_source.CACHE_FLAG},
        "scenery_shift": rooms_source.ROOM_SCN_SHIFT,
    }




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


def test_original(sprites, graphic_map, font, day):
    """A 48K .sna holding `font` and the carried sheet's sprites, laid out as
    the game lays its own out but in another order, with two mirrored.

    The order is the sheet's reversed, except for the last band: the sprites no
    band claims are put there in the game's own order, so theirs has to stay
    as it was for the sheet to come out the same."""
    ram = bytearray(0xC000)
    ram[FONT_SOURCE - RAM_START:FONT_SOURCE - RAM_START + len(font)] = font
    ram[DAY_SOURCE - RAM_START:DAY_SOURCE - RAM_START + len(day)] = day
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
    return bytearray(27) + ram


def add_castle(original):
    """The carried castle and collectables, written into the test original
    the way the game holds them: rooms.py's decoding run backwards.

    The rooms go in ascending order with no $FF after a room that has no
    objects, which is how the game has them and fills $6251-$6BD0 exactly;
    the templates' blocks go in the reverse of their tables' order, which the
    game's are not in either, so that only the tables say where each is."""
    atlas = castle.read_castle(KNIGHTLORE)
    # Names to numbers, and each entry's box from graphics.json: in place.
    rooms_source.resolve_graphics(atlas)
    scenery, objects = atlas["sceneryTemplates"], atlas["objectTemplates"]
    scenery_index = {name: n for n, name in enumerate(scenery)}
    object_index = {name: n for n, name in enumerate(objects)}

    def put(at, data):
        original[27 + at - RAM_START:27 + at - RAM_START + len(data)] = bytes(data)

    at = rooms_py.ROOM_SIZE_TBL
    for shape in atlas["roomDimensions"].values():
        put(at, (shape["u"], shape["v"], shape["z"]))
        at += 3
    at = rooms_py.LOCATION_TBL
    for room in sorted(atlas["rooms"], key=lambda r: r["number"]):
        body = [scenery_index[s["template"]] for s in room["scenery"]]
        if room["objects"]:
            body.append(0xFF)
            for group in room["objects"]:
                body.append(object_index[group["template"]] << 3 | (len(group["positions"]) - 1))
                body += [p["u"] | p["v"] << 3 | p["z"] << 6 for p in group["positions"]]
        attr = room["ink"] | castle.shape_index(atlas, room["dimensions"], "the test") << 3
        put(at, [room["number"], len(body) + 2, attr] + body)
        at += 3 + len(body)
    if at != rooms_py.LOCATION_END:
        sys.exit("the carried rooms come to $%04X, not $%04X" % (at, rooms_py.LOCATION_END))

    for table, count, first, end, templates, is_scenery in (
            (rooms_py.BLOCK_TYPE_TBL, rooms_py.BLOCK_TYPE_COUNT,
             rooms_py.BLOCK_TYPE_TBL + 2 * rooms_py.BLOCK_TYPE_COUNT, rooms_py.BG_TYPE_TBL,
             objects, False),
            (rooms_py.BG_TYPE_TBL, rooms_py.BG_TYPE_COUNT,
             rooms_py.BG_TYPE_TBL + 2 * rooms_py.BG_TYPE_COUNT, kl_extract.ROOM_DATA_END,
             scenery, True)):
        names = list(templates)
        if len(names) != count:
            sys.exit("the carried castle has %d templates of a kind the game has %d of"
                     % (len(names), count))
        at = first
        for n in reversed(range(count)):
            put(table + 2 * n, (at & 0xFF, at >> 8))
            for entry in templates[names[n]]:
                record = rooms_source.record_of(entry, is_scenery)
                put(at, record)
                at += len(record)
            put(at, (0,))
            at += 1
        if at > end:
            sys.exit("the carried templates run past $%04X" % end)

    said = json.loads((KNIGHTLORE / "specials.json").read_text(encoding="utf-8"))
    for row, place in enumerate(said["collectables"]):
        put(kl_extract.SPECIALS_TBL + row * SPECIALS_STRIDE + 1,
            (place["u"], place["v"], place["z"], place["room"]))
    put(kl_extract.OBJECTS_REQUIRED, said["wanted"])


def check_test_original(where, original):
    """The real extraction of the test original must give back the carried
    sheet. Returns the hashes of what it extracted, for the test to pin."""
    from PIL import Image
    knightlore = copy_game(where)
    path = where / "original.sna"
    path.write_bytes(original)
    run(knightlore, "kl_extract.py", str(path))
    run(knightlore, "rooms.py")
    run(knightlore, "sprite_sheet.py")
    made = Image.open(knightlore / "sprites.png").convert("RGBA")
    carried = Image.open(KNIGHTLORE / "sprites.png").convert("RGBA")
    if made.size != carried.size or made.tobytes() != carried.tobytes():
        sys.exit("the test original does not extract to the carried sprites.png")
    for name in ("sprites.json", "graphics.json", "rooms.json", "templates.json",
                 "specials.json"):
        if (json.loads((knightlore / name).read_text(encoding="utf-8"))
                != json.loads((KNIGHTLORE / name).read_text(encoding="utf-8"))):
            sys.exit(f"the test original does not extract to the carried {name}")
    return {name: hashlib.sha256((knightlore / name).read_bytes()).hexdigest()
            for name in ("font.bin", "sprite_data.bin")}




def check_carried_is_the_originals():
    """The page can only make what an original has. If the carried sheet or
    castle has been edited -- which is what they are for -- no copy gives it,
    and the page would turn every one away; so that stops the build here, the
    way original.json's carried hashes stop a release."""
    pins = json.loads((KNIGHTLORE / "original.json").read_text(encoding="utf-8"))
    changed = edited(KNIGHTLORE, pins)
    if changed:
        sys.exit(", ".join(changed) + " no longer what an original gives (original.json's "
                 "carried hashes): the page makes the game from a copy of the original, "
                 "so it cannot make these")


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
    check_carried_is_the_originals()
    sprites, graphic_map = read_carried_sheet()

    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        for name in ("a", "b", "c", "d", "e"):
            (temp / name).mkdir()
        ram, found, _ = build(temp / "a", blank)
        ram_b, found_b, z80_b = build(temp / "b", pattern)
        ram_c, found_c, _ = build(temp / "c", blank, swap_ink=True)
        ram_e, found_e, _ = build(temp / "e", blank, move_things=True)
        if not found == found_b == found_c == found_e:
            sys.exit("the four builds put their labels in different places")

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
        rows_sha256 = hashlib.sha256(b"".join(emitted_rows(s) for s in sprites)).hexdigest()

        # The DAY lettering: data in a DB, so where its label says.
        day_at = found["panel_word"] - RAM_START
        day = bytes(image[day_at:day_at + DAY_LENGTH])
        image[day_at:day_at + DAY_LENGTH] = bytes(DAY_LENGTH)

        # The castle: everything room_data.s assembles, from room_size_tbl
        # to the panel data that follows it; and the collectables. Moving
        # every position may change nothing else.
        castle_at = found["room_size_tbl"] - RAM_START
        castle_length = found["panel_pieces"] - found["room_size_tbl"]
        where_at = found["special_where_start"] - RAM_START
        where_length = kl_extract.SPECIALS_ROWS * 4
        wanted_at = found["special_wanted"] - RAM_START
        wanted_length = kl_extract.OBJECTS_REQUIRED_COUNT
        castle_spans = [(castle_at, castle_length), (where_at, where_length),
                        (wanted_at, wanted_length)]
        changed = differences(ram, ram_e)
        stray = outside(castle_spans, changed)
        if stray:
            sys.exit("the castle's positions change more of the image than the castle, first "
                     "at $%04X" % (stray[0] + RAM_START))
        if not changed:
            sys.exit("moving every position in the castle changed nothing")
        castle_bytes = bytes(image[castle_at:castle_at + castle_length])
        specials_bytes = (bytes(image[where_at:where_at + where_length])
                          + bytes(image[wanted_at:wanted_at + wanted_length]))
        for at, length in castle_spans:
            image[at:at + length] = bytes(length)

        if args.reference:
            original = test_original(sprites, graphic_map, pattern, day)
            add_castle(original)
            pins = check_test_original(temp / "d", original)

    extracted = json.loads((KNIGHTLORE / "original.json").read_text(encoding="utf-8"))["extracted"]
    out = Path(args.out) / "knightlore"
    out.mkdir(parents=True, exist_ok=True)
    (out / "template.bin").write_bytes(bytes(image))
    (out / "template.json").write_text(json.dumps({
        "_what": "web/knightlore_template.py: the Filmation Knight Lore's 48K image "
                 "from $4000, everything of Ultimate's in it blank, and where to put the "
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
        # Not sprite_data.bin's hash: that covers bits of every record the
        # build never reads -- the flags in a sprite's width byte, which the
        # game leaves set or not depending on when the copy was saved -- so it
        # turns away copies that make this very game. The rows the build
        # emits are the whole of what the sprites put in the image.
        "sprite_rows_sha256": rows_sha256,
        "menu_corner_graphic": MENU_CORNER_GRAPHIC,
        "day_at": found["panel_word"],
        "day_source": DAY_SOURCE,
        "day_length": DAY_LENGTH,
        "day_sha256": hashlib.sha256(day).hexdigest(),
        "castle": dict(castle_policy(), **{
            "size_table": rooms_py.ROOM_SIZE_TBL,
            "location_table": rooms_py.LOCATION_TBL,
            "location_end": rooms_py.LOCATION_END,
            "object_table": rooms_py.BLOCK_TYPE_TBL,
            "object_count": rooms_py.BLOCK_TYPE_COUNT,
            "scenery_table": rooms_py.BG_TYPE_TBL,
            "scenery_count": rooms_py.BG_TYPE_COUNT,
            "at": found["room_size_tbl"],
            "length": castle_length,
            "room_count": found["ROOM_COUNT"],
            "max_body": found["ROOM_MAX_BODY"],
            "max_objects": found["ROOM_MAX_OBJECTS"],
            "sha256": hashlib.sha256(castle_bytes).hexdigest(),
        }),
        "specials": {
            "table": kl_extract.SPECIALS_TBL,
            "rows": kl_extract.SPECIALS_ROWS,
            "stride": SPECIALS_STRIDE,
            "wanted_from": kl_extract.OBJECTS_REQUIRED,
            "wanted_count": kl_extract.OBJECTS_REQUIRED_COUNT,
            "where_at": found["special_where_start"],
            "wanted_at": found["special_wanted"],
            "sha256": hashlib.sha256(specials_bytes).hexdigest(),
        },
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
