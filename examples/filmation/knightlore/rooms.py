"""Turn room_data.bin into assembly source.

Knight Lore does not store rooms as lists of objects. It stores templates and
expands them: a room is an attribute byte plus a handful of indices, and those
indices name pieces of scenery and groups of objects that are shared across the
whole castle. Room $B3 is four indices -- arch north, arch east, arch south and
the walls for a square room -- and they expand to 19 objects.

This reads the tables the game keeps at $6248-$6FF1 and writes them out as
source we can read and edit, rather than a block of bytes. The layout changes on
the way through: the game bounds each room record with a length and terminates
its scenery list with $FF, and we use two explicit counts instead, because we
are generating the source and a count is cheaper to walk than a terminator.

The names come from the code map in tcdev's disassembly of Knight Lore, as
converted to SkoolKit by Michael R. Cook. Only the factual layer is used -- what
each table is and what its entries are called.

Run via build.py, which regenerates when room_data.bin or this script is newer.
"""
import collections
import json
import sys
from pathlib import Path

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

TAB = chr(9)
ROOM_SCN_SHIFT = 5          # where a room header keeps its scenery count
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


def templates(table, count, stride, names, prefix):
    """Distinct templates in table order, and the label each entry points at.

    Several table entries share a template -- four of the object types are the
    same block seen from different sides -- so a label is emitted once, named
    after the first entry that reaches it.
    """
    label_at = {}
    order = []
    for i in range(count):
        addr = w(table + i * 2)
        if addr not in label_at:
            label_at[addr] = "%s_%s" % (prefix, names[i])
            order.append((addr, label_at[addr], block(addr, stride)))
    return order, [label_at[w(table + i * 2)] for i in range(count)]


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


def pieces_by_index(table, count, stride):
    """Template contents keyed by TABLE index, duplicates included.

    templates() collapses shared templates into one label; this does not,
    because a room names table indices and needs each one to have a length.
    """
    return [block(w(table + i * 2), stride) for i in range(count)]


# The flags byte is written in OUR layout -- OBJ.FLAGS, bit for bit -- so that
# room_add copies it into the record as it stands. The game's byte means
# something else: bit 6 mirrors the piece, bit 1 says nothing collides with it,
# and bits 2 and 4 are its own business (carriable, and a flag it never tests
# for scenery), which our engine keeps elsewhere and so drops here.
#
# These have to agree with the EQUs in object.s; room.s ASSERTs that they do,
# against the ROOM_FLAG_ copies emitted at the foot of room_data.s.
GAME_MIRROR = 0x40
GAME_PASSABLE = 0x02

FLIP_FLAG = 0x01            # OBJ_FLIP_H: drawn the other way round
PASSABLE_FLAG = 0x04        # OBJ_PASSABLE: nothing collides with it
SHARED_SHIFT_FLAG = 0x08    # OBJ_SHARED_SHIFT: rotate into the shared buffer
CACHE_FLAG = 0x10           # OBJ_CACHE: draw from a private copy of the graphic
BACKGROUND_FLAG = 0x40      # OBJ_BACKGROUND: drawn first and never sorted

# Walls and trees are scenery: solid, never walked through, and so never worth
# sorting against anything. Arches and gates are doorways the knight passes
# behind, and the wizard and the pot are objects in their own right -- all of
# those keep their place in the sort. The room builder used to work this out
# from the template's index every time it built a room.
BACKGROUND_TEMPLATES = ("bg_walls_", "bg_trees_")

# Templates whose pieces rotate at draw time instead of holding a buffer for
# the life of the room. Walls and trees line the edges of a room and a
# character is rarely in front of one, so their buffers sit idle -- room $88
# rotates ten objects and eight of them are never redrawn at all. Arches, gates
# and the objects a character walks around keep their own buffers, because a
# shared-buffer piece is re-rotated on every single draw.
# Nothing, now. The walls and trees were marked for a while, to keep the
# rotation arena small; it cost more in redrawing than it saved in memory --
# see SHIFT_ARENA_SIZE in shift.s. The flag and the machinery behind it are
# still there, and object_place falls back on them when the arena runs out.
SHARED_SHIFT_TEMPLATES = ()


