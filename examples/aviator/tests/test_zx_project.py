"""Checks spectrum/project.s against the Python port: ScaleUp on every
input, DivideScaled and ScaleDown on the moments recorded during the tour
and on random inputs, and ProjectPoint on recorded moments, comparing the
whole game state.

    python tests/test_zx_project.py
"""

import statistics
import sys

from harness import Check, booted, rng
import recorder
import zx
from model import memory, project
from model import names as n


def report_times(times):
    if times:
        print(f"      {statistics.mean(times):,.0f} T-states on average, {max(times):,} at most")


def check_scale_up(z):
    c = Check("scale_up")
    times = []
    for v in list(range(1, 4096)) + list(range(4096, 65536, 7)):
        out = z.call("scale_up", hl=v)
        times.append(out["t"])
        c.compare(v, project.scale_up(v), (out["hl"], out["a"]))
    report = c.report()
    report_times(times)
    return report


def divide_inputs(snap):
    """DivideScaled's inputs as the original has them at its entry."""
    n_ = (snap.x << 8) | snap.y
    tts = (snap.mem[n.TT] << 8) | snap.mem[n.S]
    return n_, tts, snap.mem[n.K], snap.mem[n.UU]


def call_divide(z, inputs):
    num, tts, k, uu = inputs
    z.poke("dv_tt", [tts >> 8, tts & 0xFF, k])
    z.poke("dv_uu", [uu])
    out = z.call("divide_scaled", hl=num)
    return (out["hl"], out["a"]), out["t"]


def check_divide(z):
    ok = True
    samples = recorder.recordings("tour", ["DivideScaled"])["DivideScaled"]
    c = Check("divide_scaled (tour)")
    times = []
    for snap in samples:
        inputs = divide_inputs(snap)
        got, t = call_divide(z, inputs)
        times.append(t)
        c.compare(inputs, project.divide_scaled(*inputs), got)
    ok = c.report() and ok
    report_times(times)
    r = rng()
    c = Check("divide_scaled (random)")
    for _ in range(5000):
        idx = r.randrange(256)
        inputs = (r.choice([0, r.randrange(1, 0x10000), r.randrange(1, 0x100)]),
                  project.reciprocal(idx), r.randrange(256), r.randrange(16))
        got, _ = call_divide(z, inputs)
        c.compare(inputs, project.divide_scaled(*inputs), got)
    return c.report() and ok


def call_scale_down(z, inputs):
    uu, vv, ww, xq, yq = inputs
    z.poke("sd_uu", [uu, vv, ww])
    z.poke("sd_x", [xq & 0xFF, xq >> 8, yq & 0xFF, yq >> 8])
    out = z.call("scale_down")
    b = z.peek("sd_x", 4)
    return (b[0] | (b[1] << 8), b[2] | (b[3] << 8)), out["t"]


def check_scale_down(z):
    ok = True
    samples = recorder.recordings("tour", ["ScaleDown"])["ScaleDown"]
    c = Check("scale_down (tour)")
    times = []
    for snap in samples:
        m = snap.mem
        inputs = (m[n.UU], m[n.VV], m[n.WW], (m[n.QQ] << 8) | m[n.PP], (m[n.Q] << 8) | m[n.P])
        got, t = call_scale_down(z, inputs)
        times.append(t)
        c.compare(inputs, project.scale_down(*inputs), got)
    ok = c.report() and ok
    report_times(times)
    r = rng()
    c = Check("scale_down (random)")
    for _ in range(5000):
        uu = r.randrange(16)
        inputs = (uu, (uu + r.randrange(-8, 10)) & 0xFF, (uu + r.randrange(-8, 10)) & 0xFF,
                  r.choice([0, r.randrange(0x4000, 0x10000)]), r.choice([0, r.randrange(0x4000, 0x10000)]))
        got, _ = call_scale_down(z, inputs)
        c.compare(inputs, project.scale_down(*inputs), got)
    return c.report() and ok


def main():
    print("Z80 projection")
    booted()
    recorder.recordings("tour", ["DivideScaled", "ScaleDown", "ProjectPoint"])
    with zx.Spectrum() as z:
        z.put_state(memory.M)
        ok = check_scale_up(z)
        ok = check_divide(z) and ok
        ok = check_scale_down(z) and ok
        ok = zx.check_recorded(z, "tour", "ProjectPoint", "project_point",
                               lambda s: dict(af=s.mem[n.GG] << 8),
                               lambda s: project.project_point(s.mem[n.GG])) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
