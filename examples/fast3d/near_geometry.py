"""model.py's cut at the near plane against exact geometry, on random
objects straddling it: every edge with one end in front of the near plane
and one behind it must be cut, and its cut end must lie on the near plane
and within 3 of the edge in 3D, in units of c / 4 -- a pixel across, at the
near plane, and a 32nd of a world unit in depth; and none may be held to
WIDE_LIMIT, as model.py says none can be. No other edge may be cut, every line must start at its edge's front
end, and only the vertices behind the plane may go unprojected. All of it
through model.object_lines, which the Z80's cut_edges is held to.
(Bringing the ends to those units, floor(c / 4), moves the edge by less
than sqrt 3, and near_crossing finds x and y each within 0.62 of where
that edge crosses: under 2.7 in all.) check.py holds the Z80 to the model.

    python near_geometry.py
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model                                                      # noqa: E402
from build import check_models, models                           # noqa: E402

TOLERANCE = 3

rng = random.Random(7)
shapes = ([(v, model.faces_to_edges(f), model.bounding_radius(v)) for v, f in models().values()] +
          [(v, model.part_edges(f, p)[0], model.bounding_radius(v)) for v, f, p in check_models().values()])


def off_edge(p, a, b) -> float:
    """How far p is from the segment a-b, in 3D."""
    d = [q - s for q, s in zip(b, a)]
    s = sum((pp - aa) * dd for pp, aa, dd in zip(p, a, d)) / sum(dd * dd for dd in d)
    s = max(0.0, min(1.0, s))
    return math.dist(p, [aa + s * dd for aa, dd in zip(a, d)])


scenes, cuts, widest, worst, total, wrong = 0, 0, 0, 0.0, 0.0, 0
while scenes < 20000:
    vertices, edges, r = shapes[rng.randrange(len(shapes))]
    r_view, r5 = model.cull_radii(r)
    tz = model.NEAR_PLANE + rng.randint(-r_view, r_view)
    reach = (abs(tz) + r5) // 2
    t = (rng.randint(-reach, reach), rng.randint(-reach, reach), tz)
    if rng.random() < 0.25:                 # at the side of the view, where a cut
        t = (rng.choice((-1, 1)) * reach, t[1], tz)     # can land past WIDE_LIMIT
    if model.culled(t, r):
        continue
    scenes += 1
    m = model.view_matrix(model.make_matrix(*(rng.randrange(256) for _ in range(3))),
                          model.make_matrix(*(rng.randrange(256) for _ in range(3))))
    points, lines = model.object_lines(vertices, edges, m, t)
    # camera space, in units of c / 4; and which edges cross the plane, worked
    # out here from depth alone, the behind end first
    c = [[x / 4 for x in model.view_point(model.rotate(m, v), t)] for v in vertices]
    plane = model.NEAR_PLANE / 4
    crossing = [(j, i) if c[i][2] >= plane else (i, j) for i, j in edges
                if (c[i][2] < plane) != (c[j][2] < plane)]
    if ([p is None for p in points] != [v[2] < plane for v in c] or len(lines) != len(crossing)
            or any(line[:2] != points[front] for line, (_, front) in zip(lines, crossing))):
        wrong += 1
        continue
    for line, (behind, front) in zip(lines, crossing):
        cuts += 1
        a, b = c[behind], c[front]
        x, y = line[2] - 128, 96 - line[3]
        widest = max(widest, abs(x), abs(y))
        if model.WIDE_LIMIT in (abs(x), abs(y)):
            wrong += 1                          # held: model.py says it never is
            continue
        # the cut end, drawn as a point on the plane, against the edge in 3D
        off = off_edge((x, y, plane), a, b)
        worst, total = max(worst, off), total + off
print(f"{scenes:,} objects straddling the near plane, {cuts:,} edges cut; every cut end on the "
      f"plane and within {worst:.3f} of the edge (mean {total / cuts:.3f}), in 32nds of a unit; "
      f"the widest {widest:,} px from the centre; points, edges cut or left, or ends held, wrongly: {wrong}")
if worst > TOLERANCE or wrong:
    sys.exit("model.object_lines' cut is not as close to the geometry as it should be")