def room_pieces(bg, fg, scenery, objects):
    """(graphic, mirrored) for every piece a room expands to."""
    out = []
    for i in scenery:
        if i < len(bg):
            for p in bg[i]:
                if p[0] >= 2:
                    out.append((p[0], 1 if p[7] & 0x40 else 0))
    i = 0
    while i < len(objects):
        typ, count = (objects[i] >> 3) & 0x1F, (objects[i] & 7) + 1
        if typ < len(fg):
            for _ in range(count):
                for p in fg[typ]:
                    if p[0] >= 2:
                        out.append((p[0], 1 if p[4] & 0x40 else 0))
        i += 1 + count
    return out


def cache_way(table, bg, fg):
    """Which way round of each graphic should be drawn from a private copy.

    A graphic is shared by everything drawn from it, and an object that wants
    it the other way round mirrors it where it lies. Two objects in one room
    wanting opposite ways therefore mirror it back and forth, twice a region,
    ten thousand T at a time for something the size of an arch -- and every
    room in the castle has at least one such pair, because the north and south
    arches are the east and west ones mirrored.

    Nothing about that is discoverable only at run time: the rooms are fixed
    and so are the templates they expand to. So work out here which graphics
    some room wants both ways, nominate one orientation of each, and mark
    every piece that wears it. Those take a private copy at placement and the
    rest go on sharing, so nothing is ever mirrored twice.

    The orientation nominated is the one that crowds fewest pieces into a
    single room, since the arena has to hold the worst room's copies.
    """
    worst = collections.defaultdict(int)
    contested = set()
    for attr, body in table.values():
        scenery, objects = split_body(body)
        pieces = room_pieces(bg, fg, scenery, objects)
        ways = collections.defaultdict(set)
        seen = collections.Counter()
        for g, f in pieces:
            ways[g].add(f)
            seen[(g, f)] += 1
        for g, s in ways.items():
            if len(s) > 1:
                contested.add(g)
        for key, n in seen.items():
            worst[key] = max(worst[key], n)
    return {g: (0 if worst[(g, 0)] <= worst[(g, 1)] else 1) for g in contested}


def count_objects(bg, fg, scenery, objects):
    """How many objects a room expands to -- what the object pool has to hold."""
    n = sum(len(bg[i]) for i in scenery if i < len(bg))
    i = 0
    while i < len(objects):
        typ, count = (objects[i] >> 3) & 0x1F, (objects[i] & 7) + 1
        if typ < len(fg):
            n += count * len(fg[typ])
        i += 1 + count
    return n


def our_flags(entry, gfx_at, flags_at, cached, label=""):
    """The template entry with its flags byte rewritten in our layout."""
    g, flags = entry[gfx_at], entry[flags_at]
    ours = 0
    if flags & GAME_MIRROR:
        ours |= FLIP_FLAG
    if flags & GAME_PASSABLE:
        ours |= PASSABLE_FLAG
    if cached.get(g) == (1 if flags & GAME_MIRROR else 0):
        ours |= CACHE_FLAG
    if SHARED_SHIFT_TEMPLATES and label.startswith(SHARED_SHIFT_TEMPLATES):
        ours |= SHARED_SHIFT_FLAG
    if label.startswith(BACKGROUND_TEMPLATES):
        ours |= BACKGROUND_FLAG
    entry = list(entry)
    entry[flags_at] = ours
    return tuple(entry)


def flag_note(flags):
    return ", ".join(name for bit, name in ((FLIP_FLAG, "mirrored"),
                                            (PASSABLE_FLAG, "passable"),
                                            (CACHE_FLAG, "cached"),
                                            (SHARED_SHIFT_FLAG, "shared shift"),
                                            (BACKGROUND_FLAG, "background"))
                     if flags & bit)


