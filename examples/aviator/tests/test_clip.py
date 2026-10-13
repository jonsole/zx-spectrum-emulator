"""Checks model/clip.py against the original's line clipping, run on the 6502.

- DrawClippedLine and DrawClippedHorizon: the moments recorded during the tour
  flight (tests/recorder.py) and random lines, comparing every byte the
  original leaves outside scratch, the screen and SELF_MODIFIED (below).
- ClipStartOfLine and ClipBestEndOfLine: the recorded moments and random
  lines, comparing whether the line survives, the clipped point and
  direction they return in zero page, and memory (xTemp1Lo, yTemp1Lo,
  maxCoord).
- SwapLinePoints: the recorded moments and random inputs, its results in
  zero page.
- The draw hook: for every line drawn, a hook that draws plain Bresenham
  lines in a 160x256 Mode 5 picture, from the point each line is drawn from
  out to each of its ends, must land within a pixel of every pixel the
  original's DrawCanopyLine lights on the BBC's screen, and they of it, in
  the same colour. The screen is cleared before each call so that pixels
  already lit cannot hide any of the line. A hook that joins the two ends
  with one line must do the same, except on clipped horizon halves, which
  jog by two pixels on the BBC (see clip.CanopyLine): within two there.
- clip.trace_canopy_line, which the hook's ends come from, must light exactly
  the original's pixels -- for the lines drawn above, and for the recorded
  calls of DrawCanopyLine itself, which include EraseCanopyLines' (drawn in
  colour 1 here, so that they show).

Left out of the memory comparison, besides what replay.compare leaves out,
are the bytes of DrawCanopyLine's code that it rewrites for each line's
direction (clip.SELF_MODIFIED). Only the drawing code reads them and it sets
each one before every use, so they are drawing, which the port leaves to its
own renderer, not state.

    python tests/test_clip.py
"""

import sys

from harness import Check, booted, interesting16, rng
import beeb
import recorder
from replay import check_recorded, compare
from model import clip, memory
from model import names as n
from model.memory import M

FLIGHT = "tour"
RECORDED = ["DrawClippedLine", "DrawClippedHorizon", "ClipStartOfLine", "ClipBestEndOfLine",
            "SwapLinePoints", "DrawCanopyLine"]
EXTRA = [(a, a + 1) for a in clip.SELF_MODIFIED]

RANDOM_CLIPS = 5_000
RANDOM_LINES = 2_000
RANDOM_SWAPS = 2_000

# The Mode 5 pixel row of the canopy's y = 0, from the original's xLookup and
# yLookup tables: y runs up the screen from there, so row = 159 - y.
BOTTOM_ROW = 159

# The colour pairs FlipColours sets: colourCycle with the colourLogic that
# goes with it (buffer 1 drawn in colour 2, buffer 2 in colour 1).
COLOUR_STATES = ((0xF0, 0x40), (0x0F, 0x80))
DRAW_IN_COLOUR_1 = 0x80


# ---- reading and setting the original's zero page ---------------------------

def pair(mem, hi, lo):
    return (mem[getattr(n, hi)] << 8) | mem[getattr(n, lo)]


def set_pair(mem, hi, lo, value):
    mem[getattr(n, hi)] = (value >> 8) & 0xFF
    mem[getattr(n, lo)] = value & 0xFF


def line_from(mem):
    """The line being clipped, from where the original keeps it."""
    return clip.Line(pair(mem, "RR", "R"), pair(mem, "SS", "S"), mem[n.TT],
                     pair(mem, "QQ", "W"), pair(mem, "H", "G"), mem[n.UU],
                     pair(mem, "I", "T"), pair(mem, "J", "U"), mem[n.V])


def put_line(mem, line):
    set_pair(mem, "RR", "R", line.x0)
    set_pair(mem, "SS", "S", line.y0)
    set_pair(mem, "QQ", "W", line.x1)
    set_pair(mem, "H", "G", line.y1)
    set_pair(mem, "I", "T", line.dx)
    set_pair(mem, "J", "U", line.dy)
    mem[n.TT], mem[n.UU], mem[n.V] = line.code0, line.code1, line.v


def moment(m):
    """The machine's state now, as a recorded moment."""
    s = m.snapshot()
    return beeb.Snapshot(s.mem[:recorder.MEMORY_TOP], s.a, s.x, s.y, s.s, s.pc, s.p)


def restore(m, snap):
    m.restore(beeb.Snapshot(snap.mem, snap.a, snap.x, snap.y, snap.s, snap.pc, snap.p))


