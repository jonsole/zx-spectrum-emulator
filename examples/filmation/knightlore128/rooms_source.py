"""Turn rooms.json into room_data.s and room_list.s -- Knight Lore's castle as
assembler source.

Two files, because on the 128K they go to different places. room_data.s is the
templates, which every room is built from and which stay in the $6000 region;
room_list.s is the rooms themselves, which go to bank 4 and are paged in only
while room_find copies one out (see room_build.s). The list is the part that
grows as the castle does.

rooms.py decodes the game's tables into rooms.json; this turns that into
something the engine can be built against. The split is Pentagram's, and it is
deliberate: the JSON is the readable, editable form, and this only ever reads
it, so renaming a template, recolouring a room or moving a block is done there
-- by hand, or in the room designer -- and never here.

Knight Lore does not store rooms as lists of objects. It stores templates and
expands them: a room is an attribute byte plus a handful of indices, and those
indices name pieces of scenery and groups of objects that are shared across the
whole castle. Room $B3 is four indices -- arch north, arch east, arch south and
the walls for a square room -- and they expand to 19 objects.

The layout changes on the way through. The game bounds each room record with a
length and ends its scenery list with $FF; we keep the length and use an
explicit scenery count instead of the terminator, because we are generating the
source and a count is cheaper to walk than a terminator. The flags byte is
rewritten in the engine's OBJ.FLAGS layout so that room_add can copy it into a
record as it stands, and the two templates no room names are left out.

The names in rooms.json come from the code map in tcdev's disassembly of Knight
Lore, as converted to SkoolKit by Michael R. Cook. Only the factual layer is
used -- what each table is and what its entries are called. Renaming one there
renames its label and its EQU here, which is half the point of the file being
JSON.

Run it after rooms.py, or through build.py, which regenerates each when its own
input is newer:

    python rooms_source.py
"""
import collections
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import castle                                                   # noqa: E402
import graphics as gfx                                          # noqa: E402

HERE = Path(__file__).resolve().parent
ATLAS = HERE / "rooms.json"
OUT = HERE / "room_data.s"
LIST_OUT = HERE / "room_list.s"

SCENERY_STRIDE = 8              # graphic, U, V, Z, size U, size V, size Z, flags
OBJECT_STRIDE = 6               # graphic, size U, size V, size Z, flags, offsets

ROOM_SCN_SHIFT = 5              # where a room header keeps its scenery count

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
# those keep their place in the sort. templates.json lists them by name, in
# meta.background; main() fills this with their labels.
BACKGROUND = set()

# The walls a doorway can stand in, in the order room.s numbers them.
SIDES = ("n", "e", "s", "w")
# A template that is not a doorway, in scenery_door_side.
NOT_A_DOORWAY = 0x80

# Templates whose pieces rotate at draw time instead of holding a buffer for
# the life of the room.
#
# Nothing, now. The walls and trees were marked for a while, to keep the
# rotation arena small; it cost more in redrawing than it saved in memory --
# see SHIFT_ARENA_SIZE in shift.s. The flag and the machinery behind it are
# still there, and object_place falls back on them when the arena runs out.
SHARED_SHIFT_TEMPLATES = ()

# The three room shapes, in the order room_size_tbl holds them.
def resolve_graphics(atlas):
    """Turn every named graphic back into the number the game knows it by.

    Done once, in place, so everything below works in the game's terms, which
    is what it is emitting. The names came out of the sprite sheet and go back
    through it -- graphics.py is the one rule, so the two cannot disagree.
    """
    known = gfx.numbers(HERE)
    if not known:
        sys.exit("%s is missing, so the graphics cannot be named back to the "
                 "numbers room_data.s needs -- run build.py, which unpacks it "
                 "from sprite_data.bin." % gfx.SHEET)
    sizes = gfx.sizes(HERE)
    for _group, template, _at, entry in castle.placements(atlas):
        # The box first, because it is looked up by the graphic's NAME and the
        # next line spends that name. Most entries have not got one of their
        # own -- the box belongs to the graphic, and sits in graphics.json --
        # so this is where it is filled in, and record_of below still just
        # reads sizeU/sizeV/sizeZ.
        # The number first: it is the lookup that says plainly when a name
        # is not in graphics.json at all, which is what a half-finished rename
        # looks like. The box would otherwise complain about a missing size.
        number = gfx.number_of(known, entry["graphic"], template)
        box = gfx.box_of(sizes, entry, template)
        entry["sizeU"], entry["sizeV"], entry["sizeZ"] = (
            box["u"], box["v"], box["z"])
        entry["graphic"] = number
    return known


