"""The whole game on the Spectrum against the Python port, frame by frame.

Both start from the original's binary as its loader leaves it and run
StartGame; then both fly one of recorder.FLIGHTS' key scripts, a main-loop
iteration (or, while a flight is over, a look for RETURN) at a time, with
the same keys, the same clock (3 centiseconds more each time it is read)
and the same timer values (n * 97 + 13 for the n-th read). The Z80 is put
in its test mode (inputs.s) for that, and the Python port draws its screen
with model/zx.py. After starting and after every iteration, the whole game
state and the whole screen must match.

    python tests/test_zx_game.py [tour|theme|crash|controls] [iterations]
"""

import statistics
import sys
import time

from harness import Check
import recorder
import zx as zxprobe
from model import game, hardware, memory, zx
from model.memory import M

KEYS_DOWN = 0xD000

# Flights of the Spectrum's own, beside recorder.FLIGHTS: since both sides
# here are the port, any keys will do. "controls" takes off as the tour
# does, then raises the undercarriage, works the flaps, the gun sights and
# the scores, holds each control for long enough to sweep its indicator,
# throttles back, stops the engine in the air and lowers the undercarriage
# again.
FLIGHTS = {
    "controls": ("270-271:T 272-360:E 345-346:B 700-701:U 760-761:F 800-801:F 820-821:I "
                 "900-901:I 950-952:P 1000-1030:L 1040-1100:, 1110-1150:S 1160-1220:D "
                 "1230-1260:A 1270-1330:; 1400-1500:W 1520-1521:T 1600-1601:U", 1800),
}


class Sequence:
    """The timer values both sides read."""

    def __init__(self):
        self.n = 0

    def __call__(self):
        self.n += 1
        return (self.n * 97 + 13) & 0xFF


def screen_diff(expected, actual):
    """The first screen row that differs, as (row, column), or None."""
    for y in range(192):
        a = zx.address(0, y)
        if expected[a:a + 32] != actual[a:a + 32]:
            for b in range(32):
                if expected[a + b] != actual[a + b]:
                    return y, b
    return None


def compare(z, screen, label, c):
    got = z.get_state(bytearray(M))
    diffs = zxprobe.compare_state(M, got)
    z80_screen = z.peek(0x4000, 6144)
    where = screen_diff(screen.bitmap, z80_screen)
    if where:
        diffs.append(("screen", "model/zx.py", f"differs from row {where[0]}, byte {where[1]}"))
    c.compare(label, [], diffs)
    if diffs:
        out = zxprobe.ROOT / "output"
        (out / "game_mismatch_z80.scr").write_bytes(z80_screen + bytes(768))
        (out / "game_mismatch_port.scr").write_bytes(bytes(screen.bitmap) + bytes(768))
    return not diffs


def main():
    flight = sys.argv[1] if len(sys.argv) > 1 else "tour"
    keys_spec, length = FLIGHTS.get(flight) or recorder.FLIGHTS[flight]
    iterations = int(sys.argv[2]) if len(sys.argv) > 2 else length
    ranges = recorder.parse_keys(keys_spec)

    screen = zx.Screen()
    screen.install()
    game.wire_hooks()
    clock = [0]

    def port_clock():
        clock[0] += 3
        return clock[0]

    hardware.clock = port_clock
    hardware.source = Sequence()
    hardware.keys = lambda code: False

    c = Check(f"the whole game ({flight})")
    times = []
    started = time.time()
    with zxprobe.Spectrum() as z:
        z.poke("input_mode", [1])
        z.poke("test_clock", [0])
        z.poke("test_timer", [13])
        z.poke(KEYS_DOWN, bytes(256))
        g = game.Game()
        z.call("start_game")
        ok = compare(z, screen, "starting", c)
        held_before = None
        for i in range(iterations if ok else 0):
            held = [k for lo, hi, ks in ranges if lo <= i < hi for k in ks]
            codes = {hardware.KEY_CODES[k] for k in held}
            hardware.keys = lambda code, codes=codes: code in codes
            if held != held_before:
                page = bytearray(256)
                for code in codes:
                    page[code] = 1
                z.poke(KEYS_DOWN, page)
                held_before = held
            over = g.iterate()
            out = z.call("game_step")
            times.append(out["t"])
            if over is not None:
                print(f"  iteration {i}: {type(over).__name__} ({over})")
            if not compare(z, screen, f"iteration {i} keys {held}", c):
                break
    ok = c.report()
    if times:
        print(f"      {statistics.mean(times):,.0f} T-states a frame on average "
              f"({statistics.mean(times) / 69888:.1f} TV frames), {max(times):,} at most; "
              f"{time.time() - started:.0f} s")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