def emit(out):
    def line(label, mnemonic, operands, comment=""):
        # a label longer than its column still needs a space after it
        text = (label + " ").ljust(20) if label else " " * 20
        text += mnemonic.ljust(8) + operands
        if comment:
            text = text.ljust(68) + "; " + comment
        out.append(text.rstrip())

    out.append("; Generated by rooms.py from room_data.bin -- do not edit.")
    out.append(";")
    for para in __doc__.strip().split("\n\n")[1:4]:
        for l in para.split("\n"):
            out.append("; " + l if l else ";")
        out.append(";")
    out.append("")
    out.append("")

    cached = cache_way(rooms(),
                       pieces_by_index(BG_TYPE_TBL, BG_TYPE_COUNT, 8),
                       pieces_by_index(BLOCK_TYPE_TBL, BLOCK_TYPE_COUNT, 6))

    line("", ";", "", "")
    out.pop()
    out.append("; --- room shapes -----------------------------------------------------------")
    out.append(";")
    out.append("; Three of them, and the index is bits 3 and 4 of a room's attribute byte.")
    out.append("; Only the floor changes shape; every room is 128 tall.")
    line("room_size_tbl:", "", "")
    for i, tag in enumerate(("square", "narrow along U", "narrow along V")):
        sx, sy, sz = data[ROOM_SIZE_TBL - BASE + i * 3:ROOM_SIZE_TBL - BASE + i * 3 + 3]
        line("", "DB", "%3d, %3d, %3d" % (sx, sy, sz), "%d - %s" % (i, tag))
    out.append("")
    out.append("")

    # --- scenery -----------------------------------------------------------
    out.append("; --- scenery ---------------------------------------------------------------")
    out.append(";")
    out.append("; A piece is: sprite, U, V, Z, size U, size V, size Z, flags -- which is our")
    out.append("; object record almost field for field. Each template ends in a zero sprite.")
    out.append(";")
    out.append("; The flags byte is already OBJ.FLAGS, not the game's: bit 0 mirrors the")
    out.append("; piece, bit 2 lets things through it, bit 3 rotates it into the shared buffer")
    out.append("; at draw time, bit 4 draws it from a private copy of its graphic because some")
    out.append("; room holds another piece wanting that graphic the other way round, and bit 6")
    out.append("; puts it in the unsorted background run. room_add copies it as it stands.")
    out.append("")
    bg, bg_refs = templates(BG_TYPE_TBL, BG_TYPE_COUNT, 8, BG_NAMES, "bg")
    # A shared template carries one flags byte for every index that reaches it,
    # so background has to be all or nothing across them.
    for i, ref in enumerate(bg_refs):
        assert ref.startswith(BACKGROUND_TEMPLATES) ==             ("bg_" + BG_NAMES[i]).startswith(BACKGROUND_TEMPLATES), BG_NAMES[i]
    for addr, label, pieces in bg:
        line(label + ":", "", "", "%d piece%s" % (len(pieces), "" if len(pieces) == 1 else "s"))
        for p in pieces:
            p = our_flags(p, 0, 7, cached, label)
            line("", "DB", "%3d, %3d, %3d, %3d, %3d, %3d, %3d, $%02X" % p, flag_note(p[7]))
        line("", "DB", "0")
        out.append("")
    line("background_type_tbl:", "", "")
    for i, ref in enumerate(bg_refs):
        line("", "DW", ref, "$%02X" % i)
    out.append("")
    for i, name in enumerate(BG_NAMES):
        line("BG_" + name.upper(), "EQU", "$%02X" % i)
    out.append("")
    out.append("")

    # --- objects -----------------------------------------------------------
    out.append("; --- objects ---------------------------------------------------------------")
    out.append(";")
    out.append("; An entry is: sprite, size U, size V, size Z, flags, offsets. The flags byte")
    out.append("; is OBJ.FLAGS, as for scenery. There is no")
    out.append("; position -- that comes from the room, one packed byte per object -- so the")
    out.append("; same template serves every block in the castle. A template with more than")
    out.append("; one entry is an object drawn from several sprites, like a guard.")
    out.append("")
    fg, fg_refs = templates(BLOCK_TYPE_TBL, BLOCK_TYPE_COUNT, 6, FG_NAMES, "fg")
    for addr, label, entries in fg:
        line(label + ":", "", "", "%d sprite%s" % (len(entries), "" if len(entries) == 1 else "s"))
        for e in entries:
            e = our_flags(e, 0, 4, cached)
            line("", "DB", "%3d, %3d, %3d, %3d, $%02X, $%02X" % e, flag_note(e[4]))
        line("", "DB", "0")
        out.append("")
    line("block_type_tbl:", "", "")
    for i, ref in enumerate(fg_refs):
        line("", "DW", ref, "$%02X - %s" % (i, FG_NAMES[i]))
    out.append("")
    for i, name in enumerate(FG_NAMES):
        line("FG_" + name.upper(), "EQU", "$%02X" % i)
    out.append("")
    out.append("")

    # --- rooms -------------------------------------------------------------
    table = rooms()
    out.append("; --- the rooms -------------------------------------------------------------")
    out.append(";")
    out.append("; Each room is:")
    out.append(";")
    out.append(";     room number           which is what the walk matches on")
    out.append(";     skip                  bytes from here to the next record")
    out.append(";     attribute             colour in bits 0-2, room shape in bits 3-4,")
    out.append(";                           and how many scenery indices in bits 5-7")
    out.append(";     scenery type indices")
    out.append(";     object groups         a type-and-count byte, then that many")
    out.append(";                           packed positions: U cell in bits 0-2,")
    out.append(";                           V cell in bits 3-5, Z level in bits 6-7")
    out.append(";")
    out.append("; The game bounds the record with a length and ends the scenery list with")
    out.append("; $FF. The skip is that length, and the scenery count says where the")
    out.append("; scenery stops; what is left of the body is object bytes.")
    out.append(";")
    out.append("; The records carry their own number and are walked, rather than being")
    out.append("; reached through an index. An index over 256 numbers is 512 bytes to hold")
    out.append("; 128 rooms and half of it is nothing, where a number on each record is 128")
    out.append("; bytes. Knight Lore walks for the same reason: find_screen at $D3CF")
    out.append("; compares each record's own number and steps over its body.")
    out.append(";")
    out.append("; The walk needs no end: the records are in ascending order and the last is")
    out.append("; room $FF, so it always meets a number at least the one it wants.")
    out.append("")
    bg_sizes = pieces_by_index(BG_TYPE_TBL, BG_TYPE_COUNT, 8)
    fg_sizes = pieces_by_index(BLOCK_TYPE_TBL, BLOCK_TYPE_COUNT, 6)
    biggest = 0
    most_objects = 0
    assert max(table) == 0xFF, "room_find stops at the first number >= its own"
    line("room_list:", "", "")
    for rid in sorted(table):
        attr, body = table[rid]
        scenery, objects = split_body(body)
        biggest = max(biggest, len(scenery) + len(objects))
        most_objects = max(most_objects,
                           count_objects(bg_sizes, fg_sizes, scenery, objects))
        skip = 2 + len(scenery) + len(objects)
        assert len(scenery) < 8 and attr < 0x20 and skip < 256, rid
        line("room_%02X:" % rid, "DB", "$%02X, %d, $%02X"
             % (rid, skip, len(scenery) << ROOM_SCN_SHIFT | attr),
             "attr %d, shape %d, %d scenery, %d object bytes"
             % (attr & 7, attr >> 3, len(scenery), len(objects)))
        if scenery:
            line("", "DB", ", ".join("BG_" + BG_NAMES[s].upper() for s in scenery))
        i = 0
        while i < len(objects):
            group = objects[i]
            typ, count = (group >> 3) & 0x1F, (group & 7) + 1
            spots = objects[i + 1:i + 1 + count]
            line("", "DB", "$%02X, %s" % (group, ", ".join("$%02X" % s for s in spots)),
                 "%d x %s" % (count, FG_NAMES[typ] if typ < len(FG_NAMES) else "?"))
            i += 1 + count
        out.append("")
    out.append("")

    line("ROOM_SCN_SHIFT", "EQU", "%d" % ROOM_SCN_SHIFT, "the scenery count, above the attribute")
    line("ROOM_COUNT", "EQU", "%d" % len(table))
    line("ROOM_MAX_BODY", "EQU", "%d" % biggest, "longest scenery+object list")
    line("ROOM_MAX_OBJECTS", "EQU", "%d" % most_objects,
         "the fullest room, so the object pool")
    out.append("")
    out.append("; The flag bits the templates above were written with, for room.s to check")
    out.append("; against object.s.")
    for name, bit in (("FLIP", FLIP_FLAG), ("PASSABLE", PASSABLE_FLAG),
                      ("SHARED_SHIFT", SHARED_SHIFT_FLAG), ("CACHE", CACHE_FLAG),
                      ("BACKGROUND", BACKGROUND_FLAG)):
        line("ROOM_FLAG_" + name, "EQU", "$%02X" % bit)
    out.append("")
    return table


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
    return {"offsets": byte,
            "halfU": bool(byte & 1),
            "halfV": bool(byte & 2),
            "raiseZ": byte & 0xFC}


