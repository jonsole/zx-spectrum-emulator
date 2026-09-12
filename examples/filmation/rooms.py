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


# Our own bits in a piece's flags byte, which is otherwise the game's. The
# game only ever writes $10, $12, $14 and $50, so bits 0, 3, 5 and 7 are free;
# room_add tests these two directly rather than rotating them into place with
# the mirror flag.
CACHE_FLAG = 0x01           # draw from a private copy of the graphic
SHARED_SHIFT_FLAG = 0x08    # rotate into the shared buffer, at draw time

# Templates whose pieces rotate at draw time instead of holding a buffer for
# the life of the room. Walls and trees line the edges of a room and a
# character is rarely in front of one, so their buffers sit idle -- room $88
# rotates ten objects and eight of them are never redrawn at all. Arches, gates
# and the objects a character walks around keep their own buffers, because a
# shared-buffer piece is re-rotated on every single draw.
SHARED_SHIFT_TEMPLATES = ("bg_walls", "bg_trees")


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
    """The template entry with our two flag bits set where they belong."""
    g, flags = entry[gfx_at], entry[flags_at]
    add = 0
    if cached.get(g) == (1 if flags & 0x40 else 0):
        add |= CACHE_FLAG
    if label.startswith(SHARED_SHIFT_TEMPLATES):
        add |= SHARED_SHIFT_FLAG
    if not add:
        return entry
    entry = list(entry)
    entry[flags_at] = flags | add
    return tuple(entry)


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
    out.append("; Three of them, and the index is the top bits of a room's attribute byte.")
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
    out.append("; object record almost field for field. Flags bit 6 mirrors the piece.")
    out.append("; Each template ends in a zero sprite.")
    out.append(";")
    out.append("; Bits 0 and 3 of the flags are ours, not the game's -- it only ever writes")
    out.append("; $10, $12, $14 and $50, so those two are free. Bit 0 marks a piece that has")
    out.append("; to be drawn from a private copy of its graphic, because some room holds")
    out.append("; another piece wanting that graphic the other way round. Bit 3 marks one")
    out.append("; that rotates into the shared buffer at draw time rather than holding a")
    out.append("; buffer of its own for the life of the room.")
    out.append("")
    bg, bg_refs = templates(BG_TYPE_TBL, BG_TYPE_COUNT, 8, BG_NAMES, "bg")
    for addr, label, pieces in bg:
        line(label + ":", "", "", "%d piece%s" % (len(pieces), "" if len(pieces) == 1 else "s"))
        for p in pieces:
            p = our_flags(p, 0, 7, cached, label)
            note = ", ".join(x for x in ("mirrored" if p[7] & 0x40 else "",
                                         "cached" if p[7] & CACHE_FLAG else "",
                                         "shared shift" if p[7] & SHARED_SHIFT_FLAG
                                         else "") if x)
            line("", "DB", "%3d, %3d, %3d, %3d, %3d, %3d, %3d, $%02X" % p, note)
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
    out.append("; An entry is: sprite, size U, size V, size Z, flags, offsets. There is no")
    out.append("; position -- that comes from the room, one packed byte per object -- so the")
    out.append("; same template serves every block in the castle. A template with more than")
    out.append("; one entry is an object drawn from several sprites, like a guard.")
    out.append("")
    fg, fg_refs = templates(BLOCK_TYPE_TBL, BLOCK_TYPE_COUNT, 6, FG_NAMES, "fg")
    for addr, label, entries in fg:
        line(label + ":", "", "", "%d sprite%s" % (len(entries), "" if len(entries) == 1 else "s"))
        for e in entries:
            e = our_flags(e, 0, 4, cached)
            line("", "DB", "%3d, %3d, %3d, %3d, $%02X, $%02X" % e,
                 "cached" if e[4] & CACHE_FLAG else "")
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
    out.append(";     attribute and size    colour in bits 0-2, room shape in bits 3 up")
    out.append(";     counts                scenery in bits 5-7, object bytes in 0-4")
    out.append(";     scenery type indices")
    out.append(";     object groups         a type-and-count byte, then that many")
    out.append(";                           packed positions: U cell in bits 0-2,")
    out.append(";                           V cell in bits 3-5, Z level in bits 6-7")
    out.append(";")
    out.append("; The game bounds the record with a length and ends the scenery list with")
    out.append("; $FF; two counts say the same thing and are cheaper to walk.")
    out.append(";")
    out.append("; The records carry their own number and are walked, rather than being")
    out.append("; reached through an index. An index over 256 numbers is 512 bytes to hold")
    out.append("; 128 rooms and half of it is nothing, where a number on each record is 128")
    out.append("; bytes that pack into the header for free -- the two counts needed a byte")
    out.append("; each and fit in one. Knight Lore walks for the same reason: find_screen")
    out.append("; at $D3CF compares each record's own number and steps over its body.")
    out.append("")
    bg_sizes = pieces_by_index(BG_TYPE_TBL, BG_TYPE_COUNT, 8)
    fg_sizes = pieces_by_index(BLOCK_TYPE_TBL, BLOCK_TYPE_COUNT, 6)
    biggest = 0
    most_objects = 0
    line("room_list:", "", "")
    for rid in sorted(table):
        attr, body = table[rid]
        scenery, objects = split_body(body)
        biggest = max(biggest, len(scenery) + len(objects))
        most_objects = max(most_objects,
                           count_objects(bg_sizes, fg_sizes, scenery, objects))
        assert len(scenery) < 8 and len(objects) < 32, rid
        line("room_%02X:" % rid, "DB", "$%02X, $%02X, $%02X"
             % (rid, attr, len(scenery) << 5 | len(objects)),
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

    out.append("; The walk runs from the first record to here. Ascending by number,")
    out.append("; which is what lets the 1 and 2 keys step from one room to the next.")
    line("room_list_end:", "", "")
    out.append("")
    line("ROOM_SCN_SHIFT", "EQU", "5", "the scenery count sits in the top three bits")
    line("ROOM_OBJ_MASK", "EQU", "$1F", "...and the object byte count in the low five")
    line("ROOM_COUNT", "EQU", "%d" % len(table))
    line("ROOM_MAX_BODY", "EQU", "%d" % biggest, "longest scenery+object list")
    line("ROOM_MAX_OBJECTS", "EQU", "%d" % most_objects,
         "the fullest room, so the object pool")
    out.append("")
    return table


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


if __name__ == "__main__":
    main()
