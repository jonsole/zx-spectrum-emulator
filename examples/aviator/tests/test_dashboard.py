"""Checks model/dashboard.py against the original, run on the 6502.

Every check compares two things: the memory the original leaves (outside
the temporaries, the stack and the screen, as replay.compare does), and the
picture. For the picture, the port's drawing hook is given to a renderer
that draws each event into a 160x256 Mode 5 picture, started from the
original's screen before the call; afterwards it must match the original's
screen pixel for pixel, which shows the hook's events carry everything the
original draws. The two screen bytes the game reads back as state are
compared in memory as well.

- The screen lookup tables are the mapping the port works out instead.
- GetHandVector exhaustively, ArtificialHorizon on random matrices, and
  GetRadarVector exhaustively, against the original's results.
- DrawVectorLine on random lines; ShowUpsideDownBar for every roll.
- UpdateIndicator for each indicator, on random inputs, a few hundred calls
  in a row so the line buffers carry over from one call to the next.
- The radar's alien and ResetRadar, which the tour never shows or calls,
  from the tour's moments with an alien put near the plane.
- Every routine on the moments recorded at its entry during the tour.

    python tests/test_dashboard.py
"""

import sys

from harness import Check, booted, interesting16, interesting8, rng  # sets up the paths
import beeb
import recorder
import replay
from model import dashboard, matrices, memory
from model import names as n
from model.memory import M

FLIGHT = "tour"
SCREEN = 0x5800
RANDOM_CASES = 20_000
SEQUENCE = 300               # UpdateIndicator calls in a row, per indicator

# ---- a renderer for the hook: a Mode 5 picture -------------------------------

# For each pixel position in a byte, the logical colour of every byte value.
PIXEL_TABLES = [bytes((((b >> (7 - k)) & 1) << 1) | ((b >> (3 - k)) & 1) for b in range(256))
                for k in range(4)]


def screen_picture(mem):
    """The Mode 5 screen in mem as 160x256 logical colours, row by row."""
    pic = bytearray(160 * 256)
    for y in range(256):
        start = SCREEN + (y >> 3) * 320 + (y & 7)
        row = bytes(mem[start:start + 320:8])
        base = y * 160
        for k in range(4):
            pic[base + k:base + 160:4] = row.translate(PIXEL_TABLES[k])
    return pic


class Picture:
    """A hook that draws the dashboard's events on a Mode 5 picture: a line
    sets its pixels to colour 3 or, erasing, 0; a pattern sets its four."""

    def __init__(self, mem):
        self.pixels = screen_picture(mem)

    def __call__(self, event):
        pixels = self.pixels
        if isinstance(event, dashboard.Line):
            colour = 0 if event.erase else 3
            for x, y in event.pixels():
                if x < 160:
                    pixels[y * 160 + x] = colour
        else:
            base = event.y * 160 + event.x
            for k, c in enumerate(event.colours()):
                pixels[base + k] = c


def pixel_differences(picture, mem):
    """How many pixels of the picture differ from the screen in mem."""
    screen = screen_picture(mem)
    if picture.pixels == screen:
        return 0
    return sum(1 for a, b in zip(picture.pixels, screen) if a != b)


def state_bytes(mem):
    """The screen bytes the game reads back as state."""
    return mem[dashboard.UPSIDE_DOWN_BAR], mem[dashboard.JOYSTICK_ENABLED]


def drawing(picture, run):
    dashboard.hook = picture
    try:
        return run()
    finally:
        dashboard.hook = dashboard._no_hook


class Stack:
    """Enough of a snapshot for replay.compare's stack exclusion."""

    def __init__(self, s):
        self.s = s


# ---- the screen mapping ------------------------------------------------------

def check_screen_tables():
    """DrawVectorLine finds a pixel's byte from yLookup and xLookup plus
    159 - J; the port takes that to be the byte of screen row screen_y(J)."""
    booted()
    c = Check("screen lookup tables")
    for j in range(256):
        row = j >> 3
        base = M[n.yLookupLo + row] | (M[n.yLookupHi + row] << 8)
        y = dashboard.screen_y(j)
        for col in range(40):
            offset = M[n.xLookupLo + col] | (M[n.xLookupHi + col] << 8)
            original = (base + offset + ((159 - j) & 0xFF)) & 0xFFFF
            c.compare((j, col), SCREEN + (y >> 3) * 320 + col * 8 + (y & 7), original)
    return c.report()


# ---- the pure routines -------------------------------------------------------

def check_get_hand_vector():
    m = booted()
    c = Check("GetHandVector")
    for x in range(7):
        for a in range(256):
            m.cpu.a, m.cpu.x = a, x
            m.call("GetHandVector")
            c.compare((a, x), (m.mem[n.W], m.mem[n.G], m.mem[n.R]), dashboard.get_hand_vector(a, x))
    return c.report()


