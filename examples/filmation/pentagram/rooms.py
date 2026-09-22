"""Turn room_data.bin into rooms.json, a readable form of Pentagram's castle.

Pentagram does not store rooms as lists of objects. It stores templates and
expands them: a room is an attribute byte and a handful of indices, and those
indices name pieces of scenery and groups of objects shared across the whole
game. The 139 rooms hold 565 scenery entries and 286 object entries, and those
286 expand to 980 placed objects.

The layout below was read off the running game rather than guessed, with a
read watchpoint over the tables -- instruction fetches do not trip one, so it
picked out real data reads from the code mixed in among them. The builder is
at $C92F.

  $5E07  room size table, three bytes an entry (U, V, Z). Only three entries.

  $5E10  the room directory, up to $696C. One variable-length record a room,
         searched by room number:

           +0  room number
           +1  the record's length, counted from +1; the next record is at
               +1 + length
           +2  the room's ink colour in bits 0-2 (the builder ORs in $40 for
               BRIGHT) and a size index in bits 3-7, multiplied by three to
               index the size table
           +3  the body, length-2 bytes, in two sections

         The body-byte count running out is what ends a record. There is no
         end marker, and trusting one is how you mis-read this format.

         SCENERY comes first, two bytes an entry: an index into the table at
         $696D, then the room number a doorway leads to, or zero where the
         piece is not a way out. Every one of the 289 non-zero values is a
         real room, all 139 rooms have at least one exit, and 288 of the 289
         are reciprocated -- so this is the game's map. Knight Lore has no
         such byte; its scenery entries are a bare index. The 8-byte template is copied in, and the
         game keeps copying further 8-byte blocks while the next byte is not
         zero, so one entry can place a chain of pieces. A byte of $FF, on its
         own, ends the section.

         OBJECTS follow, and are NOT a fixed size. Byte 0 holds a repeat count
         in bits 0-2 (`(byte AND 7) + 1`) and, in bits 3-7, an index taken as
         two rotates right then AND $3E -- an even number. Then one position
         byte per instance follows, so an entry is 1 + count bytes. An index of
         $3E is not a terminator: the game adds $40 to the object table's base
         and carries on, paging it so a five-bit index can reach past thirty-two
         templates. Pentagram's own data never does this, but it is handled.

  $696D  scenery template pointers, thirty-two of two bytes
  $69AD  the scenery templates themselves, eight bytes a block
  $6CE5  object template pointers, indexed by the even number above
  $6D23  the object templates, five bytes each

Templates are named by index here. Knight Lore's equivalents have real names,
taken from the code map in tcdev's disassembly; nothing comparable has been
worked out for Pentagram yet, so `scenery_07` and `object_12` stand in until
the pieces are identified. Renaming them later is the point of the file being
JSON.

Run it against the output of pg_extract.py:

    python rooms.py
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import castle as castle_fmt                                     # noqa: E402
import graphics as gfx                                          # noqa: E402

HERE = Path(__file__).resolve().parent
PACKED = HERE / "room_data.bin"
OUT = HERE / "rooms.json"

BASE = 0x5E00                   # where the block sat in the game

ROOM_SIZE_TBL = 0x5E07
ROOM_SIZE_COUNT = 3
ROOM_DIR = 0x5E10
ROOM_DIR_END = 0x696D           # exclusive

SCENERY_TBL = 0x696D
SCENERY_COUNT = 32              # indices 0-31, one word each
SCENERY_BLOCK = 8

OBJECT_TBL = 0x6CE5             # indexed by a byte offset, so entries are even
OBJECT_COUNT = 31               # even indices 0 to 60
OBJECT_BLOCK = 5

# Template fields, confirmed against the builder: a scenery block's eight bytes
# are copied straight into an object record, so byte 0 is the graphic number
# ($B2EE reads it from field +0) and byte 7 is the flags, which field +7 holds.
# An object template's five bytes go to fields +0, +4, +5, +6 and +7, so its
# byte 0 is the graphic and byte 4 the flags.
SCENERY_GRAPHIC, SCENERY_FLAGS = 0, 7
OBJECT_GRAPHIC, OBJECT_FLAGS = 0, 4

# Across every template a room actually uses, the flags byte takes just two
# values, $10 and $50, and within each group of four variants it alternates --
# the same graphics drawn the other way round. Bit 6 is the mirror, the same
# bit Knight Lore uses. Bit 4 is set throughout and its meaning is not yet
# known; bit 2 appears on five object templates only.
FLAG_MIRROR = 0x40

GRAPHIC_COUNT = 172             # what graphic_map.json holds

# Doorways. Exactly twelve scenery templates ever carry a destination -- 0 to 7
# and 24 to 27 -- in three sets of four, and the side is `index & 3` with
# 0=N, 1=E, 2=S, 3=W, the same convention Knight Lore uses. Proven, not
# assumed: within a set the north and south deltas cancel (+9/-9, +16/-16) and
# east and west are always +1 and -1. room_build.s needs this to know which
# sides of a room have a way out.
DOOR_INDICES = tuple(range(8)) + (24, 25, 26, 27)
SIDES = ("n", "e", "s", "w")
DOOR_SET = {0: "a", 4: "b", 24: "c"}

SECTION_END = 0xFF              # ends the scenery section
PAGE_ESCAPE = 0x3E              # ...and pages the object table instead of ending it
PAGE_STEP = 0x40

data = None


def b(addr):
    return data[addr - BASE]


def w(addr):
    return data[addr - BASE] | (data[addr - BASE + 1] << 8)


# The three floor shapes, in the order the game's own table holds them --
# bits 3 and 4 of a room's attribute byte are an index into it, so the order is
# the game's and cannot be rearranged. rooms.json names them instead, because
# "square" says what a room is and "0" does not.
SHAPE_NAMES = ("square", "narrowU", "narrowV")


def sizes():
    """The room floor shapes: three bytes an entry, as the builder reads it."""
    out = {}
    for n in range(ROOM_SIZE_COUNT):
        at = ROOM_SIZE_TBL + n * 3
        out[SHAPE_NAMES[n]] = {"u": b(at), "v": b(at + 1), "z": b(at + 2)}
    return out


# The graphics this castle names. graphics.py is the one place the number and
# the name meet, so rooms_source.py puts the numbers back by exactly the rule
# that took them out.
def json_flags(byte):
    """The game's flags byte, named where we know what a bit means.

    Only the mirror bit is acted on downstream. $04 (mobile) and $10 (selected
    into the list built at $B547) are understood but not mapped -- see
    rooms_source.py -- so they stay in `rest` rather than being guessed at.
    """
    return {
        "mirrored": bool(byte & FLAG_MIRROR),
        "passable": False,      # Pentagram's own bit for this is not known
        "rest": byte & ~FLAG_MIRROR & 0xFF,
    }


def scenery_templates(known):
    """Each scenery template: its chain of 8-byte blocks.

    The game copies a block, then looks at the byte after it and copies another
    while that byte is not zero, so a template is as long as its chain.
    """
    out = {}
    for n in range(SCENERY_COUNT):
        at = w(SCENERY_TBL + n * 2)
        blocks = []
        p = at
        while b(p):
            raw = [b(p + i) for i in range(SCENERY_BLOCK)]
            blocks.append({
                "graphic": gfx.name_of(known, raw[SCENERY_GRAPHIC]),
                "u": raw[1], "v": raw[2], "z": raw[3],
                "sizeU": raw[4], "sizeV": raw[5], "sizeZ": raw[6],
                "flags": json_flags(raw[SCENERY_FLAGS]),
            })
            p += SCENERY_BLOCK
        if n in DOOR_INDICES:
            name = "door_%s_%s" % (DOOR_SET[n & ~3], SIDES[n & 3])
        else:
            # Everything else is scenery with no way out. Naming these by what
            # they look like wants someone to open sprites.png; the data only
            # proves they are not doorways, so they keep their index.
            name = "scenery_%02d" % n
        # Keyed by name, and the name is all a template carries besides its
        # pieces. Whether it is a doorway, and which wall it stands in, is
        # decided by its position in the table, the way the game decides it
        # -- castle.side_of has the rule. The name only says so for a reader.
        out[name] = blocks
    return out


def object_templates(known):
    """Each object template: its chain of 5-byte entries.

    The five bytes of an entry are spread into an object record's fields +0,
    +4, +5, +6 and +7; +1 to +3 are the position, which comes from the room,
    and +8 is the room number. Like the scenery templates these chain -- $CA51
    reads the byte after an entry and loops back to $C9DB while it is not zero
    -- so one object index can place several pieces.
    """
    out = {}
    for n in range(OBJECT_COUNT):
        index = n * 2
        at = w(OBJECT_TBL + index)
        entries = []
        p = at
        while b(p):
            raw = [b(p + i) for i in range(OBJECT_BLOCK)]
            entries.append({
                "graphic": gfx.name_of(known, raw[OBJECT_GRAPHIC]),
                "sizeU": raw[1], "sizeV": raw[2], "sizeZ": raw[3],
                "flags": json_flags(raw[OBJECT_FLAGS]),
                # Pentagram's own entries are five bytes and carry no placement
                # nudge, so this is nothing everywhere -- but Knight Lore has a
                # sixth byte that offsets a template half a cell in U or V and
                # lifts it in Z, its room_build.s reads one too, and the remake
                # keeps the capability rather than losing it to an accident of
                # which game came first.
                "offsets": {"halfU": False, "halfV": False, "raiseZ": 0},
            })
            p += OBJECT_BLOCK
        out["object_%02d" % n] = entries
    return out


def unpack_position(byte):
    """A packed position byte: U cell in bits 0-2, V in bits 3-5, Z in 6-7.

    Both games pack it the same way. Knight Lore's room emitter documents it;
    Pentagram's builder unpacks it with rotates -- four RLCAs then AND $70 for
    U, one for V, two then AND 3 for Z -- which works out to the same fields.
    """
    return {"u": byte & 7, "v": (byte >> 3) & 7, "z": (byte >> 6) & 3}


def rooms(scenery_names, object_names):
    """Every room record, decoded into its scenery and object entries."""
    out = []
    at = ROOM_DIR
    while at < ROOM_DIR_END:
        number, length, attr = b(at), b(at + 1), b(at + 2)
        end = at + 1 + length
        left = length - 2
        p = at + 3

        scenery, objects = [], []
        in_scenery = True
        page = 0
        while left > 0:
            entry = b(p)
            p += 1
            left -= 1

            if in_scenery:
                if entry == SECTION_END:
                    in_scenery = False
                    continue
                if left <= 0:
                    sys.exit("room %d: a scenery entry runs past the record" % number)
                scenery.append({"template": scenery_names[entry],
                                "destination": b(p)})
                p += 1
                left -= 1
                continue

            index = (entry >> 2) & 0x3E
            if index == PAGE_ESCAPE:
                # Not an end marker -- the object table's base moves on instead.
                p += 1
                left -= 1
                page += PAGE_STEP
                continue

            positions = []
            for _ in range((entry & 7) + 1):
                if left <= 0:
                    break
                positions.append(b(p))
                p += 1
                left -= 1
            objects.append({"template": object_names[index + page],
                            "positions": [unpack_position(x) for x in positions]})

        if p != end:
            sys.exit("room %d at $%04X consumed to $%04X, but the record ends at $%04X"
                     % (number, at, p, end))

        out.append({
            "number": number,
            "ink": attr & 7,
            "dimensions": SHAPE_NAMES[attr >> 3],
            "scenery": scenery,
            "objects": objects,
        })
        at = end
    return out


def main():
    global data
    if not PACKED.is_file():
        sys.exit("%s is missing -- run pg_extract.py against your own copy of "
                 "the tape to produce it" % PACKED.name)
    data = PACKED.read_bytes()

    known = gfx.names(HERE)
    if not known:
        print("  no %s: graphics will be named by number until the sheet is "
              "unpacked" % gfx.SHEET)
    scenery = scenery_templates(known)
    objects = object_templates(known)
    # A room names a template by its offset into the game's own table: the
    # scenery table is one entry a template, the object table two bytes each.
    scenery_names = dict(enumerate(scenery))
    object_names = {n * 2: name for n, name in enumerate(objects)}

    castle = rooms(scenery_names, object_names)

    # Four scenery templates hold graphic numbers past the end of the graphic
    # table. Every one of them is a template no room ever names, so they are
    # dead pointers rather than a mis-read chain -- but mark them, so nothing
    # downstream tries to draw one.
    numbers = {r["number"] for r in castle}
    for room in castle:
        for piece in room["scenery"]:
            if piece["destination"] and piece["destination"] not in numbers:
                sys.exit("room %d has a doorway to room %d, which does not exist"
                         % (room["number"], piece["destination"]))

    # Only a doorway template may name a destination.
    for room in castle:
        for piece in room["scenery"]:
            if piece["destination"] and not castle_fmt.side_of({"meta": {"game": "pentagram"}, "sceneryTemplates": scenery}, piece["template"]):
                sys.exit("room %d: %s carries a destination but is not a doorway"
                         % (room["number"], piece["template"]))

    # A template a room uses has to be drawable. Checked rather than recorded:
    # it is worked out from the rest of the file, so a "used" or "valid" field
    # would only be something to fall out of date.
    named = {s["template"] for r in castle for s in r["scenery"]}
    named |= {o["template"] for r in castle for o in r["objects"]}
    drawable = set(known.values())
    for group in (scenery, objects):
        for name, pieces in group.items():
            if name in named and not all(p["graphic"] in drawable
                                         for p in pieces):
                sys.exit("%s is used by a room but names a graphic the table "
                         "has no number for" % name)

    atlas = {
        "meta": {
            "version": 1,
            "game": "pentagram",
            "comment": "Written by rooms.py from room_data.bin; see its "
                       "docstring for the format. Template names are "
                       "placeholders until the pieces are identified.",
            # The artwork this castle is drawn with. A template carries a
            # GRAPHIC NUMBER, which is the game's own index and means nothing
            # without a sheet numbered the same way -- so the file says which
            # one rather than leaving whatever opens it to assume. The paths
            # are relative to this file.
            "sprites": {
                "sheet": "sprites.png",
                "atlas": "sprites.json",
                "graphics": "graphics.json",
            },
            # ...and the file its templates are in, which is a file of its own:
            # a template is castle-wide, not part of a room.
            "templates": castle_fmt.TEMPLATES,
        },
        "roomDimensions": sizes(),
        "sceneryTemplates": scenery,
        "objectTemplates": objects,
        "rooms": castle,
    }
    # The box each piece occupies belongs to the graphic, not to the template
    # that places one, so it goes into graphics.json and leaves rooms.json
    # saying only where the exceptions are. graphics.py has the rule.
    kept = gfx.fold_sizes(HERE, atlas)

    # Two files, one job each: the rooms, and the templates they place.
    castle_fmt.write_castle(HERE, atlas)

    placed = sum(len(o["positions"]) for r in castle for o in r["objects"])
    print("%s: %d rooms, %d scenery entries, %d object entries placing %d objects"
          % (OUT.name, len(castle),
             sum(len(r["scenery"]) for r in castle),
             sum(len(r["objects"]) for r in castle), placed))
    print("graphics.json: %d graphics given a size; %d template entries keep "
          "a box of their own" % (len(gfx.sizes(HERE)), len(kept)))


if __name__ == "__main__":
    main()
