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
sprites, in Knight Lore -- and they are NOT interchangeable: the pixel nudge
in sprite_adj.s is per graphic number, and graphics 30 and 150 draw the same
bitmap four rows apart. So a shared frame's name takes the number with it -- knight.legs.1.g144 --
and every name is one graphic.

The sheet is gitignored and made by build.py from the packed sprite data, which
is also gitignored -- so a tree that can build the game has one, and a tree that
cannot has no room data to emit either. vscode-extension/room_render.js derives
the same names for the designer, and tests/room_model_test.js holds the two
together.
"""
import json
from pathlib import Path

SHEET = "sprites.json"


def _sheet(game_dir):
    path = Path(game_dir) / SHEET
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (ValueError, OSError):
        return None


def names(game_dir):
    """graphic number -> name, for every graphic the sheet can draw.

    Empty when there is no sheet; the caller says what that means for it.
    """
    sheet = _sheet(game_dir)
    if sheet is None:
        return {}
    try:
        gmap = sheet["meta"]["zx"]["game"]["graphicMap"]
        sprites = sheet["meta"]["zx"]["sprites"]
    except KeyError:
        return {}

    sharing = {}
    for graphic, n in enumerate(gmap):
        if n is not None:
            sharing.setdefault(n, []).append(graphic)

    out = {}
    for graphic, n in enumerate(gmap):
        if n is None or n >= len(sprites):
            continue
        label = sprites[n]["label"]
        out[graphic] = label if len(sharing[n]) == 1 else "%s.g%d" % (label, graphic)
    return out


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
                "since the pixel nudge in sprite_adj.s is per graphic number."
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
        "The names come from the sprite sheet: run the game's build.py once to "
        "unpack it, or rerun rooms.py if the sheet's own names have changed."
        % (whose, name, SHEET))
