"""Checks spectrum/theme.s and scoring.s against the Python port: the
moments tests/test_theme.py replays from the Theme flight, its synthetic
alien hits, explosions and high scores, every BCD score addition, and
planes placed in and around the bridge's and the town's skill zones, upside
down or not.

The Z80 runs in its test mode, where the timer gives v, v + 97, ... and
both sides read the same values. Compared: the whole game state, the
result in A where there is one, and whether the flight ended.

    python tests/test_zx_theme.py
"""

import statistics
import sys

from harness import Check, booted, rng
import recorder
import beeb
import test_theme as tt
from test_zx_flight import TIMER_STEP, Timer
import zx as zxprobe
from model import dashboard, events, flight, hardware, memory, scoring, sound, theme, visibility
from model import names as n
from model.memory import M

FLIGHT = "theme"

# Each routine: (Z80 label, registers from the snapshot, Python call, whether
# A is its result). The ones that can end the flight go through try_call.
ROUTINES = {
    "FireGuns": ("fire_guns", None, lambda s: theme.fire_guns(), False),
    "UpdateBullets": ("update_bullets", None, lambda s: theme.update_bullets(), False),
    "CheckIfAlienIsHit": ("check_if_alien_is_hit", lambda s: dict(af=s.mem[n.objectId] << 8),
                          lambda s: theme.check_if_alien_is_hit(s.mem[n.objectId]), False),
    "ExplodeAlien": ("explode_alien", None, lambda s: theme.explode_alien(), False),
    "SpawnAlien": ("spawn_alien", None, lambda s: theme.spawn_alien(), False),
    "UpdateAliens": ("update_aliens", None, lambda s: theme.update_aliens(), False),
    "AlienInAcornsville": ("alien_in_acornsville", None, lambda s: theme.alien_in_acornsville(), False),
    "SetRandomNumber": ("set_random_number", None, lambda s: theme.set_random_number(), True),
    "CheckFlyingSkills": ("check_flying_skills", lambda s: dict(af=s.y << 8),
                          lambda s: scoring.check_flying_skills(s.y), False),
    "UpdateHighScore": ("update_high_score", None, lambda s: scoring.update_high_score(), False),
    "SetObjectCoords": ("set_object_coords", lambda s: dict(af=s.mem[n.GG] << 8),
                        lambda s: visibility.set_object_coords(s.mem[n.GG]), True),
    "ProcessLine": ("process_line",
                    lambda s: dict(af=s.mem[n.lineId] << 8, bc=0 if s.mem[n.HH] else 1),
                    lambda s: visibility.process_line(s.mem[n.lineId], check_distance=not s.mem[n.HH]),
                    False),
    "ProcessLinesToHide": ("process_lines_to_hide", None, lambda s: visibility.process_lines_to_hide(),
                           False),
    "UpdateLinesToShow": ("update_lines_to_show", None, lambda s: visibility.update_lines_to_show(),
                          False),
}
RAISING = {"AlienInAcornsville", "CheckFlyingSkills"}


class Runner:
    def __init__(self, z):
        self.z = z
        sound.hook = lambda number: None
        flight.define_envelope = lambda offset: None
        flight.draw_fuel_pixel = lambda pixel, mode: None
        flight.show_upside_down_bar = dashboard.show_upside_down_bar
        flight.draw_indicator = lambda letter, lit: None
        dashboard.hook = lambda event: None
        scoring.display_hook = lambda *args: None
        z.poke("input_mode", [1])

    def run(self, name, snap, timer_start):
        label, registers, port, returns_a = ROUTINES[name]
        z = self.z
        z.put_state(snap.mem)
        z.poke("test_timer", [timer_start])
        regs = registers(snap) if registers else {}
        if name in RAISING:
            out = z.call("try_call", hl=z.address(label), **regs)
            over = out["a"] != 0
            z_result = None
        else:
            out = z.call(label, **regs)
            over = False
            z_result = out["a"] if returns_a else None
        got = z.get_state(bytearray(snap.mem))
        memory.load(snap.mem)
        hardware.source = Timer(timer_start)
        p_over = False
        p_result = None
        try:
            p_result = port(snap)
        except events.FlightOver:
            p_over = True
        if not returns_a or p_over:
            p_result = None
        elif p_result is not None:
            p_result &= 0xFF
        expected = (p_over, p_result)
        actual = (over, z_result)
        diffs = zxprobe.compare_state(M, got)
        if diffs:
            actual = actual + (diffs,)
        return expected, actual, out["t"]


def check(runner, name, cases, label):
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


def synthetic(name, setup, count, seed):
    """Cases made from recorded UpdateAliens moments by setup(mem, r), as
    test_theme.py makes them; registers as setup returns them."""
    m = booted()
    samples = recorder.recordings(FLIGHT, ["UpdateAliens"])["UpdateAliens"]
    r = rng(seed)
    cases = []
    for i in range(count):
        base = samples[i % len(samples)]
        mem = bytearray(base.mem)
        regs = setup(mem, r)
        snap = beeb.Snapshot(bytes(mem), regs.get("a", base.a), regs.get("x", base.x),
                             regs.get("y", base.y), base.s, m.label(name), base.p)
        cases.append((snap, r.randrange(256)))
    return cases


