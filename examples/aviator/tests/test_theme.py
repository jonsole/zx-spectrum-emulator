"""Checks model/theme.py and model/scoring.py against the original, on moments
recorded during the theme flight (tests/recorder.py), plus the visibility
routines again, since the Theme's aliens take paths through them the tour
never does. The BCD score addition is checked on every pair of scores.

The routines that read the VIA timer for random numbers are given the same
value on both sides: a different one for each moment.

    python tests/test_theme.py
"""

import sys

from harness import Check, booted
import recorder
import replay
from model import events, hardware, memory, scoring, theme, visibility
from model import names as n

FLIGHT = "theme"

CHECKS = {
    "FireGuns": lambda s: theme.fire_guns(),
    "UpdateBullets": lambda s: theme.update_bullets(),
    "CheckIfAlienIsHit": lambda s: theme.check_if_alien_is_hit(s.mem[n.objectId]),
    "ExplodeAlien": lambda s: theme.explode_alien(),
    "SpawnAlien": lambda s: theme.spawn_alien(),
    "UpdateAliens": lambda s: theme.update_aliens(),
    "AlienInAcornsville": lambda s: theme.alien_in_acornsville(),
    "SetRandomNumber": lambda s: theme.set_random_number(),
    "CheckFlyingSkills": lambda s: scoring.check_flying_skills(s.y),
    "UpdateHighScore": lambda s: scoring.update_high_score(),
    "SetObjectCoords": lambda s: visibility.set_object_coords(s.mem[n.GG]),
    "ProcessLine": lambda s: visibility.process_line(s.mem[n.lineId], check_distance=not s.mem[n.HH]),
    "ProcessLinesToHide": lambda s: visibility.process_lines_to_hide(),
    "UpdateLinesToShow": lambda s: visibility.update_lines_to_show(),
}


def check_bcd():
    m = booted()
    c = Check("UpdateScore (all pairs)")
    digits = [d for d in range(256) if (d >> 4) < 10 and (d & 15) < 10]
    for hi in (0x00, 0x01, 0x05, 0x50, 0x98, 0x99):
        for lo in digits:
            for add in (0x0003, 0x0005, 0x0010, 0x0020, 0x0040, 0x0050, 0x0099, 0x0150):
                for mem in (m.mem, memory.M):
                    mem[n.scoreHi], mem[n.scoreLo] = hi, lo
                m.cpu.a, m.cpu.x = add & 0xFF, add >> 8
                m.call("UpdateScore")
                scoring.update_score(add)
                c.compare((hex(hi), hex(lo), hex(add)), (m.mem[n.scoreHi], m.mem[n.scoreLo]),
                          (memory.M[n.scoreHi], memory.M[n.scoreLo]))
    return c.report()


def check_with_timer(name, run):
    """replay.check_recorded, with the VIA timer read fixed for each moment."""
    m = booted()
    samples = recorder.recordings(FLIGHT, [name])[name]
    c = Check(f"{name} ({FLIGHT})")
    for i, snap in enumerate(samples):
        value = (i * 37 + 11) & 0xFF
        m.via_t1 = lambda: value
        hardware.source = lambda: value
        try:
            expected = replay.replay(m, snap)
        except RuntimeError:
            # The routine didn't return: the original crashed or ended the
            # game, which the port signals with an exception instead.
            memory.load(snap.mem)
            try:
                run(snap)
                c.compare(f"pc &{snap.pc:04X}", "game over", "carried on")
            except events.FlightOver:
                c.compare(f"pc &{snap.pc:04X}", "game over", "game over")
            continue
        memory.load(snap.mem)
        run(snap)
        diffs = replay.compare(snap, expected, bytes(memory.M[:len(snap.mem)]))
        c.compare(f"pc &{snap.pc:04X} a={snap.a:02X} x={snap.x:02X} y={snap.y:02X}", [], diffs)
    m.via_t1 = None
    hardware.source = hardware._default
    return c.report()


