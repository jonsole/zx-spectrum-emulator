"""Turn rooms.json into room_data.s -- Pentagram's castle as assembler source.

rooms.py decodes the game's tables into rooms.json; this turns that into
something the engine can be built against. The split is deliberate: the JSON
is the readable, editable form, and this only ever reads it, so renaming a
template or moving a room is done there and never here.

The layout changes on the way through, in three places:

  * A template's entries become fixed six or eight byte records ending in a
    zero graphic, which is what the game's own format already is. Pentagram's
    object entries are five bytes where Knight Lore's are six, and the sixth
    is a placement nudge -- half a cell in U or V, and a height in Z. Pentagram
    has no such byte, so a zero is emitted in its place and the capability is
    kept rather than lost. See unpack_offsets in ../knightlore/rooms.py.

  * The scenery section's $FF terminator becomes a count, packed into the
    spare bits above the attribute, because a count is cheaper to walk. The
    count is stored biased by one: rooms hold three to eight scenery entries,
    and eight will not fit in three bits, but seven will. Every room has at
    least one, so nothing is lost -- and one room, 59, has exactly eight,
    which is what forced the bias.

  * The flags byte is rewritten in the engine's OBJ.FLAGS layout so that
    room_add can copy it into a record as it stands.

On that last point, only one bit is translated with any confidence:

    $40 mirror  ->  OBJ_FLIP_H

Two of the game's bits are understood but not yet mapped:

    $04   the object is mobile: fields +$09/+$0A/+$0B are a movement vector,
          $CD87 clears them to stop it, and $B775/$B832 pass a vector from one
          record to another on contact. The engine's OBJ_MOVABLE ($80) is the
          obvious candidate, but object.s uses that to mean "this is a
          character", which is not the same claim, so it is left alone until
          Pentagram's own behaviours are written.

    $10   selects the object into a list built at $B547. Every template a room
          uses has it, so its absence most likely means background, which
          would make it the inverse of OBJ_BACKGROUND ($40). What consumes the
          list has not been traced, so this is not acted on either.

OBJ_CACHE is not emitted at all. Knight Lore works out which graphics some
room wants both ways round and nominates one orientation to be drawn from a
private copy, so nothing is mirrored twice a region -- see cache_way in
../knightlore/rooms.py. That is a performance question, not a correctness one,
and it wants Pentagram's own rooms measured rather than Knight Lore's answer
assumed.

Run it after rooms.py:

    python rooms_source.py
"""
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import graphics as gfx                                          # noqa: E402

HERE = Path(__file__).resolve().parent
ATLAS = HERE / "rooms.json"
OUT = HERE / "room_data.s"

SCENERY_STRIDE = 8              # graphic, U, V, Z, size U, size V, size Z, flags
OBJECT_STRIDE = 6               # graphic, size U, size V, size Z, flags, offsets

GAME_MIRROR = 0x40
FLIP_FLAG = 0x01                # OBJ_FLIP_H
BACKGROUND_FLAG = 0x40          # OBJ_BACKGROUND: drawn first and never sorted

# The scenery nothing can ever be behind: the trees and stone walls along the
# two back walls -- U 64 and V 192, or U 96 and V 160 for the narrow rooms --
# which the room's own bounds keep him in front of. Knight Lore marks its
# walls and trees the same way (BACKGROUND_TEMPLATES there), and for the same
# reason: they need never be compared with anything. The game's own flags do
# not say so -- every scenery template carries $10 -- so it is said here, by
# name, and checked by position below.
#
# Not the doorways, which he walks through, and not anything on the front
# walls (U or V 56-59), which the background run would put behind everything.
BACKGROUND_TEMPLATES = {"scenery_%02d" % n for n in (8, 9, 10, 11, 12, 13, 14, 15,
                                                     16, 17, 20, 21)}
BACK_WALLS_U = (64, 96)
BACK_WALLS_V = (192, 160)

ROOM_SCN_SHIFT = 5              # the scenery count, above the attribute
SCN_COUNT_BIAS = 1              # ...stored biased by one, so eight fits in three bits