def json_entries(entries, flags_at, offsets_at=None):
    out = []
    for raw in entries:
        entry = {
            "graphic": raw[0],
            "flags": raw[flags_at],
            "mirrored": bool(raw[flags_at] & GAME_MIRROR),
            "bytes": list(raw),
        }
        if offsets_at is not None:
            entry.update(unpack_offsets(raw[offsets_at]))
        out.append(entry)
    return out


def json_templates(table, count, stride, flags_at, names, prefix, key,
                   offsets_at=None):
    out = []
    for i in range(count):
        at = w(table + i * 2)
        out.append({
            "index": i,
            "name": "%s_%s" % (prefix, names[i]),
            "address": "$%04X" % at,
            key: json_entries(block(at, stride), flags_at, offsets_at),
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
    scenery = json_templates(BG_TYPE_TBL, BG_TYPE_COUNT, SCENERY_STRIDE,
                             SCENERY_FLAGS_AT, BG_NAMES, "scenery", "blocks")
    objects = json_templates(BLOCK_TYPE_TBL, BLOCK_TYPE_COUNT, OBJECT_STRIDE,
                             OBJECT_FLAGS_AT, FG_NAMES, "object", "entries",
                             OBJECT_OFFSETS_AT)
    castle = json_rooms(table,
                        {t["index"]: t["name"] for t in scenery},
                        {t["index"]: t["name"] for t in objects})

    named = {s["template"] for r in castle for s in r["scenery"]}
    named |= {o["template"] for r in castle for o in r["objects"]}
    for group, key in ((scenery, "blocks"), (objects, "entries")):
        for t in group:
            t["used"] = t["name"] in named
            t["valid"] = all(e["graphic"] < GRAPHIC_COUNT for e in t[key])

    atlas = {
        "meta": {
            "version": 1,
            "game": "knightlore",
            "comment": "Written by rooms.py from room_data.bin; the same "
                       "schema Pentagram's rooms.py writes.",
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
    out = []
    table = emit(out)
    (HERE / "room_data.s").write_text("\n".join(out) + "\n", encoding="utf-8")
    print("room_data.s: %d rooms" % len(table))
    write_json(table)


if __name__ == "__main__":
    main()