def check_artificial_horizon():
    m = booted()
    r = rng()
    c = Check("ArtificialHorizon")
    for _ in range(RANDOM_CASES):
        for i in range(5):
            lo, hi = interesting8(r), interesting8(r)
            m.mem[n.matrix4Lo + i] = M[n.matrix4Lo + i] = lo
            m.mem[n.matrix4Hi + i] = M[n.matrix4Hi + i] = hi
        k, y = r.randrange(2), r.choice([0, 3])
        m.mem[n.K] = k
        m.cpu.y = y
        m.call("ArtificialHorizon")
        c.compare((k, y, bytes(M[n.matrix4Lo:n.matrix4Lo + 5]).hex(), bytes(M[n.matrix4Hi:n.matrix4Hi + 5]).hex()),
                  m.cpu.a, dashboard.artificial_horizon(k, y))
    return c.report()


def check_get_radar_vector():
    m = booted()
    c = Check("GetRadarVector")
    for x in (0, 1):
        for a in range(256):
            m.cpu.a, m.cpu.x = a, x
            m.call("GetRadarVector")
            t, u, v = dashboard.get_radar_vector(a, x)
            # The dot's direction is whatever V held, and is not looked at.
            original = (m.mem[n.T], m.mem[n.U], m.mem[n.V] if x == 0 else None, m.mem[n.previousCompass])
            c.compare((a, x), original, (t, u, v if x == 0 else None, M[n.previousCompass]))
    return c.report()


# ---- drawing -----------------------------------------------------------------

def check_vector_lines():
    """Random lines, on the canopy and on the dashboard, drawn one after
    another on the same screen."""
    m = booted()
    r = rng()
    picture = Picture(m.mem)
    c = Check("DrawVectorLine (random)")
    for _ in range(5_000):
        t, u = r.randrange(25), r.randrange(25)
        if t == 0 and u == 0:
            t = 1
        i = r.randrange(24, 136)
        j = r.choice([r.randrange(30, 131), r.randrange(184, 232)])
        v, mode = interesting8(r), interesting8(r)
        for name, value in (("I", i), ("J", j), ("T", t), ("U", u), ("V", v), ("N", mode)):
            m.mem[getattr(n, name)] = value
        m.call("DrawVectorLine")
        drawing(picture, lambda: dashboard.draw_vector_line(i, j, t, u, v, mode & 0x80))
        pixels = pixel_differences(picture, m.mem)
        c.compare((i, j, t, u, hex(v), hex(mode)), 0, pixels)
        if pixels:
            picture = Picture(m.mem)                   # start again from the original's screen
    return c.report()


def check_show_upside_down_bar():
    m = booted()
    picture = Picture(m.mem)
    c = Check("ShowUpsideDownBar (all)")
    for z in range(256):
        m.mem[n.zRotationHi] = M[n.zRotationHi] = z
        m.call("ShowUpsideDownBar")
        drawing(picture, dashboard.show_upside_down_bar)
        c.compare(z, (0, state_bytes(m.mem)), (pixel_differences(picture, m.mem), state_bytes(M)))
    return c.report()


def check_fuel():
    """DrawFuelPixel for every level, drawing then erasing, and
    UpdateFuelGauge on every count of the main loop's counter."""
    m = booted()
    r = rng()
    picture = Picture(m.mem)
    c = Check("DrawFuelPixel (all)")
    for x in (0, 0x80):
        for a in range(66):
            m.cpu.a, m.cpu.x = a, x
            m.call("DrawFuelPixel")
            drawing(picture, lambda: dashboard.draw_fuel_pixel(a, x))
            c.compare((a, x), 0, pixel_differences(picture, m.mem))
    ok = c.report()
    c = Check("UpdateFuelGauge (all)")
    for count in range(256):
        level = r.randrange(66)
        m.mem[n.mainLoopCounter] = M[n.mainLoopCounter] = count
        m.mem[n.fuelLevel] = M[n.fuelLevel] = level
        m.cpu.a, m.cpu.x = level, 0
        m.call("DrawFuelPixel")                    # something to erase
        drawing(picture, lambda: dashboard.draw_fuel_pixel(level, 0))
        m.call("UpdateFuelGauge")
        drawing(picture, dashboard.update_fuel_gauge)
        c.compare((count, level), 0, pixel_differences(picture, m.mem))
    return c.report() and ok


# ---- UpdateIndicator on random inputs ------------------------------------------

def _set(m, addr, value):
    m.mem[addr] = M[addr] = value & 0xFF