def game_flags(entry):
    """The flags byte as the game had it, from the bits rooms.py named."""
    said = entry["flags"]
    return ((GAME_MIRROR if said["mirrored"] else 0)
            | (GAME_PASSABLE if said["passable"] else 0)
            | (said.get("rest", 0) & 0xFF))


def offsets_byte(entry):
    """...and the placement nudge, the same way round."""
    said = entry.get("offsets") or {}
    return ((1 if said.get("halfU") else 0)
            | (2 if said.get("halfV") else 0)
            | (said.get("raiseZ", 0) & 0xFC))


def record_of(entry, scenery):
    """One template entry as the bytes room_add reads.

    Scenery is eight -- graphic, its own U, V and Z, three half-sizes and the
    flags -- and an object six, with no position of its own and a nudge byte on
    the end instead. The flags byte here is still the GAME's; our_flags rewrites
    it below, where the whole castle is in hand to work OBJ_CACHE out.
    """
    if scenery:
        return [entry["graphic"], entry["u"], entry["v"], entry["z"],
                entry["sizeU"], entry["sizeV"], entry["sizeZ"], game_flags(entry)]
    return [entry["graphic"], entry["sizeU"], entry["sizeV"], entry["sizeZ"],
            game_flags(entry), offsets_byte(entry)]


def line(out, label, mnemonic, operands, comment=""):
    # a label longer than its column still needs a space after it
    text = (label + " ").ljust(20) if label else " " * 20
    text += mnemonic.ljust(8) + operands
    if comment:
        text = text.ljust(68) + "; " + comment
    out.append(text.rstrip())


def label_of(name):
    """The assembler label for a template, from its name in rooms.json.

    rooms.json calls them scenery_ and object_, which says what they are; the
    source has called them bg_ and fg_ since the disassembly did, and
    room_build.s and the BG_/FG_ EQUs are written that way.
    """
    if name.startswith("scenery_"):
        return "bg_" + name[len("scenery_"):]
    if name.startswith("object_"):
        return "fg_" + name[len("object_"):]
    return name


def bare(name):
    """A template's name with the kind stripped off: for an EQU or a comment."""
    label = label_of(name)
    return label[3:] if label[:3] in ("bg_", "fg_") else label


def room_pieces(scn_by_name, obj_by_name, room):
    """(graphic, mirrored) for every piece a room expands to."""
    out = []
    for s in room["scenery"]:
        for p in scn_by_name[s["template"]]:
            if p["graphic"] >= 2:
                out.append((p["graphic"], 1 if p["flags"]["mirrored"] else 0))
    for o in room["objects"]:
        entries = obj_by_name[o["template"]]
        for _ in o["positions"]:
            for p in entries:
                if p["graphic"] >= 2:
                    out.append((p["graphic"], 1 if p["flags"]["mirrored"] else 0))
    return out


def cache_way(rooms, scn_by_name, obj_by_name):
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
    for room in rooms:
        ways = collections.defaultdict(set)
        seen = collections.Counter()
        for g, f in room_pieces(scn_by_name, obj_by_name, room):
            ways[g].add(f)
            seen[(g, f)] += 1
        for g, s in ways.items():
            if len(s) > 1:
                contested.add(g)
        for key, n in seen.items():
            worst[key] = max(worst[key], n)
    return {g: (0 if worst[(g, 0)] <= worst[(g, 1)] else 1) for g in contested}


def our_flags(entry, cached, label=""):
    """A template entry's flags byte, rewritten in our layout."""
    g, flags = entry["graphic"], game_flags(entry)
    ours = 0
    if flags & GAME_MIRROR:
        ours |= FLIP_FLAG
    if flags & GAME_PASSABLE:
        ours |= PASSABLE_FLAG
    if cached.get(g) == (1 if flags & GAME_MIRROR else 0):
        ours |= CACHE_FLAG
    if SHARED_SHIFT_TEMPLATES and label.startswith(SHARED_SHIFT_TEMPLATES):
        ours |= SHARED_SHIFT_FLAG
    if label in BACKGROUND:
        ours |= BACKGROUND_FLAG
    return ours


def flag_note(flags):
    return ", ".join(name for bit, name in ((FLIP_FLAG, "mirrored"),
                                            (PASSABLE_FLAG, "passable"),
                                            (CACHE_FLAG, "cached"),
                                            (SHARED_SHIFT_FLAG, "shared shift"),
                                            (BACKGROUND_FLAG, "background"))
                     if flags & bit)


