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

Four files, because the two halves of the output go to different places in
the image. The table has to be ALIGNed to its own 512 bytes, and when it comes
last that alignment lands between the bitmaps and the table as padding -- 308
bytes of it, and it swallows anything saved anywhere else in the image, since
the total is rounded up to a boundary either way. Emitted separately, the
table goes where a 512 boundary already falls and the bitmaps go last, with
nothing after them that has to be aligned.

    sprite_data.s       the sprites, bottom row first, mask and data
                        interleaved, with the blank bottom rows trimmed off
    sprite_table.s      256 pointers, indexed by Knight Lore's graphic number
    sprite_adj_gen.s    the pixel nudges from graphics.json
    graphics_gen.s      a GFX_ label for every graphic number

graphics.json is the other input, and is not generated here: it says which
sprite each graphic number draws, and carries the nudges adj.py harvested from
a running Knight Lore. The rows the sheet trimmed off are already folded into
those, by sprite_sheet.py, once as the sheet was made.
"""

import argparse
import re
import sys
from pathlib import Path

# The engine's own facts about this game: what animates, what keeps its blank
# bottom rows, the two rotation buffers, and the graphic that draws nothing.
# They are hand-written constants, not data, so they live in source -- next to
# sprite_sheet.py's own use of them rather than couriered through a JSON file.
import sprite_sheet as game
from sprite_sheet import GRAPHIC_COUNT

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


def emit_bitmaps(sprites, animated):
    out = []
    for n, sprite in enumerate(sprites):
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

    # Graphic 1 is Knight Lore's way of drawing nothing: it is what the
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


def graphic_top(facts):
    """One past the highest graphic number anything can name.

    Both per-graphic tables are only ever read by graphic number -- object
    placement, room_adjust, and the few graphics the code draws by name -- so
    nothing reads past the last graphic that has a sprite, and the entries
    after it are dead bytes: 136 in the sprite table, 68 in the nudge index.
    Each table stops there, rounded up to a whole row of its source."""
    gmap = facts["graphicMap"]
    return 1 + max(g for g in range(len(gmap))
                   if gmap[g] is not None or g == facts["blankGraphic"])


def emit_table(sprites, facts):
    # The table is indexed by KNIGHT LORE's graphic number, not by our sprite
    # number. Its own table at $7112 is 256 pointers into sprite memory and
    # several graphic numbers share a bitmap -- 186 valid graphics across 103
    # sprites -- so the room templates can name sprites directly only if we
    # number them its way. graphics.json holds that mapping, by name; it came
    # out of that table, which kl_extract.py reads.
    #
    # 256 entries is 512 bytes, so the table is ALIGNed to its own size and
    # object_update reaches it by doubling a pre-halved base, rather than the
    # single `ld h,high sprite_table` that a 128-entry table allowed.
    gmap = facts["graphicMap"]
    blank = facts["blankGraphic"]
    top = (graphic_top(facts) + 3) & ~3
    out = ["\t\t\tALIGN\t512", "sprite_table:"]
    for row in range(0, top, 4):
        cells = []
        for g in range(row, row + 4):
            n = gmap[g]
            cells.append('sprite_blank' if g == blank
                         else sprites[n]["name"] if n is not None else '0')
        out.append('\t\t\tDW\t' + ', '.join(cells) + '\t; $%02X' % row)
    return out


# ---------------------------------------------------------------------------
# The pixel adjustments, with the trimmed rows folded in.
#
# graphics.json holds what adj.py harvested from a running Knight Lore: the
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
    """graphic_map.json -> the nudge (x, y) for every graphic, and mirrored.

    The harvest is data, so it is kept as data. A graphic the file does not
    mention is not nudged, and `mirrored` is only there where the other way
    round wants a different pair -- four of them do. The `sprite` beside them
    is the other half of the same entry and is not this function's business.
    """
    said = facts["graphics"]
    plain, flipped = [], []
    # Keyed by NUMBER, not by the string the file writes: read_sheet_files has
    # already turned the keys into ints. Looking one up the other way silently
    # finds nothing, and every graphic is then drawn with no nudge at all --
    # which is a whole game very slightly wrong rather than a crash.
    for g in range(GRAPHIC_COUNT):
        entry = said.get(g) or {}
        pair = (entry.get("x", 0), entry.get("y", 0))
        other = entry.get("mirrored")
        plain.append(pair)
        flipped.append((other["x"], other["y"]) if other else pair)
    return plain, flipped


def signed(v):
    return v - 256 if v > 127 else v


def label_of(name):
    """The assembler label for a graphic, from the name graphics.json keys it by.

    werewolf.legs.1 -> GFX_WEREWOLF_LEGS_1. Anything that is not a letter or a
    digit becomes an underscore, so a rename in the JSON carries straight
    through to the source: the two cannot drift, because one is made from the
    other every build.
    """
    return "GFX_" + re.sub(r"[^A-Za-z0-9]", "_", name).upper()


def emit_labels(facts):
    """graphics_gen.s: what every graphic number is called.

    The game indexes sprite_table, the nudge table and every template record by
    a graphic NUMBER, and the sources used to spell those numbers out -- 16 for
    the player's legs, 96 for the first collectable. A number says nothing
    about what it draws, and moving one meant finding every place that knew it.

    So the numbers come from graphics.json, where they sit beside the name and
    the artwork, and this turns each into an EQU the sources can use instead.
    Rename a graphic there and the label follows on the next build; refer to a
    graphic that is not in the table and the assembler says so rather than
    quietly assembling the wrong index.
    """
    out = [
        "; --- graphic numbers -------------------------------------------------------",
        ";",
        "; Generated by sprite_source.py from graphics.json -- do not edit. One EQU a",
        "; graphic, named after the key it sits under there, so the sources can say",
        "; what they mean: GFX_WEREWOLF_LEGS_1 rather than 48.",
        ";",
        "; The number is the game's own and cannot be chosen freely: sprite_table is",
        "; indexed by it, and some of the numbering is arithmetic -- a collectable in",
        "; flight is its own graphic plus SPECIAL_FLIGHT. The NAME is free.",
        "",
    ]
    for number in sorted(facts["graphics"]):
        entry = facts["graphics"][number]
        label = label_of(entry["graphic"])
        note = entry.get("sprite") or "no bitmap of its own"
        out.append("%-24s EQU     %3d                 ; %s"
                   % (label, number, note))
    out.append("")
    return out


def emit_adj(sprites, facts):
    plain, flipped = read_adj(facts)
    gmap = facts["graphicMap"]
    want = []                       # (x, y) and its mirrored twin, per graphic
    for g in range(256):
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
    out.append("; Generated by sprite_source.py from graphic_map.json -- do not edit.")
    out.append(";")
    out.append("; The pixel nudge that lines a sprite's artwork up with its logical")
    out.append("; position: what adj.py harvested from a running Knight Lore, plus the")
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
    for row in range(0, (graphic_top(facts) + 7) & ~7, 8):
        cells = ", ".join("$%02X" % index[g] for g in range(row, row + 8))
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

    for name, lines in (("sprite_data.s", emit_bitmaps(sprites, animated)),
                        ("sprite_table.s", emit_table(sprites, facts)),
                        ("graphics_gen.s", emit_labels(facts)),
                        ("sprite_adj_gen.s", emit_adj(sprites, facts))):
        (args.out_dir / name).write_text(chr(10).join(lines) + chr(10), encoding="utf-8")
        print(f"Wrote {name}")


if __name__ == "__main__":
    main()
