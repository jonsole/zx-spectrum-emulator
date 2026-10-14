"""Checks spectrum/flight.s and controls.s against the Python port, on the
cases tests/test_flight.py checks the port against the original with: the
moments recorded at each routine's entry during the tour, random inputs for
each routine, and recorded ApplyFlightModel moments scrambled into states
the tour never reaches (stalls, landings, crashes, turbulence, a bumpy
ride, running out of fuel).

Each case starts both sides from the same memory; the Z80 runs in its test
mode, where the timer gives v, v + 97, ... and both sides read the same
values, and where the sounds and envelopes asked for are logged. Compared:
the whole game state, the result, whether it crashed, the sounds and
envelopes, and how many times the timer was read.

    python tests/test_zx_flight.py [fraction]

fraction (default 0.25) is the share of test_flight.py's random cases to
run.
"""

import statistics
import sys

from harness import Check, rng
import recorder
import test_flight as tf
import zx as zxprobe
from model import dashboard, events, flight, hardware, memory, sound
from model import names as n
from model.memory import M

TIMER_STEP = 97


class Timer:
    """v + 97, v + 2 * 97, ...: the Z80's test timer from v."""

    def __init__(self, start):
        self.value = start
        self.reads = 0

    def __call__(self):
        self.value = (self.value + TIMER_STEP) & 0xFF
        self.reads += 1
        return self.value


def on_ground(snap):
    return snap.mem[n.L]


# Each routine: (Z80 label, registers from the snapshot, extra pokes, how to
# read the Z80's result, the Python call, the Python result).
def _z80_carry_clear(out):
    return out["carry"] == 0


ROUTINES = {
    "ApplyFlightModel": ("apply_flight_model", None, None, None),
    "AdjustTurn": ("adjust_turn", None, None, None),
    "AdjustVelocity": ("adjust_velocity", None, None, None),
    "AdjustRotation": ("adjust_rotation", None, None, None),
    "ApplyAerodynamics": ("apply_aerodynamics", None, "ground", None),
    "ScaleFlightForces": ("scale_flight_forces", None, None, None),
    "GetMoments": ("get_moments", None, None, None),
    "ApplyFlightControl": ("apply_flight_control", None, "ground", None),
    "ApplyTurnAndThrust": ("apply_turn_and_thrust", None, "ground", None),
    "CheckPlaneOnRunway": ("check_plane_on_runway", None, None, _z80_carry_clear),
    "ProcessLanding": ("process_landing", None, "ground", None),
    "ApplyBumpyRide": ("apply_bumpy_ride", lambda s: dict(bc=(s.y << 8) | s.x, de=s.c), None, None),
    "ScaleByAltitude": ("scale_by_altitude", lambda s: dict(hl=(s.y << 8) | s.x), None,
                        lambda out: (out["a"] << 16) | out["hl"]),
    "RetractFlapsIfFast": ("retract_flaps_if_fast", lambda s: dict(af=s.a << 8), None, None),
    "FillUpFuelTank": ("fill_up_fuel_tank", None, None, None),
    "SetEngine": ("set_engine", lambda s: dict(af=s.a << 8), None, None),
    "ToggleEngineSound": ("toggle_engine_sound", lambda s: dict(af=(0 if s.p & 0x02 else 1) << 8),
                          None, None),
    "MakeEngineSound": ("make_engine_sound", None, None, None),
    "ResetEngineSound": ("reset_engine_sound", None, None, None),
    "IndicatorU": ("indicator_u", None, None, None),
    "IndicatorF": ("indicator_f", None, None, None),
    "IndicatorB": ("indicator_b", None, None, None),
    "IndicatorT": ("indicator_t", None, None, None),
    "ProcessOtherKeys": ("process_other_keys", lambda s: dict(af=s.x << 8), None,
                         lambda out: out["a"]),
    "NextRandomNumber": ("next_random_number", None, None, lambda out: out["a"]),
}


# The routines that can end the flight, run through try_call; the rest are
# called directly, so their results in A and the carry survive.
RAISING = {"ApplyFlightModel", "ProcessLanding"}


