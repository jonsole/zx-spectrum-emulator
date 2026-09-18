"""Pull the room tables, the font and the sprites out of a Pentagram tape.

Run this once, by hand, against your own copy of the game:

    python pg_extract.py "path/to/Pentagram.tzx"

Unlike Knight Lore's kl_extract.py this reads the tape rather than a snapshot,
and that is not a stylistic choice. Pentagram's `game` block is 31,390 bytes
loaded verbatim to $5E00-$D89D, so the shipped tape *is* the memory map -- but
the game mirrors sprites in place as it draws them and records which way round
one is now in the top bits of its width byte. By the time the machine reaches
the menu four sprites have already been turned and rewritten, so any snapshot,
however early, bakes that in. The tape cannot: every header flag in it is $00.

It writes four files next to itself, and those are what the build uses -- the
tape itself is never needed again and is not in this repository:

  room_data.bin    $5E00-$6DD6, 4,055 bytes: the room size table at $5E07,
                   three bytes an entry; the room directory at $5E10 to $696C;
                   and the templates from $696D. The directory is searched by
                   room number, one variable-length record each: +0 the room
                   number, +1 the record's length counted from +1, +2 the ink
                   colour in bits 0-2 (the builder ORs in $40 for BRIGHT) and a
                   room-size index in bits 3-7, which it multiplies by three to
                   index the size table. The objects follow from +3.

                   Note the region holds executable code as well as these
                   tables, so this file is not pure data.

  graphic_map.bin  172 bytes, one per Pentagram graphic number, giving the
                   index of the sprite in sprite_data.bin that holds its
                   bitmap, or 255 for the graphic numbers the game does not
                   use. The game's own table at $6DD7 is 172 pointers into
                   sprite memory, reached as graphic * 2 + $6DD7; several
                   graphic numbers share a bitmap, and the rest point at a
                   record whose width byte is zero, which is how the game says
                   "draw nothing".

  font.bin         $8355-$84AC, 344 bytes: forty-three 8x8 characters, codes
                   $30 to $5A -- the digits, seven punctuation marks and the
                   upper-case letters, with no lower case. The game prints a
                   character at base + code * 8, and text is plain ASCII with
                   bit 7 marking the last character of a string. Two bases are
                   used for the one table: $81D5 for text, so that code $30
                   lands on $8355, and $8355 itself for the BCD digit pairs the
                   score is drawn from, indexed 0 to 15. It sits between the
                   first and second runs of sprites, which is what separates
                   them; $84AD to $8546 is not the font and is not claimed
                   here.

  sprite_data.bin  the 87 sprites, in the game's own format and address order,
                   taken from three runs -- $6F2F-$8354, $8547-$9394 and
                   $9397-$A708 -- with the font and a two-byte hole between
                   them. Each run is walked by its own record sizes and has to
                   land exactly on its end, which is the check that the walk
                   stayed in step.
"""
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent

GAME_START = 0x5E00             # where the tape's `game` block loads
GAME_NAME = "game"

ROOM_DATA_START = 0x5E00
ROOM_DATA_END = 0x6DD7          # exclusive, and the graphic table starts here
GRAPHIC_TBL = 0x6DD7            # the builder indexes it as graphic * 2 + this
ROOM_SIZE_TBL = 0x5E07          # three bytes an entry
ROOM_DIR = 0x5E10               # variable-length records, searched by room number
ROOM_DIR_END = 0x696D           # exclusive
GRAPHIC_TBL_END = 0x6F2F        # exclusive, and the first sprite run starts here
FONT_START = 0x8355             # character code $30, '0'
FONT_END = 0x84AD               # exclusive; one past code $5A, 'Z'
SPRITE_RUNS = ((0x6F2F, 0x8355), (0x8547, 0x9395), (0x9397, 0xA709))
MIRRORED = 0xE0                 # width-byte flags; bit 7 is the one the game
                                # toggles in place as it mirrors a sprite
NO_SPRITE = 255


def tape_blocks(path):
    """The data blocks of a .tzx, standard speed (ID $10) and turbo (ID $11).

    Only the block types Pentagram's tape actually uses are decoded; anything
    else stops the walk rather than being silently skipped, so a tape that is
    not this one fails loudly instead of yielding half a game.
    """
    raw = Path(path).read_bytes()
    if raw[:8] != b"ZXTape!\x1a":
        sys.exit("%s is not a TZX file" % path)

    blocks = []
    at = 10                     # 8-byte signature, then major/minor version
    while at < len(raw):
        block_id = raw[at]
        at += 1
        if block_id == 0x10:                    # standard speed data
            length = raw[at + 2] | (raw[at + 3] << 8)
            blocks.append(raw[at + 4:at + 4 + length])
            at += 4 + length
        elif block_id == 0x11:                  # turbo speed data
            length = raw[at + 0x0F] | (raw[at + 0x10] << 8) | (raw[at + 0x11] << 16)
            blocks.append(raw[at + 0x12:at + 0x12 + length])
            at += 0x12 + length
        elif block_id == 0x30:                  # text description
            at += 1 + raw[at]
        elif block_id == 0x32:                  # archive info
            at += 2 + (raw[at] | (raw[at + 1] << 8))
        else:
            sys.exit("%s: unexpected TZX block $%02X at %d" % (path, block_id, at - 1))
    return blocks


