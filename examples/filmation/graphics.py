"""What a game's graphic numbers are called, from its sprite sheet.

A template entry's first byte is a GRAPHIC NUMBER: the game's own index, and
what room_data.s has to carry. rooms.json names it instead, because a number
says nothing about what a piece is, and this is the one place that turns one
into the other -- rooms.py names them on the way out and rooms_source.py puts
the numbers back on the way in, both games, so the rule cannot drift between
the four of them and leave a castle built from the wrong pieces.

The names come from the sheet, which is where the artwork already has some.
sprite_sheet.py numbers the sheet the way the game numbers its graphics, so
graphicMap is the game's own mapping rather than an invention.

Several graphic numbers can share one frame -- 186 valid graphics over 103
sprites, in Knight Lore -- and they are NOT interchangeable: the pixel nudge is
per graphic number, and graphics 30 and 150 draw the same bitmap four rows
apart. So a shared frame's name takes the number with it -- knight.legs.1.g144
-- and every name is one graphic.

The names are seeded from the sprites when the sheet is first written and
stored in it after that, so they are a graphic's own. Pointing a graphic at a
different bitmap is not a rename.

The sheet is gitignored and made by build.py from the packed sprite data, which
is also gitignored -- so a tree that can build the game has one, and a tree that
cannot has no room data to emit either. vscode/room_render.js derives
the same names for the designer, and vscode/tests/room_model_test.js holds the two
together.
"""
import json
from pathlib import Path

import castle

SHEET = "sprites.json"
TABLE = "graphics.json"


def _read(game_dir, leaf):
    path = Path(game_dir) / leaf
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return None


def _sheet(game_dir):
    return _read(game_dir, SHEET)


def sprite_names(sheet):
    """Every sprite the sheet holds, by the path its group tree gives it.

    A sprite's name IS where it sits: sabreman.legs.1 is the sprite called "1"
    in the group "legs" inside the group "sabreman". Nothing carries a dotted
    name, so this is the only place that spells one out.
    """
    out = []

    def walk(node, path):
        for key in (node.get("sprites") or {}):
            out.append(".".join(path + [key]))
        for group, sub in (node.get("group") or {}).items():
            walk(sub, path + [group])

    walk(sheet or {}, [])
    return out


def names(game_dir):
    """graphic number -> name, for every graphic that draws something.

    Empty when there is no table; the caller says what that means for it.

    A graphic's name is the key it sits under in graphics.json, and the number
    the game knows it by is a field there. It used to be the other way round --
    keyed by number, with the name worked out from the sprite -- and rooms.json
    then referred to graphics by a name that appeared in no file at all, so
    searching for one found nothing and a reference could not be checked by
    eye. The names are still SEEDED by that rule when the table is first
    written; after that they are the file's, and renaming one is an edit.
    """
    table = _read(game_dir, TABLE)
    if table is None:
        return {}
    out = {}
    for name, entry in (table.get("graphics") or {}).items():
        if entry.get("sprite") is not None:
            out[entry["number"]] = name
    return out


def seeded_names(table, known):
    """The names a table gets when it is first written, from the sprites.

    A graphic is named after the sprite it draws. Where several draw one sprite
    -- 42 of them do, in Knight Lore -- the number goes on the end, because
    they are NOT interchangeable: the nudge is per graphic, and 30 and 150 put
    the same bitmap four rows apart.
    """
    drawn = {}
    for number, sprite in table.items():
        if isinstance(sprite, str) and sprite in known:
            drawn[number] = sprite

    sharing = {}
    for graphic, sprite in drawn.items():
        sharing.setdefault(sprite, []).append(graphic)

    return {graphic: sprite if len(sharing[sprite]) == 1
            else "%s.g%d" % (sprite, graphic)
            for graphic, sprite in drawn.items()}


def numbers(game_dir):
    """...and back: name -> graphic number.

    Two graphics with the same name would quietly collapse into one here, and a
    castle naming it would be built from whichever won -- the wrong piece, with
    nothing said. sprite_sheet.py cannot produce a duplicate (a label is its
    group's name and the sprite's, and a sprite belongs to one group), so one
    can only come from an edited sheet, and it is worth stopping for.
    """
    taken = {}
    for graphic, name in names(game_dir).items():
        if name in taken:
            raise SystemExit(
                "%s gives graphics %d and %d the same name, %r.\n"
                "A name has to mean one graphic: they are not interchangeable, "
                "since the pixel nudge in %s is per graphic number." % TABLE
                % (SHEET, taken[name], graphic, name))
        taken[name] = graphic
    return taken


