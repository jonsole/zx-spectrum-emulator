"""The sprite sheet back into assembler: sprites.png and sprites.json ->
sprite_data.s, sprite_table.s and sprite_adj_gen.s.

    python sprite_source.py

sprite_sheet.py made the pair out of the game's own packed artwork, and this
is the other half of that round trip: what it writes is what the assembler
sees, so editing the PNG is how the game's artwork changes. build.py runs it
whenever the sheet, this script or the harvested adjustments have moved on.

The picture is what counts: sprites.json says where each sprite is in it and
what its colours mean, and every sprite's one-pixel frame is checked against
those rectangles before a byte is read -- see ../sheet.py, which reads the
sheet for both games.

Three files, because the two halves of the output go to different places in
the image. The table has to be ALIGNed to its own 512 bytes, and when it comes
last that alignment lands between the bitmaps and the table as padding -- 308
bytes of it, and it swallows anything saved anywhere else in the image, since
the total is rounded up to a boundary either way. Emitted separately, the
table goes where a 512 boundary already falls and the bitmaps go last, with
nothing after them that has to be aligned.

    sprite_data.s       the sprites, bottom row first, mask and data
                        interleaved, with the blank bottom rows trimmed off
    sprite_table.s      256 pointers, indexed by Pentagram's graphic number
    sprite_adj_gen.s    the pixel nudges from graphics.json

graphics.json is the other input, and is not generated here: it says which
sprite each graphic number draws, and carries the nudges adj.py harvested from
a running Pentagram. The rows the sheet trimmed off are already folded into
those, by sprite_sheet.py, once as the sheet was made, and so are the nudges
the game sets from a constant.
"""

import argparse
import sys
from pathlib import Path

# The engine's own facts about this game -- what keeps its blank rows, the
# rotation buffers -- are hand-written constants beside sprite_sheet.py's own
# use of them.
import sprite_sheet as game

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import sheet                                                    # noqa: E402

HERE = Path(__file__).resolve().parent

def check(sprites, facts, animated):
    """The facts about the trimmed set that the engine relies on."""
    gmap = facts["graphicMap"]

    for graphic in facts["wholeSpriteGraphics"]:
        n = gmap[graphic]
        assert sprites[n]["trim"] == 0, "graphic %d was meant to be left whole" % graphic

    # Everything that animates gets its buffer the first time it needs one,
    # sized from the frame it happens to be showing -- so every frame an
    # object can go on to show has to fit a buffer sized from any other. The
    # trim leaves the frames of one animation different heights; shift_alloc's
    # rounding to eights is what brings them back together, and this is where
    # that is checked.
    def rotated_size(n):
        rows = sprites[n]["h"]
        if n in animated:
            rows = ((rows - 1) | 7) + 1     # shift_alloc rounds these to eights
        return (sprites[n]["w"] + 1) * 2 * rows + 2

    # The knight keeps two rotation buffers for life, sized by shift_alloc
    # from two named sprites -- CHARACTER_LARGEST and CHARACTER_TALLEST in
    # character.s. The trim changes heights, so check that each is still at
    # least as big as every frame its half can wear; one that is not gets
    # rotated past its end.
    for buffer in facts["rotationBuffers"]:
        need = max(rotated_size(gmap[g]) for g in buffer["graphics"])
        assert rotated_size(buffer["sprite"]) >= need, (
            "%s (sprite %d) gives %d bytes but a frame needs %d"
            % (buffer["label"], buffer["sprite"], rotated_size(buffer["sprite"]), need))

    for frames in facts["animations"]:
        sizes = {rotated_size(gmap[g]) for g in frames}
        assert len(sizes) == 1, (
            "graphics %s want rotation buffers of %s bytes -- the first one shown "
            "would be overrun by a later one" % (frames, sorted(sizes)))