# ---- random lines -------------------------------------------------------------

def coordinate(r, low, high):
    """A screen coordinate: often inside the canopy, often near it, sometimes
    far off, sometimes anything at all."""
    choice = r.random()
    if choice < 0.3:
        return r.randrange(low, high + 1)
    if choice < 0.7:
        return r.randrange(low - 400, high + 400) & 0xFFFF
    if choice < 0.9:
        return r.randrange(-8000, 8000) & 0xFFFF
    return interesting16(r)


def random_line(r):
    """A line as DrawClippedLine's first three parts leave it."""
    x0, x1 = coordinate(r, 4, 155), coordinate(r, 4, 155)
    y0, y1 = coordinate(r, 0, 151), coordinate(r, 0, 151)
    v = clip.HORIZON if r.random() < 0.1 else 0
    dx, dy = (x1 - x0) & 0xFFFF, (y1 - y0) & 0xFFFF
    if dx & 0x8000:
        v |= clip.LEFTWARDS
        dx = (-dx) & 0xFFFF
    if dy & 0x8000:
        v |= clip.DOWNWARDS
        dy = (-dy) & 0xFFFF
    return clip.Line(x0, y0, clip.classify(x0, y0), x1, y1, clip.classify(x1, y1), dx, dy, v)


def random_drawing_moment(m, r):
    """Set a booted machine up to draw a random line between two points:
    their coordinates, which end is behind, the colour state (with the
    drawing code modified for it, as DrawCanopyView does first) and how full
    the line buffers are. Returns the point IDs."""
    start, end = r.sample(range(252), 2)
    line = random_line(r)
    for pid, x, y in ((start, line.x0, line.y0), (end, line.x1, line.y1)):
        z = r.randrange(1, 0x8000) if r.random() < 0.8 else r.randrange(0x8000, 0x10000)
        for (lo, hi), value in zip(((n.xPointLo, n.xPointHi), (n.yPointLo, n.yPointHi),
                                    (n.zPointLo, n.zPointHi)), (x, y, z)):
            m.mem[lo + pid] = value & 0xFF
            m.mem[hi + pid] = value >> 8
    m.mem[n.colourCycle], m.mem[n.colourLogic] = r.choice(COLOUR_STATES)
    m.mem[n.lineBuffer1Count] = r.choice([255, 255, r.randrange(48), 46, 47])
    m.mem[n.lineBuffer2Count] = r.choice([47, 47, r.randrange(48, 95), 94, 95])
    m.call("ModifyDrawRoutine")
    m.mem[n.L], m.mem[n.M] = start, end
    return start, end


# ---- the screen ---------------------------------------------------------------

def lit_pixels(m):
    """{(x, row): logical colour} for every lit pixel on the BBC's screen."""
    return {(x, row): c for row, line in enumerate(m.logical_pixels()) for x, c in enumerate(line) if c}


def bresenham(x0, y0, x1, y1):
    """The pixels of a plain line from one end to the other."""
    pixels = []
    dx, dy = abs(x1 - x0), -abs(y1 - y0)
    sx, sy = (1 if x0 < x1 else -1), (1 if y0 < y1 else -1)
    err = dx + dy
    while True:
        pixels.append((x0, y0))
        if x0 == x1 and y0 == y1:
            return pixels
        e2 = 2 * err
        if e2 >= dy:
            err += dy
            x0 += sx
        if e2 <= dx:
            err += dx
            y0 += sy


def hook_picture(lines, through_start=True):
    """What a simple hook draws for the lines it is given, in a 160x256 Mode 5
    picture, as {(x, row): colour}: for each, a line from the point it is
    drawn from out to each of its ends, or with through_start False a single
    line from end to end."""
    picture = {}
    for line in lines:
        if through_start:
            runs = ((line.x_from, line.y_from, line.x0, line.y0),
                    (line.x_from, line.y_from, line.x1, line.y1))
        else:
            runs = ((line.x0, line.y0, line.x1, line.y1),)
        for run in runs:
            for x, y in bresenham(*run):
                picture[(x, BOTTOM_ROW - y)] = line.colour
    return picture


def traced(entry):
    """The pixels clip.trace_canopy_line lights for a buffer entry, as rows."""
    return {(x, BOTTOM_ROW - y) for one in clip.trace_canopy_line(*entry) for x, y in one}


def buffer_entry(mem, slot):
    """A line buffer entry, in trace_canopy_line's order (r, s, w, g, t, u, v)."""
    return tuple(mem[table + slot] for table in (n.lineBufferR, n.lineBufferS, n.lineBufferW,
                                                  n.lineBufferG, n.lineBufferT, n.lineBufferU,
                                                  n.lineBufferV))


