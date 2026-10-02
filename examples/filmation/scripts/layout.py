"""Where things are in a Filmation game's folder.

Every game keeps the same shape:

    <game>/build.py     the one command: assembles the game
    <game>/*.s          the game's own assembler, hand-written
    <game>/scripts/     the Python that makes and checks its data
    <game>/metadata/    the JSON: rooms, templates, the graphic table, the
                        sprite sheet's rectangles, the charms -- what you edit
    <game>/art/         the pictures you edit: the sprite sheet
    <game>/generated/   the .s the build writes from metadata/ and art/, never
                        edited and never committed
    <game>/extracted/   what an extractor pulled out of your own copy of the
                        original, never committed
    <game>/output/      what the build makes: the snapshot, the SLD, the listing
    <game>/tests/       its Z80 unit tests

The shared Python -- this file, castle.py, sheet.py, graphics.py and the rest --
is in examples/filmation/scripts/.

A folder with no metadata/ in it is taken to be laid out flat: its JSON, its
pictures, what was extracted and what is generated, all at the top. That is
how game-disassemblies' room tools hand over a castle of their own --
knightlore_rooms.py points the extractor and the sheet maker at one -- and it
keeps every reader and writer here working on one.
"""

from pathlib import Path

FILMATION = Path(__file__).resolve().parent.parent

METADATA = "metadata"
ART = "art"
GENERATED = "generated"
EXTRACTED = "extracted"
SCRIPTS = "scripts"


def game_dir(name):
    """A game's folder, from its name: examples/filmation/<name>."""
    return FILMATION / name


def flat(game):
    """Whether a folder is laid out flat: everything at its top, no metadata/."""
    return not (Path(game) / METADATA).is_dir()


def _in(game, folder):
    here = Path(game)
    return here if flat(here) else here / folder


def picture(game, name):
    """How the JSON names one of a game's pictures: relative to metadata/,
    where the JSON is, so ../art/<name> -- or, in a flat folder, just <name>."""
    return name if flat(game) else "../" + ART + "/" + name


def metadata(game):
    """Where a game's JSON is."""
    return _in(game, METADATA)


def art(game):
    """Where a game's pictures are."""
    return _in(game, ART)


def generated(game):
    """Where the build writes a game's generated source. Gitignored, so it
    may not be there yet: whatever writes into it makes it."""
    return _in(game, GENERATED)


def extracted(game):
    """Where a game's extractor leaves what it pulled from the original.
    Gitignored, so it may not be there yet: the extractor makes it."""
    return _in(game, EXTRACTED)
