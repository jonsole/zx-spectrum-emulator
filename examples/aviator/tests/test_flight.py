"""Checks model/flight.py against the original's flight model, run on the 6502.

Three kinds of case:

- moments recorded at each routine's entry during the tour flight
  (tests/recorder.py), replayed through the original and the port;
- random inputs, from the booted game, for each routine: the variables it
  reads are set at random (weighted towards the edges that its branches
  test) and everything else is as the game left it;
- recorded ApplyFlightModel moments with the plane's state scrambled -- put
  on the ground or just above it, on or off the runway, wheels up or down,
  brakes and flaps, stalling, near an exploding alien, out of fuel,
  descending fast -- for the branches the tour never reaches (it never
  stalls, lands, crashes, lowers the flaps or meets an alien).

Every case compares all memory below the screen except the zero-page
temporaries and the stack below the call; the routine's results; the
hooks' calls (sounds, envelopes, the fuel gauge, the upside-down bar)
against the original's calls to MakeSound, DefineEnvelope, DrawFuelPixel
and ShowUpsideDownBar; the indicators' screen bytes, which a test hook draws
as the original does; and whether it crashed. A case that crashes is
compared at the moment the original reaches Crash, since Crash never returns
(it waits for RETURN and starts a new game). The User VIA timer is fed the
same random bytes on both sides.

    python tests/test_flight.py
"""

import sys

from harness import Check, booted, interesting16, interesting8, rng  # (sets up the paths)
import beeb
import recorder
import replay
from model import events, flight, hardware, memory, sound
from model import names as n
from model.memory import M

FLIGHT = "tour"
TOP = 0x8000                 # memory compared: everything below the OS
MAX_CYCLES = 5_000_000

# The indicators' screen addresses and pixel patterns (lit, dim), from the
# source's header.
INDICATORS = {"U": (0x7E82, 0x77, 0x55), "F": (0x7E9A, 0xCC, 0x44),
              "B": (0x7EAA, 0x77, 0x55), "T": (0x7D82, 0x77, 0x55)}
INDICATOR_BYTES = [addr + row for addr, _, _ in INDICATORS.values() for row in range(3)]


# ---- running both sides ---------------------------------------------------

class Timer:
    """The values a sequence of VIA timer reads see; the same values for the
    original and the port, and a count of the reads each made."""

    def __init__(self, values):
        self.values = values or [0xFF]
        self.reads = 0

    def __call__(self):
        v = self.values[self.reads % len(self.values)]
        self.reads += 1
        return v


