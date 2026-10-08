#!/usr/bin/env python3
"""Builds the Filmation Pentagram for the web page that remakes it from a
visitor's own copy of the original (web/pentagram.html), with everything of
Ultimate's left out for the page to put back.

What the page takes from the copy -- its tape's `game` block, or a 48K
snapshot -- and how each lands in the image:

  The font is copied byte for byte: pg_extract.py takes $8355-$84AC out of
  the game, and the build writes the same 344 bytes back at `font`.

  The sprites are the game's records in its four runs, turned back where the
  game has flipped them (pg_extract.py), and every row the build emits is one
  of a record's rows -- stored bottom row first, emitted top row first,
  without the blank rows sprite_sheet.py trims off, the mask inverted
  (sprite_source.py), and only the sprites some graphic draws. The image
  keeps each sprite's size; which record is which sprite on the sheet comes
  from the copy's own graphic table at $6DD7.

  The castle is re-encoded: rooms.py decodes the game's room directory and
  templates ($5E00-$6DD6) into rooms.json and templates.json, and
  rooms_source.py encodes them again in the remake's layout -- room_data.s,
  from room_size_tbl to the font after it. remake_pentagram.js does the same
  from the copy's tables; this gives it only what the remake decides for
  itself: which templates are background and which are doorways.

  The quest tables (quest_source.py) and the notes and tunes
  (sound_source.py) are the game's own bytes, rearranged: records cut down
  to the fields the remake keeps, the note table as far as the highest note
  the tunes play, the tunes the game plays, each where the build puts it.

The repository carries the sprite sheet and the castle but not the font, the
quest or the sound, so the build here has blanks for those -- of the shape
web/pentagram_layout.json says the original's are, since the note table and
the tunes decide where everything after them goes.

None of that is taken on trust. The game is built four times: as the
template, with blanks; with the font, quest and sound patterned; with the
sheet's ink and paper swapped; and with every position in the castle moved.
The patterns may change only the font, quest and sound, the sheet's pixels
only the sprites' rows, and the positions only the castle; and the rows in
the template build must be the sheet's, emitted as described, before they
are blanked.

With --reference it also writes what web/tests/pentagram_test.js checks the
page against: a tape made from the carried files and the patterns -- its
sprites the carried sheet's, which is the game's own order and comes back as
original.json's sprite_data.bin byte for byte -- which the real
pg_extract.py, rooms.py and sprite_sheet.py are run on and must turn back
into the carried sheet and castle; and the .z80 build.py made with the
patterns. The page given that tape has to make that .z80, byte for byte.

    python web/pentagram_template.py --out web/site --reference web/site-test

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
PENTAGRAM = FILMATION / "pentagram"

sys.path.insert(0, str(WEB))
sys.path.insert(0, str(FILMATION))
sys.path.insert(0, str(PENTAGRAM))
from filmation_common import (differences, edited, emitted_rows,   # noqa: E402
                              labels, outside, run)
import castle                                                   # noqa: E402
import pg_extract                                               # noqa: E402
import rooms as rooms_py                                        # noqa: E402
import rooms_source                                             # noqa: E402
import sheet                                                    # noqa: E402
import sprite_sheet                                             # noqa: E402

RAM_START = 0x4000
FONT_LENGTH = pg_extract.FONT_END - pg_extract.FONT_START
QUEST_LENGTH = (pg_extract.QUEST_TABLE_LEN + pg_extract.QUEST_SPOTS_LEN
                + pg_extract.QUEST_TARGETS_LEN)
# What quest_source.py keeps of each 16-byte record: graphic, U, V, Z and the
# three sizes, then -- past the flags at +7 -- the room at +8.
QUEST_RECORDS = pg_extract.QUEST_TABLE_LEN // 16
QUEST_KEPT = (0, 1, 2, 3, 4, 5, 6, 8)
NOTES = (pg_extract.SOUND_TUNES - pg_extract.SOUND_NOTES) // 3
TUNES = ("title", "unused", "start", "water", "over", "win")
PLAYED = ("start", "water", "over", "win")
TUNE_END = 0xFF

LAYOUT = json.loads((WEB / "pentagram_layout.json").read_text(encoding="utf-8"))


# --- the extracted files, blank or patterned, in the original's shape -------

def font_bin(pattern):
    return bytes((n * 7 + 1) & 0xFF for n in range(FONT_LENGTH)) if pattern else bytes(FONT_LENGTH)


def quest_bin(pattern):
    return bytes((n * 5 + 3) & 0xFF for n in range(QUEST_LENGTH)) if pattern else bytes(QUEST_LENGTH)


def sound_bin(pattern):
    """sound.bin as pg_extract.py writes it: the jingles, the whole note table,
    then the six tunes each ended by $FF -- each tune its original's length,
    and the highest note any of them plays the original's highest."""
    highest = LAYOUT["sound"]["highest"]
    jingles = bytes((n * 3 + 1) & 0xFF for n in range(pg_extract.SOUND_JINGLES_LEN)) \
        if pattern else bytes(pg_extract.SOUND_JINGLES_LEN)
    notes = bytes((n * 11 + 2) & 0xFF for n in range(NOTES * 3)) if pattern else bytes(NOTES * 3)
    tunes = b""
    for t, name in enumerate(TUNES):
        length = LAYOUT["sound"]["tunes"][name]
        if pattern:
            # Notes 1 to `highest`, with a length in the top two bits: never
            # $FF, never past the table.
            body = bytes(((n * 7 + t) % highest + 1) | ((n % 4) << 6) for n in range(length))
        else:
            body = bytes(length)
        if name == "title":
            body = bytes([highest]) + body[1:]
        tunes += body + bytes([TUNE_END])
    assert len(tunes) == pg_extract.SOUND_TUNES_END - pg_extract.SOUND_TUNES, len(tunes)
    return jingles + notes + tunes


