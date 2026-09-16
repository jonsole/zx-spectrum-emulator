import io
import sys
from pathlib import Path

# The two halves of the output go to different places in the image. The table
# has to be ALIGNed to its own 512 bytes, and when it comes last that
# alignment lands between the bitmaps and the table as padding -- 308 bytes of
# it, and it swallows anything saved anywhere else in the image, since the
# total is rounded up to a boundary either way. Emitted separately, the table
# goes where a 512 boundary already falls and the bitmaps go last, with
# nothing after them that has to be aligned.
#
#   python sprites.py table     the graphic-number table alone
#   python sprites.py bitmaps   the sprites alone
#   python sprites.py adj       the pixel adjustments, with the trims folded in
#   python sprites.py           all three, bitmaps first, for reading by hand
part = sys.argv[1] if len(sys.argv) > 1 else "all"
bitmaps = io.StringIO()
console, sys.stdout = sys.stdout, bitmaps

# Four places draw a sprite without asking object_update for it, and each one
# knows how tall it is: the panel's pieces and the menu's frame hang from a row
# of their own, and the sun window walks its disc sixteen rows down and its
# frame six bytes a row for all thirty-one. A sprite of theirs that lost rows
# here would slide down its anchor or read past its end, and no adjustment
# would put it back -- the frame's corner is drawn upside down as well, which
# no adjustment could ever answer for. They keep their blank rows.
WHOLE_SPRITE_GRAPHICS = (
    88, 96,             # the sun and the moon, sixteen rows in sun_place
    90, 186,            # the window's frame, indexed by row in sun_draw
    134, 135, 136, 140, # the panel's chain, bars, ends and the knight's head
    137,                # the menu's frame: its corner, drawn upside down too
)
gmap = Path('graphic_map.bin').read_bytes()
whole_sprites = {gmap[g] for g in WHOLE_SPRITE_GRAPHICS}

# Everything else that animates gets its buffer the first time it needs one,
# sized from the frame it happens to be showing -- so every frame an object can
# go on to show has to fit a buffer sized from any other. The trim leaves the
# frames of one animation different heights; shift_alloc's rounding to eights
# is what brings them back together, and this is where that is checked. The
# groups are the movers': a flicker pair, a guard's torso and its walking legs,
# the ghost's four faces, the spell's four frames, the gate, and the wizard.
# (Collectables and what rises from the pot are given one size up front.)
# Their sprites carry bit 7 of byte 0, which is what tells shift_alloc to
# round; scenery keeps its buffers exact.
ANIMATIONS = (
    (176, 177), (180, 181), (86, 87),                       # fires
    (178, 179), (182, 183),                                 # balls
    (150, 151), (30, 31), (158, 159),                       # torsos, wizard's legs
    tuple(range(144, 150)) + tuple(range(152, 158)),        # a guard's legs
    (80, 81, 82, 83), (164, 165, 166, 167), (8, 9),         # ghost, spell, gate
)
animated_sprites = {gmap[g] for frames in ANIMATIONS for g in frames}

f_data = Path('sprite_data.bin').read_bytes()

spr_num = 0
spr_list = []
spr_trim = []               # blank rows taken off the bottom of each sprite
spr_widths = []             # and what is left of each, for the checks below
spr_heights = []
while f_data:

    spr_w_f = f_data[0]
    spr_h = f_data[1]
    f_data = f_data[2:]

    spr_w = spr_w_f & 0x1f

    spr_list.append("sprite_{:03}".format(spr_num))
    print("\t\t\tALIGN 4") # we can align on 4 byte boundary so we can use INC L / DEC L to move between width, height and start of mask/data
    print(spr_list[-1]+':')
    spr_num += 1

    #print("\t\t\tDB\t{},{}".format(spr_w * 8, spr_h))
    # The blit index, not a width: (width - 2) scaled by the stride of a
    # sprite_jump_table group, which puts the width class in bits 4 to 6
    # and leaves bit 0 for the mirrored flag.
    num_bytes = spr_w * spr_h * 2
    spr_bytes = f_data[:num_bytes]

    spr_mask_bytes = list(spr_bytes[0::2])     # mask
    spr_data_bytes = list(spr_bytes[1::2])     # data

    # split sprite data and mask into rows
    spr_mask_list = [spr_mask_bytes[i : i + spr_w] for i in range(0, len(spr_mask_bytes), spr_w)]  
    spr_data_list = [spr_data_bytes[i : i + spr_w] for i in range(0, len(spr_data_bytes), spr_w)]  

    # reverse as binary data is upside down (as per usual for Ultimate)
    spr_mask_list.reverse()
    spr_data_list.reverse()

    # Rows at the bottom that cover nothing are 88 rows across 40 of the
    # sprites -- 524 bytes, 536 once the alignment that follows them falls in
    # too -- and every one of them is walked by the blit, by the rotation and
    # by the region the object disturbs. They come off here -- and because a
    # sprite hangs from its bottom row, every graphic drawn with it has that
    # many added to its pixel nudge, which is what the adjustments part below
    # does. At least one row always stays: a sprite of none would draw 256.
    trim = 0
    while (len(spr_trim) not in whole_sprites
           and len(spr_mask_list) - trim > 1
           and all(m == 0 for m in spr_mask_list[-1 - trim])
           and all(d == 0 for d in spr_data_list[-1 - trim])):
        trim += 1
    if trim:
        spr_mask_list = spr_mask_list[:-trim]
        spr_data_list = spr_data_list[:-trim]
    spr_trim.append(trim)
    spr_widths.append(spr_w)
    spr_heights.append(len(spr_mask_list))

    # The blit index, not a width: (width - 2) scaled by the stride of a
    # sprite_jump_table group, which puts the width class in bits 4 to 6
    # and leaves bit 0 for the mirrored flag. The height is what is left of
    # the sprite once its blank bottom rows are off.
    animated = 0x80 if len(spr_trim) - 1 in animated_sprites else 0
    print("\t\t\tDB\t{},{}".format((spr_w - 2) * 16 | animated, len(spr_mask_list)))

    for spr_data,spr_mask in zip(spr_data_list,spr_mask_list):

        # generate comment 
        c = ''        
        for d,m in zip(spr_data, spr_mask):
            m_bits = "{0:08b}".format(255 ^ m)
            d_bits = "{0:08b}".format(d)
            for b in range(0, 8):
                ms = m_bits[b]
                ds = d_bits[b]
                c += '  ' if ms == '1' else '..' if ds == '0' else '##'

        # generate data + mask interleaved
        print('\t\t\tDB\t' + ','.join(['0b{0:08b},0b{1:08b}'.format(255^m,d) for d,m in zip(spr_data, spr_mask)]) + ' ;' + c)                

        #print('\t\t\tDB\t' + ','.join(['0b{0:08b}'.format(x) for x in spr_data]) + ' ;' + c)

    # mask data
    #for spr_data,spr_mask in zip(spr_data_list,spr_mask_list):
    #    print('\t\t\tDB\t' + ','.join(['0b{0:08b}'.format(255 ^ x) for x in spr_mask]))

    f_data = f_data[num_bytes:]

