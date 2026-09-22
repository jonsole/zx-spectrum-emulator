"""Harvest Pentagram's per-graphic pixel adjustments into sprites.json.

Every object the game draws is nudged a few pixels from its logical position
so that the artwork lines up, and the pair lands in each live object record at
+$12 and +$13. Which pair depends on the graphic and on whether it is
mirrored, and the choice is made inside the game's per-graphic update routines
-- it is behaviour, not a table, so there is nothing to read out statically.

So take the values instead of the code. This drives a running Pentagram over
DAP, forces it through every room, then walks Sabreman round every facing,
and reads the pairs back out of the live records.

    python adj.py           # needs zx_server running on 4711

Expect to re-run it: any change to the sprite numbering invalidates the index,
and a partial harvest is worse than none, so it always reports its coverage
and refuses to overwrite a good file with a worse one.

-- how it differs from ../knightlore/adj.py -------------------------------

Knight Lore forces a room by patching the jump that closes its frame loop to
land one instruction earlier, on the room-entry call, so every frame rebuilds
the room named at a fixed address. Pentagram has no such call site: nothing
in the image does a plain CALL or JP to its builder at $C92F, which is reached
indirectly, so there is no jump to bend.

What works instead is to run the game's own room-entry sequence on demand.
$C6B6 is a complete one -- LD IX,$A76F, then the three calls that leave the
old room, build the new one and draw it -- and it is fallen into rather than
called, so there is nothing to patch. Naming the room in $A777 (the player
record's own +8) and pointing PC at $C6B6 performs a real room change.

An earlier version stopped at the builder and wrote the room there instead.
That looked right and was not: the builder is only re-entered when the game
genuinely changes room, so with the player standing still the breakpoint
almost never fired again, and it reached half the rooms by luck rather than
by mechanism. If coverage ever collapses, suspect the forcing before the
harvest.

Checked by hand before this was written: pointing PC at $C6B6 with 42 in
$A777 gives a pool whose records carry room 42 and its doorway destination
58 -- exactly what rooms.json holds for it.

The record layout is Knight Lore's, field for field, which is why the offsets
below match its own: graphic at +0, flags at +7, and the nudge at +$12/+$13.
"""
import base64
import json
import socket
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
ATLAS = HERE / "rooms.json"
# Where the harvest goes: beside the sprite each graphic number draws, because
# the two are halves of one fact -- how that number is drawn. Only this half
# needs a running game, so emit() merges rather than replacing.
OUT = HERE / "sprites.json"

ROM = "C:/Users/jonso/zx-spectrum-emulator/roms/48.rom"
GAME = "C:/Users/jonso/zx-spectrum-emulator/snapshots/Pentagram-clean.sna"

BUILDER = 0xC92F                # room_build's first instruction
ROOM_AT = 0xA777                # the room wanted: the player record's own +8
REGISTERS_REF = 1000            # the DAP "Registers" scope

POOL_START = 0xA76F             # the player's own records come first
POOL_END = 0xAE10
OBJ_STRIDE = 32
GFX, FLAGS, ADJ_X, ADJ_Y = 0x00, 0x07, 0x12, 0x13

GAME_MIRROR = 0x40              # in the template, and copied into the record
GRAPHIC_COUNT = 172

# Sabreman: legs 32-39 and body 40-47, four frames a block, two blocks. No room
# names them, so the rooms pass never sees them and walk_character() does.
CHARACTER_GRAPHICS = set(range(32, 48))
# What falls out of the sky: the spawner at $CBAB picks one of these from
# $CC09 into the two slots at $A7EF and $A80F, and they cycle their frames.
FLYER_GRAPHICS = set(range(48, 52)) | {80, 81} | set(range(160, 172))
FLYER_SLOTS = (0xA7EF, 0xA80F)
START_KEY = "0"                 # starts a game from the menu
TURN_KEY = "Z"                  # turns him a quarter
WALK_KEY = "A"                  # walks him the way he faces

TAB = chr(9)