class Sides:
    """The booted machine with traps that log the original's calls to the
    routines the port leaves to hooks, and the port's hooks logging the same
    way."""

    def __init__(self):
        self.m = booted()
        self.base = self.m.snapshot()
        self.original_log = []
        self.port_log = []
        m = self.m
        traps = {
            "MakeSound": lambda: self.original_log.append(("sound", m.cpu.a)),
            "DefineEnvelope": lambda: self.original_log.append(("envelope", m.cpu.a)),
            "DrawFuelPixel": lambda: self.original_log.append(("fuel", m.cpu.a, m.cpu.x)),
            "ShowUpsideDownBar": lambda: self.original_log.append(("bar", m.mem[n.zRotationHi])),
        }
        for name, fn in traps.items():
            m.cpu.traps[m.label(name)] = fn
        self.crash = m.label("Crash")
        sound.hook = lambda number: self.port_log.append(("sound", number))
        flight.define_envelope = lambda offset: self.port_log.append(("envelope", offset))
        flight.draw_fuel_pixel = lambda pixel, mode: self.port_log.append(("fuel", pixel, mode))
        flight.show_upside_down_bar = lambda: self.port_log.append(("bar", M[n.zRotationHi]))
        flight.draw_indicator = draw_indicator

    def moment(self, entry, pokes=(), a=0, x=0, y=0, p=0x20, base=None):
        """A snapshot to run from: the booted game (or a recorded moment)
        with the given bytes changed, about to enter a routine."""
        start = self.base if base is None else base
        mem = bytearray(start.mem[:TOP])
        for addr, value in pokes:
            mem[addr] = value & 0xFF
        return beeb.Snapshot(bytes(mem), a, x, y, start.s, self.m.label(entry), p)

    def run(self, snap, port, result=None, timer=()):
        """Run the original and the port from snap. port(snap) runs the
        Python, returning its result; result(machine) reads the original's.
        Returns (inputs, expected, actual) for Check.compare."""
        m = self.m
        self.original_log.clear()
        self.port_log.clear()
        original_timer, port_timer = Timer(list(timer)), Timer(list(timer))

        m.via_t1 = original_timer
        m.restore(snap)
        cpu = m.cpu
        ret = beeb.RETURN_TRAP - 1
        cpu.push(ret >> 8)
        cpu.push(ret & 0xFF)
        cpu.run(until={beeb.RETURN_TRAP, self.crash}, max_cycles=MAX_CYCLES)
        if cpu.pc not in (beeb.RETURN_TRAP, self.crash):
            raise RuntimeError(f"&{snap.pc:04X} did not return (pc &{cpu.pc:04X})")
        original_crashed = cpu.pc == self.crash
        expected_mem = bytes(m.mem[:TOP])
        expected_result = None if original_crashed or result is None else result(m)

        memory.load(snap.mem)
        hardware.source = port_timer
        port_crashed = False
        actual_result = None
        try:
            actual_result = port(snap)
        except events.Crash:
            port_crashed = True
        if port_crashed or result is None:
            actual_result = None
        actual_mem = bytes(M[:TOP])

        diffs = replay.compare(snap, expected_mem, actual_mem)
        indicators = [(f"&{a:04X}", expected_mem[a], actual_mem[a]) for a in INDICATOR_BYTES
                      if expected_mem[a] != actual_mem[a]]
        expected = (original_crashed, expected_result, list(self.original_log),
                    original_timer.reads)
        actual = (port_crashed, actual_result, list(self.port_log), port_timer.reads)
        if diffs or indicators:
            actual = actual + (diffs + indicators,)
        return expected, actual


def draw_indicator(letter, lit):
    """A test hook that draws an indicator as the original does, so the
    screen bytes can be compared."""
    addr, on, off = INDICATORS[letter]
    for row in range(3):
        M[addr + row] = on if lit else off


def flags(a, c=0):
    """The status register after loading A (N and Z from it), with C."""
    return 0x20 | (0x80 if a & 0x80 else 0) | (0x02 if a == 0 else 0) | (c & 1)


# ---- the routines, as each side is asked for them --------------------------
#
# For each routine: how the port is called from a snapshot, and how the
# original's result is read off the machine (None when it returns nothing).

def _scale_by_altitude_result(m):
    return (m.cpu.y << 16) | (m.cpu.x << 8) | m.mem[n.V]


