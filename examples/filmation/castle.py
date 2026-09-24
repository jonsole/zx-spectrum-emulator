"""What a Filmation castle's two files look like, and nothing about what is in them.

A castle is two files, one job each:

  rooms.json       the rooms -- what shape each is, its ink, and which
                   templates it places where -- and the floor shapes
  templates.json   the templates themselves: castle-wide pieces every room
                   naming one is built from

They were one file. A template is not part of a room, though -- a change to one
moves every room that names it -- and it gets an editor of its own, which wants
a document of its own to give it a proper undo and Save.

Both games write these files and both read them back, so the shape lives here
rather than four times over -- rooms.py decodes the game's own tables into
them, rooms_source.py turns them back into room_data.s, and the room designer
and the templates editor open them in between. Everything that reads them gets
ONE castle, the two merged, through read_castle; write_castle splits it again.

Two rules run through the file.

Anything with a NAME is keyed by that name. A floor shape is "square", a
template is "scenery_arch_n"; neither carries a "name" field, because the key
is the identity and a copy inside the entry is only something to disagree with.
Neither carries an index either: where an ordinal matters to the game -- bits 3
and 4 of a room's attribute byte index the floor-shape table straight -- it is
the order the keys are written in, which JSON keeps and both Python and
JavaScript preserve.

A PLACEMENT is not a name. A scenery template is a list of pieces put down in
order, and the same piece can appear several times: Knight Lore's
scenery_walls_1 lays scenery.26 five times along a wall. So a template's
placements are a list, and each one names the graphic it draws the way
graphics.json names a sprite -- as a reference, not as its own identity.

The layout is written out rather than left to json.dumps, because this is a
file people read and edit: a placement is one record and belongs on one line,
and json.dumps(indent=1) spreads each across nine.
"""
import json
import re
from pathlib import Path

# What the files are called when rooms.py first writes them. After that each
# names the other in its meta -- rooms.json says where its templates are,
# templates.json says which rooms it belongs to -- and a reader follows those
# rather than assuming. rooms.json is the one name that is fixed: it is where
# a castle is opened from.
ROOMS = "rooms.json"
TEMPLATES = "templates.json"


def _beside(here, name, whose, key):
    """A file one of the castle's files names, relative to it and inside its
    directory: the file is data, and data does not get to point anywhere."""
    if not isinstance(name, str) or not name:
        raise SystemExit("%s does not say %s in its meta.%s, and nothing is "
                         "assumed about where it is." % (whose,
                         "where its templates are" if key == "templates"
                         else "which rooms it belongs to", key))
    path = (here / name).resolve()
    if path.parent != here.resolve():
        raise SystemExit("%s names %r in meta.%s, which is not beside it."
                         % (whose, name, key))
    return path


def templates_path(game_dir):
    """Where a castle's templates are, as its rooms.json says."""
    here = Path(game_dir)
    rooms = json.loads((here / ROOMS).read_text(encoding="utf-8"))
    return _beside(here, (rooms.get("meta") or {}).get("templates"), ROOMS, "templates")

# The two kinds of template, in the order they appear in the file.
GROUPS = ("sceneryTemplates", "objectTemplates")


def read_castle(game_dir):
    """Both files, as one castle: the rooms with the templates in them.

    The templates' own meta block comes along as `templatesMeta`, so writing
    the castle back gives the file the header it had.
    """
    here = Path(game_dir)
    rooms = json.loads((here / ROOMS).read_text(encoding="utf-8"))
    where = _beside(here, (rooms.get("meta") or {}).get("templates"), ROOMS, "templates")
    if not where.is_file():
        raise SystemExit("%s names %s as its templates, and it is not there -- "
                         "run rooms.py to make the pair." % (ROOMS, where.name))
    templates = json.loads(where.read_text(encoding="utf-8"))
    # ...and the templates have to say they are these rooms' own. Two castles'
    # files paired by mistake would build rooms out of the wrong pieces.
    back = _beside(here, (templates.get("meta") or {}).get("rooms"), where.name, "rooms")
    if back.name != ROOMS:
        raise SystemExit("%s belongs to %s, not to %s." % (where.name, back.name, ROOMS))
    castle = dict(rooms)
    for group in GROUPS:
        castle[group] = templates[group]
    castle["templatesMeta"] = templates.get("meta") or {}
    return castle


