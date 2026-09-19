"""The sprite sheet back into assembler: sprites.png and sprites.json ->
sprite_data.s, sprite_table.s and sprite_adj_gen.s.

    python sprite_source.py

sprite_sheet.py made the pair out of the game's own packed artwork, and this
is the other half of that round trip: what it writes is what the assembler
sees, so editing the PNG is how the game's artwork changes. build.py runs it
whenever the sheet, this script or the harvested adjustments have moved on.

The picture is what counts. sprites.json is an atlas in the shape the ZX
Spectrum extension's graphics panel reads, and the panel takes a sprite's
bytes from the atlas rather than from the picture, so every sprite carries a
base64 copy of its own record; this rewrites those copies from the pixels each
time it runs, and the atlas therefore never falls behind the sheet.

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
    sprite_adj_gen.s    the pixel nudges from sprite_adj.s, with the rows this
                        script trimmed folded in

sprite_adj.s is the other input, and is not generated here: adj.py harvested
it from a running Pentagram, and it is committed and never edited.
"""

import argparse
import base64
import json
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent

# How a pixel's colour in the sheet becomes the two bits the Z80 wants: does
# the sprite cover the screen here, and what does it put down if it does. The
# names are the contract with sprite_sheet.py; the colours themselves come out
# of the atlas, so only that script decides what the sheet looks like.
PIXEL_BITS = {
    "transparent": (0, 0),
    "paper": (1, 0),
    "ink": (1, 1),
    "stray": (0, 1),                    # a data bit under a hole in the mask
}
OPAQUE = 128                            # alpha at or above this is a colour


def read_atlas(path):
    """sprites.json -> the sprite entries in sprite order, and our own facts."""
    atlas = json.loads(path.read_text(encoding="utf-8"))
    zx = atlas.get("meta", {}).get("zx", {})
    if "sprites" not in zx or "game" not in zx:
        raise SystemExit(f"{path.name} is not a sheet written by sprite_sheet.py")
    return atlas, zx["sprites"], zx["game"]


def read_sheet(sheet, atlas, entries, palette):
    """The sheet's pixels, as (mask, data) byte rows a sprite, top row first."""
    image = Image.open(sheet).convert("RGBA")
    colours = {tuple(rgba[:3]): PIXEL_BITS[name] for name, rgba in palette.items()}
    pixels = image.load()

    sprites = []
    for entry in entries:
        width, height = entry["width"], entry["height"]
        box = atlas["frames"][entry["frames"][0]]["frame"]
        if box["x"] + width * 8 > image.width or box["y"] + height > image.height:
            raise SystemExit(f"{entry['name']} runs off {sheet.name}, which is "
                             f"{image.width}x{image.height}")
        mask_rows, data_rows = [], []
        for row in range(height):
            mask, data = bytearray(width), bytearray(width)
            for byte in range(width):
                for bit in range(8):
                    r, g, b, a = pixels[box["x"] + byte * 8 + bit, box["y"] + row]
                    if a < OPAQUE:
                        continue        # anything see-through is a hole
                    if (r, g, b) not in colours:
                        raise SystemExit(
                            f"{entry['name']} has a colour the sheet has no "
                            f"meaning for at ({byte * 8 + bit}, {row}): "
                            f"#{r:02X}{g:02X}{b:02X}")
                    m, d = colours[(r, g, b)]
                    mask[byte] |= m << (7 - bit)
                    data[byte] |= d << (7 - bit)
            mask_rows.append(mask)
            data_rows.append(data)
        sprites.append({
            "name": entry["name"],
            "w": width,
            "h": height,
            "flag": entry.get("flag", 0),
            "mask": mask_rows,
            "data": data_rows,
        })
    return sprites


def packed_record(sprite):
    """A sprite as sprite_data.bin holds it, which is what the atlas carries.

    The header the game shipped -- its width with its own flag bit, and the
    untrimmed height -- then a row at a time, mask byte then data byte, bottom
    row first.
    """
    record = bytearray((sprite["w"] | sprite["flag"], len(sprite["rows"])))
    for mask, data in reversed(sprite["rows"]):
        for byte in range(sprite["w"]):
            record.append(mask[byte])
            record.append(data[byte])
    return bytes(record)