def _set16(m, lo, hi, value):
    _set(m, lo, value)
    _set(m, hi, value >> 8)


def _random_matrices(m, r):
    """Matrix 4 for a random attitude, built by the ported SetMatrices so it
    is a real rotation (a random one could put the horizon anywhere)."""
    for axis in range(3):
        _set16(m, n.xRotationLo + axis, n.xRotationHi + axis, r.randrange(0x10000))
        matrices.project_axis_angle(axis)
    matrices.set_matrices()
    m.mem[:SCREEN] = M[:SCREEN]                    # everything they wrote, below the screen


INPUTS = {
    0: lambda m, r: _set(m, n.yRotationHi, r.randrange(256)),
    1: lambda m, r: _set16(m, n.zVelocityPLo, n.zVelocityPHi, interesting16(r)),
    2: lambda m, r: _set16(m, n.yPlaneLo, n.yPlaneHi, interesting16(r)),
    3: lambda m, r: _set(m, n.altitudeMinutes, r.randrange(106)),
    4: lambda m, r: _set16(m, n.yVelocityHi, n.yVelocityTop, interesting16(r)),
    5: lambda m, r: _set16(m, n.yTurnHi, n.yTurnTop, interesting16(r)),
    6: lambda m, r: _set(m, n.slipRate, interesting8(r)),
    7: _random_matrices,
    8: lambda m, r: (_set(m, n.aileronPosition, interesting8(r)), _set(m, n.elevatorPosition, interesting8(r))),
    9: lambda m, r: _set(m, n.rudderPosition, interesting8(r)),
    10: lambda m, r: (_set(m, n.aileronPosition, interesting8(r)), _set(m, n.elevatorPosition, interesting8(r))),
    # The flight model keeps thrust within 0 to 1280. From 1488 the bar would
    # be off the right of the screen, where the original's pixels land in its
    # own code; the port does not follow it there.
    11: lambda m, r: _set16(m, n.thrustLo, n.thrustHi, r.choice([0, 1280, r.randrange(1281)])),
}


def check_update_indicator_random():
    ok = True
    for x in range(12):
        m = booted()
        r = rng(1983 + x)
        picture = Picture(m.mem)
        c = Check(f"UpdateIndicator {x} (random)")
        for _ in range(SEQUENCE):
            INPUTS[x](m, r)
            m.cpu.x = x
            m.call("UpdateIndicator")
            drawing(picture, lambda: dashboard.update_indicator(x))
            original = bytes(m.mem[:0x8000])
            diffs = replay.compare(Stack(m.cpu.s), original, bytes(M[:0x8000]))
            pixels = pixel_differences(picture, m.mem)
            c.compare(f"inputs at call {c.cases}", ([], 0, state_bytes(original)), (diffs, pixels, state_bytes(M)))
            if diffs or pixels:
                memory.load(original)                  # start again from the original's state
                picture = Picture(m.mem)
        ok = c.report() and ok
    return ok


# ---- recorded moments ----------------------------------------------------------

def zp(s, name):
    return s.mem[getattr(n, name)]


RECORDED = {
    "UpdateIndicator": lambda s: dashboard.update_indicator(s.x),
    "UpdateDashboard": lambda s: dashboard.update_dashboard(),
    "UpdateDash7To11": lambda s: dashboard.update_dash_7_to_11(),
    "DrawIndicatorHand": lambda s: dashboard.draw_indicator_hand(s.a, s.x),
    "DrawIndicatorLine": lambda s: dashboard.draw_indicator_line(s.x, zp(s, "W"), zp(s, "G"), zp(s, "R"),
                                                                 zp(s, "S"), zp(s, "H")),
    "ShowUpsideDownBar": lambda s: dashboard.show_upside_down_bar(),
    "DrawIndicatorBar": lambda s: dashboard.draw_indicator_bar(s.a, s.x, zp(s, "W"), s.y, zp(s, "H"),
                                                               None, zp(s, "S")),
    "DrawJoystickCross": lambda s: dashboard.draw_joystick_cross(s.a & 0x80),
    "DrawOrthoLine": lambda s: dashboard.draw_ortho_line((zp(s, "H") + zp(s, "W")) & 0xFF, s.mem[n.joyCoord],
                                                         zp(s, "S"), zp(s, "T"), zp(s, "U"), zp(s, "N") & 0x80),
    "EraseOrthoLine": lambda s: dashboard.erase_ortho_line((zp(s, "G") + zp(s, "W")) & 0xFF, s.mem[n.joyCoord],
                                                           zp(s, "S"), zp(s, "T"), zp(s, "U")),
    "DrawVectorLine": lambda s: dashboard.draw_vector_line(zp(s, "I"), zp(s, "J"), zp(s, "T"), zp(s, "U"),
                                                           zp(s, "V"), zp(s, "N") & 0x80),
    "UpdateRadarBlip": lambda s: dashboard.update_radar_blip(s.y),
    "DrawRadarBlip": lambda s: dashboard.draw_radar_blip(),
    "ResetRadar": lambda s: dashboard.reset_radar(),
    "UpdateFuelGauge": lambda s: dashboard.update_fuel_gauge(),
    "DrawFuelPixel": lambda s: dashboard.draw_fuel_pixel(s.a, s.x),
}