# --- building ---------------------------------------------------------------

def copy_game(where):
    game = where / "filmation"
    shutil.copytree(FILMATION, game, ignore=shutil.ignore_patterns("output", "__pycache__"))
    pentagram = game / "pentagram"
    for stale in ("font.png", "font.json", "font.s", "quest_data.s", "sound_data.s",
                  "sound_title.s", "sprite_data.bin", "graphic_map.json", "room_data.bin"):
        (pentagram / stale).unlink(missing_ok=True)
    return pentagram


def build(where, pattern=False, swap_ink=False, move_things=False):
    """Builds the game in a copy at `where`: the font, quest and sound blank or
    patterned, the sheet's ink and paper swapped and the castle's positions
    moved if asked. Returns the 48K image, its labels, and the .z80."""
    pentagram = copy_game(where)
    (pentagram / "font.bin").write_bytes(font_bin(pattern))
    (pentagram / "quest.bin").write_bytes(quest_bin(pattern))
    (pentagram / "sound.bin").write_bytes(sound_bin(pattern))
    if swap_ink:
        swap_ink_and_paper(pentagram / "sprites.png")
    if move_things:
        move_positions(pentagram)
    run(pentagram, "build.py")
    output = pentagram / "output"
    return ((output / "pentagram.bin").read_bytes(),
            labels(output / "pentagram.sld"),
            (output / "pentagram.z80").read_bytes())


def swap_ink_and_paper(path):
    """Every pixel a sprite covers, drawn the other colour: the mask stays, so
    no row becomes blank and no trim moves."""
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


def move_positions(pentagram):
    """Every object in every room a cell along in U: nothing the castle's
    shape or counts depend on changes, and everything that is a position does."""
    path = pentagram / "rooms.json"
    said = json.loads(path.read_text(encoding="utf-8"))
    for room in said["rooms"]:
        for group in room["objects"]:
            for spot in group["positions"]:
                spot["u"] ^= 1
    path.write_text(json.dumps(said, indent=1) + "\n", encoding="utf-8")


# --- the carried sheet -------------------------------------------------------