def write_castle(game_dir, castle):
    """...and back into its two files."""
    here = Path(game_dir)
    where = _beside(here, (castle.get("meta") or {}).get("templates"), ROOMS, "templates")
    (here / ROOMS).write_text(format_rooms(castle), encoding="utf-8")
    where.write_text(format_templates(castle), encoding="utf-8")


def templates_meta(castle):
    """The templates file's header: what it is, and which game it belongs to.

    The game is needed, not just polite: which templates are doorways is
    decided by their position in the game's own table, and the two games put
    them in different places.
    """
    said = castle.get("templatesMeta")
    if said:
        return said
    game = (castle.get("meta") or {}).get("game")
    return {
        "version": 1,
        "game": game,
        # The rooms these templates belong to, named as rooms.json names this
        # file: neither leaves the other to be guessed.
        "rooms": ROOMS,
        "comment": "The castle's templates: pieces every room naming one is "
                   "built from. rooms.json places them.",
    }


def shape_index(atlas, name, whose):
    """A floor shape's name back to the index the attribute byte holds.

    Nothing guesses. A room naming a shape the file has not got would
    otherwise be emitted as some other shape, and its floor would be the wrong
    size with nothing said.
    """
    for n, shape in enumerate(atlas["roomDimensions"]):
        if shape == name:
            return n
    raise SystemExit(
        "%s wants the floor shape %r, which rooms.json does not have.\n"
        "roomDimensions names them: %s"
        % (whose, name, ", ".join(atlas["roomDimensions"])))


def placements(atlas):
    """Every placement in the castle, with the template it belongs to.

    The one walk both directions want, so neither has to remember that a
    template is now a list under its name.
    """
    for group in GROUPS:
        for name, pieces in atlas[group].items():
            for index, piece in enumerate(pieces):
                yield group, name, index, piece


# --- writing it out --------------------------------------------------------

def _scalar(value):
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, str):
        return '"%s"' % value
    if isinstance(value, list):
        # One line, the way JSON spells it: str() would write a Python list,
        # quoted with apostrophes, which no JSON reader takes.
        return "[%s]" % ", ".join(_scalar(item) for item in value)
    return str(value)


def _flat(said, keys=None):
    """A mapping on one line, in the order its keys were written."""
    return "{ %s }" % ", ".join(
        '"%s": %s' % (key, _scalar(said[key]))
        for key in (keys or said))


def _piece(piece, pad):
    """One placement: its graphic and where it goes, then its named bits.

    The record first, because that is what you read down a column of them for,
    and the flags and the nudge after, each kept whole on a line of its own.
    """
    head = ['"graphic": %s' % _scalar(piece["graphic"])]
    for key in ("u", "v", "z", "sizeU", "sizeV", "sizeZ"):
        if key in piece:
            head.append('"%s": %s' % (key, _scalar(piece[key])))

    lines = ["%s{ %s" % (pad, ", ".join(head))]
    tail = ['"%s": %s' % (key, _flat(piece[key]))
            for key in ("flags", "offsets") if key in piece]
    for i, cell in enumerate(tail):
        lines[-1] += ","
        lines.append("%s  %s" % (pad, cell))
    lines[-1] += " }"
    return lines


def format_rooms(atlas):
    """rooms.json, in the layout described at the top of this module."""
    out = ['{', ' "meta": %s,' % _block(atlas["meta"], 1), '']

    out.append(' "roomDimensions": {')
    shapes = list(atlas["roomDimensions"])
    width = max(len(name) for name in shapes) + 3
    for i, name in enumerate(shapes):
        out.append('  %-*s %s%s' % (width, '"%s":' % name,
                                    _flat(atlas["roomDimensions"][name]),
                                    "," if i < len(shapes) - 1 else ""))
    out.append(' },')

    out.append('')
    out.append(' "rooms": [')
    rooms = atlas["rooms"]
    for i, room in enumerate(rooms):
        out.extend(_room(room, "  "))
        if i < len(rooms) - 1:
            out[-1] += ","
    out.append(' ]')
    out.append('}')
    return "\n".join(out) + "\n"