for g in WHOLE_SPRITE_GRAPHICS:
    assert spr_trim[gmap[g]] == 0, "graphic %d was meant to be left whole" % g

# The knight keeps two rotation buffers for life, sized by shift_alloc from two
# named sprites -- CHARACTER_LARGEST and CHARACTER_TALLEST in character.s. The
# trim changes heights, so check that each is still at least as big as every
# frame its half can wear; one that is not gets rotated past its end. The
# frames are character_frame's: a base, a facing block of 0 or 8, and a walk
# phase, or for the body the glance frames that follow the phases -- and both
# halves wear the death and arrival sparkles, 112 to 127.
def rotated_size(n):
    rows = spr_heights[n]
    if n in animated_sprites:
        rows = ((rows - 1) | 7) + 1             # shift_alloc rounds these to eights
    return (spr_widths[n] + 1) * 2 * rows + 2

KNIGHT_LEGS = ([b + k for b in (16, 48) for k in list(range(0, 6)) + list(range(8, 14))]
               + list(range(112, 128)))
KNIGHT_BODY = [b + k for b in (32, 64) for k in range(16)] + list(range(112, 128))
for label, sprite, frames in (("CHARACTER_LARGEST", 30, KNIGHT_LEGS),
                              ("CHARACTER_TALLEST", 92, KNIGHT_BODY)):
    need = max(rotated_size(gmap[g]) for g in frames)
    assert rotated_size(sprite) >= need, (
        "%s (sprite %d) gives %d bytes but a frame needs %d"
        % (label, sprite, rotated_size(sprite), need))

for frames in ANIMATIONS:
    sizes = {rotated_size(gmap[g]) for g in frames}
    assert len(sizes) == 1, (
        "graphics %s want rotation buffers of %s bytes -- the first one shown "
        "would be overrun by a later one" % (frames, sorted(sizes)))


# Graphic 1 is Knight Lore's way of drawing nothing: it is what the knight's
# top half wears while he changes between man and wolf, and the game's own table
# has no bitmap for it. Ours cannot point at nothing -- the draw would read its
# sprite out of the ROM -- so it points at a sprite that covers nothing instead:
# two bytes by one row, every mask bit clear of the screen.
print("\t\t\tALIGN 4")
print("sprite_blank:")
print("\t\t\tDB\t0,1")
print("\t\t\tDB\t0b11111111,0b00000000,0b11111111,0b00000000 ;" + "  " * 16)

# The table is indexed by KNIGHT LORE's graphic number, not by our sprite
# number. Its own table at $7112 is 256 pointers into sprite memory and
# several graphic numbers share a bitmap -- 186 valid graphics across 103
# sprites -- so the room templates can name sprites directly only if we
# number them its way. graphic_map.bin holds that mapping; see kl_extract.py.
#
# 256 entries is 512 bytes, so the table is ALIGNed to its own size and
# object_update reaches it by doubling a pre-halved base, rather than the
# single `ld h,high sprite_table` that a 128-entry table allowed.
sys.stdout = console
if part in ("all", "bitmaps"):
    print(bitmaps.getvalue(), end="")