def read_carried_sheet():
    """The carried sheet's sprites in sheet order -- which is the game's own --
    with their rows and trims, and for each one a graphic that draws it, or
    None for the two no graphic does."""
    _tree, entries, facts = sheet.read_sheet_files(
        sprite_sheet, PENTAGRAM / "sprites.json", PENTAGRAM / "graphics.json")
    rows = sheet.read_sheet(PENTAGRAM / "sprites.png", entries, facts["palette"])
    trims = {}

    def walk(node, path):
        for key, box in (node.get("sprites") or {}).items():
            trims[sheet.NAME_SEPARATOR.join(path + [key])] = box.get("trim", 0)
        for group, sub in (node.get("group") or {}).items():
            walk(sub, path + [group])

    walk(json.loads((PENTAGRAM / "sprites.json").read_text(encoding="utf-8")), [])
    graphic_of = {}
    for graphic, n in enumerate(facts["graphicMap"]):
        if n is not None:
            graphic_of.setdefault(n, graphic)
    sprites = []
    for n, (entry, sprite) in enumerate(zip(entries, rows)):
        sprites.append({"label": entry["asm"], "name": entry["name"],
                        "graphic": graphic_of.get(n), "w": sprite["w"], "h": sprite["h"],
                        "trim": trims[entry["name"]],
                        "mask": sprite["mask"], "data": sprite["data"]})
    return sprites, facts["graphicMap"]


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


def castle_policy():
    """What the remake decides about the castle for itself, for
    remake_pentagram.js, in the game's table order: which scenery templates
    are background, and which are doorways (and so carry a destination)."""
    atlas = castle.read_castle(PENTAGRAM)
    names = list(atlas["sceneryTemplates"])
    return {
        "scenery_background": [name in rooms_source.BACKGROUND_TEMPLATES for name in names],
        "scenery_doorway": [bool(castle.side_of(atlas, name)) for name in names],
        "flags": {"game_mirror": rooms_source.GAME_MIRROR,
                  "flip": rooms_source.FLIP_FLAG,
                  "background": rooms_source.BACKGROUND_FLAG},
        "scenery_shift": rooms_source.ROOM_SCN_SHIFT,
        "scenery_bias": rooms_source.SCN_COUNT_BIAS,
    }


# --- a tape for the test, made from the carried files ------------------------

def test_memory(sprites, graphic_map, font, quest, sound):
    """The 64K the tape's `game` block loads into, as pg_extract.py reads it:
    the carried sprites in their runs, the graphic table, the castle written
    back from the carried JSON, and the given font, quest and sound."""
    memory = bytearray(0x10000)
    memory[pg_extract.FONT_START:pg_extract.FONT_END] = font

    at = pg_extract.QUEST_TABLE
    memory[at:at + pg_extract.QUEST_TABLE_LEN] = quest[:pg_extract.QUEST_TABLE_LEN]
    rest = quest[pg_extract.QUEST_TABLE_LEN:]
    memory[pg_extract.QUEST_SPOTS:pg_extract.QUEST_SPOTS + pg_extract.QUEST_SPOTS_LEN] = \
        rest[:pg_extract.QUEST_SPOTS_LEN]
    memory[pg_extract.QUEST_TARGETS:pg_extract.QUEST_TARGETS + pg_extract.QUEST_TARGETS_LEN] = \
        rest[pg_extract.QUEST_SPOTS_LEN:]
    memory[pg_extract.SOUND_JINGLES:pg_extract.SOUND_JINGLES + pg_extract.SOUND_JINGLES_LEN] = \
        sound[:pg_extract.SOUND_JINGLES_LEN]
    memory[pg_extract.SOUND_NOTES:pg_extract.SOUND_TUNES_END] = \
        sound[pg_extract.SOUND_JINGLES_LEN:]

    # The sprites, in order, filling each run exactly.
    address = {}
    queue = list(range(len(sprites)))
    for start, end in pg_extract.SPRITE_RUNS:
        at = start
        while at < end:
            if not queue:
                sys.exit("the carried sheet runs out before the run at $%04X is full" % start)
            n = queue.pop(0)
            rec = record(sprites[n])
            address[n] = at
            memory[at:at + len(rec)] = rec
            at += len(rec)
        if at != end:
            sys.exit("the carried sheet's sprites overrun the run at $%04X" % start)
    if queue:
        sys.exit("the carried sheet has sprites past the game's runs")
    for graphic in range(sprite_sheet.GRAPHIC_COUNT):
        n = graphic_map[graphic] if graphic < len(graphic_map) else None
        target = address[n] if n is not None else 0
        pointer = pg_extract.GRAPHIC_TBL + 2 * graphic
        memory[pointer:pointer + 2] = bytes((target & 0xFF, target >> 8))

    add_castle(memory)
    return memory