def trim(sprites, whole):
    """Take the blank bottom rows off every sprite that can spare them.

    Rows at the bottom that cover nothing are 88 rows across 40 of the
    sprites -- 524 bytes, 536 once the alignment that follows them falls in
    too -- and every one of them is walked by the blit, by the rotation and by
    the region the object disturbs. They come off here -- and because a sprite
    hangs from its bottom row, every graphic drawn with it has that many added
    to its pixel nudge, which is what the adjustments below do. At least one
    row always stays: a sprite of none would draw 256.
    """
    for n, sprite in enumerate(sprites):
        # What the atlas carries is the whole sprite, blank rows and all --
        # the picture's own rows, before any of this.
        sprite["rows"] = list(zip(sprite["mask"], sprite["data"]))
        taken = 0
        while (n not in whole
               and len(sprite["mask"]) - taken > 1
               and not any(sprite["mask"][-1 - taken])
               and not any(sprite["data"][-1 - taken])):
            taken += 1
        if taken:
            sprite["mask"] = sprite["mask"][:-taken]
            sprite["data"] = sprite["data"][:-taken]
        sprite["trim"] = taken
        sprite["h"] = len(sprite["mask"])


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
    # The table is indexed by KNIGHT LORE's graphic number, not by our sprite
    # number. Its own table at $7112 is 256 pointers into sprite memory and
    # several graphic numbers share a bitmap -- 186 valid graphics across 103
    # sprites -- so the room templates can name sprites directly only if we
    # number them its way. graphic_map.bin holds that mapping; see
    # pg_extract.py, and sprites.json carries it from there.
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
# sprite_adj.s is what adj.py harvested from a running Pentagram: the nudge
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

def read_adj(harvest):
    """sprite_adj.s -> the nudge (x, y) for every graphic, and mirrored."""
    text = harvest.read_text(encoding="utf-8")

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
    # Pentagram names 172 graphics where Knight Lore names 256, so adj.py
    # emits an index only that long -- padding it out to 256 would cost 84
    # bytes in the region with the least room to spare. Graphics past the end
    # never reach a sprite table entry, so give them the no-nudge pair rather
    # than running off the list.
    none = pairs[0]
    plain, flipped = [], []
    for g in range(256):
        if g >= len(index):
            plain.append(none)
            flipped.append(none)
            continue
        entry = index[g]
        pair = pairs[(entry & 0x7E) // 2]
        plain.append(pair)
        flipped.append(pairs[mirror[g] // 2] if entry & 0x80 else pair)
    return plain, flipped


def signed(v):
    return v - 256 if v > 127 else v


def emit_adj(sprites, facts, harvest):
    plain, flipped = read_adj(harvest)
    # Nudges the original sets from a constant, which override the harvest:
    # see FIXED_NUDGES in sprite_sheet.py.
    for g, (x, y) in facts.get("fixedNudges", {}).items():
        plain[int(g)] = flipped[int(g)] = (x & 0xFF, y & 0xFF)
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
    out.append("; Generated by sprite_source.py from sprite_adj.s -- do not edit.")
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


def refresh_atlas(path, atlas, entries, sprites):
    """Put the picture's own bytes back in the atlas, if they have moved on.

    The graphics panel reads a sprite's bytes from here, not from the picture,
    so an edited PNG would otherwise still open as the artwork it replaced.
    Only `bytes` and `length` change; everything else in the file is left
    exactly as it was written.
    """
    changed = False
    for entry, sprite in zip(entries, sprites):
        record = packed_record(sprite)
        packed = base64.b64encode(record).decode("ascii")
        if entry.get("bytes") != packed or entry.get("length") != len(record):
            entry["bytes"] = packed
            entry["length"] = len(record)
            changed = True
    if changed:
        path.write_text(json.dumps(atlas, indent=1) + "\n", encoding="utf-8")
    return changed


def main():
    parser = argparse.ArgumentParser(
        description="Turn the sprite sheet into the game's sprite sources.")
    parser.add_argument("--sheet", type=Path, default=HERE / "sprites.png",
                        help="the sprite sheet PNG (default: sprites.png)")
    parser.add_argument("--json", type=Path, default=HERE / "sprites.json",
                        help="the atlas that describes it (default: sprites.json)")
    parser.add_argument("--adj", type=Path, default=HERE / "sprite_adj.s",
                        help="the harvested nudges (default: sprite_adj.s)")
    parser.add_argument("--out-dir", type=Path, default=HERE,
                        help="where the .s files go (default: beside this script)")
    args = parser.parse_args()

    for needed in (args.sheet, args.json, args.adj):
        if not needed.is_file():
            raise SystemExit(f"{needed} is missing -- run sprite_sheet.py to make "
                             "the sheet from sprite_data.bin")

    atlas, entries, facts = read_atlas(args.json)
    gmap = facts["graphicMap"]
    whole = {gmap[g] for g in facts["wholeSpriteGraphics"]}
    animated = {gmap[g] for frames in facts["animations"] for g in frames}

    sprites = read_sheet(args.sheet, atlas, entries, facts["palette"])
    trim(sprites, whole)
    check(sprites, facts, animated)

    used = {n for n in gmap if n is not None}
    for name, lines in (("sprite_data.s", emit_bitmaps(sprites, animated, used)),
                        ("sprite_table.s", emit_table(sprites, facts)),
                        ("sprite_adj_gen.s", emit_adj(sprites, facts, args.adj))):
        (args.out_dir / name).write_text("\n".join(lines) + "\n", encoding="utf-8")
        print(f"Wrote {name}")

    if refresh_atlas(args.json, atlas, entries, sprites):
        print(f"Brought {args.json.name}'s copy of the bytes back in step with "
              f"{args.sheet.name}")


if __name__ == "__main__":
    main()
