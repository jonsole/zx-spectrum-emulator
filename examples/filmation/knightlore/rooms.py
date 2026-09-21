"""Turn room_data.bin into rooms.json, a readable form of Knight Lore's castle.

Knight Lore does not store rooms as lists of objects. It stores templates and
expands them: a room is an attribute byte plus a handful of indices, and those
indices name pieces of scenery and groups of objects that are shared across the
whole castle. Room $B3 is four indices -- arch north, arch east, arch south and
the walls for a square room -- and they expand to 19 objects.

This reads the tables the game keeps at $6248-$6FF1 and writes them out as
JSON we can read and edit, rather than a block of bytes. It stops there:
rooms_source.py turns rooms.json into room_data.s, and the split is the point.
The JSON is the editable form -- by hand, or in the room designer -- and
nothing downstream of it reads room_data.bin again, so an edit survives.

The names come from the code map in tcdev's disassembly of Knight Lore, as
converted to SkoolKit by Michael R. Cook. Only the factual layer is used -- what
each table is and what its entries are called.

Run via build.py, which regenerates when room_data.bin or this script is newer.
Running it by hand is how you go back to the game's own rooms, and it overwrites
whatever rooms.json holds.
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import graphics as gfx                                          # noqa: E402

HERE = Path(__file__).resolve().parent
BASE = 0x6248                       # where the block sat in the game

ROOM_SIZE_TBL = 0x6248
LOCATION_TBL = 0x6251
LOCATION_END = 0x6BD1
BLOCK_TYPE_TBL = 0x6BD1
BLOCK_TYPE_COUNT = 29
BG_TYPE_TBL = 0x6CE2
BG_TYPE_COUNT = 24

BG_NAMES = [
    "arch_n", "arch_e", "arch_s", "arch_w",
    "tree_arch_n", "tree_arch_e", "tree_arch_s", "tree_arch_w",
    "gate_0", "gate_1", "gate_2", "gate_3",
    "walls_0", "walls_1", "walls_2",
    "trees_0", "trees_1", "trees_2",
    "wizard", "pot",
    "high_arch_e", "high_arch_s", "high_arch_e_base", "high_arch_s_base",
]

FG_NAMES = [
    "block", "fire", "ball_ud_y", "rock", "gargoyle", "spike", "chest",
    "table", "guard_ew", "ghost", "fire_ns", "block_high", "ball_ud_xy",
    "guard_square", "block_ew", "block_ns", "moveable_block", "spike_high",
    "spike_ball", "spike_ball_falling", "fire_ew", "dropping_block",
    "collapsing_block", "ball_bounce", "ball_ud", "repel_spell",
    "gate_ud_1", "gate_ud_2", "ball_ud_x",
]

data = None


def b(addr):
    return data[addr - BASE]


def w(addr):
    return b(addr) | (b(addr + 1) << 8)


def block(addr, stride):
    """A template: entries of `stride` bytes, ending in a zero sprite."""
    out = []
    while b(addr):
        out.append(tuple(data[addr - BASE:addr - BASE + stride]))
        addr += stride
    return out


def rooms():
    """Every room record: number -> (attribute byte, body bytes)."""
    out = {}
    p = LOCATION_TBL
    while p < LOCATION_END:
        rid, length, attr = b(p), b(p + 1), b(p + 2)
        out[rid] = (attr, bytes(data[p + 3 - BASE:p + 1 + length - BASE]))
        p += length + 1
    return out


def split_body(body):
    """Scenery indices, then the object bytes that follow the $FF."""
    if 0xFF in body:
        cut = body.index(0xFF)
        return list(body[:cut]), list(body[cut + 1:])
    return list(body), []


# --- the shared intermediate -------------------------------------------------
#
# rooms.json is the same schema Pentagram's rooms.py writes, so one generator
# can serve both games. The two formats agree more than they differ: the room
# header is identical (+0 number, +1 length, +2 colour in bits 0-2 and a size
# index in bits 3-4), both keep three room sizes, both split the body at an
# $FF, and both encode an object entry as a type and repeat count in one byte
# followed by one position byte an instance. Where they differ is the scenery
# entry -- Knight Lore names a template in a single byte, Pentagram follows the
# index with a second byte -- so `byte` is simply absent here.
#
# In both games a template is a chain of fixed-size entries ending in a zero
# graphic, the graphic is the entry's first byte, and the flags are its last
# ($40 mirrors it either way round).
SCENERY_STRIDE, SCENERY_FLAGS_AT = 8, 7
# Knight Lore's object entries are SIX bytes -- sprite, size U, size V, size Z,
# flags, offsets -- where Pentagram's are five. The flags sit at index 4 in
# both. This is exactly the sort of per-game detail a decoder has to own.
OBJECT_STRIDE, OBJECT_FLAGS_AT, OBJECT_OFFSETS_AT = 6, 4, 5
GRAPHIC_COUNT = 256
# The one bit of the game's flags byte this reads: everything else it copies
# through untouched, and rooms_source.py is where they become OBJ.FLAGS.
GAME_MIRROR = 0x40
GAME_PASSABLE = 0x02


def unpack_position(byte):
    """A packed position byte: U cell in bits 0-2, V in bits 3-5, Z in 6-7.

    Both games pack it the same way. Knight Lore's room emitter documents it;
    Pentagram's builder unpacks it with rotates -- four RLCAs then AND $70 for
    U, one for V, two then AND 3 for Z -- which works out to the same fields.
    """
    return {"u": byte & 7, "v": (byte >> 3) & 7, "z": (byte >> 6) & 3}


def unpack_offsets(byte):
    """The template's placement nudge: half a cell in U and/or V, and a height.

    room_unpack adds the whole byte into Z and masks $FC off again, which works
    because level * 12 is always a multiple of four, so one byte carries all
    three nudges without ever being unpacked. See room_build.s.
    """
    return {"halfU": bool(byte & 1),
            "halfV": bool(byte & 2),
            "raiseZ": byte & 0xFC}


# The graphics this castle names. graphics.py is the one place the number and
# the name meet, so rooms_source.py puts the numbers back by exactly the rule
# that took them out.
def json_flags(byte):
    """The game's flags byte, named where we know what a bit means.

    Bit 6 mirrors the piece and bit 1 lets things through it. The rest is the
    game's own business -- carriable, and a bit it never tests for scenery --
    which rooms_source.py drops on the way to OBJ.FLAGS. It is kept whole here
    rather than guessed at, so nothing is lost and the file claims no more than
    is actually known.
    """
    return {
        "mirrored": bool(byte & GAME_MIRROR),
        "passable": bool(byte & GAME_PASSABLE),
        "rest": byte & ~(GAME_MIRROR | GAME_PASSABLE) & 0xFF,
    }


def json_entries(entries, flags_at, known, offsets_at=None):
    """A template's pieces, field by field rather than as the record's bytes.

    Scenery carries its own place in the world and needs nothing from the room;
    an object takes one from the room's packed position and carries a nudge
    instead. That is the whole difference between the two shapes.
    """
    out = []
    for raw in entries:
        if offsets_at is None:
            entry = {
                "graphic": gfx.name_of(known, raw[0]),
                "u": raw[1], "v": raw[2], "z": raw[3],
                "sizeU": raw[4], "sizeV": raw[5], "sizeZ": raw[6],
            }
        else:
            entry = {
                "graphic": gfx.name_of(known, raw[0]),
                "sizeU": raw[1], "sizeV": raw[2], "sizeZ": raw[3],
            }
        entry["flags"] = json_flags(raw[flags_at])
        if offsets_at is not None:
            entry["offsets"] = unpack_offsets(raw[offsets_at])
        out.append(entry)
    return out


def json_templates(table, count, stride, flags_at, labels, prefix, key,
                   known, offsets_at=None):
    out = []
    for i in range(count):
        at = w(table + i * 2)
        out.append({
            "index": i,
            "name": "%s_%s" % (prefix, labels[i]),
            "address": "$%04X" % at,
            key: json_entries(block(at, stride), flags_at, known, offsets_at),
        })
    return out


def json_rooms(table, scenery_names, object_names):
    out = []
    for number in sorted(table):
        attr, body = table[number]
        scenery_ids, object_bytes = split_body(body)

        scenery = [{"template": scenery_names[i]} for i in scenery_ids]

        objects = []
        i = 0
        while i < len(object_bytes):
            entry = object_bytes[i]
            typ, count = (entry >> 3) & 0x1F, (entry & 7) + 1
            objects.append({
                "template": object_names[typ],
                "positions": [unpack_position(x)
                              for x in object_bytes[i + 1:i + 1 + count]],
            })
            i += 1 + count

        out.append({
            "number": number,
            "ink": attr & 7,
            "size": attr >> 3,
            "scenery": scenery,
            "objects": objects,
        })
    return out


def write_json(table):
    known = gfx.names(HERE)
    if not known:
        print("  no %s: graphics will be named by number until the sheet is "
              "unpacked" % gfx.SHEET)
    scenery = json_templates(BG_TYPE_TBL, BG_TYPE_COUNT, SCENERY_STRIDE,
                             SCENERY_FLAGS_AT, BG_NAMES, "scenery", "blocks",
                             known)
    objects = json_templates(BLOCK_TYPE_TBL, BLOCK_TYPE_COUNT, OBJECT_STRIDE,
                             OBJECT_FLAGS_AT, FG_NAMES, "object", "entries",
                             known, OBJECT_OFFSETS_AT)
    castle = json_rooms(table,
                        {t["index"]: t["name"] for t in scenery},
                        {t["index"]: t["name"] for t in objects})

    named = {s["template"] for r in castle for s in r["scenery"]}
    named |= {o["template"] for r in castle for o in r["objects"]}
    for group, key in ((scenery, "blocks"), (objects, "entries")):
        for t in group:
            t["used"] = t["name"] in named
            t["valid"] = all(e["graphic"] in set(known.values()) for e in t[key])

    atlas = {
        "meta": {
            "version": 1,
            "game": "knightlore",
            "comment": "Written by rooms.py from room_data.bin; the same "
                       "schema Pentagram's rooms.py writes.",
            # The artwork this castle is drawn with. A template carries a
            # GRAPHIC NUMBER, which is the game's own index and means nothing
            # without a sheet numbered the same way -- so the file says which
            # one rather than leaving whatever opens it to assume. The paths
            # are relative to this file.
            "sprites": {
                "sheet": "sprites.png",
                "atlas": "sprites.json",
                "adjust": "sprite_adj.s",
            },
        },
        "sizes": [{"index": n,
                   "u": b(ROOM_SIZE_TBL + n * 3),
                   "v": b(ROOM_SIZE_TBL + n * 3 + 1),
                   "z": b(ROOM_SIZE_TBL + n * 3 + 2)} for n in range(3)],
        "sceneryTemplates": scenery,
        "objectTemplates": objects,
        "rooms": castle,
    }
    (HERE / "rooms.json").write_text(json.dumps(atlas, indent=1) + "\n",
                                     encoding="utf-8")
    placed = sum(len(o["positions"]) for r in castle for o in r["objects"])
    print("rooms.json: %d rooms, %d scenery entries, %d object entries placing %d objects"
          % (len(castle), sum(len(r["scenery"]) for r in castle),
             sum(len(r["objects"]) for r in castle), placed))


def main():
    global data
    packed = HERE / "room_data.bin"
    if not packed.is_file():
        sys.exit("room_data.bin is missing -- run kl_extract.py against your "
                 "own copy of the game first")
    data = packed.read_bytes()
    write_json(rooms())


if __name__ == "__main__":
    main()