if part == "bitmaps":
    sys.exit()

table = io.StringIO()
console, sys.stdout = sys.stdout, table
print("\t\t\tALIGN\t512")
print("sprite_table:")
for row in range(0, 256, 4):
    cells = []
    for g in range(row, row + 4):
        n = gmap[g]
        cells.append('sprite_blank' if g == 1 else spr_list[n] if n < len(spr_list) else '0')
    print('\t\t\tDW\t' + ', '.join(cells) + '\t; $%02X' % row)

sys.stdout = console
if part in ("all", "table"):
    print(table.getvalue(), end="")
if part == "table":
    sys.exit()


# ---------------------------------------------------------------------------
# The pixel adjustments, with the trimmed rows folded in.
#
# sprite_adj.s is what adj.py harvested from a running Knight Lore: the nudge
# its own code gives each graphic, as a table of distinct pairs, an index a
# graphic long, and the handful of graphics whose mirror image wants a
# different pair. That file is the harvest and is never edited.
#
# A sprite hangs from its bottom row -- object_place works the row out and
# object_update takes the height off it -- so a sprite with blank rows taken
# off its bottom draws that much lower. Adding the same number to ADJ_Y, which
# is subtracted from the base row, puts it back. That is per GRAPHIC, because
# the index is per graphic, so the pairs are rebuilt here from the effective
# values rather than patched.

def read_adj():
    """sprite_adj.s -> the nudge (x, y) for every graphic, and mirrored."""
    text = Path("sprite_adj.s").read_text(encoding="utf-8")

    def numbers(chunk):
        out = []
        for line in chunk.splitlines():
            line = line.split(";")[0].strip()
            if not line.startswith("DB"):
                continue
            for v in line[2:].split(","):
                v = v.strip()
                if v:
                    out.append(int(v[1:], 16) if v.startswith("$") else int(v))
        return out

    pairs_text = text.split("sprite_adj_pairs:")[1].split("sprite_adj_mirror:")[0]
    flat = numbers(pairs_text)
    pairs = [(flat[i], flat[i + 1]) for i in range(0, len(flat), 2)]

    mirror_text = text.split("sprite_adj_mirror:")[1].split("sprite_adj_index:")[0]
    flat = numbers(mirror_text)
    mirror = {}
    for i in range(0, len(flat) - 1, 2):
        if flat[i] == 0:
            break
        mirror[flat[i]] = flat[i + 1]

    index = numbers(text.split("sprite_adj_index:")[1])
    plain, flipped = [], []
    for g in range(256):
        entry = index[g]
        pair = pairs[(entry & 0x7E) // 2]
        plain.append(pair)
        flipped.append(pairs[mirror[g] // 2] if entry & 0x80 else pair)
    return plain, flipped


def signed(v):
    return v - 256 if v > 127 else v


plain, flipped = read_adj()
want = []                       # (x, y) and its mirrored twin, per graphic
for g in range(256):
    n = gmap[g]
    trim = spr_trim[n] if n < len(spr_trim) else 0
    out = []
    for x, y in (plain[g], flipped[g]):
        out.append((x, (signed(y) + trim) & 0xFF))
    want.append(tuple(out))

pairs, index, mirror = [], [], []
for g, (normal, other) in enumerate(want):
    if normal not in pairs:
        pairs.append(normal)
    entry = pairs.index(normal) * 2
    if other != normal:
        if other not in pairs:
            pairs.append(other)
        mirror.append((g, pairs.index(other) * 2))
        entry |= 0x80
    index.append(entry)
assert len(pairs) * 2 <= 128, "more pairs than an index byte can name"

print("; Generated by sprites.py from sprite_adj.s -- do not edit.")
print(";")
print("; The pixel nudge that lines a sprite's artwork up with its logical")
print("; position: what adj.py harvested from a running Knight Lore, plus the")
print("; rows sprites.py took off the bottom of that sprite -- see the trim")
print("; above. %d pairs cover all 256 graphics both ways round." % len(pairs))
print("")
print("sprite_adj_pairs:")
for i, (x, y) in enumerate(pairs):
    print("\t\t\t\t\tDB\t\t%6d,%4d\t\t; %d" % (signed(x), signed(y), i * 2))
print("")
print("")
print("; Graphics whose mirror image wants a different nudge from their")
print("; plain one. Graphic, then its mirrored index; a zero graphic ends it.")
print("sprite_adj_mirror:")
for g, entry in mirror:
    print("\t\t\t\t\tDB\t\t%3d, %3d" % (g, entry))
print("\t\t\t\t\tDB\t\t0")
print("")
print("")
print("; One byte a graphic: its pair, doubled, plus bit 7 if the mirror")
print("; differs. Page-aligned, so the graphic number IS the low byte of")
print("; the address and the lookup needs no arithmetic at all.")
print("\t\t\t\t\tALIGN\t256")
print("sprite_adj_index:")
for row in range(0, 256, 8):
    cells = ", ".join("$%02X" % index[g] for g in range(row, row + 8))
    print("\t\t\t\t\tDB\t\t%s\t\t; %d" % (cells, row))