def emit_bitmaps(sprites, animated, used):
    out = []
    for n, sprite in enumerate(sprites):
        # A sprite no graphic points at is never drawn, so it is not worth
        # the uncontended memory: two of them, 200 bytes between them.
        if n not in used:
            continue
        # ALIGN 4 so the blit can use INC L / DEC L to move between the width,
        # the height and the start of the mask and data.
        out.append("\t\t\tALIGN 4")
        out.append(sprite["name"] + ":")
        # The blit index, not a width: (width - 2) scaled by the stride of a
        # sprite_jump_table group, which puts the width class in bits 4 to 6
        # and leaves bit 0 for the mirrored flag. Bit 7 is what tells
        # shift_alloc to round an animated sprite's buffer up to eights;
        # scenery keeps its buffers exact. The height is what is left of the
        # sprite once its blank bottom rows are off.
        flag = 0x80 if n in animated else 0
        out.append("\t\t\tDB\t{},{}".format((sprite["w"] - 2) * 16 | flag, sprite["h"]))
        # Top row first -- the game's own data is upside down, and the sheet
        # is the right way up -- with the mask inverted: a set bit there keeps
        # the screen, which is what the blit's `and mask : xor data` wants.
        # The comment beside each row is the row as it looks.
        for data, mask in zip(sprite["data"], sprite["mask"]):
            picture = ""
            for d, m in zip(data, mask):
                m_bits = "{0:08b}".format(255 ^ m)
                d_bits = "{0:08b}".format(d)
                for b in range(0, 8):
                    picture += ('  ' if m_bits[b] == '1'
                                else '..' if d_bits[b] == '0' else '##')
            out.append('\t\t\tDB\t' + ','.join(
                '0b{0:08b},0b{1:08b}'.format(255 ^ m, d)
                for d, m in zip(data, mask)) + ' ;' + picture)

    # Graphic 1 is Pentagram's way of drawing nothing: it is what the
    # knight's top half wears while he changes between man and wolf, and the
    # game's own table has no bitmap for it. Ours cannot point at nothing --
    # the draw would read its sprite out of the ROM -- so it points at a
    # sprite that covers nothing instead: two bytes by one row, every mask bit
    # clear of the screen.
    out.append("\t\t\tALIGN 4")
    out.append("sprite_blank:")
    out.append("\t\t\tDB\t0,1")
    out.append("\t\t\tDB\t0b11111111,0b00000000,0b11111111,0b00000000 ;" + "  " * 16)
    return out


def emit_table(sprites, facts):
    # The table is indexed by PENTAGRAM's graphic number, not by our sprite
    # number. Several graphic numbers share a bitmap -- 144 graphics across 88
    # sprites -- so the room templates can name sprites directly only if we
    # number them its way. graphics.json holds that mapping, by name; it came
    # out of that table, which pg_extract.py reads.
    #
    # 256 entries is 512 bytes, so the table is ALIGNed to its own size and
    # object_update reaches it by doubling a pre-halved base, rather than the
    # single `ld h,high sprite_table` that a 128-entry table allowed.
    gmap = facts["graphicMap"]
    blank = facts["blankGraphic"]
    out = ["\t\t\tALIGN\t512", "sprite_table:"]
    for row in range(0, 256, 4):
        cells = []
        for g in range(row, row + 4):
            # Pentagram names 170 graphics, not 256. The table still fills a
            # whole 512 bytes, because the engine reaches it by doubling a
            # pre-halved base and so needs the ALIGN either way; the graphics
            # past the game's own simply hold 0.
            n = gmap[g] if g < len(gmap) else None
            cells.append('sprite_blank' if g == blank
                         else sprites[n]["name"] if n is not None else '0')
        out.append('\t\t\tDW\t' + ', '.join(cells) + '\t; $%02X' % row)
    return out


# ---------------------------------------------------------------------------
# The pixel adjustments, with the trimmed rows folded in.
#
# graphics.json holds what adj.py harvested from a running Pentagram: the
# nudge its own code gives each graphic, beside the sprite that graphic draws,
# and the handful whose mirror image wants a different one. Those are the
# harvest and are never edited; the pair table, the index and the exception
# list are this file's packing of them, and are built below rather than carried
# around.
#
# A sprite hangs from its bottom row -- object_place works the row out and
# object_update takes the height off it -- so a sprite with blank rows taken
# off its bottom draws that much lower. Adding the same number to ADJ_Y, which
# is subtracted from the base row, puts it back. That is per GRAPHIC, because
# the index is per graphic, so the pairs are rebuilt here from the effective
# values rather than patched.

def read_adj(facts):
    """graphics.json -> the nudge (x, y) for every graphic, and mirrored.

    The harvest is data, so it is kept as data. A graphic the file does not
    mention is not nudged, and `mirrored` is only there where the other way
    round wants a different pair -- four of them do. The `sprite` beside them
    is the other half of the same entry and is not this function's business.
    """
    said = facts["graphics"]
    plain, flipped = [], []
    # Keyed by NUMBER: read_sheet_files has already turned the file's names
    # into the numbers the game knows them by.
    for g in range(256):
        entry = said.get(g) or {}
        pair = (entry.get("x", 0), entry.get("y", 0))
        other = entry.get("mirrored")
        plain.append(pair)
        flipped.append((other["x"], other["y"]) if other else pair)
    return plain, flipped


