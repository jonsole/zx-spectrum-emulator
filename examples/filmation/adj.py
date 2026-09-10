"""Harvest Knight Lore's per-graphic pixel adjustments into sprite_adj.s.

Every object the game draws is nudged a few pixels from its logical position so
that the artwork lines up: `set_pixel_adj` at $C72B stores a signed pair into
each object record. Which pair depends on the object's graphic number and on
whether it is mirrored, and the choice is made inside 29 different per-graphic
update routines -- it is behaviour, not a table, and porting it would mean
porting the game's object logic.

So take the values instead of the code. This drives a running Knight Lore over
DAP, visits enough rooms to see every graphic the castle uses both ways round,
and reads the pairs back out of the live object records.

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
OBJ_TBL = 0x5C88              # room objects start at slot 4
OBJ_END = 0x6108
OBJ_STRIDE = 32
GFX, FLAGS, ADJ_X, ADJ_Y = 0x00, 0x07, 0x12, 0x13

# Ten rooms are enough to see all 50 (graphic, mirrored) pairs the castle uses.
ROOMS = [0x88, 0x08, 0x01, 0xE3, 0x67, 0x9B, 0xB4, 0xD7, 0x09, 0x5E]


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

    # make every frame rebuild the room named at $5C10
    d.write(FRAME_LOOP_JP, [ROOM_ENTRY & 0xFF, ROOM_ENTRY >> 8])
    # ...and stop the game changing that number itself. The player is still
    # walking about in there, and crossing an edge would move us elsewhere.
    d.write(EXIT_SCREEN, [0x00, 0x00, 0x00])

    found = {}
    for room in ROOMS:
        d.write(CURRENT_ROOM, [room])
        # Several passes: a record exists as soon as the room is built, but its
        # adjustment is only filled in when that object is next updated, so a
        # single look catches some of them still at zero.
        seen = 0
        for _ in range(4):
            d.write(CURRENT_ROOM, [room])
            d.go(0.25)
            table = d.read(OBJ_TBL, OBJ_END - OBJ_TBL)
            for i in range(len(table) // OBJ_STRIDE):
                r = table[i * OBJ_STRIDE:(i + 1) * OBJ_STRIDE]
                if r[GFX] == 0:
                    break
                seen = max(seen, i + 1)
                pair = (r[ADJ_X], r[ADJ_Y])
                if pair == (0, 0):
                    continue                # not updated yet; ignore, never store
                key = (r[GFX], 1 if r[FLAGS] & 0x40 else 0)
                if key in found and found[key] != pair:
                    print("  ! room $%02X: graphic %d flip %d gives %s, had %s"
                          % (room, key[0], key[1], pair, found[key]))
                found[key] = pair
        print("room $%02X: %d records, %d pairs known" % (room, seen, len(found)))
    d.req("disconnect")
    return found


def signed(v):
    return v - 256 if v > 127 else v


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
            lines.append("%-20s%-8s%4d,%4d%s"
                         % ("", "DB", signed(x), signed(y),
                            (" " * 8 + note) if note else ""))
        lines.append("")
    return "\n".join(lines) + "\n"


def main():
    try:
        found = harvest()
    except (socket.error, OSError) as e:
        sys.exit("cannot reach zx_server on port 4711 (%s) -- start it first" % e)
    print()
    print("harvested %d (graphic, mirrored) pairs" % len(found))
    (HERE / "sprite_adj.s").write_text(emit(found), encoding="utf-8")
    print("wrote sprite_adj.s")


if __name__ == "__main__":
    main()
