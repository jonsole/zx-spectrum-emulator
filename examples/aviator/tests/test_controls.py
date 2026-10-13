"""Checks model/controls.py against the original: the key logger and the
routines that read keys or the joystick, on recorded moments with keys held
at random (the same keys on both sides).

UpdateFlightModel's own parts (the axes and the throttle) are checked with
the rest of UpdateFlightModel, which needs the flight model.

    python tests/test_controls.py
"""

import sys

from harness import Check, booted, rng
import beeb
import recorder
import replay
from model import controls, hardware, memory
from model import names as n

FLIGHT = "tour"
CASES = 300
NAMES = list(hardware.KEY_CODES)


def run_with_keys(name, run, setup=None):
    m = booted()
    samples = recorder.recordings(FLIGHT, ["UpdateKeyLogger"])["UpdateKeyLogger"]
    r = rng()
    c = Check(name)
    for i in range(CASES):
        base = samples[i % len(samples)]
        held = set(r.sample(NAMES, r.choice([0, 1, 1, 2, 3])))
        stick = (r.randrange(0x10000), r.randrange(0x10000))
        fire = r.randrange(2)
        mem = bytearray(base.mem)
        if setup:
            setup(mem, r)
        m.keys = held
        m.joystick = stick
        codes = {hardware.KEY_CODES[k] for k in held}
        hardware.keys = lambda code: code in codes
        hardware.joystick = lambda ch: stick[ch - 1] if ch in (1, 2) else fire
        m.joystick_fire = fire
        snap = beeb.Snapshot(bytes(mem), base.a, base.x, base.y, base.s, m.label(name), base.p)
        expected = replay.replay(m, snap)
        memory.load(snap.mem)
        run()
        diffs = replay.compare(snap, expected, bytes(memory.M[:len(snap.mem)]))
        c.compare(f"keys {sorted(held)}", [], diffs)
    hardware.keys = hardware._no_keys
    hardware.joystick = hardware._centred
    m.keys = set()
    return c.report()


def main():
    print("controls")
    ok = run_with_keys("UpdateKeyLogger", controls.update_key_logger)

    def volume(mem, r):
        mem[n.soundData + 10] = r.choice([0, 1, 0xFF, 0xF1, 0xF0, 0xF8, r.randrange(256)])

    ok = run_with_keys("ProcessVolumeKeys", controls.process_volume_keys, volume) and ok

    def tab(mem, r):
        mem[n.pressingTab] = r.choice([0, 0x80])
        mem[n.row29_char20_4] = r.choice([0, 0x88])

    ok = run_with_keys("ToggleJoystick", controls.toggle_joystick, tab) and ok

    def joystick_on(mem, r):
        mem[n.row29_char20_4] = r.choice([0, 0x88])

    ok = run_with_keys("ReadJoystick", controls.read_joystick, joystick_on) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