ROUTINES = {
    "ApplyFlightModel": (lambda s: flight.apply_flight_model(), None),
    "AdjustTurn": (lambda s: flight.adjust_turn(), None),
    "AdjustVelocity": (lambda s: flight.adjust_velocity(), None),
    "AdjustRotation": (lambda s: flight.adjust_rotation(), None),
    "ApplyAerodynamics": (lambda s: flight.apply_aerodynamics(s.mem[n.L]), None),
    "ScaleFlightForces": (lambda s: flight.scale_flight_forces(), None),
    "GetMoments": (lambda s: flight.get_moments(), None),
    "ApplyFlightControl": (lambda s: flight.apply_flight_control(s.mem[n.L]), None),
    "ApplyTurnAndThrust": (lambda s: flight.apply_turn_and_thrust(s.mem[n.L]), None),
    "CheckPlaneOnRunway": (lambda s: flight.check_plane_on_runway(), lambda m: m.cpu.c == 0),
    "ProcessLanding": (lambda s: flight.process_landing(s.mem[n.L]), None),
    "ApplyBumpyRide": (lambda s: flight.apply_bumpy_ride(s.x, s.y, s.c), None),
    "ScaleByAltitude": (lambda s: flight.scale_by_altitude((s.y << 8) | s.x),
                        _scale_by_altitude_result),
    "ResetVariable": (lambda s: flight.reset_variable(s.x), None),
    "RetractFlapsIfFast": (lambda s: flight.retract_flaps_if_fast(s.a), None),
    "FillUpFuelTank": (lambda s: flight.fill_up_fuel_tank(), None),
    "SetEngine": (lambda s: flight.set_engine(s.a), None),
    "ToggleEngineSound": (lambda s: flight.toggle_engine_sound(0 if s.p & 0x02 else 1), None),
    "MakeEngineSound": (lambda s: flight.make_engine_sound(), None),
    "ResetEngineSound": (lambda s: flight.reset_engine_sound(), None),
    "IndicatorU": (lambda s: flight.indicator_u(), None),
    "IndicatorF": (lambda s: flight.indicator_f(), None),
    "IndicatorB": (lambda s: flight.indicator_b(), None),
    "IndicatorT": (lambda s: flight.indicator_t(), None),
    "ProcessOtherKeys": (lambda s: flight.process_other_keys(s.x), lambda m: m.cpu.a),
    "NextRandomNumber": (lambda s: flight.next_random_number(), lambda m: m.cpu.a),
}


# ---- recorded moments -----------------------------------------------------

def check_recorded(sides):
    """Every recorded moment of every routine, from the tour. ApplyBumpyRide
    is never called there (the plane stays on the runway), nor are the
    indicators but IndicatorB, nor ResetEngineSound; those are covered by
    the random cases."""
    samples = recorder.recordings(FLIGHT, list(ROUTINES))
    r = rng(7)
    ok = True
    for name, (port, result) in ROUTINES.items():
        c = Check(f"{name} (tour)")
        for snap in samples[name]:
            timer = [r.randrange(256) for _ in range(4)]
            expected, actual = sides.run(snap, port, result, timer)
            c.compare(f"pc &{snap.pc:04X} a={snap.a:02X} x={snap.x:02X} y={snap.y:02X}",
                      expected, actual)
        ok = c.report() and ok
    return ok


# ---- random inputs --------------------------------------------------------

def _p16(lo, hi, value, i=0):
    return [(lo + i, value & 0xFF), (hi + i, (value >> 8) & 0xFF)]


def _p24(lo, hi, top, value, i=0):
    return [(lo + i, value & 0xFF), (hi + i, (value >> 8) & 0xFF), (top + i, (value >> 16) & 0xFF)]


def _r24(r):
    if r.random() < 0.3:
        return (interesting16(r) << 8 | r.randrange(256)) & 0xFFFFFF
    v = interesting16(r)
    return v | 0xFF0000 if v & 0x8000 else v


def _position(r):
    """A control position: often near the centre, sometimes at the limits."""
    choice = r.random()
    if choice < 0.5:
        return r.randrange(-6, 7) & 0xFF
    if choice < 0.8:
        return r.randrange(-116, 119) & 0xFF
    return r.randrange(256)


def _near_runway(r, sides):
    """xPlane and zPlane on, beside or near the runway, or anywhere."""
    base = sides.base.mem
    ax = base[n.xObjectLo + 1] | (base[n.xObjectHi + 1] << 8)
    az = base[n.zObjectLo + 1] | (base[n.zObjectHi + 1] << 8)
    if r.random() < 0.2:
        x, z = interesting16(r), interesting16(r)
    else:
        x = ax + r.randrange(-300, 600)
        z = az + r.randrange(-600, 24 * 256 + 600)
    return _p16(n.xPlaneLo, n.xPlaneHi, x) + _p16(n.zPlaneLo, n.zPlaneHi, z)