def distance(a, b):
    """How far, in pixels across or down, the furthest pixel of a is from the
    nearest of b, and b's from a's; up to 3, or 99 if further."""
    worst = 0
    for one, other in ((a, b), (b, a)):
        for x, y in one:
            for d in range(4):
                if any((x + i, y + j) in other for i in range(-d, d + 1) for j in range(-d, d + 1)):
                    break
            else:
                d = 99
            worst = max(worst, d)
    return worst


# ---- running both -------------------------------------------------------------

def draw_both(m, snap, entry, horizon):
    """Draw the line of a moment on the original, on a cleared screen, and in
    the port with a hook that collects what it is given. Returns (original's
    memory, port's memory, lit pixels, lines the hook got, port's result)."""
    restore(m, snap)
    m.mem[beeb.SCREEN:0x8000] = bytes(0x8000 - beeb.SCREEN)
    m.call(entry)
    expected = bytes(m.mem[:len(snap.mem)])
    lit = lit_pixels(m)
    memory.load(snap.mem)
    got = []
    clip.draw_hook = got.append
    try:
        result = clip.draw_clipped_line(snap.mem[n.L], snap.mem[n.M], horizon)
    finally:
        clip.draw_hook = clip._no_drawing
    return expected, bytes(M[:len(snap.mem)]), lit, got, result


class Drawing:
    """The checks on drawn lines, accumulated over many moments."""

    def __init__(self, label):
        self.memory = Check(f"{label} memory")
        self.hook = Check(f"{label} hook")
        self.straight = Check(f"{label} end to end")
        self.trace = Check(f"{label} pixels")
        self.drawn = self.clipped = self.jogs = 0

    def check(self, m, snap, entry, horizon):
        expected, actual, lit, got, result = draw_both(m, snap, entry, horizon)
        where = f"L={snap.mem[n.L]} M={snap.mem[n.M]}"
        self.memory.compare(where, [], compare(snap, expected, actual, EXTRA))
        if not got:
            for c in (self.hook, self.straight):
                c.compare(where, "nothing drawn", "nothing drawn" if not lit else "lines lit")
            return
        self.drawn += 1
        line = got[0]
        self.clipped += line.clipped
        colours = sorted(set(lit.values()))
        picture = hook_picture(got)
        apart = distance(picture, lit)
        self.hook.compare(f"{where} {got} {apart} apart", (True, colours),
                          (apart <= 1, sorted(set(picture.values()))))
        # A clipped horizon half jogs at the clipped point (clip.CanopyLine).
        jog = line.horizon and line.clipped
        self.jogs += jog
        apart = distance(hook_picture(got, through_start=False), lit)
        self.straight.compare(f"{where} {got} {apart} apart", True, apart <= (2 if jog else 1))
        entry_now = buffer_entry(M, result.slot)
        self.trace.compare(f"{where} {entry_now}", sorted(lit), sorted(traced(entry_now)))

    def report(self):
        ok = True
        for c in (self.memory, self.hook, self.straight, self.trace):
            ok = c.report() and ok
        print(f"      ({self.drawn} of {self.memory.cases} lines drawn, {self.clipped} of them "
              f"clipped, {self.jogs} clipped horizon halves)")
        return ok


# ---- the checks ----------------------------------------------------------------

def check_recorded_lines(samples):
    ok = True
    m = booted()
    for name, horizon in (("DrawClippedLine", False), ("DrawClippedHorizon", True)):
        ok = check_recorded(FLIGHT, name, lambda s, h=horizon: clip.draw_clipped_line(
            s.mem[n.L], s.mem[n.M], h), EXTRA) and ok
        d = Drawing(f"{name} ({FLIGHT})")
        for snap in samples[name]:
            d.check(m, snap, name, horizon)
        ok = d.report() and ok
    return ok