def signed(v):
    return v - 256 if v > 127 else v


def emit_adj(sprites, facts):
    plain, flipped = read_adj(facts)
    gmap = facts["graphicMap"]
    want = []                       # (x, y) and its mirrored twin, per graphic
    # As in read_adj: Pentagram's graphic map is 172 long, not 256, and the
    # tables emitted here are indexed by graphic number, so they end where the
    # game's graphics do.
    for g in range(len(gmap)):
        n = gmap[g]
        taken = sprites[n]["trim"] if n is not None else 0
        out = []
        for x, y in (plain[g], flipped[g]):
            out.append((x, (signed(y) + taken) & 0xFF))
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

    out = []
    out.append("; Generated by sprite_source.py from graphics.json -- do not edit.")
    out.append(";")
    out.append("; The pixel nudge that lines a sprite's artwork up with its logical")
    out.append("; position: what adj.py harvested from a running Pentagram, plus the")
    out.append("; rows sprite_source.py took off the bottom of that sprite -- see the")
    out.append("; trim above. %d pairs cover all 256 graphics both ways round." % len(pairs))
    out.append("")
    out.append("sprite_adj_pairs:")
    for i, (x, y) in enumerate(pairs):
        out.append("\t\t\t\t\tDB\t\t%6d,%4d\t\t; %d" % (signed(x), signed(y), i * 2))
    out.append("")
    out.append("")
    out.append("; Graphics whose mirror image wants a different nudge from their")
    out.append("; plain one. Graphic, then its mirrored index; a zero graphic ends it.")
    out.append("sprite_adj_mirror:")
    for g, entry in mirror:
        out.append("\t\t\t\t\tDB\t\t%3d, %3d" % (g, entry))
    out.append("\t\t\t\t\tDB\t\t0")
    out.append("")
    out.append("")
    out.append("; One byte a graphic: its pair, doubled, plus bit 7 if the mirror")
    out.append("; differs. Page-aligned, so the graphic number IS the low byte of")
    out.append("; the address and the lookup needs no arithmetic at all.")
    out.append("\t\t\t\t\tALIGN\t256")
    out.append("sprite_adj_index:")
    # 172 entries, not 256: Pentagram stops at graphic 171, so the page the
    # ALIGN reserves is only part filled and the 84 bytes that would pad it
    # go elsewhere. The lookup is unaffected -- no graphic number reaches
    # past the end of the table.
    for row in range(0, len(index), 8):
        cells = ", ".join("$%02X" % b for b in index[row:row + 8])
        out.append("\t\t\t\t\tDB\t\t%s\t\t; %d" % (cells, row))
    return out


def main():
    parser = argparse.ArgumentParser(
        description="Turn the sprite sheet into the game's sprite sources.")
    parser.add_argument("--sheet", type=Path, default=HERE / "sprites.png",
                        help="the sprite sheet PNG (default: sprites.png)")
    parser.add_argument("--json", type=Path, default=HERE / "sprites.json",
                        help="what is in it (default: sprites.json)")
    parser.add_argument("--graphics", type=Path, default=HERE / "graphics.json",
                        help="the graphic table (default: graphics.json)")
    parser.add_argument("--out-dir", type=Path, default=HERE,
                        help="where the .s files go (default: beside this script)")
    args = parser.parse_args()

    for needed in (args.sheet, args.json, args.graphics):
        if not needed.is_file():
            raise SystemExit(f"{needed} is missing -- run sprite_sheet.py once "
                             "against your own copy of the game to make it")

    _sheet, entries, facts = sheet.read_sheet_files(game, args.json, args.graphics)
    gmap = facts["graphicMap"]
    whole = {gmap[g] for g in facts["wholeSpriteGraphics"] if gmap[g] is not None}
    animated = {gmap[g] for frames in facts["animations"] for g in frames
                if gmap[g] is not None}

    sprites = sheet.read_sheet(args.sheet, entries, facts["palette"])
    # The sheet is trimmed already -- sprite_sheet.py does it as it draws -- so
    # this finds nothing to take. It stays as the check that that is true, and
    # to work out the rows each sprite ended up with.
    sheet.trim(sprites, whole)
    check(sprites, facts, animated)

    used = {n for n in gmap if n is not None}
    for name, lines in (("sprite_data.s", emit_bitmaps(sprites, animated, used)),
                        ("sprite_table.s", emit_table(sprites, facts)),
                        ("sprite_adj_gen.s", emit_adj(sprites, facts))):
        (args.out_dir / name).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"Wrote {name}")


if __name__ == "__main__":
    main()
