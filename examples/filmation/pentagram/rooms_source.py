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

HERE = Path(__file__).resolve().parent
ATLAS = HERE / "rooms.json"
OUT = HERE / "room_data.s"

SCENERY_STRIDE = 8              # graphic, U, V, Z, size U, size V, size Z, flags
OBJECT_STRIDE = 6               # graphic, size U, size V, size Z, flags, offsets

GAME_MIRROR = 0x40
FLIP_FLAG = 0x01                # OBJ_FLIP_H

ROOM_SCN_SHIFT = 5              # the scenery count, above the attribute
SCN_COUNT_BIAS = 1              # ...stored biased by one, so eight fits in three bits

TAB = chr(9)


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
        for e in entries:
            body = list(e["bytes"])
            while len(body) < stride:
                body.append(0)              # the offsets byte Pentagram has not got
            body[stride - 1 if stride == SCENERY_STRIDE else 4] = our_flags(e["flags"])
            note = "mirrored" if e["mirrored"] else ""
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
    out.append(";     scenery               two bytes each: the template, then the room")
    out.append(";                           a doorway leads to, or zero")
    out.append(";     object groups         a type-and-count byte, then that many packed")
    out.append(";                           positions: U cell in bits 0-2, V cell in")
    out.append(";                           bits 3-5, Z level in bits 6-7")
    out.append(";")
    out.append("; The destination byte is what makes Pentagram's map work. It is not a")
    out.append("; grid: forty distinct deltas, and thirteen different ones for a single")
    out.append("; doorway direction, so no arithmetic recovers it. The byte is also the")
    out.append("; authority, not the template -- one south doorway is an exit in")
    out.append("; twenty-eight rooms and blocked in one.")
    out.append("")

    biggest = most_objects = 0
    line(out, "room_list:", "", "")
    for r in rooms:
        scn, obs = r["scenery"], r["objects"]
        body = 2 * len(scn) + sum(1 + len(o["positions"]) for o in obs)
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
            line(out, "", "DB", "SCN_%s, $%02X"
                 % (label_of(s["template"])[4:].upper(), dest),
                 "-> room %d" % dest if dest else "")
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
    out.append("")

    OUT.write_text("\n".join(out) + "\n", encoding="utf-8")
    print("%s: %d rooms, %d scenery templates, %d object templates, "
          "fullest room %d objects" % (OUT.name, len(rooms), len(scenery),
                                       len(objects), most_objects))


if __name__ == "__main__":
    main()
