"""Checks the Revs road engine against models of what it should do.

    python examples/revs/tests/run_tests.py [--no-build] [name ...]

Builds the engine (build.py, which needs sjasmplus and the track data), then
runs it in cpp-core's snapshot_probe and checks:

  maths    log16, yaw_angle, pitch_line and verge_width, called directly,
           against exact values and view_model.py's BBC routines
  verges   the verge point lists the Z80 builds, against view_model.py's
           from the same camera, at a dozen places round the track
  screen   the view on the screen, byte for byte, against screen_model.py's
           edges and compose fed the Z80's own point lists
  compose  compose_screen on marker records shuffled out of x order, so that
           it has to sort them
  beam     that every update's writes to the screen show in the same frame,
           so no frame mixes two views
  speed    the work from each frame interrupt to the next HALT over a lap,
           whose median must fit in three frames

With names it runs only those. The probe has to have been built first:

    cpp-core/build.ps1 -Release -Target snapshot_probe

Expected values are worked out from the models, never captured from the
Z80's own output. The emulator does not model contended memory, so the
speed check says what an uncontended 48K would do.
"""

import argparse
import math
import random
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
REVS = HERE.parent
sys.path.insert(0, str(REVS))
sys.path.insert(0, str(HERE))

import screen_model as sm  # noqa: E402
import track_data  # noqa: E402
import view_model as vm  # noqa: E402
from probe import Probe, ProbeError, find_probe, read_symbols, signed16  # noqa: E402
from track_model import Track  # noqa: E402

SNAPSHOT = REVS / "output" / "revs.z80"
SLD = REVS / "output" / "revs.sld"

# Camera segments the views are checked at: straights, the hairpins and the
# fast curves, and both sides of the start line.
SEGMENTS = [0, 60, 150, 300, 330, 480, 520, 600, 700, 760, 900, 1010]
# The 48K's frame, and the three of them an update has to fit in.
FRAME_TSTATES = 69_888
BUDGET = 3 * FRAME_TSTATES
# Frames for the engine to get from `start` to its main loop: the track and
# the first view are built before it gets there.
STARTUP_FRAMES = 200
# More than one update can take; a runto that needs longer has hung.
UPDATE_FRAMES = 50
# Updates for the camera to go once round Silverstone at its own speed.
LAP_UPDATES = 1100


class Views:
    """The engine's memory at each of SEGMENTS, at two moments: at the HALT
    (the verge lists and markers for this camera, before compose uses them)
    and back at main_loop after (this camera's view on the screen, though
    the next update's first points have been started by then)."""

    def __init__(self, probe: Probe):
        self.at_halt = {}
        self.composed = {}
        probe.load(SNAPSHOT)
        probe.runto("main_loop", STARTUP_FRAMES)
        for seg in SEGMENTS:
            # Moving the camera at main_loop: the update now running draws
            # the old camera's view, the next one this.
            probe.set_word("cam_seg", seg)
            probe.runto("main_loop", UPDATE_FRAMES)
            probe.runto("main_loop.wait_frame", UPDATE_FRAMES)
            self.at_halt[seg] = probe.memory()
            probe.runto("main_loop", UPDATE_FRAMES)
            self.composed[seg] = probe.memory()


class Report:
    def __init__(self):
        self.failures = 0

    def result(self, name: str, ok: bool, detail: str) -> None:
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
        if not ok:
            self.failures += 1

    def note(self, line: str) -> None:
        print(f"       {line}")