def name_of(known, graphic):
    """A graphic's name, or one made from its number.

    A template can name a graphic the sheet has no artwork for -- four of
    Pentagram's do, and they are templates no room places -- and a castle still
    has to be able to say what it is built from.
    """
    return known.get(graphic, "gfx_%02X" % graphic)


def number_of(known, name, whose):
    """...and the number back, or a plain failure naming what asked.

    Nothing guesses here. A name with no number cannot go in a record, and
    emitting the wrong one would build a castle out of the wrong pieces.
    """
    if name in known:
        return known[name]
    if name.startswith("gfx_"):
        try:
            return int(name[4:], 16)
        except ValueError:
            pass
    raise SystemExit(
        "%s names the graphic %r, which %s does not have.\n"
        "A graphic's name is the key it sits under there. If you renamed one, "
        "rename it everywhere that refers to it; if the table has not been "
        "written yet, run the game's build.py once."
        % (whose, name, TABLE))


def sizes(game_dir):
    """graphic name -> its collision box, as {"u": .., "v": .., "z": ..}.

    The box a piece occupies in the world: half-widths along the two ground
    axes and a height, which is what the engine sorts and collides with. It
    belongs to the graphic rather than to the template that places one, so it
    lives in graphics.json beside the nudge -- rooms.json used to repeat it on
    every entry, and 120 Knight Lore entries said 39 distinct things.

    Stored UNMIRRORED. Mirroring reflects a piece across the isometric axis, so
    the two ground axes trade places and U and V swap; the height never
    changes. Every doorway in both games is placed both ways round, which is
    why the file cannot simply state the box as it is drawn.

    Empty when there is no table; the caller says what that means for it.
    """
    table = _read(game_dir, TABLE)
    if table is None:
        return {}
    out = {}
    for name, entry in (table.get("graphics") or {}).items():
        box = entry.get("size")
        if box is not None:
            out[name] = {"u": box["u"], "v": box["v"], "z": box["z"]}
    return out


def box_of(known_sizes, entry, whose):
    """The box a template entry occupies, the way round that entry sits.

    An entry may carry sizeU/sizeV/sizeZ of its own, and then it means them:
    that is the override for a piece whose box is not its graphic's. Knight
    Lore has one real case -- the blank, passable, zero-height second entry of
    a guard template, which is the guard's patrol extent rather than a shape --
    and Pentagram has four in templates no room places.

    Otherwise the box comes from the graphic, swapped if the entry is mirrored.
    """
    if "sizeU" in entry:
        return {"u": entry["sizeU"], "v": entry["sizeV"], "z": entry["sizeZ"]}
    name = entry["graphic"]
    box = known_sizes.get(name)
    if box is None:
        raise SystemExit(
            "%s places the graphic %r, which %s gives no size.\n"
            "A template entry needs a box: either give the graphic a \"size\" "
            "there, or put sizeU/sizeV/sizeZ on the entry itself."
            % (whose, name, TABLE))
    if (entry.get("flags") or {}).get("mirrored"):
        return {"u": box["v"], "v": box["u"], "z": box["z"]}
    return dict(box)


