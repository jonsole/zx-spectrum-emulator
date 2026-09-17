"""Pull the room tables and the graphic map out of a Knight Lore snapshot.

Run this once, by hand, against your own copy of the game:

    python kl_extract.py "path/to/Knight Lore.sna"

It writes five files next to itself, and those are what the build uses
-- the snapshot itself is never needed again and is not in this repository:

  font.bin         $6108-$6247, 320 bytes: forty 8x8 characters, which is all
                   the text the game has. Digits first, then letters; no lower
                   case and no punctuation beyond what a word needs. It sits
                   immediately in front of the room tables, which is why the
                   game's object walk uses it as the end of the object table.

  room_data.bin    $6248-$6FF1, 2,986 bytes: the room size table, every room
                   definition, and the scenery and object templates they are
                   built from. rooms.py turns this into room_data.s.

  sprite_data.bin  $728C-$AF6B less six empty records, 15,572 bytes: the 103
                   sprites, in the game's own format and address order.
                   sprite_sheet.py turns this into the sprite sheet.

  graphic_map.bin  256 bytes, one per Knight Lore graphic number, giving the
                   index of the sprite in sprite_data.bin that holds its
                   bitmap, or 255 for the graphic numbers the game does not
                   use. The game's own table at $7112 is 256 pointers into
                   sprite memory, and several graphic numbers share a bitmap,
                   which is why 186 valid graphics resolve to 103 sprites.
                   the sheet carries this, to number sprite_table the way the
                   game numbers its graphics, so the room templates can name
                   sprites directly.

  specials.bin     142 bytes: where each of the 32 collectables starts --
                   U, V, Z and room, four bytes each, from the second to
                   fifth bytes of every nine-byte row of special_objs_tbl at
                   $6FF2 -- and then the fourteen-long order the wizard asks
                   for them in, objects_required at $C27D, before the game
                   shuffles it.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

FONT_START = 0x6108
FONT_END = 0x6248               # exclusive, and the room data starts here
ROOM_DATA_START = 0x6248
ROOM_DATA_END = 0x6FF2          # exclusive
SPRITE_TBL = 0x7112
SPRITES_START = 0x728C
SPRITES_END = 0xAF6C            # exclusive, and the code starts here
MIRRORED = 0x40                 # width-byte flag: stored mirrored right now
SPECIALS_TBL = 0x6FF2           # 32 rows of 9, ending where SPRITE_TBL starts
SPECIALS_ROWS = 32
OBJECTS_REQUIRED = 0xC27D
OBJECTS_REQUIRED_COUNT = 14
GRAPHIC_COUNT = 256
NO_SPRITE = 255


def load_sna(path):
    """A 48K .sna is a 27-byte header then RAM from $4000."""
    raw = Path(path).read_bytes()
    if len(raw) != 49179:
        sys.exit("%s is %d bytes; a 48K .sna is 49179" % (path, len(raw)))
    return raw[27:]


def sprites(ram):
    """The game's sprite records, walked in address order from $728C.

    Each record is a width byte (low five bits; the top three are flags), a
    height byte, then a mask and a bitmap byte for every cell. They chain by
    their own size, so landing exactly on $AF6C, where the code begins, is the
    check that the walk stayed in step.

    Six records at $7D98 are empty -- 0 by 0, holes in the game's numbering --
    and are left out, so our sprite numbers are positions among the rest.
    graphic_map below numbers them the same way; the two only agree because
    they come from this one walk.

    Returns the packed records and the address each one sits at, which is what
    the game's own graphic table points to.
    """
    packed = bytearray()
    addresses = []
    p = SPRITES_START
    while p < SPRITES_END:
        width = ram[p - 0x4000] & 0x1F
        height = ram[p - 0x4000 + 1]
        size = 2 + width * height * 2
        if width and height:
            if ram[p - 0x4000] & MIRRORED:
                # The game mirrors sprites in place as it draws them, and bit 6
                # records which way round one is now. A snapshot caught with
                # one turned would bake that in.
                sys.exit("sprite at $%04X is mirrored in this snapshot -- take "
                         "one from before the game has drawn anything" % p)
            packed += ram[p - 0x4000:p - 0x4000 + size]
            addresses.append(p)
        p += size
    if p != SPRITES_END:
        sys.exit("sprite walk ended at $%04X, not $%04X -- wrong game?"
                 % (p, SPRITES_END))
    return bytes(packed), addresses


def graphic_map(ram, addresses):
    index_of = {addr: n for n, addr in enumerate(addresses)}
    out = bytearray([NO_SPRITE]) * GRAPHIC_COUNT
    resolved = 0
    for graphic in range(GRAPHIC_COUNT):
        p = SPRITE_TBL + graphic * 2 - 0x4000
        addr = ram[p] | (ram[p + 1] << 8)
        if addr in index_of:
            out[graphic] = index_of[addr]
            resolved += 1
    return bytes(out), resolved


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    ram = load_sna(sys.argv[1])

    font = ram[FONT_START - 0x4000:FONT_END - 0x4000]
    (HERE / "font.bin").write_bytes(font)
    print("font.bin         %d bytes ($%04X-$%04X), %d characters"
          % (len(font), FONT_START, FONT_END - 1, len(font) // 8))

    rooms = ram[ROOM_DATA_START - 0x4000:ROOM_DATA_END - 0x4000]
    (HERE / "room_data.bin").write_bytes(rooms)
    print("room_data.bin    %d bytes ($%04X-$%04X)"
          % (len(rooms), ROOM_DATA_START, ROOM_DATA_END - 1))

    specials = bytearray()
    for row in range(SPECIALS_ROWS):
        at = SPECIALS_TBL + row * 9 - 0x4000
        specials += ram[at + 1:at + 5]
    at = OBJECTS_REQUIRED - 0x4000
    specials += ram[at:at + OBJECTS_REQUIRED_COUNT]
    (HERE / "specials.bin").write_bytes(specials)
    print("specials.bin     %d bytes, %d collectables and the order they are wanted in"
          % (len(specials), SPECIALS_ROWS))

    packed, addresses = sprites(ram)
    (HERE / "sprite_data.bin").write_bytes(packed)
    print("sprite_data.bin  %d bytes ($%04X-$%04X), %d sprites"
          % (len(packed), SPRITES_START, SPRITES_END - 1, len(addresses)))

    gmap, resolved = graphic_map(ram, addresses)
    (HERE / "graphic_map.bin").write_bytes(gmap)
    print("graphic_map.bin  %d bytes, %d graphic numbers resolved"
          % (len(gmap), resolved))


if __name__ == "__main__":
    main()