def _synthetic(name, samples, setup, run, cases, observe=None):
    """Moments made from recorded ones: setup(mem, rng) changes the copy of
    memory (both sides get the same), then the routine runs on both.
    observe(), if given, is called after each run of the port."""
    from harness import rng
    import beeb
    m = booted()
    r = rng()
    c = Check(f"{name} (synthetic)")
    for i in range(cases):
        base = samples[i % len(samples)]
        mem = bytearray(base.mem)
        regs = setup(mem, r)
        snap = beeb.Snapshot(bytes(mem), regs.get("a", base.a), regs.get("x", base.x),
                             regs.get("y", base.y), base.s, m.label(name), base.p)
        expected = replay.replay(m, snap)
        memory.load(snap.mem)
        run(snap)
        if observe:
            observe()
        diffs = replay.compare(snap, expected, bytes(memory.M[:len(snap.mem)]))
        c.compare(f"case {i}", [], diffs)
    return c.report()


def _set_object(mem, oid, x, y, z):
    for base_lo, base_hi, v in ((n.xObjectLo, n.xObjectHi, x), (n.yObjectLo, n.yObjectHi, y),
                                (n.zObjectLo, n.zObjectHi, z)):
        mem[base_lo + oid] = v & 0xFF
        mem[base_hi + oid] = (v >> 8) & 0xFF


def check_alien_hits():
    """Bullet trails placed around an alien's weak spot at random, so that
    some pass through it and some miss, for each alien object and every
    feeding stage."""
    samples = recorder.recordings(FLIGHT, ["UpdateAliens"])["UpdateAliens"]

    def setup(mem, r):
        oid = r.choice([30, 31, 32, 33])
        mem[n.objectId] = oid
        mem[n.hitTimer] = 0
        for pid in (183, 188):
            mem[n.zObjectPoint + pid] = (mem[n.zObjectPoint + pid] & 15) | (r.randrange(2, 6) << 4)
        ax, ay, az = r.randrange(0x1000, 0xE000), r.randrange(0, 0x0800), r.randrange(0x1000, 0xE000)
        _set_object(mem, oid, ax, ay, az)
        spot = (ax + 0x500, ay, az + 0x500)
        aimed = r.random() < 0.5                 # half the trails start in the box
        for back, front in ((12, 13), (14, 15)):
            if aimed:
                near = [s + r.randrange(0, 0x14) for s in spot]
                step = [r.randrange(-0x40, 0x40) for _ in range(3)]
            else:
                near = [s + r.randrange(-0x180, 0x180) for s in spot]
                step = [r.randrange(-0x300, 0x300) for _ in range(3)]
            _set_object(mem, back, *near)
            _set_object(mem, front, *(a + b for a, b in zip(near, step)))
        return {"y": oid}

    hits = []
    ok = _synthetic("CheckIfAlienIsHit", samples, setup,
                    lambda s: theme.check_if_alien_is_hit(s.mem[n.objectId]), 400,
                    observe=lambda: hits.append(memory.M[n.hitTimer] == theme.EXPLOSION))
    print(f"      ({sum(hits)} of them hits)")
    return ok


def check_explosions():
    """Explosions part-way through, for each alien and feeding stage, and the
    last iteration of each, which scores it."""
    samples = recorder.recordings(FLIGHT, ["UpdateAliens"])["UpdateAliens"]

    def setup(mem, r):
        mem[n.hitObjectId] = r.choice([30, 31, 32])
        mem[n.hitTimer] = r.choice([1, 2, 26, 27, r.randrange(1, 28)])
        mem[n.feedingStage] = r.randrange(5)
        mem[n.randomNumbers] = r.randrange(11)
        for i in range(11):
            mem[n.randomNumbers + 1 + i] = r.randrange(256)
        return {}

    return _synthetic("ExplodeAlien", samples, setup, lambda s: theme.explode_alien(), 300)


def check_high_score():
    samples = recorder.recordings(FLIGHT, ["UpdateAliens"])["UpdateAliens"]

    def setup(mem, r):
        for name in ("scoreHi", "scoreLo", "highScoreHi", "highScoreLo"):
            mem[getattr(n, name)] = r.choice([0x00, 0x01, 0x10, 0x99, r.randrange(0x9A)])
        return {}

    return _synthetic("UpdateHighScore", samples, setup, lambda s: scoring.update_high_score(), 300)


def main():
    print("theme and scoring")
    ok = check_bcd()
    recorder.recordings(FLIGHT, list(CHECKS))
    for name, run in CHECKS.items():
        ok = check_with_timer(name, run) and ok
    ok = check_alien_hits() and ok
    ok = check_explosions() and ok
    ok = check_high_score() and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