class Dap:
    def __init__(self):
        self.sock = socket.create_connection(("127.0.0.1", 4711))
        self.buf = b""
        self.seq = 0
        self.stopped = False

    def _read(self):
        while b"\r\n\r\n" not in self.buf:
            self.buf += self.sock.recv(65536)
        head, rest = self.buf.split(b"\r\n\r\n", 1)
        n = int([l for l in head.decode().split("\r\n")
                 if l.lower().startswith("content-length")][0].split(":")[1])
        while len(rest) < n:
            rest += self.sock.recv(65536)
        self.buf = rest[n:]
        m = json.loads(rest[:n])
        if m.get("type") == "event" and m.get("event") == "stopped":
            self.stopped = True
        return m

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
        self.stopped = False
        self.req("continue", {"threadId": 1})
        time.sleep(seconds)
        self.req("pause", {"threadId": 1})
        time.sleep(0.05)

    def set_pc(self, addr):
        self.req("setVariable", {"variablesReference": REGISTERS_REF,
                                 "name": "PC", "value": "0x%04X" % addr})

    def breakpoint_at(self, addr):
        self.req("setInstructionBreakpoints",
                 {"breakpoints": [{"instructionReference": hex(addr)}]})

    def no_breakpoints(self):
        self.req("setInstructionBreakpoints", {"breakpoints": []})

    def run_to_break(self, timeout=4.0):
        """Continue until the breakpoint stops us. True if it did."""
        self.stopped = False
        self.req("continue", {"threadId": 1})
        deadline = time.time() + timeout
        self.sock.settimeout(0.25)
        try:
            while time.time() < deadline and not self.stopped:
                try:
                    self._read()
                except socket.timeout:
                    pass
        finally:
            self.sock.settimeout(None)
        if not self.stopped:
            self.req("pause", {"threadId": 1})
            time.sleep(0.05)
        return self.stopped


def covering_rooms(atlas):
    """The fewest rooms that between them use every graphic the rooms reach.

    Only a minority of the game's graphics appear in room data at all -- the
    rest are the player's own frames, the movers, the panel and the menu, none
    of which a room names. Visiting all 139 rooms is therefore mostly wasted;
    a greedy cover gets the same graphics in a dozen.
    """
    scenery = {t["name"]: [b["graphic"] for b in t["blocks"]]
               for t in atlas["sceneryTemplates"]}
    objects = {t["name"]: [e["graphic"] for e in t["entries"]]
               for t in atlas["objectTemplates"]}
    per = {}
    for r in atlas["rooms"]:
        g = set()
        for s_ in r["scenery"]:
            g |= set(scenery[s_["template"]])
        for o in r["objects"]:
            g |= set(objects[o["template"]])
        per[r["number"]] = g

    reachable = set().union(*per.values())
    need, cover = set(reachable), []
    while need:
        best = max(per, key=lambda r: len(per[r] & need))
        if not per[best] & need:
            break
        cover.append(best)
        need -= per[best]
    return cover, reachable