def _random_cases(sides, r, name):
    """(snapshot, timer values) for one random case of a routine."""
    timer = [r.randrange(256) for _ in range(4)]
    pk = []
    a = x = y = c = 0
    if name == "AdjustTurn":
        for i in range(3):
            pk += _p24(n.xTurnLo, n.xTurnHi, n.xTurnTop, _r24(r), i)
            pk += _p24(n.dxTurnLo, n.dxTurnHi, n.dxTurnTop, _r24(r), i)
    elif name == "AdjustVelocity":
        for i in range(3):
            pk += _p24(n.xVelocityLo, n.xVelocityHi, n.xVelocityTop, _r24(r), i)
            pk += _p16(n.dxVelocityLo, n.dxVelocityHi, interesting16(r), i)
    elif name == "AdjustRotation":
        for i in range(3):
            pk += [(n.xPlaneBot + i, r.randrange(256)), (n.xPlaneTop + i, interesting8(r))]
            pk += _p16(n.xPlaneLo, n.xPlaneHi, interesting16(r), i)
            pk += _p16(n.xVelocityHi, n.xVelocityTop, interesting16(r), i)
            pk += _p16(n.xRotationLo, n.xRotationHi, interesting16(r), i)
            pk += _p16(n.dxRotationLo, n.dxRotationHi, interesting16(r), i)
    elif name == "GetMoments":
        for i in range(3):
            pk += _p16(n.xTurnHi, n.xTurnTop, interesting16(r), i)
            pk += _p16(n.xLiftDragLo, n.xLiftDragHi, interesting16(r), i)
    elif name == "ApplyFlightControl":
        for i in range(3):
            pk += [(n.elevatorPosition + i, _position(r)),
                   (n.keyLoggerLo + i, r.choice([0, 0, 1])),
                   (n.keyLoggerHi + i, r.choice([1, 0xFF]))]
        pk += [(n.L, r.randrange(2))] + _p16(n.zLiftDragLo, n.zLiftDragHi, interesting16(r))
    elif name == "ScaleFlightForces":
        for i in (0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12):
            pk += _p16(n.xMomentsLo, n.xMomentsHi, interesting16(r), i)
        pk += [(n.forceFactor + 4, r.choice([39, 156])), (n.forceFactor + 5, r.randrange(256)),
               (n.forceFactor + 7, r.choice([0, 152]))]
    elif name == "ApplyTurnAndThrust":
        for i in range(3):
            pk += _p24(n.xMomentsScLo, n.xMomentsScHi, n.xMomentsScTop, _r24(r), i)
            pk += _p24(n.xControlsScLo, n.xControlsScHi, n.xControlsScTop, _r24(r), i)
            pk += _p24(n.xLiftDragScLo, n.xLiftDragScHi, n.xLiftDragScTop, _r24(r), i)
        pk += _p24(n.zSlipMomentScLo, n.zSlipMomentScHi, n.zSlipMomentScTop, _r24(r))
        pk += _p24(n.yFlapsLiftScLo, n.yFlapsLiftScHi, n.yFlapsLiftScTop, _r24(r))
        pk += _p16(n.yGravityLo, n.yGravityHi, interesting16(r))
        speed = r.choice([r.randrange(0, 0x4000), r.randrange(0x2E00, 0x3200), interesting16(r)])
        pk += _p16(n.zVelocityPLo, n.zVelocityPHi, speed)
        pk += _p16(n.thrustLo, n.thrustHi, r.choice([r.randrange(0, 1281), 1280, 1024, 0]))
        pk += [(n.engineStatus, r.randrange(2)), (n.L, r.randrange(2)),
               (n.yPlaneHi, interesting8(r)),
               (n.flapsStatus, r.randrange(2)), (n.forceFactor + 5, r.randrange(256)),
               (n.zLinearLo, r.randrange(256))]
    elif name == "ApplyAerodynamics":
        for i in range(3):
            pk += _p16(n.xVelocityPLo, n.xVelocityPHi, interesting16(r), i)
            pk += _p16(n.xTurnHi, n.xTurnTop, interesting16(r), i)
        if r.random() < 0.5:
            # Slow and steep, to stall.
            pk += _p16(n.zVelocityPLo, n.zVelocityPHi, r.randrange(0, 0x1000))
            pk += _p16(n.yVelocityPLo, n.yVelocityPHi, r.randrange(-0x800, 0x800) & 0xFFFF)
        pk += [(n.yPlaneHi, r.choice([0, 0, 1, interesting8(r)])),
               (n.yPlaneLo, r.choice([r.randrange(40), r.randrange(256)])),
               (n.forceFactor + 4, r.choice([39, 156])), (n.L, r.randrange(2)),
               (n.flapsStatus, r.randrange(2))]
    elif name == "ScaleByAltitude":
        v = interesting16(r)
        x, y = v & 0xFF, v >> 8
        pk += [(n.yPlaneHi, interesting8(r))]
    elif name == "CheckPlaneOnRunway":
        pk += _near_runway(r, sides)
    elif name == "ProcessLanding":
        pk += _landing_inputs(r, sides)
    elif name == "ApplyBumpyRide":
        x = r.choice([flight.Z_ROTATION, flight.Y_PLANE])
        y = r.randrange(9)
        c = r.randrange(2)
        pk += [(n.zVelocityPHi, interesting8(r))] + _p16(n.xTurnHi, n.xTurnTop, interesting16(r), x)
    elif name == "ResetVariable":
        x = r.randrange(256)
    elif name == "RetractFlapsIfFast":
        a = interesting8(r) if r.random() < 0.5 else r.randrange(10, 20)
        pk += [(n.flapsStatus, r.randrange(2)), (n.forceFactor + 5, r.randrange(256))]
    elif name == "FillUpFuelTank":
        pk += [(n.mainLoopCounter, r.randrange(256)), (n.fuelLevel, r.randrange(70)),
               (n.landingStatus, r.randrange(256))]
    elif name in ("SetEngine", "ToggleEngineSound", "MakeEngineSound", "ResetEngineSound"):
        a = r.randrange(2) if name == "SetEngine" else r.choice([0, 7, r.randrange(256)])
        pk += [(n.engineStatus, r.randrange(2)), (n.forceFactor + 5, r.randrange(256)),
               (n.zVelocityPHi, interesting8(r)),
               (flight.ENGINE_PITCH, r.choice([255, r.randrange(256)]))]
        pk += _p16(n.thrustLo, n.thrustHi, r.choice([r.randrange(0, 1281), 0, 1280]))
        if r.random() < 0.3:
            # Make the new pitch equal the old one.
            thrust = pk[-2][1] | (pk[-1][1] << 8)
            k = ((thrust >> 4) + pk[2][1]) & 0xFF
            pk.append((flight.ENGINE_PITCH, (k + 80) & 0xFF))
    elif name == "IndicatorU":
        pk += [(n.ucStatus, r.randrange(2)), (n.onGround, r.randrange(2)),
               (n.forceFactor + 5, r.randrange(256)), (n.yLandingGear, r.randrange(256))]
    elif name == "IndicatorF":
        pk += [(n.flapsStatus, r.randrange(2)), (n.forceFactor + 5, r.randrange(256)),
               (n.forceFactor + 7, r.randrange(256))]
    elif name == "IndicatorB":
        pk += [(n.brakesStatus, interesting8(r))]
    elif name == "IndicatorT":
        pk += [(n.themeStatus, interesting8(r))]
    elif name == "ProcessOtherKeys":
        x = r.choice([4, 5])
        key = r.choice([0, x, x + 3])
        pk += [(n.keyLoggerLo + x, key)]
        for i in range(5):
            pk += [(n.pressingUFBS + i, r.choice([0, 0, 1])), (n.ucStatus + i, r.randrange(2))]
    elif name == "NextRandomNumber":
        pk += [(n.randomNumbers, r.choice([r.randrange(12), r.randrange(256)]))]
    p = flags(a, c)
    return sides.moment(name, pk, a=a, x=x, y=y, p=p), timer