def _radar_result(s):
    t, u, v = dashboard.get_radar_vector(s.a, s.x)
    return (t, u) if s.x else (t, u, v)       # the dot's direction is not looked at


# Routines whose results come back in the temporaries: (the port's call, and
# the original's results from the moment, the machine and the memory it left).
RESULTS = {
    "GetHandVector": (lambda s: dashboard.get_hand_vector(s.a, s.x),
                      lambda s, m, mem: (mem[n.W], mem[n.G], mem[n.R])),
    "ArtificialHorizon": (lambda s: dashboard.artificial_horizon(zp(s, "K"), s.y),
                          lambda s, m, mem: m.cpu.a),
    "GetRadarVector": (_radar_result,
                       lambda s, m, mem: (mem[n.T], mem[n.U]) if s.x else (mem[n.T], mem[n.U], mem[n.V])),
}


def check_moments(name, samples, run, result=None, label=None):
    """Replay each moment through the original and the port, comparing the
    memory, the picture and the state bytes, and the results if given."""
    m = booted()
    c = Check(label or f"{name} ({FLIGHT})")
    for snap in samples:
        expected = replay.replay(m, snap)
        original_result = result(snap, m, expected) if result else None
        memory.load(snap.mem)
        picture = Picture(snap.mem)
        port_result = drawing(picture, lambda: run(snap))
        diffs = replay.compare(snap, expected, bytes(M[:len(snap.mem)]))
        pixels = pixel_differences(picture, expected)
        c.compare(f"pc &{snap.pc:04X} a={snap.a:02X} x={snap.x:02X} y={snap.y:02X}",
                  ([], 0, state_bytes(expected), original_result),
                  (diffs, pixels, state_bytes(M), port_result if result else None))
    return c.report()


def check_recorded(recordings):
    ok = True
    for name, run in RECORDED.items():
        ok = check_moments(name, recordings[name], run) and ok
    for name, (run, result) in RESULTS.items():
        ok = check_moments(name, recordings[name], run, result) and ok
    return ok


# ---- the alien on the radar, and ResetRadar --------------------------------------

def _with_alien(snap, r, pc, y=None):
    """A copy of a moment with object 33, the flying alien, put near the
    plane and the alien's old dot somewhere on the radar, to start the
    routine at pc from."""
    mem = bytearray(snap.mem)
    for axis, spread in ((0, 14), (1, 3), (2, 26)):
        plane = mem[n.xPlaneHi + axis]
        mem[n.xObjectHi + dashboard.ALIEN + axis * n.nextAxis] = (plane + r.randrange(-spread, spread + 1)) & 0xFF
    mem[n.xRadarBuffer + 1] = dashboard.RADAR_X + r.randrange(-12, 13)
    mem[n.yRadarBuffer + 1] = (dashboard.RADAR_J + r.randrange(-25, 26)) & 0xFF
    return beeb.Snapshot(bytes(mem), snap.a, snap.x, snap.y if y is None else y, snap.s, pc, snap.p)


def check_alien(recordings):
    r = rng()
    samples = recordings["UpdateRadarBlip"]
    blip = [_with_alien(s, r, s.pc, dashboard.ALIEN) for s in samples for _ in range(3)]
    ok = check_moments("UpdateRadarBlip", blip, RECORDED["UpdateRadarBlip"],
                       label="UpdateRadarBlip (alien)")
    reset = [_with_alien(s, r, n.ResetRadar) for s in samples]
    return check_moments("ResetRadar", reset, RECORDED["ResetRadar"], label="ResetRadar (tour+alien)") and ok


def main():
    print("dashboard")
    names = list(RECORDED) + list(RESULTS)
    recordings = recorder.recordings(FLIGHT, names)      # fly once for any not cached
    ok = True
    for check in (check_screen_tables, check_get_hand_vector, check_artificial_horizon,
                  check_get_radar_vector, check_vector_lines, check_show_upside_down_bar, check_fuel,
                  check_update_indicator_random):
        ok = check() and ok
    ok = check_recorded(recordings) and ok
    ok = check_alien(recordings) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