def check_random_lines():
    ok = True
    r = rng()
    for name, horizon, cases in (("DrawClippedLine", False, RANDOM_LINES),
                                 ("DrawClippedHorizon", True, RANDOM_LINES // 2)):
        d = Drawing(f"{name} (random)")
        for _ in range(cases):
            m = booted()
            random_drawing_moment(m, r)
            d.check(m, moment(m), name, horizon)
        ok = d.report() and ok
    return ok


def run_clipper(m, snap, name):
    """Run ClipStartOfLine or ClipBestEndOfLine from a moment as DrawClippedLine
    calls it. AbortLine drops the return address the call pushed and returns
    through the one beneath it, DrawClippedLine's, so a second return into
    the trap goes there. Returns (whether the line survived, memory)."""
    restore(m, snap)
    ret = beeb.RETURN_TRAP - 1
    m.cpu.push(ret >> 8)
    m.cpu.push(ret & 0xFF)
    s = m.cpu.s
    m.call(name)
    return m.cpu.s == s, bytes(m.mem[:len(snap.mem)])


PORTS = {"ClipStartOfLine": clip.clip_start_of_line, "ClipBestEndOfLine": clip.clip_best_end_of_line}


def check_clip(c, m, name, snap, counts):
    survived, expected = run_clipper(m, snap, name)
    memory.load(snap.mem)
    line = line_from(snap.mem)
    kept = PORTS[name](line)
    counts[kept] += 1
    original = (True, expected[n.R], expected[n.S], expected[n.V]) if survived else (False,)
    port = (True, line.x0, line.y0, line.v) if kept else (False,)
    diffs = compare(snap, expected, bytes(M[:len(snap.mem)]))
    c.compare(f"line {[hex(v) for v in (pair(snap.mem, 'RR', 'R'), pair(snap.mem, 'SS', 'S'))]}",
              (original, []), (port, diffs))


def check_clippers(samples):
    ok = True
    m = booted()
    for name in PORTS:
        counts = {False: 0, True: 0}
        c = Check(f"{name} ({FLIGHT})")
        for snap in samples[name]:
            check_clip(c, m, name, snap, counts)
        ok = c.report() and ok
        print(f"      ({counts[True]} clipped, {counts[False]} dropped)")
        r = rng()
        counts = {False: 0, True: 0}
        c = Check(f"{name} (random)")
        for _ in range(RANDOM_CLIPS):
            m = booted()
            put_line(m.mem, random_line(r))
            check_clip(c, m, name, moment(m), counts)
        ok = c.report() and ok
        print(f"      ({counts[True]} clipped, {counts[False]} dropped)")
    return ok


def check_swap(samples):
    """SwapLinePoints, on its recorded inputs and random ones: its results are
    all in zero page."""
    m = booted()
    r = rng()
    c = Check("SwapLinePoints")
    snaps = list(samples["SwapLinePoints"])
    for _ in range(RANDOM_SWAPS):
        m = booted()
        put_line(m.mem, clip.Line(*(interesting16(r) for _ in range(2)), r.randrange(256),
                                  *(interesting16(r) for _ in range(2)), r.randrange(256),
                                  interesting16(r), interesting16(r), r.randrange(256)))
        snaps.append(moment(m))
    for snap in snaps:
        restore(m, snap)
        m.call("SwapLinePoints")
        line = line_from(snap.mem)
        clip.swap_line_points(line)
        c.compare(f"end {hex(line.x1)},{hex(line.y1)}",
                  (pair(m.mem, "RR", "R"), pair(m.mem, "SS", "S"), m.mem[n.TT]),
                  (line.x0, line.y0, line.code0))
    return c.report()


def check_canopy_line(samples):
    """trace_canopy_line against every recorded call of DrawCanopyLine, from
    DrawClippedLine and from EraseCanopyLines (which draws with colourLogic
    0), each drawn in colour 1 on a cleared screen."""
    m = booted()
    c = Check(f"DrawCanopyLine ({FLIGHT})")
    erasing = clipped = 0
    for snap in samples["DrawCanopyLine"]:
        mem = snap.mem
        erasing += mem[n.colourLogic] == 0
        restore(m, snap)
        m.mem[n.colourLogic] = DRAW_IN_COLOUR_1
        m.call("ModifyDrawRoutine")
        m.mem[beeb.SCREEN:0x8000] = bytes(0x8000 - beeb.SCREEN)
        m.call("DrawCanopyLine")
        entry = (mem[n.R], mem[n.S], mem[n.W], mem[n.G], mem[n.T], mem[n.U], mem[n.V])
        clipped += bool(entry[-1] & clip.CLIPPED)
        c.compare(f"entry {entry}", sorted(lit_pixels(m)), sorted(traced(entry)))
    ok = c.report()
    print(f"      ({erasing} of them erasing, {clipped} clipped)")
    return ok


def main():
    print("clip")
    samples = recorder.recordings(FLIGHT, RECORDED)     # fly once for any not cached
    ok = check_swap(samples)
    ok = check_clippers(samples) and ok
    ok = check_recorded_lines(samples) and ok
    ok = check_canopy_line(samples) and ok
    ok = check_random_lines() and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