def format_templates(atlas):
    """templates.json, the same way: a template to a name, a piece to a line."""
    out = ['{', ' "meta": %s,' % _block(templates_meta(atlas), 1)]

    for n, group in enumerate(GROUPS):
        out.append('')
        out.append(' "%s": {' % group)
        names = list(atlas[group])
        for i, name in enumerate(names):
            pieces = atlas[group][name]
            if not pieces:
                out.append('  "%s": []%s'
                           % (name, "," if i < len(names) - 1 else ""))
                continue
            out.append('  "%s": [' % name)
            for j, piece in enumerate(pieces):
                lines = _piece(piece, "   ")
                if j < len(pieces) - 1:
                    lines[-1] += ","
                out.extend(lines)
            out.append('  ]%s' % ("," if i < len(names) - 1 else ""))
        out.append(' }%s' % ("," if n < len(GROUPS) - 1 else ""))

    out.append('}')
    return "\n".join(out) + "\n"


def _room(room, pad):
    """One room: what it is on a line, then what stands in it."""
    head = [key for key in ("number", "ink", "dimensions", "sky") if key in room]
    lines = ["%s{ %s," % (pad, ", ".join('"%s": %s' % (k, _scalar(room[k]))
                                         for k in head))]

    scenery = room.get("scenery") or []
    if scenery:
        lines.append('%s  "scenery": [' % pad)
        for i, ref in enumerate(scenery):
            lines.append('%s   %s%s' % (pad, _flat(ref),
                                        "," if i < len(scenery) - 1 else ""))
        lines.append('%s  ],' % pad)
    else:
        lines.append('%s  "scenery": [],' % pad)

    objects = room.get("objects") or []
    if not objects:
        lines.append('%s  "objects": []' % pad)
        lines.append("%s}" % pad)
        return lines

    lines.append('%s  "objects": [' % pad)
    for i, group in enumerate(objects):
        spots = group["positions"]
        lines.append('%s   { "template": %s, "positions": ['
                     % (pad, _scalar(group["template"])))
        for j, spot in enumerate(spots):
            lines.append('%s    %s%s' % (pad, _flat(spot),
                                         "," if j < len(spots) - 1 else ""))
        lines.append('%s   ] }%s' % (pad, "," if i < len(objects) - 1 else ""))
    lines.append('%s  ]' % pad)
    lines.append("%s}" % pad)
    return lines


def _block(said, depth):
    """A nested mapping, one key to a line: the meta block and nothing else."""
    pad = " " * depth
    lines = ["{"]
    keys = list(said)
    for i, key in enumerate(keys):
        comma = "," if i < len(keys) - 1 else ""
        if isinstance(said[key], dict):
            lines.append('%s "%s": %s%s'
                         % (pad, key, _block(said[key], depth + 1), comma))
        else:
            lines.append('%s "%s": %s%s' % (pad, key, _scalar(said[key]), comma))
    lines.append("%s}" % pad)
    return "\n".join(lines)


# --- doorways --------------------------------------------------------------

# Which scenery templates are a way out of a room, and which wall they stand
# in. Decided by the template's POSITION in the table, because that is how the
# games decide it: Knight Lore's room_build.s tests the index (`cp 8`, then the
# two high arches), and Pentagram's room builder reads a destination byte after
# exactly the scenery indices listed here. The names say the same thing today
# -- scenery_arch_e, door_b_n -- but a name can be edited and the game's code
# cannot, so the name is never trusted for this.
SIDES = ("n", "e", "s", "w")

DOORWAYS = {
    # indices 0-7: the arches, plain and among the trees, side in bits 0-1;
    # 20 and 21: the two high arches, which only face east and south.
    "knightlore": dict([(i, SIDES[i & 3]) for i in range(8)]
                       + [(20, "e"), (21, "s")]),
    # rooms.py's DOOR_INDICES: three sets of four, side in bits 0-1.
    "pentagram": dict((i, SIDES[i & 3])
                      for i in tuple(range(8)) + (24, 25, 26, 27)),
}


def side_of(atlas, name):
    """The wall a scenery template stands in, or None if it is not a doorway.

    A castle whose templates.json says which of its templates are doorways --
    meta.doorways, template name to wall -- is taken at its word, and then any
    template can be one; knightlore128's builder reads a table made from it.
    The two games whose builders test the index fall back to DOORWAYS."""
    said = (atlas.get("templatesMeta") or {}).get("doorways")
    if said is not None:
        return said.get(name)
    rule = DOORWAYS.get((atlas.get("meta") or {}).get("game"), {})
    for index, key in enumerate(atlas["sceneryTemplates"]):
        if key == name:
            return rule.get(index)
    return None