def _landing_inputs(r, sides):
    """The state ProcessLanding reads, at random but mostly near the ground."""
    pk = _near_runway(r, sides)
    pk += [(n.L, r.randrange(2)), (n.onGround, r.randrange(2)),
           (n.landingStatus, r.choice([0, 0x40, 0x80, r.randrange(256)])),
           (n.zVelocityPHi, r.choice([r.randrange(0, 20), interesting8(r)])),
           (n.yPlaneHi, r.choice([0, 0, 0, 0, 0xFF, 1, 2, 3])),
           (n.yPlaneLo, r.choice([r.randrange(16), r.randrange(256)])),
           (n.yLandingGear, r.choice([5, 10])),
           (n.yVelocityLo, r.randrange(256)),
           (n.yVelocityTop, r.choice([0xFF, 0xFF, 0xFE, 0, 1, 2, r.randrange(256)])),
           (n.yVelocityHi, r.choice([r.randrange(256), 0xFF - r.randrange(60), r.randrange(60)])),
           (n.ucStatus, r.randrange(2)), (n.engineStatus, r.randrange(2)),
           (n.propellorStatus, 0), (n.reached512ft, 0),
           (n.forceFactor + 5, r.randrange(256)), (flight.ENGINE_PITCH, r.randrange(256))]
    for i in range(3):
        pk += _p16(n.xRotationLo, n.xRotationHi, interesting16(r), i)
        pk += _p16(n.xTurnHi, n.xTurnTop, interesting16(r), i)
    pk += _p16(n.thrustLo, n.thrustHi, r.randrange(0, 1281))
    return pk


