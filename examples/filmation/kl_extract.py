"""Pull the room tables and the graphic map out of a Knight Lore snapshot.

Run this once, by hand, against your own copy of the game:

    python kl_extract.py "path/to/Knight Lore.sna"

It writes three small files next to itself, and those are what the build uses
-- the snapshot itself is never needed again and is not in this repository:

  font.bin         $6108-$6247, 320 bytes: forty 8x8 characters, which is all
                   the text the game has. Digits first, then letters; no lower
                   case and no punctuation beyond what a word needs. It sits
                   immediately in front of the room tables, which is why the
                   game's object walk uses it as the end of the object table.

  room_data.bin    $6248-$6FF1, 2,986 bytes: the room size table, every room
                   definition, and the scenery and object templates they are
                   built from. rooms.py turns this into room_data.s.

  graphic_map.bin  256 bytes, one per Knight Lore graphic number, giving the
                   index of the sprite in sprite_data.bin that holds its
                   bitmap, or 255 for the graphic numbers the game does not
                   use. The game's own table at $7112 is 256 pointers into
                   sprite memory, and several graphic numbers share a bitmap,
                   which is why 186 valid graphics resolve to 103 sprites.
                   sprites.py uses this to number sprite_table the way the
                   game numbers its graphics, so the room templates can name
                   sprites directly.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

FONT_START = 0x6108
FONT_END = 0x6248               # exclusive, and the room data starts here
ROOM_DATA_START = 0x6248
ROOM_DATA_END = 0x6FF2          # exclusive
SPRITE_TBL = 0x7112
GRAPHIC_COUNT = 256
NO_SPRITE = 255


def load_sna(path):
    """A 48K .sna is a 27-byte header then RAM from $4000."""
    raw = Path(path).read_bytes()
    if len(raw) != 49179:
        sys.exit("%s is %d bytes; a 48K .sna is 49179" % (path, len(raw)))
    return raw[27:]


def sprite_addresses(ram):
    """Where each sprite in sprite_data.bin lives in the game's memory.

    sprite_data.bin is the game's sprite records walked in address order, so
    finding each one in RAM gives us the address the game's own table points
    at. They are distinctive enough that a plain search is unambiguous.
    """
    packed = (HERE / "sprite_data.bin").read_bytes()
    out = []
    i = 0
    while i < len(packed):
        width = packed[i] & 0x1F
        height = packed[i + 1]
        record = packed[i:i + 2 + width * height * 2]
        at = ram.find(record)
        if at < 0:
            sys.exit("sprite %d is not in this snapshot -- wrong game?" % len(out))
        out.append(0x4000 + at)
        i += len(record)
    return out


def graphic_map(ram):
    index_of = {addr: n for n, addr in enumerate(sprite_addresses(ram))}
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

    gmap, resolved = graphic_map(ram)
    (HERE / "graphic_map.bin").write_bytes(gmap)
    print("graphic_map.bin  %d bytes, %d graphic numbers resolved"
          % (len(gmap), resolved))


if __name__ == "__main__":
    main()