TAB = chr(9)


def resolve_graphics(atlas):
    """Turn every named graphic back into the number the game knows it by.

    Done once, in place, so everything below works in the game's terms, which
    is what it is emitting. The names came out of the sprite sheet and go back
    through it -- graphics.py is the one rule, so the two cannot disagree.
    ../knightlore/rooms_source.py does the same.
    """
    known = gfx.numbers(HERE)
    if not known:
        sys.exit("%s is missing, so the graphics cannot be named back to the "
                 "numbers room_data.s needs -- run build.py, which unpacks it "
                 "from sprite_data.bin." % gfx.SHEET)
    for group, key in ((atlas["sceneryTemplates"], "blocks"),
                       (atlas["objectTemplates"], "entries")):
        for template in group:
            for entry in template[key]:
                entry["graphic"] = gfx.number_of(known, entry["graphic"],
                                                 template["name"])
    return known


def game_flags(entry):
    """The flags byte as the game had it, from the bits rooms.py named."""
    said = entry["flags"]
    return ((GAME_MIRROR if said["mirrored"] else 0)
            | (said.get("rest", 0) & 0xFF))


def record_of(entry, scenery):
    """One template entry as the bytes room_add reads.

    Scenery is eight -- graphic, its own U, V and Z, three half-sizes and the
    flags. An object is six here even though Pentagram's own are five: the
    sixth is the placement nudge its room_build.s reads and its data never
    uses, and emitting a zero keeps the capability rather than losing it.
    """
    if scenery:
        return [entry["graphic"], entry["u"], entry["v"], entry["z"],
                entry["sizeU"], entry["sizeV"], entry["sizeZ"], game_flags(entry)]
    said = entry.get("offsets") or {}
    nudge = ((1 if said.get("halfU") else 0)
             | (2 if said.get("halfV") else 0)
             | (said.get("raiseZ", 0) & 0xFC))
    return [entry["graphic"], entry["sizeU"], entry["sizeV"], entry["sizeZ"],
            game_flags(entry), nudge]


def line(out, label, mnemonic, operands, comment=""):
    text = (label + " ").ljust(20) if label else " " * 20
    text += mnemonic.ljust(8) + operands
    if comment:
        text = text.ljust(68) + "; " + comment
    out.append(text.rstrip())


def our_flags(flags):
    """The game's flags byte in the engine's OBJ.FLAGS layout."""
    ours = 0
    if flags & GAME_MIRROR:
        ours |= FLIP_FLAG
    return ours


def label_of(name):
    if name.startswith("object_"):
        return "obj_" + name[len("object_"):]
    if name.startswith("scenery_"):
        return "scn_" + name[len("scenery_"):]
    return "scn_" + name              # the doorways, which carry real names


def emit_templates(out, templates, key, stride, title, blurb):
    """One labelled block a template, and the table the rooms index it by.

    Several table entries can point at the same template, so a label is
    emitted once, named after the first entry that reaches it, and the table
    holds a word per index as the game's own does.
    """
    out.append("; --- %s %s" % (title, "-" * (72 - len(title))))
    out.append(";")
    for l in blurb:
        out.append("; " + l if l else ";")
    out.append("")

    seen = {}
    for t in templates:
        if t["address"] in seen:
            continue
        seen[t["address"]] = label_of(t["name"])
        entries = t[key]
        line(out, label_of(t["name"]) + ":", "", "",
             "%d %s" % (len(entries), "entry" if len(entries) == 1 else "entries"))
        background = t["name"] in BACKGROUND_TEMPLATES
        if background:
            # Every piece on a back wall -- the narrow rooms' templates turn
            # the corner, so one piece of each is on the other wall.
            for e in entries:
                assert e["u"] in BACK_WALLS_U or e["v"] in BACK_WALLS_V,                     "%s has a piece off the back walls, at U %d V %d"                     % (t["name"], e["u"], e["v"])
        for e in entries:
            body = record_of(e, stride == SCENERY_STRIDE)
            assert len(body) == stride, (t["name"], body)
            flags = our_flags(game_flags(e))
            if background:
                flags |= BACKGROUND_FLAG
            body[stride - 1 if stride == SCENERY_STRIDE else 4] = flags
            note = "mirrored" if e["flags"]["mirrored"] else ""
            line(out, "", "DB", ", ".join("%3d" % b for b in body), note)
        line(out, "", "DB", "0")
        out.append("")
    return seen


