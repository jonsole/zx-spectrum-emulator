"""Knight Lore's artwork as a sprite sheet: sprite_data.bin -> sprites.png,
sprites.json and graphics.json, beside this script.

    python sprite_sheet.py

sprite_data.bin is what kl_extract.py lifts out of a real Knight Lore: 103
sprites, each two header bytes then mask and data bytes interleaved, bottom
row first. That is a fine shape for a Z80 to draw from and a poor one to look
at or to edit, so this unpacks it once into a picture and a description:

    sprites.png     every sprite the right way up, each in a one-pixel
                    magenta frame, laid out in bands of related frames --
                    the knight, then each thing that animates, then the
                    panel, then the scenery
    sprites.json    what the picture's colours mean, and where each sprite
                    sits in it, in a tree of named groups
    graphics.json   which sprite each graphic number draws, its pixel nudge
                    and its box -- names, boxes and the harvested nudges are
                    kept from the file already there

sprite_source.py turns them back into sprite_data.s, sprite_table.s,
graphics_gen.s and sprite_adj_gen.s on every build, checking each sprite's
frame as it goes. The round trip is exact, so the files are the artwork's home
from here on: edit the PNG, rebuild, and the game changes. sprite_data.bin is
only ever the seed, and running this again overwrites edits to the picture.

What the sheet looks like and how it is written are ../sheet.py's, shared with
Pentagram. What is here is what only Knight Lore knows: which sprites belong
together, what they are called, what animates and what the engine relies on.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "scripts"))
import sheet                                                    # noqa: E402

HERE = Path(__file__).resolve().parent.parent      # the game's folder
TITLE = "Knight Lore"
EXTRACTOR = "kl_extract.py"
# How many graphic numbers the game has, and so how wide the table is.
# Lightkeep has 512: bit 8 of a graphic is bit 0 of the record's ADJ_Y, and
# the engine's code for it is assembled because this is over 256. 256 and
# 257 are never used, as 0 and 1 are not: the room builder reads a
# template's graphic by its low byte, and 0 ends a template and 1 skips.
GRAPHIC_COUNT = 512

# Knight Lore's graphic numbers, gathered into the bands the sheet is laid out
# in, and the groups sprites.json names them by. A sprite goes in the first band
# that names it and is drawn once, so the later bands hold only what the
# earlier ones left; the last one sweeps up everything no band asked for.
# Several of these are the same groupings sprite_source.py checks -- the
# knight's frames and the animations --
# because seeing an animation's frames side by side is exactly what makes a
# sheet worth having.
# The sparkle Sabreman dies into, and the wizard's spell -- one set of six
# sprites doing both jobs. Either half of him can be wearing it, which is why
# it used to be tacked onto the end of BOTH lists below and so ended up named
# as legs; it is neither, and has a band of its own.
SPELL = list(range(112, 128))
LEG_POSES = list(range(0, 6)) + list(range(8, 14))
SABREMAN_LEGS = [16 + k for k in LEG_POSES]
SABREMAN_BODY = [32 + k for k in range(16)]

# Everything that animates, as sprite_source.py checks it: every frame in a
# group has to rotate into a buffer sized from any other frame in it.
#
# Knight Lore gives some of these twice over -- a guard's legs at 144-157, a
# second fire at 176 and a second ball at 182 -- drawing the same sprites with
# the same nudges. This game draws them from one set, which gave the numbers
# back for new art: a guard walks on the knight's own legs, whose leg bits lay
# out the same way (mover_guard_face in movers.s).
ANIMATIONS = (
    (180, 181), (86, 87),                                   # fires
    (178, 179),                                             # balls
    (150, 151), (30, 31),                                   # torsos
    tuple(SABREMAN_LEGS),                                   # a guard's legs
    (80, 81, 82, 83), (164, 165, 166, 167), (8, 9),         # ghost, spell, gate
    (144, 145, 146, 147),                                   # a torch's flame
)

# Knight Lore 128K also has the werewolf, the twinkle Sabreman turns into him
# through, the sun and moon and their window, Pentagram's art, the wizard and
# the collectables he asks for. Lightkeep has none of them: stages 0c and 0d
# took them out of the sheet and the table.

# What a room is built out of. Knight Lore dresses its rooms two ways -- stone
# castle and forest -- and each has its own walls and its own doorway arch, so
# the same four jobs are done by two sets of sprites.
WALL_CASTLE = (10, 11, 12, 13, 14, 15)   # scenery_walls_0/1/2: three
                                # stones and three pillars, contiguous
WALL_FOREST = (128, 129, 130)   # scenery_trees_0/1/2
DOOR_CASTLE = (2, 3)            # scenery_arch_n/e/s/w, and the high arches
DOOR_FOREST = (4, 5)            # scenery_tree_arch_n/e/s/w

PANEL = (134, 135, 136, 140)    # the chain, the bars, the ends, Sabreman's head
MENU = (137, 138, 139)          # the frame's corner, drawn upside down too;
                                # a run's four pixels; and the bar. MENU_SIDE_BITS
                                # and MENU_BAR_ROWS in menu.s name the last two.

# Sprites that keep their blank bottom rows, because the code that draws them
# knows its own height rather than asking object_update for it.
#
# NOT the same set as the four groups above, though it nearly is: the menu's
# corner is drawn whole, but its side and bar are drawn a fixed number of rows
# in, so whatever is under that never matters and they trim like anything
# else. What a sprite IS and how it is DRAWN are different questions.
WHOLE_SPRITE_GRAPHICS = PANEL + (137,)

# The knight keeps two rotation buffers for life, sized from these two
# sprites, named as sprites.json names them; every frame the matching half can
# wear has to fit. With the werewolf gone, the legs' largest is the sparkle and
# the body's is Sabreman's own seventh frame, a row taller than it.
# The sparkle is in both, though it is in neither band: a half wearing it has
# to fit the buffer it already has, and taking it out of the lists above is
# about where it is DRAWN on the sheet, not about what a buffer must hold.
ROTATION_BUFFERS = (
    ("CHARACTER_LARGEST", "spell.1", SABREMAN_LEGS + SPELL),
    ("CHARACTER_TALLEST", "sabreman.body.7", SABREMAN_BODY + SPELL),
)

# The groups a sprite can be in, and what they claim.
#
# A band is (name, what it is called on the picture, the graphics it claims),
# and a fourth element makes it a parent: its children are bands in their own
# right and their names hang off its own. So the tree below names a sprite
# knight.legs.1 -- the path to its group, then which one it is within that
# group, counting from one.
#
# Nesting is only about the name and the picture's headings. Everything
# downstream sees the flattened list, in the order written here, which is the
# order the picture is laid out in and the order the atlas reads.
#
# A sprite belongs to the FIRST band that claims it, so the order matters where
# two would claim the same one -- and the last leaf sweeps up whatever no band
# asked for.
BANDS = (
    ("sabreman", "Sabreman", (), (
        ("legs", "Sabreman's legs", SABREMAN_LEGS),
        ("body", "Sabreman's body", SABREMAN_BODY),
    )),
    # A guard's legs are Sabreman's own -- graphics 144 to 157 name sprites
    # 55 to 62, which sabreman.legs has already taken -- so they have no band of
    # their own, and editing the knight's walk changes theirs with it.
    ("guard", "the guard's torso", (150, 151, 30, 31)),
    ("spell", "the spell, and the sparkle Sabreman dies into", SPELL),
    ("fires", "fires", (176, 177, 180, 181, 86, 87)),
    ("balls", "balls", (178, 179, 182, 183)),
    ("ghost", "the ghost", (80, 81, 82, 83)),
    ("gate", "the portcullis", (8, 9)),
    ("panel", "the status panel", PANEL),
    ("menu", "the menu's frame", MENU),
    ("wall", "what closes a room in", (), (
        ("castle", "stone walls", WALL_CASTLE),
        ("forest", "trees", WALL_FOREST),
    )),
    ("door", "what you walk through", (), (
        ("castle", "stone arches", DOOR_CASTLE),
        ("forest", "tree arches", DOOR_FOREST),
    )),
    ("scenery", "scenery", ()),         # and the sweep-up
)

# What a sprite is CALLED, where a number will not do. The key is any graphic
# that draws it; the sprite it lands on takes the name, whatever band claims it
# and wherever it falls in that band. Everything unnamed is numbered within its
# group instead, which is all most of them need -- sabreman.legs.3 says enough.
#
# Add to this rather than editing sprites.json: the sheet is written from here.
SPRITE_NAMES = {
    23: "floor_spike",
    63: "spike_ball",
    6: "wood_block",
    22: "gargoyle",
    7: "block",
    85: "chest",
    84: "table",
    141: "cauldron",
    142: "cauldron_lid",
}

# What each animation is called. Keyed by the sprites it plays, so a set of
# graphics that draws the same animation somewhere else lands on the same name.
ANIMATION_NAMES = {
    ("fires.1", "fires.2"): "fire",
    ("balls.1", "balls.2"): "ball",
    ("guard.1", "guard.2"): "guard",
    ("ghost.1", "ghost.2", "ghost.3", "ghost.4"): "ghost",
    ("gate.1", "gate.1"): "gate",
    ("spell.1", "spell.2", "spell.3", "spell.2"): "spell",
    ("sabreman.legs.1", "sabreman.legs.2", "sabreman.legs.3",
     "sabreman.legs.4", "sabreman.legs.3", "sabreman.legs.2",
     "sabreman.legs.5", "sabreman.legs.6", "sabreman.legs.7",
     "sabreman.legs.8", "sabreman.legs.7", "sabreman.legs.6"): "guard_walk",
}

# Nudges the original sets from a constant rather than per graphic. Knight
# Lore has none; Pentagram does, and the two read the same way.
FIXED_NUDGES = {}

# Graphic 1 is Knight Lore's way of drawing nothing: its own table has no
# bitmap for it, and ours points at a sprite that covers nothing instead.
BLANK_GRAPHIC = 1

# The sprite groups that are loaded room by room on the 128K. They live in the
# library in banks 1, 3 and 7, and a room's are copied into the room page in
# bank 0 as it is entered -- see room_page.s. Every other group is resident: in
# bank 0 for good, because the code draws it by number, in any room -- the
# knight, the spells, the panel and the menu.
#
# A room that names any sprite in one of these groups gets the WHOLE group
# (the name up to its last dot: all of "scenery", all of "wall.castle"). That
# is what covers a mover or a piece of scenery that changes its graphic within
# its own group -- a fire's two frames, the cauldron and its lid -- without a
# list of which graphics each one cycles through. Nothing here is drawn by the
# code except as a frame of something a room placed; a graphic that is would
# show the placeholder sprite_missing instead, and must move to a resident
# group.
#
# "pentagram" is all of Pentagram's art, merged in by pentagram_merge.py: its
# walls and archways, its scenery, its creatures and the things its mechanics
# put up. Its groups (pentagram.wall.trees, pentagram.block ...) are what a room
# loads whole. Anything of it the code comes to draw in any room moves out to
# a resident group then.
ROOM_GROUPS = ("wall", "door", "scenery", "guard", "fires", "balls",
               "ghost", "gate", "pentagram", "castle")


def main():
    sheet.make(sys.modules[__name__])


if __name__ == "__main__":
    main()
