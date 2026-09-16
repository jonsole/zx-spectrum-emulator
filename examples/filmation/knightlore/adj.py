"""Harvest Knight Lore's per-graphic pixel adjustments into sprite_adj.s.

Every object the game draws is nudged a few pixels from its logical position so
that the artwork lines up: `set_pixel_adj` at $C72B stores a signed pair into
each object record. Which pair depends on the object's graphic number and on
whether it is mirrored, and the choice is made inside 29 different per-graphic
update routines -- it is behaviour, not a table, and porting it would mean
porting the game's object logic.

So take the values instead of the code. This drives a running Knight Lore over
DAP, visits enough rooms to see every graphic the castle uses both ways round,
and reads the pairs back out of the live object records. The player's own
halves live in the first few slots of the same table, so they are harvested
along with the scenery.

Forcing a room needs no register writes: the frame loop ends with `JP $AFBD`
at $B085, one instruction past the room-entry call at $AFBA, so patching that
jump to $AFBA makes the game rebuild its room every frame from whatever room
number is at $5C10. Write the room number, let a frame pass, read the records.

    python adj.py            # needs zx_server running and the game to hand

Writes sprite_adj.s, which the build includes. Re-run it only if the sprite
numbering changes.
"""
import base64
import json
import re
import socket
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
TAB = chr(9)
ROM = "C:/Users/jonso/zx-spectrum-emulator/roms/48.rom"
GAME = "C:/Users/jonso/zx-spectrum-emulator/snapshots/Knight Lore (1984)(Ultimate).sna"

FRAME_LOOP_JP = 0xB086        # operand of the JP that closes the frame loop
ROOM_ENTRY = 0xAFBA           # ...pointed here, every frame rebuilds the room
CURRENT_ROOM = 0x5C10
EXIT_SCREEN = 0xCABA          # LD (IX+$08),A -- the game changing its own room
OBJ_TBL = 0x5C08              # the player is slots 0-3, the room from 4
OBJ_END = 0x6108
OBJ_STRIDE = 32
GFX, FLAGS, ADJ_X, ADJ_Y = 0x00, 0x07, 0x12, 0x13

# Ten rooms are enough to see all the (graphic, mirrored) pairs the castle uses.
ROOMS = [0x88, 0x08, 0x01, 0xE3, 0x67, 0x9B, 0xB4, 0xD7, 0x09, 0x5E]

# Knight Lore does not have a key per direction. It scans four groups of keys
# as units -- the routine at $B5F7 is called with masks that pull several
# address lines low at once -- and the two that matter here are:
#
#   A S D F G / ENTER L K J H   walk forward
#   CAPS Z X C V / SPACE SYM M N B   turn on the spot
#
# so he has to be turned before he will wear anything but the one facing. That
# is why the first harvest came back with graphics 16-21 and 32-37 and nothing
# for 24-29 and 40-45: he walked the same way for the whole run.
WALK_KEY = "S"
TURN_KEY = "X"
TURNS = 26          # far more than the four facings, because the point is to
                    # still be walking when night falls: the knight turns into
                    # a werewolf, whose frames are a whole second character
                    # (48-61 legs, 64-77 body) with its own adjustments


class Dap:
    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", 4711))
        self.buf = b""
        self.seq = 0

    def _read(self):
        while b"\r\n\r\n" not in self.buf:
            self.buf += self.sock.recv(65536)
        head, rest = self.buf.split(b"\r\n\r\n", 1)
        n = int([l for l in head.decode().split("\r\n")
                 if l.lower().startswith("content-length")][0].split(":")[1])
        while len(rest) < n:
            rest += self.sock.recv(65536)
        self.buf = rest[n:]
        return json.loads(rest[:n])

    def req(self, command, arguments=None):
        self.seq += 1
        body = json.dumps({"seq": self.seq, "type": "request", "command": command,
                           "arguments": arguments or {}}).encode()
        self.sock.sendall(b"Content-Length: %d\r\n\r\n" % len(body) + body)
        while True:
            m = self._read()
            if m.get("type") == "response" and m.get("request_seq") == self.seq:
                return m

    def read(self, addr, n):
        out = b""
        while n:
            take = min(n, 256)
            out += base64.b64decode(
                self.req("readMemory", {"memoryReference": hex(addr), "count": take})
                ["body"]["data"])
            addr += take
            n -= take
        return out

    def write(self, addr, data):
        self.req("writeMemory", {"memoryReference": hex(addr),
                                 "data": base64.b64encode(bytes(data)).decode()})

    def go(self, seconds):
        self.req("continue", {"threadId": 1})
        time.sleep(seconds)
        self.req("pause", {"threadId": 1})
        time.sleep(0.05)