def load_tape(path):
    """The 48K address space with the tape's `game` block loaded into it.

    A header block is a 19-byte block whose flag is 0: a type, ten characters
    of name, a length and two parameters. The one we want is the CODE file
    called `game`; the block after it is its bytes, between a flag and a
    checksum.
    """
    blocks = tape_blocks(path)
    for n, block in enumerate(blocks):
        if len(block) != 19 or block[0] != 0x00:
            continue
        name = block[2:12].decode("ascii", errors="replace").rstrip()
        if block[1] != 3 or name != GAME_NAME:
            continue
        address = block[14] | (block[15] << 8)
        if address != GAME_START:
            sys.exit("`game` loads at $%04X, not $%04X -- wrong game?" % (address, GAME_START))
        data = blocks[n + 1][1:-1]
        memory = bytearray(0x10000)
        memory[address:address + len(data)] = data
        print("game             %d bytes ($%04X-$%04X)"
              % (len(data), address, address + len(data) - 1))
        return memory
    sys.exit("%s has no CODE block called `%s`" % (path, GAME_NAME))


def sprites(memory):
    """The game's sprite records, walked in address order through three runs.

    Each record is a width byte (low five bits; the top three are the flags
    saying which way round it is now) and a height byte, then a mask and a
    bitmap byte for every cell. They chain by their own size, so landing
    exactly on the end of each run is the check that the walk stayed in step.

    Returns the packed records and the address each one sits at, which is what
    the game's own graphic table points to.
    """
    packed = bytearray()
    addresses = []
    for start, end in SPRITE_RUNS:
        at = start
        while at < end:
            width = memory[at] & 0x1F
            height = memory[at + 1]
            if not width or not height:
                sys.exit("empty sprite record at $%04X -- the walk lost its place" % at)
            if memory[at] & MIRRORED:
                # The game mirrors sprites in place as it draws them and the
                # top bits record which way round one is now. A tape has not
                # drawn anything; a snapshot has.
                sys.exit("sprite at $%04X is flagged $%02X -- extract from the tape, "
                         "not from a snapshot" % (at, memory[at] & MIRRORED))
            size = 2 + width * height * 2
            packed += memory[at:at + size]
            addresses.append(at)
            at += size
        if at != end:
            sys.exit("sprite run from $%04X ended at $%04X, not $%04X -- wrong game?"
                     % (start, at, end))
    return bytes(packed), addresses


def graphic_map(memory, addresses):
    """One sprite index per graphic number, or 255 where the game uses none."""
    index_of = {address: n for n, address in enumerate(addresses)}
    out = bytearray()
    resolved = 0
    for at in range(GRAPHIC_TBL, GRAPHIC_TBL_END, 2):
        address = memory[at] | (memory[at + 1] << 8)
        index = index_of.get(address, NO_SPRITE)
        out.append(index)
        if index != NO_SPRITE:
            resolved += 1
    return bytes(out), resolved


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    memory = load_tape(sys.argv[1])

    rooms = memory[ROOM_DATA_START:ROOM_DATA_END]
    (HERE / "room_data.bin").write_bytes(rooms)
    print("room_data.bin    %d bytes ($%04X-$%04X)"
          % (len(rooms), ROOM_DATA_START, ROOM_DATA_END - 1))

    packed, addresses = sprites(memory)

    gmap, resolved = graphic_map(memory, addresses)
    (HERE / "graphic_map.bin").write_bytes(gmap)
    print("graphic_map.bin  %d bytes, %d graphic numbers resolved to %d sprites"
          % (len(gmap), resolved, len(set(gmap) - {NO_SPRITE})))

    font = memory[FONT_START:FONT_END]
    (HERE / "font.bin").write_bytes(font)
    print("font.bin         %d bytes ($%04X-$%04X)"
          % (len(font), FONT_START, FONT_END - 1))

    (HERE / "sprite_data.bin").write_bytes(packed)
    print("sprite_data.bin  %d bytes, %d sprites in %d runs"
          % (len(packed), len(addresses), len(SPRITE_RUNS)))


if __name__ == "__main__":
    main()
