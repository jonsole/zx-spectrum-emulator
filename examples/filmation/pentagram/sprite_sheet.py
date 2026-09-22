"""Pentagram's artwork as a sprite sheet: sprite_data.bin -> sprites.png,
sprites.json and graphics.json, beside this script.

    python sprite_sheet.py

sprite_data.bin is what pg_extract.py lifts out of a real Pentagram: 88
sprites, each two header bytes then mask and data bytes interleaved, bottom
row first. That is a fine shape for a Z80 to draw from and a poor one to look
at or to edit, so this unpacks it once into a picture and a description:

    sprites.png     every sprite the right way up, each in a one-pixel
                    magenta frame -- one band of them for now, until
                    Pentagram's are worked out and grouped
    sprites.json    what the picture's colours mean, and where each sprite
                    sits in it
    graphics.json   which sprite each graphic number draws, its pixel nudge
                    and its box -- names, boxes and the harvested nudges are
                    kept from the file already there

sprite_source.py turns them back into sprite_data.s, sprite_table.s and
sprite_adj_gen.s on every build, checking each sprite's frame as it goes. The
round trip is exact, so the files are the artwork's home from here on: edit
the PNG, rebuild, and the game changes. sprite_data.bin is only ever the
seed, and running this again overwrites edits to the picture.

What the sheet looks like and how it is written are ../sheet.py's, shared with
Knight Lore. What is here is what only Pentagram knows.
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import sheet                                                    # noqa: E402

HERE = Path(__file__).resolve().parent
TITLE = "Pentagram"
EXTRACTOR = "pg_extract.py"
# How many graphic numbers the game has, and so how wide the table is.
GRAPHIC_COUNT = 172

# What a sprite or an animation is called, where a number will not do. Knight
# Lore's are filled in; Pentagram's pieces have not been identified yet, so
# every sprite is numbered within its group and nothing is named.
SPRITE_NAMES = {}
ANIMATION_NAMES = {}

# Pentagram's graphic numbers, gathered into the bands the sheet is laid out
# in, and the groups sprites.json names them by. A sprite goes in the first band
# that names it and is drawn once, so the later bands hold only what the
# earlier ones left; the last one sweeps up everything no band asked for.
# Several of these are the same groupings sprite_source.py checks -- the
# knight's frames and the animations --
# because seeing an animation's frames side by side is exactly what makes a
# sheet worth having.
# None of Pentagram's groupings are known yet. Knight Lore's were worked out
# by looking at its sheet and at what its code does with each graphic; the same
# has to be done here before the sheet is worth grouping, and before any of
# this can be handed to sprite_source.py's checks. Until then the sheet lays
# every sprite out in one band, which is enough to look at them.
#
# What still has to be filled in -- ROTATION_BUFFERS is done, below:
#   ANIMATIONS            frames that must share a rotation buffer's size
#   WHOLE_SPRITE_GRAPHICS sprites drawn without asking object_update, which
#                         therefore keep their blank bottom rows
#   ROTATION_BUFFERS      the two buffers the character keeps for life, which
#                         are what CHARACTER_LARGEST and CHARACTER_TALLEST
#                         come from
#   BLANK_GRAPHIC         the graphic the game draws nothing with, if it has
#                         one; Knight Lore's is graphic 1
# Sabreman, as the original was watched wearing him: four frames a block,
# two blocks a half -- 32-35 walking away from the viewer and 36-39 towards
# it for his legs, 40-43 and 44-47 for his body. Mirroring makes the other two
# facings, so there is no third block.
SABREMAN_LEGS = tuple(range(32, 40))
SABREMAN_BODY = tuple(range(40, 48))
SABREMAN_POOF = tuple(range(64, 71))    # both halves wear the puff he dies in

# Nudges the original sets from a constant, every turn, rather than per
# graphic -- so the harvest, which reads live records, can catch a frame just
# as it changed and still wearing the last routine's pair. The puff is the
# case that shows: $C111 calls $C77A on every one of its frames, which is
# always -12, -4, but the harvest had three different pairs across 64-70 and
# the puff hopped about as it played. These are written into graphics.json in
# place of whatever was harvested.
FIXED_NUDGES = {g: (-12, -4) for g in range(64, 72)}    # $C77A
# The crumbling blocks and the conveyors: $D2AD-$D2FF all call $C75F, -16, -8,
# every turn. 137-139 are only ever seen crumbling, so the harvest had them at
# nothing, and each crack jumped the block sixteen pixels right; 141 likewise.
FIXED_NUDGES.update({g: (-16, -8) for g in range(136, 144)})
# The quest's things likewise call $C75F: the bucket ($D0AC), the quest items
# and their done forms ($CF68), the pentagram's pieces ($CF14) and the
# collectables ($CD16). None is in a room as a new game starts but the
# collectables, and the harvest found only three of those, so the rest were
# drawn sixteen pixels right and eight low. A collectable put in its place
# becomes 152-156, whose routine ($CB4E) sets nothing: it keeps the nudge it
# had, so they have it too.
FIXED_NUDGES.update({g: (-16, -8) for g in [90] + list(range(112, 120))
                     + list(range(128, 136)) + list(range(144, 149))
                     + list(range(152, 157))})

ANIMATIONS = ()
# Drawn straight onto the screen with screen_sprite, which takes no pixel
# nudge and so cannot make up for blank rows trimmed off the bottom: the
# panel's pieces and the little Sabreman by the lives, and the game-over
# frame, whose 3 and 4 lost four rows each to the trim and drew that low.
WHOLE_SPRITE_GRAPHICS = (22, 58, 59, 60, 61, 62, 2, 3, 4, 5,
                         90, 144, 145, 146, 147, 148)    # and what he carries

# The two rotation buffers Sabreman keeps for life, sized from these sprites;
# every frame the matching half can wear has to fit, and sprite_source.py
# fails the build if one does not.
ROTATION_BUFFERS = (
    ("CHARACTER_LARGEST", 66, SABREMAN_LEGS + SABREMAN_POOF),
    ("CHARACTER_TALLEST", 61, SABREMAN_BODY + SABREMAN_POOF),
)

# One sweep-up band for now. A band is (name, what it is called on the picture, the graphics it claims),
# and a fourth element makes it a parent: its children hang their names off its
# own, so a sprite is named by the path to its group and then which one it is
# within that group -- sprites.1, or knight.legs.1 in Knight Lore's, whose
# sprite_sheet.py does the same.
#
# Pentagram's pieces have not been identified, so there is one group and the
# names are its index. Splitting it is a matter of writing the tree here.
BANDS = (
    ("sprites", "sprites", ()),
)

# Pentagram names 170 graphics; twenty-nine of them resolve to no sprite at
# all, in runs at 14-15, 22-25, 81, 87, 92-109 and 155-157. Whether one of
# those is the game's own "draw nothing" is not yet established, so nothing
# is claimed here.
BLANK_GRAPHIC = None


def main():
    sheet.make(sys.modules[__name__])


if __name__ == "__main__":
    main()