def add_castle(memory):
    """The carried castle, written into the test tape the way the game holds
    it: rooms.py's decoding run backwards. The rooms go in the file's order,
    which is the game's, filling the directory exactly; the templates' blocks
    after their tables, identical ones once."""
    atlas = castle.read_castle(PENTAGRAM)
    rooms_source.resolve_graphics(atlas)
    scenery, objects = atlas["sceneryTemplates"], atlas["objectTemplates"]
    scenery_index = {name: n for n, name in enumerate(scenery)}
    object_index = {name: n * 2 for n, name in enumerate(objects)}

    at = rooms_py.ROOM_SIZE_TBL
    for shape in atlas["roomDimensions"].values():
        memory[at:at + 3] = bytes((shape["u"], shape["v"], shape["z"]))
        at += 3
    at = rooms_py.ROOM_DIR
    for room in atlas["rooms"]:
        body = []
        for s in room["scenery"]:
            body += [scenery_index[s["template"]], s.get("destination", 0)]
        if room["objects"]:
            body.append(rooms_py.SECTION_END)
            for group in room["objects"]:
                body.append(object_index[group["template"]] << 2 | (len(group["positions"]) - 1))
                body += [p["u"] | p["v"] << 3 | p["z"] << 6 for p in group["positions"]]
        attr = room["ink"] | castle.shape_index(atlas, room["dimensions"], "the test") << 3
        record_bytes = bytes([room["number"], len(body) + 2, attr] + body)
        memory[at:at + len(record_bytes)] = record_bytes
        at += len(record_bytes)
    if at != rooms_py.ROOM_DIR_END:
        sys.exit("the carried rooms come to $%04X, not $%04X" % (at, rooms_py.ROOM_DIR_END))

    for table, count, stride, end, templates, is_scenery in (
            (rooms_py.SCENERY_TBL, rooms_py.SCENERY_COUNT, rooms_py.SCENERY_BLOCK,
             rooms_py.OBJECT_TBL, scenery, True),
            (rooms_py.OBJECT_TBL, rooms_py.OBJECT_COUNT, rooms_py.OBJECT_BLOCK,
             pg_extract.ROOM_DATA_END, objects, False)):
        names = list(templates)
        if len(names) != count:
            sys.exit("the carried castle has %d templates of a kind the game has %d of"
                     % (len(names), count))
        bodies = [b"".join(bytes(rooms_source.record_of(entry, is_scenery)[:stride])
                           for entry in templates[name]) for name in names]
        where = table_said(table, count, bodies)
        if where is None:
            where = packed(table + 2 * count, stride, bodies)
        written = {}
        for n, body in enumerate(bodies):
            pointer = table + 2 * n
            memory[pointer:pointer + 2] = bytes((where[n] & 0xFF, where[n] >> 8))
            written.update({pointer: memory[pointer], pointer + 1: memory[pointer + 1]})
        for n, body in enumerate(bodies):
            for i, b in enumerate(body + b"\0"):
                at = where[n] + i
                if at >= end or written.get(at, b) != b:
                    sys.exit("the carried templates cannot all be laid out where their "
                             "table says, at $%04X" % at)
                memory[at] = b
                written[at] = b


def table_said(table, count, bodies):
    """Where each template sits, if the castle itself says.

    Pentagram's four unplaced scenery templates point at the scenery table
    itself, so what rooms.py read for them -- and the carried JSON holds -- is
    the table's own bytes: the address of every template. None when no
    template's body starts with a table that points it back at the table."""
    for body in bodies:
        if len(body) < 2 * count:
            continue
        where = [body[2 * n] | body[2 * n + 1] << 8 for n in range(count)]
        if any(where[n] == table and bodies[n] == body for n in range(count)):
            return where
    return None


