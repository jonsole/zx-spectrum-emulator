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
TURNS = 9           # more than the four facings, so each is walked in twice


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


# Written on a mirrored entry that was copied from the unmirrored one rather
# than harvested. previous() skips these, so a re-run neither counts them as
# known nor lets them stand in the way of the real value turning up.
INHERITED = "; graphic %d, from the other way round"


def emit(found):
    """Two tables of 256 signed pairs, one for each way round."""
    lines = [
        "; Generated by adj.py from a running Knight Lore -- do not edit.",
        ";",
        "; The pixel nudge that lines a sprite's artwork up with its logical",
        "; position. Knight Lore picks these inside 29 per-graphic update",
        "; routines rather than reading a table, so these are the values its own",
        "; code produced, read back out of live object records.",
        ";",
        "; Indexed by graphic number. Mirrored objects get a different pair, so",
        "; there are two tables and object placement picks by the flip flag.",
        "",
    ]
    for flip, name in ((0, "sprite_adj"), (1, "sprite_adj_flipped")):
        lines.append("%-20s%s" % (name + ":", ""))
        for g in range(256):
            x, y = found.get((g, flip), (0, 0))
            note = ""
            if (g, flip) in found:
                note = "; graphic %d" % g
            elif (g, 1 - flip) in found:
                # Never seen this way round. The other way round is a far
                # better guess than nothing: a graphic mirrored in place stays
                # within a pixel or two of where it was, where (0,0) puts it
                # twelve out -- which is what the knight's walk did, jumping
                # sideways on the three frames of it the harvest had missed.
                # Marked, so previous() does not read it back as harvest.
                x, y = found[(g, 1 - flip)]
                note = INHERITED % g
            lines.append("%-20s%-8s%4d,%4d%s"
                         % ("", "DB", signed(x), signed(y),
                            (" " * 8 + note) if note else ""))
        lines.append("")
    return "\n".join(lines) + "\n"


def previous():
    """The pairs the last run wrote, so a re-run can only add to them.

    An object's adjustment is only filled in when the game next updates it,
    and which objects get updated in a quarter of a second is a lottery, so
    each run sees a slightly different subset. Merging keeps the union.
    Delete sprite_adj.s first if the sprite numbering has changed and the old
    values are no longer about the same artwork.
    """
    path = HERE / "sprite_adj.s"
    if not path.exists():
        return {}
    was = {}
    flip, g = 0, 0
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("sprite_adj_flipped:"):
            flip, g = 1, 0
        elif line.startswith("sprite_adj:"):
            flip, g = 0, 0
        else:
            m = re.match(r"\s+DB\s+(-?\d+),\s*(-?\d+)", line)
            if m:
                pair = (int(m.group(1)) & 0xFF, int(m.group(2)) & 0xFF)
                if pair != (0, 0) and "from the other way round" not in line:
                    was[(g, flip)] = pair
                g += 1
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