RANDOM_CASES = {
    "AdjustTurn": 2000, "AdjustVelocity": 2000, "AdjustRotation": 2000, "GetMoments": 2000,
    "ApplyFlightControl": 4000, "ScaleFlightForces": 2000, "ApplyTurnAndThrust": 3000,
    "ApplyAerodynamics": 3000, "ScaleByAltitude": 5000, "CheckPlaneOnRunway": 10000,
    "ProcessLanding": 10000, "ApplyBumpyRide": 3000, "ResetVariable": 1000,
    "RetractFlapsIfFast": 1000, "FillUpFuelTank": 2000, "SetEngine": 2000,
    "ToggleEngineSound": 2000, "MakeEngineSound": 2000, "ResetEngineSound": 100,
    "IndicatorU": 500, "IndicatorF": 500, "IndicatorB": 500, "IndicatorT": 500,
    "ProcessOtherKeys": 2000, "NextRandomNumber": 1000,
}


def check_random(sides):
    ok = True
    for i, (name, count) in enumerate(RANDOM_CASES.items()):
        r = rng(1983 + i)
        port, result = ROUTINES[name]
        c = Check(f"{name} (random)")
        for _ in range(count):
            snap, timer = _random_cases(sides, r, name)
            expected, actual = sides.run(snap, port, result, timer)
            c.compare(f"case {c.cases} a={snap.a:02X} x={snap.x:02X} y={snap.y:02X}",
                      expected, actual)
        ok = c.report() and ok
    return ok


# ---- scrambled flights ----------------------------------------------------