def packed(start, stride, bodies):
    """Where each template goes when laid out one after another from `start`,
    a template that is the end of another's chain sharing its bytes."""
    where, placed = {}, []
    order = sorted(range(len(bodies)), key=lambda n: -len(bodies[n]))
    at = start
    for n in order:
        for other, other_at in placed:
            gap = len(bodies[other]) - len(bodies[n])
            if bodies[other].endswith(bodies[n]) and gap % stride == 0:
                where[n] = other_at + gap
                break
        else:
            where[n] = at
            placed.append((n, at))
            at += len(bodies[n]) + 1
    return [where[n] for n in range(len(bodies))]


def tap(memory):
    """memory's `game` block as a .tap: its header, then its bytes."""
    data = bytes(memory[pg_extract.GAME_START:pg_extract.GAME_START + GAME_LENGTH])
    name = pg_extract.GAME_NAME.encode("ascii").ljust(10)
    header = (bytes([0x00, 3]) + name + len(data).to_bytes(2, "little")
              + pg_extract.GAME_START.to_bytes(2, "little") + bytes(2))

    def block(body):
        check = 0
        for b in body:
            check ^= b
        whole = body + bytes([check])
        return len(whole).to_bytes(2, "little") + whole

    return block(header) + block(bytes([0xFF]) + data)


# The `game` block's length on the tape: $5E00 to $D89D.
GAME_LENGTH = 31390