def check_maths(probe: Probe, report: Report) -> None:
    probe.load(SNAPSHOT)
    probe.runto("main_loop", STARTUP_FRAMES)
    rng = random.Random(1)

    # log16: 256 log2 v, from a 12-bit table, so within 2 of exact.
    bad = []
    for i in range(400):
        v = rng.randint(1, 65535) if i % 2 else rng.randint(1, 4000)
        got = probe.call("log16", de=v)["hl"]
        if abs(got - 256 * math.log2(v)) > 2:
            bad.append((v, got))
    report.result("maths: log16", not bad, f"{400 - len(bad)} of 400 within 2/256 of log2"
                  + (f"; first wrong {bad[:3]}" if bad else ""))

    # yaw_angle: the angle within 96 (3/8 of one of the BBC's arctan steps
    # of 32), and the distance it leaves in ya_logd within 1.2% -- or 2
    # units, close in.
    bad = []
    for i in range(600):
        dx, dz = rng.randint(-6000, 6000), rng.randint(-6000, 6000)
        if rng.random() < 0.1:
            dz = rng.choice([0, dx, -dx])        # the axes and diagonals
        got = probe.call("yaw_angle", de=dx, bc=dz)["hl"]
        want, m = vm.yaw_angle(dx, dz)
        want_dist = vm.distance(dx, dz, m)
        got_dist = 2 ** (signed16(probe.word("ya_logd")) / 256)
        if abs(signed16(got - want)) > 96 or (
                want_dist > 0 and abs(got_dist - want_dist) > max(2, want_dist * 0.012)):
            bad.append((dx, dz, hex(got), hex(want), round(got_dist), want_dist))
    report.result("maths: yaw_angle", not bad, f"{600 - len(bad)} of 600 within 96 and 1.2%"
                  + (f"; first wrong {bad[:3]}" if bad else ""))

    # pitch_line within one track line, and verge_width within 2% (or 1).
    bad = []
    for _ in range(800):
        dy, dist = rng.randint(-3000, 1000), rng.randint(1, 8000)
        logd = round(256 * math.log2(dist))
        probe.call("pitch_height", hl=dy)
        r = probe.call("pitch_line", hl=logd)
        got = None if r["f"] & 1 else (r["a"] - 256 if r["a"] >= 128 else r["a"])
        want = vm.pitch_line(dy, dist)
        if want is not None and want > 127:
            want = 127                           # pitch_line clamps there
        # Where T is within a whisker of 128, the Z80's logs and the exact
        # division can fall either side of the cut-off: both are right.
        t = 256 * (abs(dy) >> 3) / dist
        if not 124 < t < 132:
            if (got is None) != (want is None) or (want is not None and abs(got - want) > 1):
                bad.append(("pitch", dy, dist, got, want))
        for scale in (3, 4, 5):
            width = probe.call("verge_width", af=scale << 8, hl=logd)["hl"]
            want_width = (1 << 23) / (dist << scale) / 40
            if abs(width - want_width) > max(1, want_width * 0.02):
                bad.append(("width", dist, scale, width, round(want_width, 1)))
    report.result("maths: pitch_line, verge_width", not bad,
                  f"800 pitches within a line, 2,400 widths within 2%" if not bad
                  else f"{len(bad)} wrong; first {bad[:3]}")


def check_verges(views: Views, symbols: dict, report: Report) -> None:
    view = vm.View(Track(track_data.fetch("silverstone")))
    worst_x = worst_width = worst_line = 0
    bad = []
    for seg, mem in views.at_halt.items():
        def word(name):
            a = symbols[name]
            return signed16(mem[a] | mem[a + 1] << 8)
        cam = (word("cam_x"), word("cam_y"), word("cam_z"), word("cam_heading") & 0xFFFF)
        want_sides = view.verge_points(cam, word("cam_seg"))
        got_sides = sm.verge_lists(sm.Layout(symbols, mem), mem)
        for side, key in (("right", "R"), ("left", "L")):
            got = got_sides[key]
            # The model in yaw units; colours are numbered from 2 (verge
            # black) in the Z80's lists.
            want = [(128 + p[0] / 40, 128 + p[1] / 40, p[2], sm.VERGE_BLACK + p[3])
                    for p in want_sides[side]]
            if len(got) != len(want):
                bad.append(f"segment {seg} {side}: {len(got)} points, model {len(want)}")
                continue
            for g, w in zip(got, want):
                dx = abs(g[0] - w[0])
                dw = abs((g[1] - g[0]) - (w[1] - w[0]))
                dl = abs(g[2] - w[2])
                worst_x, worst_width, worst_line = max(worst_x, dx), max(worst_width, dw), max(worst_line, dl)
                # 2.6 pixels is the log tables' error at the far end, where a
                # point's yaw is a small difference of two large angles.
                if dx > 3 or dl > 1 or dw > max(3, abs(w[1] - w[0]) * 0.05) or g[3] != w[3]:
                    bad.append(f"segment {seg} {side}: {g} model {tuple(round(v, 1) for v in w)}")
    report.result("verges", not bad,
                  f"{len(SEGMENTS)} views; worst {worst_x:.1f} px across, "
                  f"{worst_width:.1f} px of width, {worst_line} line" if not bad
                  else f"{len(bad)} wrong")
    for line in bad[:6]:
        report.note(line)


def check_screen(views: Views, symbols: dict, report: Report) -> None:
    bad = []
    for seg in SEGMENTS:
        # The lists that made this screen are the ones at the HALT before
        # it: by the time compose has run, the next update's have been
        # started.
        lists_mem = views.at_halt[seg]
        layout = sm.Layout(symbols, lists_mem)
        want = sm.compose(layout, sm.edges(layout, sm.verge_lists(layout, lists_mem)))
        got = sm.screen_view(layout, views.composed[seg])
        wrong = [i for i in range(len(want)) if want[i] != got[i]]
        if wrong:
            bad.append(f"segment {seg}: {len(wrong)} bytes, first at line "
                       f"{layout.view_lines - 1 - wrong[0] // 32} byte {wrong[0] % 32}")
    report.result("screen", not bad, f"{len(SEGMENTS)} views identical to the model" if not bad
                  else f"{len(bad)} of {len(SEGMENTS)} views differ")
    for line in bad[:6]:
        report.note(line)