def scan(d, found, saw_bit7, where):
    """Fold one look at the live object pool into `found`."""
    pool = d.read(POOL_START, POOL_END - POOL_START)
    seen = 0
    for i in range(len(pool) // OBJ_STRIDE):
        r = pool[i * OBJ_STRIDE:(i + 1) * OBJ_STRIDE]
        if r[GFX] == 0 or r[GFX] >= GRAPHIC_COUNT:
            continue
        seen += 1
        pair = (r[ADJ_X], r[ADJ_Y])
        if pair == (0, 0):
            continue                # not updated yet; never store a zero
        if r[FLAGS] & 0x80:
            saw_bit7.add(r[GFX])
        key = (r[GFX], 1 if r[FLAGS] & GAME_MIRROR else 0)
        if key in found and found[key] != pair:
            print("  ! %s: graphic %d flip %d gives %s, had %s"
                  % (where, key[0], key[1], pair, found[key]))
        found[key] = pair
    return seen


def harvest(rooms):
    """Visit each room with a fresh game, and let it play untouched.

    The room is forced at the builder's own breakpoint, which is always
    reached just after the game starts, and then the breakpoint comes off and
    nothing interferes again. That matters: an earlier version pointed PC at
    the room-entry sequence instead, which forced every room perfectly and
    harvested almost nothing, because abandoning whatever the game was doing
    drifts SP until it returns into the ROM and stops updating anything. If
    the pairs come back empty, check the game is still running before
    suspecting the scan.
    """
    found, saw_bit7, forced = {}, set(), 0
    for room in rooms:
        d = Dap()
        d.req("initialize", {"adapterID": "zxspectrum"})
        d.req("launch", {"rom": ROM, "snapshot": GAME})
        d.req("configurationDone")
        # Arm the breakpoint before the machine runs at all, so that no build
        # can sail past it.
        d.breakpoint_at(BUILDER)
        # The snapshot sits on the menu, and nothing guarantees it ever leaves
        # by itself, so start a game: the first build that follows is the one
        # the breakpoint catches.
        d.req("keyDown", {"key": START_KEY})
        reached = d.run_to_break(timeout=8.0)
        d.req("keyUp", {"key": START_KEY})
        if not reached:
            print("  ! room %d: the builder was never reached after starting" % room)
            d.no_breakpoints()
            d.req("disconnect")
            continue
        d.write(ROOM_AT, [room])
        d.no_breakpoints()
        forced += 1

        # Look early and often first. The room is forced, not walked into, so
        # Sabreman lands wherever the game had him -- and in room 24 that is
        # on something deadly: within a fifth of a second he dies, and the
        # game moves him to another room, taking object_06 and the only
        # graphic 63 with it. Then slow down, for the animated objects.
        seen = 0
        for step in [0.03] * 8 + [0.25] * 8:
            d.go(step)
            seen = max(seen, scan(d, found, saw_bit7, "room %d" % room))
        print("  room %3d: %2d records, %d pairs known" % (room, seen, len(found)))
        d.req("disconnect")
    return found, saw_bit7, forced


def walk_character(found, saw_bit7):
    """Start a game the ordinary way and walk Sabreman round every facing.

    His records are the first two in the pool, so scan() already reads them;
    all this adds is making him wear every frame. Each round is a quarter
    turn and a short walk -- short, because a long one finds something in the
    room that kills him, and the death frames are not his walk. It stops as
    soon as all sixteen graphics have been seen.
    """
    d = Dap()
    d.req("initialize", {"adapterID": "zxspectrum"})
    d.req("launch", {"rom": ROM, "snapshot": GAME})
    d.req("configurationDone")
    d.go(1.0)
    d.req("keyDown", {"key": START_KEY}); d.go(0.3); d.req("keyUp", {"key": START_KEY})
    for _ in range(12):
        d.go(0.4)
        if d.read(POOL_START, 1)[0]:
            break
    else:
        print("  ! the game never started, so no character frames")
        d.req("disconnect")
        return
    d.go(0.6)

    for turn in range(40):          # generous: he dies now and then, and respawns
        if CHARACTER_GRAPHICS <= {g for g, _ in found}:
            break
        d.req("keyDown", {"key": TURN_KEY}); d.go(0.12); d.req("keyUp", {"key": TURN_KEY})
        d.go(0.3)
        d.req("keyDown", {"key": WALK_KEY})
        for _ in range(5):
            d.go(0.08)
            scan(d, found, saw_bit7, "walking")
        d.req("keyUp", {"key": WALK_KEY})
        d.go(0.1)
    seen = CHARACTER_GRAPHICS & {g for g, _ in found}
    print("  Sabreman: %d of his %d graphics seen" % (len(seen), len(CHARACTER_GRAPHICS)))
    d.req("disconnect")


def watch_flyers(found, saw_bit7):
    """Wait in a started game for the sky to drop things, and keep it doing so.

    Nothing in a room places them: $CBAB counts a timer down every turn --
    255 turns the first time -- and then drops one of eight into a free slot
    of the two it keeps. Two at once and it stops, so each flyer is cleared
    once it has been watched long enough to show all its frames, which frees
    the slot for the next.
    """
    d = Dap()
    d.req("initialize", {"adapterID": "zxspectrum"})
    d.req("launch", {"rom": ROM, "snapshot": GAME})
    d.req("configurationDone")
    d.go(1.0)
    d.req("keyDown", {"key": START_KEY}); d.go(0.3); d.req("keyUp", {"key": START_KEY})
    age = {}
    for _ in range(600):
        if FLYER_GRAPHICS <= {g for g, _ in found}:
            break
        d.go(0.3)
        scan(d, found, saw_bit7, "flyers")
        for slot in FLYER_SLOTS:
            if d.read(slot, 1)[0]:
                age[slot] = age.get(slot, 0) + 1
                if age[slot] > 12:
                    d.write(slot, [0])  # watched enough: make room for another
                    age[slot] = 0
            else:
                age[slot] = 0
    seen = FLYER_GRAPHICS & {g for g, _ in found}
    print("  flyers: %d of their %d graphics seen" % (len(seen), len(FLYER_GRAPHICS)))
    d.req("disconnect")


def signed(v):
    return v - 256 if v > 127 else v


def emit(found):
    """The nudge for every graphic that has one, as data.

    It used to be written as assembler -- a table of distinct pairs, an index a
    graphic long and a short exception list -- which is how the GAME wants it,
    not how a harvest is best kept. sprite_source.py packs it that way now, out
    of this, and the room designer reads the same file without having to parse
    assembly to do it. ../knightlore/adj.py writes the same shape.

    This MERGES into sprites.json rather than replacing it: the sheet is the
    authoritative form of the graphics, and everything else it says about a
    graphic -- its name, the sprite that draws it -- is kept.

    A graphic with no nudge is left out, and `mirrored` is given only where the
    other way round wants a different pair.
    """
    adj = {}
    for g in range(GRAPHIC_COUNT):
        for flip in (0, 1):
            # Seen only one way round: use that both ways. Every graphic seen
            # both ways that could be checked -- Sabreman's 36-39 and 44-47 --
            # has the same nudge either way, and his 32-35 are only ever worn
            # mirrored while walking, so without this their plain case would
            # fall to zero.
            adj[(g, flip)] = (found.get((g, flip)) or found.get((g, 1 - flip))
                              or (0, 0))

    if not OUT.is_file():
        raise SystemExit("%s is missing -- it is what the nudges belong in; "
                         "run sprite_sheet.py once to make it" % OUT.name)
    said = json.loads(OUT.read_text(encoding="utf-8"))
    table = said["meta"]["zx"]["game"]["graphics"]

    for g in range(GRAPHIC_COUNT):
        plain, flipped = adj[(g, 0)], adj[(g, 1)]
        entry = dict(table.get(str(g)) or {})
        # Out with the old nudge, whatever it was, and in with this run's --
        # but the sprite, and anything else the entry carries, stays.
        for key in ("x", "y", "mirrored"):
            entry.pop(key, None)
        if plain != (0, 0):
            entry["x"], entry["y"] = signed(plain[0]), signed(plain[1])
        if flipped != plain:
            entry["mirrored"] = {"x": signed(flipped[0]), "y": signed(flipped[1])}
        if entry:
            table[str(g)] = entry
        else:
            table.pop(str(g), None)

    said["meta"]["zx"]["game"]["graphics"] = {
        k: table[k] for k in sorted(table, key=int)}
    return json.dumps(said, indent=1) + "\n"


def main():
    if not ATLAS.is_file():
        sys.exit("%s is missing -- run rooms.py first" % ATLAS.name)
    atlas = json.loads(ATLAS.read_text(encoding="utf-8"))
    rooms, reachable = covering_rooms(atlas)
    print("%d rooms cover the %d graphics the room data reaches"
          % (len(rooms), len(reachable)))

    found, saw_bit7, forced = harvest(rooms)
    walk_character(found, saw_bit7)
    watch_flyers(found, saw_bit7)
    reachable = reachable | CHARACTER_GRAPHICS | FLYER_GRAPHICS

    graphics = {g for g, _ in found}
    print()
    print("visited %d of %d rooms" % (forced, len(rooms)))
    print("%d pairs over %d of the %d reachable graphics, %d distinct nudges"
          % (len(found), len(graphics & reachable), len(reachable),
             len({v for v in found.values()})))
    extra = graphics - reachable
    if extra:
        print("...and %d the rooms do not name, picked up anyway: %s"
              % (len(extra), sorted(extra)[:8]))
    if saw_bit7:
        print("NOTE: %d graphics had bit 7 of the flags set at some point." % len(saw_bit7))
        print("      The mirrored key here is bit 6, the bit the template carries;")
        print("      $B2EE tests bit 7 of the same field. If mirrored nudges look")
        print("      wrong, that is the first thing to re-check.")

    missing = reachable - graphics
    if missing:
        print("MISSING %d reachable graphics: %s" % (len(missing), sorted(missing)))
    if not found:
        sys.exit("nothing harvested -- not writing %s" % OUT.name)
    if missing:
        sys.exit("refusing to write %s while any reachable graphic is unseen. "
                 "A missing nudge is not a blank: that artwork sits visibly "
                 "wrong, which reads as an engine bug rather than a gap here."
                 % OUT.name)

    print()
    print()
    print("NOTE: this covers the rooms, Sabreman's walk and what falls from the sky.")
    print("      The panel and the menu are named by none of them and are NOT")
    print("      harvested here.")
    print("      64-71 are his appearing and dying frames, caught only when a scan")
    print("      lands mid-animation, and the original moves their nudge frame by")
    print("      frame -- so expect those to vary from run to run.")

    OUT.write_text("\n".join(emit(found)) + "\n", encoding="utf-8")
    print("wrote %s" % OUT.name)


if __name__ == "__main__":
    main()