def check_test_tape(where, tape):
    """The real extraction of the test tape must give back the carried sheet
    and castle, and the sprites as original.json has them. Returns the hashes
    of the font, quest and sound it extracted, for the test to pin."""
    from PIL import Image
    pentagram = copy_game(where)
    path = where / "pentagram.tap"
    path.write_bytes(tape)
    run(pentagram, "pg_extract.py", str(path))
    run(pentagram, "rooms.py")
    run(pentagram, "sprite_sheet.py")
    made = Image.open(pentagram / "sprites.png").convert("RGBA")
    carried = Image.open(PENTAGRAM / "sprites.png").convert("RGBA")
    if made.size != carried.size or made.tobytes() != carried.tobytes():
        sys.exit("the test tape does not extract to the carried sprites.png")
    for name in ("sprites.json", "graphics.json", "rooms.json", "templates.json"):
        if (json.loads((pentagram / name).read_text(encoding="utf-8"))
                != json.loads((PENTAGRAM / name).read_text(encoding="utf-8"))):
            sys.exit(f"the test tape does not extract to the carried {name}")
    pins = json.loads((PENTAGRAM / "original.json").read_text(encoding="utf-8"))["extracted"]
    made = hashlib.sha256((pentagram / "sprite_data.bin").read_bytes()).hexdigest()
    if made != pins["sprite_data.bin"]:
        sys.exit("the test tape's sprites are not original.json's sprite_data.bin")
    return {name: hashlib.sha256((pentagram / name).read_bytes()).hexdigest()
            for name in ("font.bin", "quest.bin", "sound.bin")}


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", default=str(WEB / "site"),
                        help="the site to write pentagram/ into (default web/site)")
    parser.add_argument("--reference",
                        help="where to write what web/tests/pentagram_test.js checks against")
    args = parser.parse_args()

    pins = json.loads((PENTAGRAM / "original.json").read_text(encoding="utf-8"))
    changed = edited(PENTAGRAM, pins)
    if changed:
        sys.exit(", ".join(changed) + " no longer what an original gives (original.json's "
                 "carried hashes): the page makes the game from a copy of the original, "
                 "so it cannot make these")
    sprites, graphic_map = read_carried_sheet()
    sound = LAYOUT["sound"]

    with tempfile.TemporaryDirectory() as temp:
        temp = Path(temp)
        for name in ("a", "b", "c", "d", "e"):
            (temp / name).mkdir()
        ram, found, _ = build(temp / "a")
        ram_b, found_b, z80_b = build(temp / "b", pattern=True)
        ram_c, found_c, _ = build(temp / "c", swap_ink=True)
        ram_d, found_d, _ = build(temp / "d", move_things=True)
        if not found == found_b == found_c == found_d:
            sys.exit("the four builds put their labels in different places")

        def span(label, length):
            return (found[label] - RAM_START, length)

        # The font, quest and sound: the patterns change those and nothing
        # else, and the font byte for byte.
        font = span("font", FONT_LENGTH)
        quest = [span("quest_start", QUEST_RECORDS * len(QUEST_KEPT)),
                 span("quest_spots", pg_extract.QUEST_SPOTS_LEN),
                 span("quest_targets", pg_extract.QUEST_TARGETS_LEN)]
        tunes = [span("sound_tune_%s_data" % name, sound["tunes"][name] + 1)
                 for name in PLAYED + ("title",)]
        notes = [span("sound_jingles", pg_extract.SOUND_JINGLES_LEN),
                 span("sound_notes", sound["highest"] * 3)] + tunes
        stray = outside([font] + quest + notes, differences(ram, ram_b))
        if stray:
            sys.exit("the font, quest and sound change more of the image than their own, "
                     "first at $%04X" % (stray[0] + RAM_START))
        if ram_b[font[0]:font[0] + FONT_LENGTH] != font_bin(True):
            sys.exit("the font is not at `font` byte for byte")

        image = bytearray(ram)
        for at, length in [font] + quest + notes:
            image[at:at + length] = bytes(length)

        # The sprites: each one's rows where its label says, as the sheet has
        # them; and the sheet's pixels change nothing else.
        spans, layout, rows = [], [], b""
        for sprite in sprites:
            if sprite["graphic"] is None:
                if sprite["label"] in found:
                    sys.exit(f"{sprite['label']} is in the build, but no graphic draws it")
                continue
            at = found.get(sprite["label"])
            if at is None:
                sys.exit(f"no label {sprite['label']} in the build")
            offset = at - RAM_START
            if image[offset + 1] != sprite["h"] or (image[offset] & 0x7F) != ((sprite["w"] - 2) * 16) & 0x7F:
                sys.exit(f"{sprite['label']}'s header is not its size")
            emitted = emitted_rows(sprite)
            if image[offset + 2:offset + 2 + len(emitted)] != emitted:
                sys.exit(f"{sprite['label']}'s rows are not the sheet's, as the page "
                         "would write them")
            image[offset + 2:offset + 2 + len(emitted)] = bytes(len(emitted))
            spans.append((offset + 2, len(emitted)))
            rows += emitted
            layout.append({"graphic": sprite["graphic"], "at": at + 2,
                           "w": sprite["w"], "h": sprite["h"], "trim": sprite["trim"]})
        changed = differences(ram, ram_c)
        stray = outside(spans, changed)
        if stray:
            sys.exit("the sprites' pixels change more of the image than their rows, first "
                     "at $%04X" % (stray[0] + RAM_START))
        if not changed:
            sys.exit("swapping the sheet's ink and paper changed nothing")

        # The castle: everything room_data.s assembles, from room_size_tbl to
        # the font after it.
        castle_at = found["room_size_tbl"] - RAM_START
        castle_length = found["font"] - found["room_size_tbl"]
        changed = differences(ram, ram_d)
        stray = outside([(castle_at, castle_length)], changed)
        if stray:
            sys.exit("the castle's positions change more of the image than the castle, first "
                     "at $%04X" % (stray[0] + RAM_START))
        if not changed:
            sys.exit("moving every position in the castle changed nothing")
        castle_bytes = bytes(image[castle_at:castle_at + castle_length])
        image[castle_at:castle_at + castle_length] = bytes(castle_length)

        if args.reference:
            memory = test_memory(sprites, graphic_map, font_bin(True), quest_bin(True),
                                 sound_bin(True))
            tape = tap(memory)
            test_pins = check_test_tape(temp / "e", tape)

    extracted = pins["extracted"]
    out = Path(args.out) / "pentagram"
    out.mkdir(parents=True, exist_ok=True)
    (out / "template.bin").write_bytes(bytes(image))
    (out / "template.json").write_text(json.dumps({
        "_what": "web/pentagram_template.py: the Filmation Pentagram's 48K image from "
                 "$4000, everything of Ultimate's in it blank, and where to put the "
                 "original's",
        "start": found["start"],
        "game_start": pg_extract.GAME_START,
        "game_name": pg_extract.GAME_NAME,
        "font": {"source": pg_extract.FONT_START, "length": FONT_LENGTH,
                 "at": found["font"], "sha256": extracted["font.bin"]},
        "quest": {"table": pg_extract.QUEST_TABLE, "records": QUEST_RECORDS,
                  "record_length": pg_extract.QUEST_TABLE_LEN // QUEST_RECORDS,
                  "kept": QUEST_KEPT,
                  "spots": pg_extract.QUEST_SPOTS, "spots_length": pg_extract.QUEST_SPOTS_LEN,
                  "targets": pg_extract.QUEST_TARGETS,
                  "targets_length": pg_extract.QUEST_TARGETS_LEN,
                  "at": found["quest_start"], "spots_at": found["quest_spots"],
                  "targets_at": found["quest_targets"], "sha256": extracted["quest.bin"]},
        "sound": {"jingles": pg_extract.SOUND_JINGLES,
                  "jingles_length": pg_extract.SOUND_JINGLES_LEN,
                  "notes": pg_extract.SOUND_NOTES, "tunes": pg_extract.SOUND_TUNES,
                  "tunes_end": pg_extract.SOUND_TUNES_END,
                  "names": TUNES, "played": PLAYED,
                  "highest": sound["highest"], "lengths": sound["tunes"],
                  "jingles_at": found["sound_jingles"], "notes_at": found["sound_notes"],
                  "tune_at": {name: found["sound_tune_%s_data" % name]
                              for name in PLAYED + ("title",)},
                  "sha256": extracted["sound.bin"]},
        "sprite_runs": pg_extract.SPRITE_RUNS,
        "sprite_table": pg_extract.GRAPHIC_TBL,
        "sprite_table_end": pg_extract.GRAPHIC_TBL_END,
        "flip_left_right": pg_extract.FLIP_LEFT_RIGHT,
        "flip_upside_down": pg_extract.FLIP_UPSIDE_DOWN,
        # Any of these still set once a copy's sprites are turned back, and
        # pg_extract.py refuses it.
        "flags_mask": pg_extract.MIRRORED,
        "sprite_rows_sha256": hashlib.sha256(rows).hexdigest(),
        "sprites": layout,
        "castle": dict(castle_policy(), **{
            "size_table": rooms_py.ROOM_SIZE_TBL,
            "directory": rooms_py.ROOM_DIR,
            "directory_end": rooms_py.ROOM_DIR_END,
            "scenery_table": rooms_py.SCENERY_TBL,
            "scenery_count": rooms_py.SCENERY_COUNT,
            "scenery_block": rooms_py.SCENERY_BLOCK,
            "object_table": rooms_py.OBJECT_TBL,
            "object_count": rooms_py.OBJECT_COUNT,
            "object_block": rooms_py.OBJECT_BLOCK,
            "section_end": rooms_py.SECTION_END,
            "page_escape": rooms_py.PAGE_ESCAPE,
            "page_step": rooms_py.PAGE_STEP,
            "at": found["room_size_tbl"],
            "length": castle_length,
            "room_count": found["ROOM_COUNT"],
            "max_body": found["ROOM_MAX_BODY"],
            "max_objects": found["ROOM_MAX_OBJECTS"],
            "sha256": hashlib.sha256(castle_bytes).hexdigest(),
        }),
        "template_sha256": hashlib.sha256(bytes(image)).hexdigest(),
    }, indent=1) + "\n", encoding="utf-8")
    print(f"wrote {out}: start ${found['start']:04X}, {len(layout)} sprites, the font, "
          "castle, quest and sound to come from the original")

    if args.reference:
        reference = Path(args.reference)
        reference.mkdir(parents=True, exist_ok=True)
        (reference / "pentagram.tap").write_bytes(tape)
        (reference / "pins.json").write_text(json.dumps(test_pins, indent=1) + "\n",
                                             encoding="utf-8")
        (reference / "pentagram.z80").write_bytes(z80_b)
        print(f"wrote {reference}: a test tape, what it extracts to, and the .z80 "
              "build.py made from the same")
    return 0


if __name__ == "__main__":
    sys.exit(main())