def alien_hit_setup(mem, r):
    oid = r.choice([30, 31, 32, 33])
    mem[n.objectId] = oid
    mem[n.hitTimer] = 0
    for pid in (183, 188):
        mem[n.zObjectPoint + pid] = (mem[n.zObjectPoint + pid] & 15) | (r.randrange(2, 6) << 4)
    ax, ay, az = r.randrange(0x1000, 0xE000), r.randrange(0, 0x0800), r.randrange(0x1000, 0xE000)
    tt._set_object(mem, oid, ax, ay, az)
    spot = (ax + 0x500, ay, az + 0x500)
    aimed = r.random() < 0.5
    for back, front in ((12, 13), (14, 15)):
        if aimed:
            near = [s + r.randrange(0, 0x14) for s in spot]
            step = [r.randrange(-0x40, 0x40) for _ in range(3)]
        else:
            near = [s + r.randrange(-0x180, 0x180) for s in spot]
            step = [r.randrange(-0x300, 0x300) for _ in range(3)]
        tt._set_object(mem, back, *near)
        tt._set_object(mem, front, *(a + b for a, b in zip(near, step)))
    return {"y": oid}


def explosion_setup(mem, r):
    mem[n.hitObjectId] = r.choice([30, 31, 32, 33])
    mem[n.hitTimer] = r.choice([1, 2, 26, 27, r.randrange(1, 28)])
    mem[n.feedingStage] = r.randrange(5)
    mem[n.randomNumbers] = r.randrange(11)
    for i in range(11):
        mem[n.randomNumbers + 1 + i] = r.randrange(256)
    return {}


def high_score_setup(mem, r):
    for name in ("scoreHi", "scoreLo", "highScoreHi", "highScoreLo"):
        mem[getattr(n, name)] = r.choice([0x00, 0x01, 0x10, 0x99, r.randrange(0x9A)])
    return {}


def skills_setup(mem, r):
    """The plane in or near one of the bridge's or the town's skill zones,
    upside down or not, with points banked or not."""
    target = r.choice([scoring.BRIDGE, scoring.TOWN])
    zones = (0, 3, 6) if target == scoring.BRIDGE else (9, 12, 15, 18)
    zone = r.choice(zones)
    for axis in range(3):
        i = zone + axis
        corner = mem[n.skillZoneLo + i] | (mem[n.skillZoneHi + i] << 8)
        size = mem[n.skillZoneSize + i] * 4
        v = corner + r.choice([r.randrange(-8, size + 8), r.randrange(size), -1, size, 0])
        mem[n.xPlaneLo + axis] = v & 0xFF
        mem[n.xPlaneHi + axis] = (v >> 8) & 0xFF
    mem[dashboard.UPSIDE_DOWN_BAR] = r.choice([0, dashboard.UPSIDE_DOWN_PATTERN])
    mem[n.pointsToAward] = r.choice([0, 0, 0x05, 0x10, 0x20])
    return {"y": target}


def check_bcd(z):
    c = Check("update_score (pairs)")
    digits = [d for d in range(256) if (d >> 4) < 10 and (d & 15) < 10]
    for hi in (0x00, 0x01, 0x05, 0x50, 0x98, 0x99):
        for lo in digits:
            for add in (0x0003, 0x0005, 0x0010, 0x0020, 0x0040, 0x0050, 0x0099, 0x0150, 0x0015):
                z.poke("scoreLo", [lo])
                z.poke("scoreHi", [hi])
                z.call("update_score", de=add)
                M[n.scoreHi], M[n.scoreLo] = hi, lo
                scoring.update_score(add)
                c.compare((hex(hi), hex(lo), hex(add)), (M[n.scoreHi], M[n.scoreLo]),
                          (z.peek("scoreHi", 1)[0], z.peek("scoreLo", 1)[0]))
    return c.report()


def main():
    ok = True
    with zxprobe.Spectrum() as z:
        runner = Runner(z)
        ok = check_bcd(z) and ok
        samples = recorder.recordings(FLIGHT, list(ROUTINES))
        for name in ROUTINES:
            cases = [(snap, (i * 37 + 11) & 0xFF) for i, snap in enumerate(samples.get(name, []))]
            if cases:
                ok = check(runner, name, cases, FLIGHT) and ok
        ok = check(runner, "CheckIfAlienIsHit", synthetic("CheckIfAlienIsHit", alien_hit_setup, 400, 1),
                   "synthetic") and ok
        ok = check(runner, "ExplodeAlien", synthetic("ExplodeAlien", explosion_setup, 300, 2),
                   "synthetic") and ok
        ok = check(runner, "UpdateHighScore", synthetic("UpdateHighScore", high_score_setup, 300, 3),
                   "synthetic") and ok
        ok = check(runner, "CheckFlyingSkills", synthetic("CheckFlyingSkills", skills_setup, 1000, 4),
                   "synthetic") and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
