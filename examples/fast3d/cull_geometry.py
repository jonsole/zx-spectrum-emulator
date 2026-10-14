"""model.py's objects and camera against their own pictures and exact
geometry, on random scenes:

1. T, from a rotation of P - C's high bytes and one of its low bytes, is
   exactly Rc^T (P - C).
2. Culling never leaves out an object any of whose vertices the model would
   draw on the screen -- in front of the eye, nearer than FAR.
3. How far the points the model draws are from the exact view.

    python cull_geometry.py
"""
import math
import random
import statistics
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model                                                      # noqa: E402
from build import objects                                         # noqa: E402

rng = random.Random(4)
shapes = [(v, model.bounding_radius(v)) for v, e in objects().values()]

for _ in range(20000):
    cam = model.make_matrix(*(rng.randrange(256) for _ in range(3)))
    C = [rng.randrange(-32768, 32768) for _ in range(3)]
    P = [c + rng.randint(-model.VIEW_BOX, model.VIEW_BOX) for c in C]
    d = [p - c for p, c in zip(P, C)]
    want = tuple(sum(cam[3 * k + i] * d[k] for k in range(3)) for i in range(3))
    if model.view_centre(P, C, cam) != want:
        sys.exit(f"T is not Rc^T (P - C) for {P}, {C}")
print("T: exactly Rc^T (P - C), 20,000 times")

missed, culled, kept, errs = 0, 0, 0, []
for _ in range(100000):
    cam_a = [rng.randrange(256) for _ in range(3)]
    cam = model.make_matrix(*cam_a)
    C = [rng.randrange(-20000, 20000) for _ in range(3)]
    reach = rng.choice((150, 600, 3000, 9000))
    P = [c + rng.randint(-reach, reach) for c in C]
    obj_a = [rng.randrange(256) for _ in range(3)]
    vertices, r = shapes[rng.randrange(len(shapes))]
    t = model.view_centre(P, C, cam)
    m = model.view_matrix(cam, model.make_matrix(*obj_a))
    # what the model would draw, culled or not (T worked out directly when
    # the box test has said no)
    t_any = t or tuple(sum(cam[3 * k + i] * (P[k] - C[k]) for k in range(3)) for i in range(3))
    drawn = False
    for v in vertices:
        rotated = model.rotate(m, v)
        point = model.project_far(rotated, t_any)
        depth = (rotated[2] + t_any[2]) / model.VIEW_SCALE
        if point and model.NEAR <= depth <= model.FAR and 0 <= point[0] < 256 and 0 <= point[1] < 192:
            drawn = True
            x, y, z = model.ideal_view(v, P, obj_a, C, cam_a)
            if z > 40:
                errs.append(math.hypot(point[0] - (128 + 256 * x / z), point[1] - (96 - 256 * y / z)))
    if t is None or model.culled(t, r):
        culled += 1
        missed += drawn
    else:
        kept += 1
errs.sort()
print(f"culling: {culled:,} culled, {kept:,} kept, of 100,000; culled with a vertex the model draws on the screen: {missed}")
print(f"points on the screen, from the exact view (z > 40): mean {statistics.mean(errs):.2f} px, "
      f"99% {errs[int(.99 * len(errs))]:.2f}, worst {errs[-1]:.2f} ({len(errs):,})")
if missed:
    sys.exit("culling left out something on the screen")