def shared_labels(templates):
    """The label each table index points at, and the blocks to emit once.

    Several table entries can share a template -- Pentagram has one of each
    kind -- so a label is emitted once, named after the first entry that
    reaches it.

    The game shared them by address, and rooms.json used to carry one. It does
    not any more: a template is its pieces, and two templates whose pieces are
    identical ARE the same block, which is the whole of what sharing an address
    meant. Checked against the addresses when they were dropped: in both games
    the two groupings are the same, template for template.
    """
    label_at = {}
    order = []
    for name, pieces in templates.items():
        body = json.dumps(pieces, sort_keys=True)
        if body not in label_at:
            label_at[body] = label_of(name)
            order.append((name, pieces))
    return order, [label_at[json.dumps(pieces, sort_keys=True)]
                   for pieces in templates.values()]


def emit_templates(out, templates, key, stride, noun, cached, only=None):
    """One labelled block a template, in table order, skipping the unreached."""
    order, refs = shared_labels(templates)
    for name, entries in order:
        label = label_of(name)
        if only is not None and label not in only:
            continue
        line(out, label + ":", "", "", "%d %s%s"
             % (len(entries), noun, "" if len(entries) == 1 else "s"))
        for e in entries:
            body = record_of(e, stride == SCENERY_STRIDE)
            assert len(body) == stride, (name, body)
            body[stride - 1 if stride == SCENERY_STRIDE else 4] = \
                our_flags(e, cached, label)
            if stride == SCENERY_STRIDE:
                text = "%3d, %3d, %3d, %3d, %3d, %3d, %3d, $%02X" % tuple(body)
                note = flag_note(body[7])
            else:
                text = "%3d, %3d, %3d, %3d, $%02X, $%02X" % tuple(body)
                note = flag_note(body[4])
            line(out, "", "DB", text, note)
        line(out, "", "DB", "0")
        out.append("")
    return refs