def main():
    if not ATLAS.is_file():
        sys.exit("%s is missing -- run rooms.py first" % ATLAS.name)
    atlas = json.loads(ATLAS.read_text(encoding="utf-8"))
    if atlas.get("meta", {}).get("game") != "pentagram":
        sys.exit("%s is not Pentagram's" % ATLAS.name)

    resolve_graphics(atlas)
    scenery = atlas["sceneryTemplates"]
    objects = atlas["objectTemplates"]
    rooms = atlas["rooms"]
    by_name = {t["name"]: t for t in scenery}
    obj_by_name = {t["name"]: t for t in objects}

    out = []
    out.append("; Generated by rooms_source.py from rooms.json -- do not edit.")
    out.append(";")
    for para in __doc__.strip().split("\n\n")[1:3]:
        for l in para.split("\n"):
            out.append("; " + l if l else ";")
        out.append(";")
    out.append("")
    out.append("")

    # --- room shapes -------------------------------------------------------
    out.append("; --- room shapes " + "-" * 58)
    out.append(";")
    out.append("; Three of them, and the index is bits 3 and 4 of a room's attribute byte.")
    out.append("; Only the floor changes shape; every room is 128 tall. The same three")
    out.append("; shapes, byte for byte, as Knight Lore's.")
    line(out, "room_size_tbl:", "", "")
    for s in atlas["sizes"]:
        line(out, "", "DB", "%3d, %3d, %3d" % (s["u"], s["v"], s["z"]),
             "%d" % s["index"])
    out.append("")
    out.append("")

    scn_labels = emit_templates(
        out, scenery, "blocks", SCENERY_STRIDE, "scenery",
        ["A piece is: graphic, U, V, Z, size U, size V, size Z, flags -- the",
         "engine's object record almost field for field. A template is a chain of",
         "them ending in a zero graphic, so one entry can place several pieces."])
    line(out, "scenery_type_tbl:", "", "")
    for t in scenery:
        line(out, "", "DW", scn_labels[t["address"]],
             "$%02X%s" % (t["index"], "  " + t["side"] if t["doorway"] else ""))
    out.append("")
    for t in scenery:
        line(out, "SCN_" + label_of(t["name"])[4:].upper(), "EQU", "$%02X" % t["index"])
    out.append("")
    out.append("")

    obj_labels = emit_templates(
        out, objects, "entries", OBJECT_STRIDE, "objects",
        ["An entry is: graphic, size U, size V, size Z, flags, offsets. There is no",
         "position -- that comes from the room, one packed byte an instance -- so",
         "the same template serves every one of them. The offsets byte is always",
         "zero here: Pentagram's own entries are five bytes and carry no nudge."])
    line(out, "object_type_tbl:", "", "")
    for t in objects:
        line(out, "", "DW", obj_labels[t["address"]], "$%02X" % t["index"])
    out.append("")
    for t in objects:
        line(out, "OBJ_" + label_of(t["name"])[4:].upper(), "EQU", "$%02X" % t["index"])
    out.append("")
    out.append("")

    # --- the rooms ---------------------------------------------------------
    out.append("; --- the rooms " + "-" * 60)
    out.append(";")
    out.append("; Each room is:")
    out.append(";")
    out.append(";     room number           which is what the walk matches on")
    out.append(";     skip                  bytes from here to the next record")
    out.append(";     attribute             colour in bits 0-2, room shape in bits 3-4,")
    out.append(";                           and the scenery count LESS ONE in bits 5-7")
    out.append(";     scenery               the template, and after a doorway's the room")
    out.append(";                           it leads to, or zero -- nothing else has one")
    out.append(";     object groups         a type-and-count byte, then that many packed")
    out.append(";                           positions: U cell in bits 0-2, V cell in")
    out.append(";                           bits 3-5, Z level in bits 6-7")
    out.append(";")
    out.append("; The destination byte is what makes Pentagram's map work. It is not a")
    out.append("; grid: forty distinct deltas, and thirteen different ones for a single")
    out.append("; doorway direction, so no arithmetic recovers it. The byte is also the")
    out.append("; authority, not the template -- one south doorway is an exit in")
    out.append("; twenty-eight rooms and blocked in one. Only the doorways carry it: the")
    out.append("; other 275 entries had one too, always zero, and that was 275 bytes.")
    out.append("")

    biggest = most_objects = 0
    line(out, "room_list:", "", "")
    for r in rooms:
        scn, obs = r["scenery"], r["objects"]
        body = sum(2 if by_name[s["template"]]["doorway"] else 1 for s in scn)
        body += sum(1 + len(o["positions"]) for o in obs)
        biggest = max(biggest, body)
        placed = sum(len(by_name[s["template"]]["blocks"]) for s in scn)
        placed += sum(len(o["positions"]) * len(obj_by_name[o["template"]]["entries"])
                      for o in obs)
        most_objects = max(most_objects, placed)

        attr = r["ink"] | (r["size"] << 3)
        count = len(scn) - SCN_COUNT_BIAS
        skip = 2 + body
        assert 0 <= count < 8 and attr < 0x20 and skip < 256, r["number"]
        line(out, "room_%02X:" % r["number"], "DB",
             "$%02X, %d, $%02X" % (r["number"], skip, count << ROOM_SCN_SHIFT | attr),
             "ink %d, shape %d, %d scenery, %d placed"
             % (r["ink"], r["size"], len(scn), placed))
        for s in scn:
            dest = s["destination"]
            name = label_of(s["template"])[4:].upper()
            if by_name[s["template"]]["doorway"]:
                line(out, "", "DB", "SCN_%s, $%02X" % (name, dest),
                     "-> room %d" % dest if dest else "walled up")
            else:
                assert dest == 0, (r["number"], s["template"])
                line(out, "", "DB", "SCN_%s" % name, "")
        for o in obs:
            n = len(o["positions"])
            group = (obj_by_name[o["template"]]["index"] << 2) | (n - 1)
            spots = ", ".join("$%02X" % (p["u"] | p["v"] << 3 | p["z"] << 6)
                              for p in o["positions"])
            line(out, "", "DB", "$%02X, %s" % (group, spots),
                 "%d x %s" % (n, o["template"]))
        out.append("")
    out.append("")

    line(out, "ROOM_SCN_SHIFT", "EQU", "%d" % ROOM_SCN_SHIFT,
         "the scenery count, above the attribute")
    line(out, "ROOM_SCN_BIAS", "EQU", "%d" % SCN_COUNT_BIAS, "...stored less this")
    line(out, "ROOM_COUNT", "EQU", "%d" % len(rooms))
    line(out, "ROOM_MAX_BODY", "EQU", "%d" % biggest, "longest scenery+object list")
    line(out, "ROOM_MAX_OBJECTS", "EQU", "%d" % most_objects,
         "the fullest room, so the object pool")
    out.append("")
    out.append("; The flag bits the templates above were written with, for room.s to check")
    out.append("; against object.s.")
    line(out, "ROOM_FLAG_FLIP", "EQU", "$%02X" % FLIP_FLAG)
    line(out, "ROOM_FLAG_BACKGROUND", "EQU", "$%02X" % BACKGROUND_FLAG)
    out.append("")

    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    print("%s: %d rooms, %d scenery templates, %d object templates, "
          "fullest room %d objects" % (OUT.name, len(rooms), len(scenery),
                                       len(objects), most_objects))


if __name__ == "__main__":
    main()