def check_compose(probe: Probe, views: Views, symbols: dict, report: Report) -> None:
    rng = random.Random(3)
    markers = symbols["MARKERS"]
    record = symbols["MARK_LINE"]
    lines = symbols["VIEW_LINES"]
    bad = []
    shuffled = 0
    for seg in SEGMENTS[::2]:
        mem = views.at_halt[seg]
        probe.restore(mem)
        # Every line redrawn, not only those that changed: NOT_EMPTY matches
        # no pattern, so no line looks the same as last time.
        probe.poke("cs_last", [symbols["NOT_EMPTY"]] * lines)
        layout = sm.Layout(symbols, mem)
        recs = {}
        for line in range(lines):
            a = markers + record * line
            r = mem[a:a + record]
            # A record: the offset of its free end, the pattern the line
            # starts in, the x that was set at, then (x, pattern) pairs.
            n = (r[0] - 4) // 2
            marks = [(r[4 + 2 * i], r[5 + 2 * i]) for i in range(n)]
            if n >= 2 and rng.random() < 0.3:
                rng.shuffle(marks)
                probe.poke(a + 4, [b for m in marks for b in m])
                shuffled += 1
            recs[line] = (r[1], marks)
        probe.call("compose_screen")
        got = sm.screen_view(layout, probe.memory())
        for line in range(lines):
            start, marks = recs[line]
            pattern = (lambda p: sm.rotate2(p)) if line & 1 else (lambda p: p)
            px = [0] * 256
            cur, pos = pattern(start), 0
            for x, p in sorted(marks, key=lambda m: m[0]):
                for i in range(pos, x):
                    px[i] = cur
                pos, cur = x, pattern(p)
            for i in range(pos, 256):
                px[i] = cur
            want = bytes(sum(((px[b * 8 + k] >> (7 - k)) & 1) << (7 - k) for k in range(8))
                         for b in range(32))
            row = (lines - 1 - line) * 32
            if got[row:row + 32] != want:
                bad.append(f"segment {seg} line {line}: {recs[line]}")
    report.result("compose", not bad and shuffled > 0,
                  f"{shuffled} lines shuffled, all drawn as sorted" if not bad
                  else f"{len(bad)} lines wrong")
    for line in bad[:6]:
        report.note(line)


def check_beam(probe: Probe, symbols: dict, report: Report) -> None:
    probe.load(SNAPSHOT)
    probe.runto("main_loop", STARTUP_FRAMES)
    updates = 200
    r = probe.beam("compose_screen", symbols["VIEW_TOP"], symbols["VIEW_LINES"], updates)
    report.result("beam", r["split"] == "0",
                  f"{r['split']} of {updates} updates shown across two frames; "
                  f"{r['writes']} writes; compose started {r['start']} T-states after the interrupt")


def check_speed(probe: Probe, symbols: dict, report: Report) -> None:
    probe.load(SNAPSHOT)
    probe.runto("main_loop", STARTUP_FRAMES)
    halt = symbols["main_loop.wait_frame"]
    # From the first instruction after the HALT to the next HALT, back-dated
    # to the interrupt. The corners take longer, so it is only the median
    # that has to fit; the rest is reported.
    r = probe.work(halt + 1, halt, LAP_UPDATES, BUDGET)
    report.result("speed", r["median"] <= BUDGET,
                  f"median {r['median']:,} T-states against three frames' {BUDGET:,}; "
                  f"99% {r['p99']:,}, worst {r['max']:,}; "
                  f"{r['over']} of {LAP_UPDATES} updates need a fourth frame")


CHECKS = ["maths", "verges", "screen", "compose", "beam", "speed"]


def main() -> None:
    parser = argparse.ArgumentParser(description="Check the Revs road engine.")
    parser.add_argument("names", nargs="*", metavar="name",
                        help="checks to run: " + ", ".join(CHECKS))
    parser.add_argument("--no-build", action="store_true", help="use output/ as it is")
    parser.add_argument("--probe", help="the snapshot_probe executable")
    args = parser.parse_args()
    names = args.names or CHECKS
    unknown = [n for n in names if n not in CHECKS]
    if unknown:
        parser.error(f"no check called {', '.join(unknown)}; there are {', '.join(CHECKS)}")

    exe = find_probe(args.probe)
    if exe is None:
        sys.exit("snapshot_probe not built -- run: cpp-core/build.ps1 -Release -Target snapshot_probe")
    if not args.no_build:
        built = subprocess.run([sys.executable, str(REVS / "build.py")])
        if built.returncode != 0:
            sys.exit("build.py failed")
    symbols = read_symbols(SLD)

    report = Report()
    with Probe(exe, symbols) as probe:
        try:
            views = Views(probe) if {"verges", "screen", "compose"} & set(names) else None
            for name in names:
                if name == "maths":
                    check_maths(probe, report)
                elif name == "verges":
                    check_verges(views, symbols, report)
                elif name == "screen":
                    check_screen(views, symbols, report)
                elif name == "compose":
                    check_compose(probe, views, symbols, report)
                elif name == "beam":
                    check_beam(probe, symbols, report)
                elif name == "speed":
                    check_speed(probe, symbols, report)
        except ProbeError as e:
            report.result("probe", False, str(e))
    print(f"{report.failures} failed" if report.failures else "all passed")
    sys.exit(1 if report.failures else 0)


if __name__ == "__main__":
    main()