def main():
    if not ATLAS.is_file():
        sys.exit("%s is missing -- run rooms.py first" % ATLAS.name)
    # The rooms and the templates they place, as one castle -- found through
    # rooms.json's own meta, which says where its templates are.
    atlas = castle.read_castle(HERE)
    meta = atlas.get("meta") or {}
    if meta.get("game") != "knightlore128":
        sys.exit("%s is not Knight Lore 128K's" % ATLAS.name)
    if (meta.get("rules") or {}).get("exits") != "table":
        sys.exit("%s does not say its exits are a table (meta.rules.exits), and "
                 "room_build.s reads a destination with every scenery entry" % ATLAS.name)
    templates_meta = atlas.get("templatesMeta") or {}
    BACKGROUND.update(label_of(name) for name in templates_meta.get("background") or [])
    doorways = templates_meta.get("doorways") or {}

    resolve_graphics(atlas)
    scenery = atlas["sceneryTemplates"]
    objects = atlas["objectTemplates"]
    rooms = atlas["rooms"]
    # A template IS its pieces, so the castle's own mapping is the lookup.
    scn_by_name = scenery
    obj_by_name = objects
    object_index = {name: n for n, name in enumerate(objects)}

    out = []
    out.append("; Generated by rooms_source.py from rooms.json -- do not edit.")
    out.append(";")
    for para in __doc__.strip().split("\n\n")[1:5]:
        for l in para.split("\n"):
            out.append("; " + l if l else ";")
        out.append(";")
    out.append("")
    out.append("")

    cached = cache_way(rooms, scn_by_name, obj_by_name)

    # --- room shapes -------------------------------------------------------
    out.append("; --- room shapes -----------------------------------------------------------")
    out.append(";")
    out.append("; Three of them, and the index is bits 3 and 4 of a room's attribute byte.")
    out.append("; Only the floor changes shape; every room is 128 tall.")
    line(out, "room_size_tbl:", "", "")
    for n, (shape, s) in enumerate(atlas["roomDimensions"].items()):
        line(out, "", "DB", "%3d, %3d, %3d" % (s["u"], s["v"], s["z"]),
             "%d - %s" % (n, shape))
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
    # A shared template carries one flags byte for every index that reaches it,
    # so background has to be all or nothing across them.
    _, bg_refs = shared_labels(scenery)
    for name, ref in zip(scenery, bg_refs):
        assert (ref in BACKGROUND) == (label_of(name) in BACKGROUND), name
    emit_templates(out, scenery, "blocks", SCENERY_STRIDE, "piece", cached)
    line(out, "background_type_tbl:", "", "")
    # The index a room names a template by is where that template sits in the
    # castle: rooms.json keys them by name, in the game's own table order.
    for index, ref in enumerate(bg_refs):
        line(out, "", "DW", ref, "$%02X" % index)
    out.append("")
    for index, name in enumerate(scenery):
        line(out, "BG_" + bare(name).upper(), "EQU", "$%02X" % index)
    out.append("")

    # Which templates are doorways, and in which wall: templates.json's
    # meta.doorways, by name. room_door_note reads this rather than testing the
    # index, so any template can be made a doorway -- a bridge, a new arch.
    for name in doorways:
        if name not in scenery:
            sys.exit("templates.json names %s as a doorway, and there is no such "
                     "scenery template" % name)
        if doorways[name] not in SIDES:
            sys.exit("templates.json gives %s the wall %r; a wall is one of %s"
                     % (name, doorways[name], ", ".join(SIDES)))
    out.append("; The wall each scenery template is a doorway in, as room.s numbers them")
    out.append("; (0 N, 1 E, 2 S, 3 W), or $%02X for one that is not a doorway." % NOT_A_DOORWAY)
    line(out, "scenery_door_side:", "", "")
    for index, name in enumerate(scenery):
        side = doorways.get(name)
        line(out, "", "DB", "$%02X" % (SIDES.index(side) if side else NOT_A_DOORWAY),
             "$%02X - %s" % (index, bare(name)))
    line(out, "SCENERY_NOT_A_DOORWAY", "EQU", "$%02X" % NOT_A_DOORWAY)
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
    # Two templates no room names -- a fire standing still and the spikes
    # raised on something -- are in the game but never placed. They are left
    # out, and their table entries hold 0: nothing looks them up.
    _, fg_refs = shared_labels(objects)
    named = {o["template"] for r in rooms for o in r["objects"]}
    reached = {label_of(name) for name, ref in zip(objects, fg_refs)
               if name in named}
    reached |= {ref for name, ref in zip(objects, fg_refs) if name in named}
    emit_templates(out, objects, "entries", OBJECT_STRIDE, "sprite", cached,
                   only=reached)
    line(out, "block_type_tbl:", "", "")
    for index, (name, ref) in enumerate(zip(objects, fg_refs)):
        if ref in reached:
            line(out, "", "DW", ref, "$%02X - %s" % (index, bare(name)))
        else:
            line(out, "", "DW", "0",
                 "$%02X - %s: no room names it" % (index, bare(name)))
    out.append("")
    for index, name in enumerate(objects):
        line(out, "FG_" + bare(name).upper(), "EQU", "$%02X" % index)
    out.append("")
    out.append("")

    # --- the rooms ---------------------------------------------------------
    # From here to the end of the records is room_list.s rather than
    # room_data.s; both files open with the same header.
    header = out[:out.index("") + 2]
    list_start = len(out)
    out.append("; --- the rooms -------------------------------------------------------------")
    out.append(";")
    out.append("; Each room is:")
    out.append(";")
    out.append(";     room number           which is what the walk matches on")
    out.append(";     skip                  bytes from here to the next record")
    out.append(";     attribute             colour in bits 0-2, room shape in bits 3-4,")
    out.append(";                           and how many scenery indices in bits 5-7")
    out.append(";     scenery entries       two bytes each: the template's index, and the")
    out.append(";                           room it leads to if it is a doorway -- or")
    out.append(";                           ROOM_NO_EXIT, for a doorway walled up and for")
    out.append(";                           everything that is not a doorway")
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

    biggest = 0
    most_objects = 0
    numbers = [r["number"] for r in rooms]
    assert numbers == sorted(numbers), "the walk needs them in ascending order"
    assert numbers[-1] == 0xFF, "room_find stops at the first number >= its own"
    # The number a destination byte holds for no way out: one no room has.
    numbers_used = set(numbers)
    free = [n for n in range(256) if n not in numbers_used]
    if not free:
        sys.exit("every room number is taken, and one is needed to mean no exit")
    no_exit = free[0]

    # Where every doorway leads, checked: to a room that exists, and only
    # from a doorway.
    def destination(room, ref):
        to = ref.get("destination")
        if ref["template"] not in doorways:
            if to is not None:
                sys.exit("room %d: %s is not a doorway, and has a destination"
                         % (room["number"], ref["template"]))
            return None
        if to is not None and to not in numbers_used:
            sys.exit("room %d: the %s doorway leads to room %d, which is not a room"
                     % (room["number"], ref["template"], to))
        return to

    line(out, "room_list:", "", "")
    for r in rooms:
        scn, obs = r["scenery"], r["objects"]
        object_bytes = sum(1 + len(o["positions"]) for o in obs)
        biggest = max(biggest, 2 * len(scn) + object_bytes)
        placed = sum(len(scn_by_name[s["template"]]) for s in scn)
        placed += sum(len(o["positions"]) * len(obj_by_name[o["template"]])
                      for o in obs)
        most_objects = max(most_objects, placed)

        attr = r["ink"] | (castle.shape_index(atlas, r["dimensions"],
                                       "room %d" % r["number"]) << 3)
        skip = 2 + 2 * len(scn) + object_bytes
        assert len(scn) < 8 and attr < 0x20 and skip < 256, r["number"]
        line(out, "room_%02X:" % r["number"], "DB", "$%02X, %d, $%02X"
             % (r["number"], skip, len(scn) << ROOM_SCN_SHIFT | attr),
             "attr %d, %s, %d scenery, %d object bytes"
             % (r["ink"], r["dimensions"], len(scn), object_bytes))
        for s in scn:
            to = destination(r, s)
            line(out, "", "DB", "BG_%s, %s" % (bare(s["template"]).upper(),
                                               "$%02X" % to if to is not None else "ROOM_NO_EXIT"),
                 "to room $%02X" % to if to is not None else
                 ("walled up" if s["template"] in doorways else ""))
        for o in obs:
            n = len(o["positions"])
            group = object_index[o["template"]] << 3 | (n - 1)
            spots = ", ".join("$%02X" % (p["u"] | p["v"] << 3 | p["z"] << 6)
                              for p in o["positions"])
            line(out, "", "DB", "$%02X, %s" % (group, spots),
                 "%d x %s" % (n, bare(o["template"])))
        out.append("")
    out.append("")
    listing = header + out[list_start:]
    del out[list_start:]

    line(out, "ROOM_SCN_SHIFT", "EQU", "%d" % ROOM_SCN_SHIFT,
         "the scenery count, above the attribute")
    line(out, "ROOM_COUNT", "EQU", "%d" % len(rooms))
    line(out, "ROOM_NO_EXIT", "EQU", "$%02X" % no_exit,
         "no room has this number: a doorway with nowhere to go")
    line(out, "ROOM_MAX_BODY", "EQU", "%d" % biggest, "longest scenery+object list")
    line(out, "ROOM_MAX_OBJECTS", "EQU", "%d" % most_objects,
         "the fullest room, so the object pool")
    out.append("")
    out.append("; The flag bits the templates above were written with, for room.s to check")
    out.append("; against object.s.")
    for name, bit in (("FLIP", FLIP_FLAG), ("PASSABLE", PASSABLE_FLAG),
                      ("SHARED_SHIFT", SHARED_SHIFT_FLAG), ("CACHE", CACHE_FLAG),
                      ("BACKGROUND", BACKGROUND_FLAG)):
        line(out, "ROOM_FLAG_" + name, "EQU", "$%02X" % bit)
    out.append("")

    # The map, checked as a whole: a doorway with no door back is a one-way
    # trip, and a room no doorway leads to can only be started in. Neither
    # stops the build -- a castle being drawn has both for a while -- but
    # both are said.
    leads = {}
    for r in rooms:
        for s in r["scenery"]:
            to = s.get("destination")
            if s["template"] in doorways and to is not None:
                leads.setdefault(r["number"], set()).add(to)
    for number, tos in sorted(leads.items()):
        for to in sorted(tos):
            if number not in leads.get(to, ()):
                print("note: room $%02X leads to room $%02X, which has no door back"
                      % (number, to))
    led_to = set().union(*leads.values()) if leads else set()
    for number in numbers:
        if number not in led_to:
            print("note: no doorway leads to room $%02X" % number)

    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    LIST_OUT.write_text("\n".join(listing) + "\n", encoding="utf-8")
    print("%s: %d rooms, %d scenery templates, %d object templates, "
          "fullest room %d objects" % (OUT.name + " and " + LIST_OUT.name, len(rooms), len(scenery),
                                       len(objects), most_objects))


if __name__ == "__main__":
    main()