def _scramble(r, sides, snap):
    """Pokes that put a recorded ApplyFlightModel moment into a state the
    tour never reaches. The matrices are left as they were: the two sides
    see the same, possibly impossible, state, which is all a comparison
    needs."""
    pk = []
    if r.random() < 0.5:
        pk += _landing_inputs(r, sides)
    else:
        pk += [(n.onGround, r.randrange(2)), (n.ucStatus, r.randrange(2))]
    pk += [(n.brakesStatus, r.randrange(2)), (n.flapsStatus, r.randrange(2)),
           (n.engineStatus, r.choice([0, 1, 1])), (n.forceFactor + 4, r.choice([39, 156, 156])),
           (n.rudderPosition, _position(r)), (n.aileronPosition, _position(r)),
           (n.elevatorPosition, _position(r))]
    for i in range(3):
        pk += [(n.keyLoggerLo + i, r.choice([0, 0, 1])), (n.keyLoggerHi + i, r.choice([1, 0xFF]))]
    if r.random() < 0.3:
        pk += [(n.hitTimer, r.randrange(1, 256)), (n.distanceFromHit, r.randrange(20)),
               (n.randomNumbers, r.randrange(11))]
        pk += [(n.randomNumbers + 1 + i, r.randrange(256)) for i in range(11)]
    if r.random() < 0.5:
        # A velocity that is slow, steep, fast or sideways.
        for i in range(3):
            v = r.choice([r.randrange(-0x800, 0x800), r.randrange(-0x4000, 0x4000),
                          interesting16(r)])
            pk += _p24(n.xVelocityLo, n.xVelocityHi, n.xVelocityTop, (v << 8) | r.randrange(256), i)
    if r.random() < 0.3:
        pk += _p16(n.dyVelocityLo, n.dyVelocityHi, interesting16(r))
    if r.random() < 0.3:
        pk += [(n.fuelLevel, r.choice([0, 1, 2])), (n.fuelUsedLo, r.randrange(0xC0, 0x100)),
               (n.fuelUsedHi, r.randrange(0xF8, 0x100))]
    if r.random() < 0.3:
        pk += _p16(n.thrustLo, n.thrustHi, r.randrange(0, 1281))
    if r.random() < 0.3:
        for i in range(3):
            pk += _p24(n.xTurnLo, n.xTurnHi, n.xTurnTop, _r24(r), i)
    return pk


SCRAMBLED_PER_MOMENT = 20


def check_scrambled(sides):
    """Recorded ApplyFlightModel moments, scrambled. Reports how many cases
    reached the branches the tour does not."""
    samples = recorder.recordings(FLIGHT, ["ApplyFlightModel"])["ApplyFlightModel"]
    r = rng(2024)
    port, result = ROUTINES["ApplyFlightModel"]
    c = Check("ApplyFlightModel (scrambled)")
    seen = {"crashed": 0, "landed": 0, "stalled": 0, "strain": 0, "turbulence": 0,
            "bumpy ride": 0, "touchdown": 0, "engine cut": 0, "on ground": 0}
    for snap in samples:
        for _ in range(SCRAMBLED_PER_MOMENT):
            moment = sides.moment("ApplyFlightModel", _scramble(r, sides, snap), base=snap)
            timer = [r.randrange(256) for _ in range(4)]
            expected, actual = sides.run(moment, port, result, timer)
            c.compare(f"case {c.cases}", expected, actual)
            crashed, _, log, reads = expected[:4]
            seen["crashed"] += crashed
            seen["landed"] += not crashed and not moment.mem[n.onGround] and M[n.onGround] == 1
            seen["stalled"] += ("sound", 4) in log
            seen["strain"] += ("sound", 3) in log
            seen["turbulence"] += moment.mem[n.hitTimer] != 0 and moment.mem[n.distanceFromHit] < 16
            seen["bumpy ride"] += reads > 0
            seen["touchdown"] += ("sound", 26) in log
            seen["engine cut"] += moment.mem[n.engineStatus] == 1 and M[n.engineStatus] == 0
            seen["on ground"] += moment.mem[n.onGround]
    ok = c.report()
    print("      reached: " + ", ".join(f"{k} {v}" for k, v in seen.items()))
    return ok


def main():
    print("flight")
    sides = Sides()
    ok = check_recorded(sides)
    ok = check_random(sides) and ok
    ok = check_scrambled(sides) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