def scan(d, found, where):
    """Fold one look at the live object table into `found`.

    Returns how many slots held an object, which is only for the progress
    line -- an empty slot is a gap, not the end of the table, since the
    knight holds 0, 1 and 3 and leaves 2 unused.
    """
    table = d.read(OBJ_TBL, OBJ_END - OBJ_TBL)
    seen = 0
    for i in range(len(table) // OBJ_STRIDE):
        r = table[i * OBJ_STRIDE:(i + 1) * OBJ_STRIDE]
        if r[GFX] == 0:
            continue
        seen = max(seen, i + 1)
        pair = (r[ADJ_X], r[ADJ_Y])
        if pair == (0, 0):
            continue                    # not updated yet; ignore, never store
        key = (r[GFX], 1 if r[FLAGS] & 0x40 else 0)
        if key in found and found[key] != pair:
            print("  ! %s: graphic %d flip %d gives %s, had %s"
                  % (where, key[0], key[1], pair, found[key]))
        found[key] = pair
    return seen


def harvest():
    d = Dap()
    d.req("initialize", {"adapterID": "zxspectrum"})
    d.req("launch", {"rom": ROM, "snapshot": GAME})
    d.req("configurationDone")

    d.go(2.0)                                   # through the loading screen
    d.req("keyDown", {"key": "0"})              # 0 starts the game
    d.go(0.2)
    d.req("keyUp", {"key": "0"})
    d.go(2.0)                                   # into the first room

    found = {}

    # The knight first. He is two objects -- legs in slot 0 and body in slot 1
    # -- and he only wears his walking frames while he is actually walking, so
    # turn him and walk him, over and over. Each facing is a different block of
    # graphics or the same block mirrored, and both want harvesting.
    for _ in range(TURNS):
        d.req("keyDown", {"key": TURN_KEY})
        d.go(0.12)
        d.req("keyUp", {"key": TURN_KEY})
        d.go(0.1)
        d.req("keyDown", {"key": WALK_KEY})
        for _ in range(8):
            d.go(0.08)
            scan(d, found, "walking")
        d.req("keyUp", {"key": WALK_KEY})
        d.go(0.12)
    print("walked the knight: %d pairs known" % len(found))

    # make every frame rebuild the room named at $5C10
    d.write(FRAME_LOOP_JP, [ROOM_ENTRY & 0xFF, ROOM_ENTRY >> 8])
    # ...and stop the game changing that number itself. The player is still
    # walking about in there, and crossing an edge would move us elsewhere.
    d.write(EXIT_SCREEN, [0x00, 0x00, 0x00])

    for room in ROOMS:
        d.write(CURRENT_ROOM, [room])
        # Several passes: a record exists as soon as the room is built, but its
        # adjustment is only filled in when that object is next updated, so a
        # single look catches some of them still at zero.
        seen = 0
        for _ in range(4):
            d.write(CURRENT_ROOM, [room])
            d.go(0.25)
            seen = max(seen, scan(d, found, "room $%02X" % room))
        print("room $%02X: %d records, %d pairs known" % (room, seen, len(found)))
    d.req("disconnect")
    return found


def signed(v):
    return v - 256 if v > 127 else v


# Written on an entry that was copied from another rather than harvested.
# previous() skips these, so a re-run neither counts them as known nor lets
# them stand in the way of the real value turning up.
INHERITED = "; graphic %d, from the other way round"
ASSUMED = "; graphic %d, assumed from %d"

# Graphics the game never draws, but a character assembled out of its artwork
# does. The castle's soldier and wizard stand still and never turn, so only one
# of their two body facings is ever on screen -- 30 and 158 -- and the other is
# not observable at any length of harvest. It is the same figure at the same
# size facing the other way, so it is the same nudge: 004 and 005 are one
# torso drawn twice, as 012 and 013 are.
STANDS_IN = {31: 30, 151: 150, 159: 158}


# Nudges taken from the game's CODE rather than from watching it run.
#
# Most of the 29 update routines work the adjustment out from the object, so
# the only way to know those is to read one back from a live record -- which is
# what the harvest does, and why it misses whatever the game did not happen to
# draw while it was watching. The rest load a fixed HL and hand it to
# set_pixel_adj, directly or through one of the adj_* helpers, and those cover
# every graphic they serve whether or not one was ever seen.
#
# Two things make this worth having beyond filling holes. Both frames of an
# animating pair come through the same routine, so they get the same nudge --
# and when one was harvested and the other was not, the missing one filled in
# as (0,0) and the thing jumped eight pixels sideways every time it animated.
# And it is checkable: of the 166 graphics here, 109 were also harvested, and
# every single one of those agrees. Not one disagreement, which is a fair test
# of the extraction and of the harvest at the same time.
#
# Extracted from the dispatch table and the adj_* helpers in the disassembly,
# grouped by value. Several helpers are a single LD HL that falls through into
# set_pixel_adj rather than jumping to it.
FROM_CODE = {}
for _xy, _graphics in {
    ( -24,   12): (
     142,),
    ( -20,   -1): (
     10,),
    ( -16,  -12): (
     88, 89, 90,),
    ( -16,   -8): (
     6, 7, 62, 63, 84, 85, 91, 143,),
    ( -12,  -12): (
     64, 65, 66, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77,
     78, 79,),
    ( -12,   -8): (
     32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45,
     46, 47,),
    ( -12,   -7): (
     48, 49, 50, 51, 52, 53, 56, 57, 58, 59, 60, 61,),
    ( -12,   -6): (
     8, 9, 16, 17, 18, 19, 20, 21, 24, 25, 26, 27, 28, 29, 80,
     81, 82, 83, 144, 145, 146, 147, 148, 149, 152, 153, 154,
     155, 156, 157,),
    ( -12,   -4): (
     96, 97, 98, 99, 100, 101, 102, 104, 105, 106, 107, 108,
     109, 110, 112, 113, 114, 115, 116, 117, 118, 119, 120,
     121, 122, 123, 124, 125, 126, 127, 131, 132, 133, 160,
     161, 162, 163, 164, 165, 166, 167, 168, 169, 170, 171,
     172, 173, 174, 175, 184, 185, 187,),
    ( -12,   -2): (
     11, 92, 93, 94, 95,),
    ( -12,    3): (
     30, 31, 158, 159,),
    ( -12,    7): (
     150, 151,),
    (  -8,   -4): (
     12, 13, 14, 15, 86, 87, 176, 177, 178, 179, 180, 181,
     182, 183,),
    (  -8,   -2): (
     103, 128, 129, 130,),
}.items():
    FROM_CODE.update(dict.fromkeys(_graphics, _xy))


def resolve(found):
    """Every graphic, both ways round, as a signed pair.

    Fills the gaps the harvest leaves: a graphic the game never draws borrows
    from the piece it stands in for, and one seen only one way round borrows
    from the other -- a graphic mirrored in place stays within a pixel or two
    of where it was, where (0,0) puts it twelve out, which is what made the
    knight jump sideways on the three frames of his walk the harvest missed.
    """
    out, borrowed = {}, {}
    for flip in (0, 1):
        for g in range(256):
            if g in FROM_CODE:
                out[(g, flip)] = tuple(v & 0xFF for v in FROM_CODE[g])
                if (g, flip) not in found:
                    borrowed[(g, flip)] = "the routine's own constant"
            elif (g, flip) in found:
                out[(g, flip)] = found[(g, flip)]
            elif g in STANDS_IN and (STANDS_IN[g], flip) in found:
                out[(g, flip)] = found[(STANDS_IN[g], flip)]
                borrowed[(g, flip)] = "stands in for %d" % STANDS_IN[g]
            elif g in STANDS_IN and (STANDS_IN[g], 1 - flip) in found:
                out[(g, flip)] = found[(STANDS_IN[g], 1 - flip)]
                borrowed[(g, flip)] = "stands in for %d" % STANDS_IN[g]
            elif (g, 1 - flip) in found:
                out[(g, flip)] = found[(g, 1 - flip)]
                borrowed[(g, flip)] = "from the other way round"
            else:
                out[(g, flip)] = (0, 0)
    return {k: (signed(x), signed(y)) for k, (x, y) in out.items()}, borrowed


def emit(found):
    """A pair table, an index into it per graphic, and the few exceptions.

    It used to be two flat tables of 256 signed pairs -- a kilobyte, and
    almost all of it repetition. Of the 512 entries only about 226 carry
    anything and there are twenty distinct pairs in the whole set, so the
    pairs are listed once and every graphic holds an index into them.

    One index serves both ways round, because only four of the 113 graphics
    that have a nudge want a different one mirrored. Bit 7 marks those and
    sends the mirrored case to a short exception list.
    """
    adj, borrowed = resolve(found)

    pairs = [(0, 0)]
    for key in sorted(adj):
        if adj[key] not in pairs:
            pairs.append(adj[key])
    if len(pairs) * 2 > 128:
        sys.exit("too many distinct nudges for a seven-bit index: %d" % len(pairs))

    index, mirror = [], []
    for g in range(256):
        plain, flipped = adj[(g, 0)], adj[(g, 1)]
        b = pairs.index(plain) * 2
        if flipped != plain:
            b |= 0x80
            mirror.append((g, pairs.index(flipped) * 2))
        index.append(b)

    L = []
    L.append("; Generated by adj.py from a running Knight Lore -- do not edit.")
    L.append(";")
    L.append("; The pixel nudge that lines a sprite's artwork up with its logical")
    L.append("; position. Knight Lore picks these inside 29 per-graphic update")
    L.append("; routines rather than reading a table, so these are the values its")
    L.append("; own code produced, read back out of live object records.")
    L.append(";")
    L.append("; %d distinct pairs cover all 256 graphics both ways round, and %d"
             % (len(pairs), len(mirror)))
    L.append("; graphics want a different one mirrored. room_adjust does the lookup.")
    L.append("")
    L.append("; The pairs, x then y. Entry 0 is no nudge at all, so a graphic")
    L.append("; nothing knows about indexes to it harmlessly.")
    L.append("sprite_adj_pairs:")
    for i, (x, y) in enumerate(pairs):
        L.append(TAB * 5 + "DB" + TAB * 2 + "%4d,%4d" % (x, y) + TAB * 2 + "; %d" % (i * 2))
    L.append("")
    L.append("")
    L.append("; Graphics whose mirror image wants a different nudge from their")
    L.append("; plain one. Graphic, then its mirrored index; a zero graphic ends it.")
    L.append("sprite_adj_mirror:")
    for g, b in mirror:
        note = borrowed.get((g, 1), "")
        L.append(TAB * 5 + "DB" + TAB * 2 + "%3d, %3d" % (g, b)
                 + ((TAB * 2 + "; " + note) if note else ""))
    L.append(TAB * 5 + "DB" + TAB * 2 + "0")
    L.append("")
    L.append("")
    L.append("; One byte a graphic: its pair, doubled, plus bit 7 if the mirror")
    L.append("; differs. Page-aligned, so the graphic number IS the low byte of")
    L.append("; the address and the lookup needs no arithmetic at all.")
    L.append(TAB * 5 + "ALIGN" + TAB + "256")
    L.append("sprite_adj_index:")
    for i in range(0, 256, 8):
        L.append(TAB * 5 + "DB" + TAB * 2
                 + ", ".join("$%02X" % b for b in index[i:i + 8])
                 + TAB * 2 + "; %d" % i)
    L.append("")
    return "\n".join(L) + "\n"


def previous():
    """The pairs the last run wrote, so a re-run can only add to them.

    An object's adjustment is only filled in when the game next updates it,
    and which objects get updated in a quarter of a second is a lottery, so
    each run sees a slightly different subset. Merging keeps the union.
    Delete sprite_adj.s first if the sprite numbering has changed and the old
    values are no longer about the same artwork.

    A mirror entry the last run BORROWED rather than harvested carries a note,
    and is skipped, so a re-run neither counts it as known nor lets it stand
    in the way of the real value turning up.
    """
    path = HERE / "sprite_adj.s"
    if not path.exists():
        return {}
    text = path.read_text(encoding="utf-8")
    if "sprite_adj_pairs" not in text:
        return {}                       # an older format: start over

    def chunk(name, end):
        start = text.index(name + ":")
        return text[start:text.index(end, start)]

    pairs = [(int(a), int(b)) for a, b in
             re.findall(r"DB\s+(-?\d+),\s*(-?\d+)",
                        chunk("sprite_adj_pairs", "sprite_adj_mirror"))]
    mirror = {}
    for line in chunk("sprite_adj_mirror", "ALIGN").splitlines():
        m = re.match(r"\s+DB\s+(\d+),\s*(\d+)", line)
        if m and ";" not in line:
            mirror[int(m.group(1))] = int(m.group(2))
    index = [int(x, 16) for x in
             re.findall(r"\$([0-9A-F]{2})", text[text.index("sprite_adj_index:"):])]
    if len(index) != 256:
        return {}

    was = {}
    for g in range(256):
        b = index[g]
        plain = pairs[(b & 0x7F) // 2]
        if plain != (0, 0):
            was[(g, 0)] = (plain[0] & 0xFF, plain[1] & 0xFF)
        if b & 0x80:
            if g in mirror:
                flipped = pairs[(mirror[g] & 0x7F) // 2]
                if flipped != (0, 0):
                    was[(g, 1)] = (flipped[0] & 0xFF, flipped[1] & 0xFF)
        elif plain != (0, 0):
            was[(g, 1)] = (plain[0] & 0xFF, plain[1] & 0xFF)
    return was


def main():
    was = previous()
    try:
        found = harvest()
    except (socket.error, OSError) as e:
        sys.exit("cannot reach zx_server on port 4711 (%s) -- start it first" % e)
    print()
    print("harvested %d (graphic, mirrored) pairs" % len(found))
    kept = 0
    for key, pair in was.items():
        if key not in found:
            found[key] = pair
            kept += 1
        elif found[key] != pair:
            print("  ! graphic %d flip %d now %s, was %s"
                  % (key[0], key[1], found[key], pair))
    if kept:
        print("kept %d more from the last run" % kept)
    (HERE / "sprite_adj.s").write_text(emit(found), encoding="utf-8")
    print("wrote sprite_adj.s -- %d pairs" % len(found))


if __name__ == "__main__":
    main()
