"""The whole game: the Python port against the original, iteration by
iteration.

Two checks:

1. Starting up. The port loads the original's binary and dashboard as the
   original's loader does and runs StartGame; its memory must then match
   the original's at the top of its first main loop.
2. Flying. From the original's own starting memory, both run a flight's key
   script, with the same clock (advancing 3 centiseconds each time it is
   read, as bbc/beeb.py's per-read clock does) and the same timer values
   (one fixed sequence, a value a read). After every iteration, all of
   memory below the screen must match, and the two screen bytes the game
   reads (the upside-down bar and the joystick switch).

Left out of the comparison: the zero-page temporaries, the stack, the
screen, and the bytes of the BBC's line drawer that the original rewrites
for each line (only the drawer reads them).

    python tests/test_game.py [tour|theme] [iterations]
"""

import sys
import time

from harness import Check
import beeb
import recorder
from model import canopy, clip, game, hardware, memory
from model import names as n

TOP = 0x5800
SCREEN_STATE = (n.row25_char13_1, n.row29_char20_4)
EXCLUDED = ([(n.P, n.HH + 1), (0x0180, 0x0200)]
            + [(a, a + 1) for a in clip.SELF_MODIFIED + canopy.DRAWING_CODE])


def differences(original, port, limit=12):
    from replay import describe
    out = []
    for lo, hi in [(0, TOP)] + [(a, a + 1) for a in SCREEN_STATE]:
        for i in range(lo, hi):
            if original[i] != port[i] and not any(a <= i < b for a, b in EXCLUDED):
                out.append((describe(i), original[i], port[i]))
                if len(out) >= limit:
                    return out
    return out


class Sequence:
    """The timer values both sides read: the same fixed sequence."""

    def __init__(self):
        self.n = 0

    def __call__(self):
        self.n += 1
        return (self.n * 97 + 13) & 0xFF


def check_start():
    m = beeb.Beeb()
    m.boot()
    game.wire_hooks()
    game.load_image()
    game.start_game()
    c = Check("starting up")
    c.compare("boot", [], differences(m.mem, memory.M))
    return c.report()


def check_flight(flight, iterations):
    keys_spec, flight_length = recorder.FLIGHTS[flight]
    iterations = iterations or flight_length
    ranges = recorder.parse_keys(keys_spec)
    m = beeb.Beeb(clock="per-read", clock_step=3)
    m.boot()
    game.wire_hooks()
    memory.M[:] = m.mem
    m.via_t1 = Sequence()
    hardware.source = Sequence()
    clock = [m.centiseconds]

    def port_clock():
        clock[0] += 3
        return clock[0]

    hardware.clock = port_clock
    c = Check(f"{flight} flight")
    g = game.Game(start=False)
    started = time.time()
    for i in range(iterations):
        held = [k for lo, hi, ks in ranges if lo <= i < hi for k in ks]
        codes = {hardware.KEY_CODES[k] for k in held}
        hardware.keys = lambda code: code in codes
        m.iterate(held)
        over = g.iterate()
        if over is not None:
            # The original waits for RETURN inside the iteration that ended
            # the flight and goes straight on to a new game; the port returns
            # first, and starts the new game on the next call.
            if "RETURN" not in held:
                c.compare(f"iteration {i}", "flying", f"flight over: {over!r}")
                break
            print(f"  iteration {i}: {type(over).__name__} ({over}), then a new game")
            g.iterate()
        diffs = differences(m.mem, memory.M)
        c.compare(f"iteration {i} keys {held}", [], diffs)
        if diffs:
            break
    print(f"  ({i + 1} iterations in {time.time() - started:.0f} s)")
    hardware.keys = hardware._no_keys
    hardware.source = hardware._default
    hardware.clock = hardware._stopped_clock
    return c.report()


def main():
    flight = sys.argv[1] if len(sys.argv) > 1 else "tour"
    iterations = int(sys.argv[2]) if len(sys.argv) > 2 else 0
    print("the whole game")
    ok = check_start()
    ok = check_flight(flight, iterations) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