class Runner:
    def __init__(self, z):
        self.z = z
        self.log = []
        sound.hook = lambda number: self.log.append(number)
        flight.define_envelope = lambda offset: self.log.append(offset | 0x80)
        flight.draw_fuel_pixel = lambda pixel, mode: None
        flight.show_upside_down_bar = dashboard.show_upside_down_bar
        flight.draw_indicator = lambda letter, lit: None
        z.poke("input_mode", [1])

    def run(self, name, snap, timer_start):
        label, registers, extra, z80_result = ROUTINES[name]
        port, result = tf.ROUTINES[name]
        z = self.z
        # The Z80.
        z.put_state(snap.mem)
        z.poke("test_timer", [timer_start])
        z.poke("sound_log_count", [0])
        if extra == "ground":
            z.poke("afm_on_ground", [on_ground(snap)])
        regs = registers(snap) if registers else {}
        if name in RAISING:
            out = z.call("try_call", hl=z.address(label), **regs)
            crashed = out["a"] == 1
        else:
            out = z.call(label, **regs)
            crashed = False
        z_result = None if crashed or z80_result is None else z80_result(out)
        got = z.get_state(bytearray(snap.mem))
        count = z.peek("sound_log_count", 1)[0]
        z_log = list(z.peek("sound_log", 16)[:count])
        z_timer = z.peek("test_timer", 1)[0]
        z_reads = 0
        v = timer_start
        while v != z_timer and z_reads < 256:
            v = (v + TIMER_STEP) & 0xFF
            z_reads += 1
        # The Python.
        memory.load(snap.mem)
        timer = Timer(timer_start)
        hardware.source = timer
        self.log.clear()
        p_crashed = False
        p_result = None
        try:
            p_result = port(snap)
        except events.Crash:
            p_crashed = True
        if p_crashed or z80_result is None:
            p_result = None
        if name == "CheckPlaneOnRunway":
            p_result = bool(p_result)
        expected = (p_crashed, p_result, list(self.log), timer.reads)
        actual = (crashed, z_result, z_log, z_reads)
        diffs = zxprobe.compare_state(M, got)
        if diffs:
            actual = actual + (diffs,)
        return expected, actual, out["t"]


def check(z, runner, name, cases, label):
    c = Check(f"{name} ({label})")
    times = []
    for snap, timer in cases:
        expected, actual, t = runner.run(name, snap, timer)
        times.append(t)
        c.compare(f"case {c.cases} a={snap.a:02X} x={snap.x:02X} y={snap.y:02X}", expected, actual)
    ok = c.report()
    if times:
        print(f"      {statistics.mean(times):,.0f} T-states on average, {max(times):,} at most")
    return ok


def main():
    fraction = float(sys.argv[1]) if len(sys.argv) > 1 else 0.25
    sides = tf.Sides()
    r = rng(5)
    ok = True
    with zxprobe.Spectrum() as z:
        runner = Runner(z)
        samples = recorder.recordings(tf.FLIGHT, list(ROUTINES))
        for name in ROUTINES:
            cases = [(snap, r.randrange(256)) for snap in samples.get(name, [])]
            if cases:
                ok = check(z, runner, name, cases, "tour") and ok
        for i, (name, count) in enumerate(tf.RANDOM_CASES.items()):
            if name not in ROUTINES:
                continue
            rr = rng(1983 + i)
            cases = []
            for _ in range(max(1, int(count * fraction))):
                snap, _ = tf._random_cases(sides, rr, name)
                cases.append((snap, rr.randrange(256)))
            ok = check(z, runner, name, cases, "random") and ok
        rs = rng(2024)
        cases = []
        for snap in samples["ApplyFlightModel"]:
            for _ in range(max(1, int(tf.SCRAMBLED_PER_MOMENT * fraction))):
                moment = sides.moment("ApplyFlightModel", tf._scramble(rs, sides, snap), base=snap)
                cases.append((moment, rs.randrange(256)))
        ok = check(z, runner, "ApplyFlightModel", cases, "scrambled") and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