def format_table(entries, sheet_leaf=SHEET):
    """graphics.json as text: one graphic to a line, with the columns lined up.

    Two scripts write this file -- sprite_sheet.py says which sprite each
    number draws and how to nudge it, rooms.py adds the box it occupies -- so
    the layout lives here rather than in whichever of them ran last. It is a
    file people edit by hand, and a rewrite that reflowed every line would bury
    the one graphic that actually changed.

    `entries` maps a graphic's NAME to what the file says about it, using the
    file's own key names. A field that is absent stays absent; x and y are
    dropped when zero, because the overwhelming majority are.

    Written in the game's own table order, which is what `number` holds: the
    file reads down the table the way the game indexes it, however the names
    are later changed around.
    """
    rows = []
    for name in sorted(entries, key=lambda k: entries[k]["number"]):
        said = entries[name]
        cells = ['"number": %3d' % said["number"]]
        if said.get("sprite"):
            cells.append('"sprite": "%s"' % said["sprite"])
        box = said.get("size")
        if box is not None:
            cells.append('"size": { "u": %d, "v": %d, "z": %d }'
                         % (box["u"], box["v"], box["z"]))
        if said.get("x"):
            cells.append('"x": %d' % said["x"])
        if said.get("y"):
            cells.append('"y": %d' % said["y"])
        mirrored = said.get("mirrored")
        if mirrored:
            cells.append('"mirrored": { "x": %d, "y": %d }'
                         % (mirrored["x"], mirrored["y"]))
        rows.append((name, cells))

    if not rows:
        return '{\n "sprites": "%s",\n "graphics": {\n }\n}\n' % sheet_leaf

    def column(prefix):
        return max((len(c) for _, cells in rows for c in cells[:3]
                    if c.startswith(prefix)), default=0)

    name_width = max(len(n) for n, _ in rows)
    widths = {'"sprite"': column('"sprite"'), '"size"': column('"size"')}
    lines = ["{", ' "sprites": "%s",' % sheet_leaf, ' "graphics": {']
    for i, (name, cells) in enumerate(rows):
        # Only the leading fields are padded into columns. The nudge trails off
        # the end, where lining it up would cost more spaces than it repays.
        for j, cell in enumerate(cells[:3]):
            for prefix, width in widths.items():
                if cell.startswith(prefix):
                    cells[j] = "%-*s" % (width, cell)
        lines.append('  %-*s { %s }%s'
                     % (name_width + 3, '"%s":' % name, ", ".join(cells),
                        "," if i < len(rows) - 1 else ""))
    lines += [" }", "}"]
    return "\n".join(lines) + "\n"


def fold_sizes(game_dir, atlas):
    """Move the boxes out of a freshly decoded castle and into graphics.json.

    rooms.py decodes a template entry's box along with the rest of its record,
    because that is where the game keeps it -- but the box belongs to the
    GRAPHIC, and repeating it on every entry is how rooms.json came to say the
    same thing 120 times. So it is folded in here, once, as the castle is
    written: the graphic gets a "size", and the entry keeps one only where it
    means something the graphic does not.

    Two things stop that being a clean sweep.

    Mirroring reflects a piece across the isometric axis, so U and V trade
    places; the box is stored the unmirrored way round and swapped back on the
    way out. Every doorway in both games is placed both ways.

    And an entry can hold bytes that are not a box at all. Knight Lore's guard
    templates carry a blank, passable, zero-height second entry whose U and V
    are the guard's patrol extent; Pentagram has four templates no room places,
    whose records decode into nonsense. Those keep their own numbers, which is
    also why the base is taken from the templates rooms DO place -- by count,
    the nonsense would outvote the real thing.

    Returns the entries that kept a box of their own, for the caller to report.
    """
    known = numbers(game_dir)

    placed = set()
    for room in atlas.get("rooms", []):
        for key in ("scenery", "objects"):
            for item in room.get(key) or []:
                placed.add(item["template"])

    def unmirrored(entry):
        box = (entry["sizeU"], entry["sizeV"], entry["sizeZ"])
        return (box[1], box[0], box[2]) if entry["flags"]["mirrored"] else box

    live, seen = {}, {}
    for _group, template, _at, entry in castle.placements(atlas):
        box = unmirrored(entry)
        seen.setdefault(entry["graphic"], []).append(box)
        if template in placed:
            live.setdefault(entry["graphic"], []).append(box)

    def commonest(boxes):
        return max(set(boxes), key=lambda box: (boxes.count(box), box))

    base = {name: commonest(live.get(name) or seen[name]) for name in seen}

    table = _read(game_dir, TABLE) or {"sprites": SHEET, "graphics": {}}
    # Keyed by the graphic's name, which is what a castle refers to it by.
    entries = dict(table.get("graphics") or {})
    for name, box in base.items():
        if known.get(name) is not None and name in entries:
            entries[name]["size"] = {"u": box[0], "v": box[1], "z": box[2]}
    Path(game_dir).joinpath(TABLE).write_text(
        format_table(entries, table.get("sprites", SHEET)), encoding="utf-8")

    kept = []
    for _group, template, _at, entry in castle.placements(atlas):
        # A graphic the sheet has not got cannot be given a size there, so the
        # entry has to go on saying it itself.
        if known.get(entry["graphic"]) is None:
            kept.append((template, entry["graphic"]))
            continue
        want = base[entry["graphic"]]
        if entry["flags"]["mirrored"]:
            want = (want[1], want[0], want[2])
        if (entry["sizeU"], entry["sizeV"], entry["sizeZ"]) == want:
            del entry["sizeU"], entry["sizeV"], entry["sizeZ"]
        else:
            kept.append((template, entry["graphic"]))
    return kept
