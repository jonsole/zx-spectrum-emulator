"""model.clip_line against exact geometry: on 400,000 random lines and
windows, every clipped end must lie within half a pixel of the true line
(along x or along y), and no line with any of itself in the window may be
left out. check.py holds the Z80 to model.clip_line; this holds the model to
the geometry.

    python clip_geometry.py
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model                                                      # noqa: E402

rng = random.Random(1); worst = 0; rejected = 0; n = 0
for _ in range(400000):
    w = sorted(rng.sample(range(256), 2)); h = sorted(rng.sample(range(192), 2))
    win = (w[0], h[0], w[1], h[1]); big = rng.choice((300, 2000, 16000))
    p = [rng.randint(-big, big + 255) for _ in range(4)]
    if rng.random() < .5:
        p[2], p[3] = 2 * rng.randint(win[0], win[2]) - p[0], 2 * rng.randint(win[1], win[3]) - p[1]
    r = model.clip_line(*p, win)
    x0, y0, x1, y1 = p; dx, dy = x1 - x0, y1 - y0; t0, t1 = 0.0, 1.0; ok = True
    for pp, q in ((-dx, x0 - win[0]), (dx, win[2] - x0), (-dy, y0 - win[1]), (dy, win[3] - y0)):
        if pp == 0:
            if q < 0: ok = False
        else:
            t = q / pp; t0, t1 = (max(t0, t), t1) if pp < 0 else (t0, min(t1, t))
    if r is None:
        rejected += ok and t0 <= t1
        continue
    n += 1
    for ex, ey in ((r[0], r[1]), (r[2], r[3])):
        off = min(abs(ey - (y0 + dy * (ex - x0) / dx)) if dx else math.inf,
                  abs(ex - (x0 + dx * (ey - y0) / dy)) if dy else math.inf,
                  0 if (ex, ey) in ((x0, y0), (x1, y1)) else math.inf)
        worst = max(worst, off)
print(f"{n:,} lines clipped; every end within {worst:.3f} px of the true line along x or y; "
      f"lines with some of themselves in the window left out: {rejected}")
if worst > 0.5 + 1e-9 or rejected:
    sys.exit("model.clip_line is not as close to the geometry as it should be")
