"""model.py's back faces against exact geometry, on random objects of one
part and of several, from every angle and distance:

1. Every closed part's faces are wound outwards: each face's normal, by
   its winding, points away from the rest of the part.
2. A face looks towards the eye when its outward normal, in camera space,
   points back at the eye: n . c0 < 0, worked out exactly in integers on
   the model's own camera-space vertices, c = T + M v. model.faces_front
   decides from the projected face instead, on points within a pixel or
   several of the exact view, with its differences shifted to fit a byte.
   So it may only be wrong about a face that is nearly edge on: one whose
   exact projected cross product u x w is within what the error in its
   three points and the shift could move it -- each side out by up to 2 e,
   e the largest error of the three, so 2 e (|u| + |w|) + 4 e^2; and the
   shift's floors, 2^shift (|u| + |w|) + 2 4^shift. It says how many faces
   are misjudged, and by the object's size on the screen. Faces without
   three vertices in front of the near plane are kept by rule, and counted
   apart.
3. The edges kept are, part by part, the edges of the faces that look
   towards the eye -- worked out here from each part's own faces, an edge
   two parts share once for each part that has a face towards the eye --
   with the misjudged faces and those kept by rule as model.faces_front
   has them. The aeroplane's tail and body share an edge.

    python face_geometry.py
"""
import math
import random
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import model                                                      # noqa: E402
from build import check_models                                    # noqa: E402

rng = random.Random(21)
shapes = {name: (v, f, p) for name, (v, f, p) in check_models().items() if p}


def cross3(a, b):
    return (a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0])


def sub(a, b):
    return [x - y for x, y in zip(a, b)]


# 1. outward winding, part by part
for name, (vertices, faces, parts) in shapes.items():
    first = 0
    for count in parts:
        part = faces[first:first + count]
        if count > 1:
            corners = {v for face in part for v in face}
            centre = [sum(vertices[v][k] for v in corners) / len(corners) for k in range(3)]
            for face in part:
                a, b, c = (vertices[v] for v in face[:3])
                n = cross3(sub(b, a), sub(c, a))
                if sum(n[k] * (a[k] - centre[k]) for k in range(3)) <= 0:
                    sys.exit(f"{name}: face {face} is not wound outwards")
        first += count
print(f"faces wound outwards: every closed part of {', '.join(shapes)}")

# 2. and 3. faces judged from the projected face, against exact geometry;
# and the edges kept
from collections import Counter                                   # noqa: E402

judged, wrong, kept, worst_slack, edges_drawn, edges_hidden, edges_differ = 0, 0, 0, 0.0, 0, 0, 0
by_shape = {name: 0 for name in shapes}
by_size = {}                                     # radius on the screen: [faces, misjudged]
for _ in range(30000):
    name = rng.choice(list(shapes))
    vertices, faces, parts = shapes[name]
    edges, edge_faces = model.part_edges(faces, parts)
    r = model.bounding_radius(vertices)
    r_view, r5 = model.cull_radii(r)
    tz = rng.choice((model.NEAR_PLANE + rng.randint(-r_view, r_view),          # straddling the near plane
                     rng.randint(model.NEAR_PLANE + r_view, 12 * r_view),     # near
                     rng.randint(12 * r_view, 127 * 3000)))                     # far
    reach = (abs(tz) + r5) // 2
    t = (rng.randint(-reach, reach), rng.randint(-reach, reach), tz)
    if model.culled(t, r):
        continue
    by_shape[name] += 1
    size = 256 * 127 * r / max(tz, model.NEAR_PLANE)
    size = "under 8 px" if size < 8 else "8 to 32" if size < 32 else "32 to 128" if size < 128 else "over 128"
    tally = by_size.setdefault(size, [0, 0])
    m = model.view_matrix(model.make_matrix(*(rng.randrange(256) for _ in range(3))),
                          model.make_matrix(*(rng.randrange(256) for _ in range(3))))
    rotated = [model.rotate(m, v) for v in vertices]
    c = [model.view_point(rv, t) for rv in rotated]
    points = [model.project_far(rv, t) for rv in rotated]
    front = model.faces_front(points, faces)
    toward = []                                  # the truth, but where the model may differ
    for f, face in enumerate(faces):
        a, b, cc = (c[v] for v in face[:3])
        truth = sum(n * p for n, p in zip(cross3(sub(b, a), sub(cc, a)), a)) < 0
        corners = [v for v in face if points[v] is not None][:3]
        if len(corners) < 3:
            kept += 1
            toward.append(True)
            continue
        judged += 1
        tally[0] += 1
        toward.append(front[f])
        if front[f] == truth:
            continue
        # how near edge on, against what the points' error and the shift could do
        exact = [(128 + 256 * c[v][0] / c[v][2], 96 - 256 * c[v][1] / c[v][2]) for v in corners]
        e = max(math.dist(points[v], p) for v, p in zip(corners, exact))
        u, w = sub(exact[1], exact[0]), sub(exact[2], exact[0])
        cross = u[0] * w[1] - u[1] * w[0]
        d = [points[corners[1]][0] - points[corners[0]][0], points[corners[1]][1] - points[corners[0]][1],
             points[corners[2]][0] - points[corners[0]][0], points[corners[2]][1] - points[corners[0]][1]]
        spread = 0
        for v in d:
            spread |= v ^ (v >> 15)
        shift = max(0, spread.bit_length() - 7)
        sides = math.hypot(*u) + math.hypot(*w)
        allowed = 2 * e * sides + 4 * e * e + (1 << shift) * sides + 2 * 4 ** shift
        worst_slack = max(worst_slack, abs(cross) / allowed)
        wrong += 1
        tally[1] += 1
    # part by part, the edges of the faces towards the eye, from the faces alone
    want, first = Counter(), 0
    for count in parts:
        pairs = set()
        for f in range(first, first + count):
            if toward[f]:
                loop = faces[f]
                pairs |= {tuple(sorted((loop[i], loop[(i + 1) % len(loop)]))) for i in range(len(loop))}
        want.update(pairs)
        first += count
    drawn = model.facing_edges(points, faces, edges, edge_faces)
    edges_differ += Counter(tuple(sorted(e)) for e in drawn) != want
    edges_drawn += len(drawn)
    edges_hidden += len(edges) - len(drawn)
print(f"{sum(by_shape.values()):,} objects ({', '.join(f'{n} {k:,}' for n, k in by_shape.items())}): "
      f"{judged:,} faces judged, {kept:,} kept without three vertices in front; "
      f"{wrong:,} ({wrong / judged:.1%}) judged otherwise than exactly, every one nearly edge on (at most "
      f"{worst_slack:.2f} of what its points' error and the shift allow)")
print("  misjudged by the object's radius on the screen: " +
      ", ".join(f"{size} {by_size[size][1] / by_size[size][0]:.1%}"
                for size in ("under 8 px", "8 to 32", "32 to 128", "over 128") if by_size.get(size, [0])[0]))
print(f"  {edges_drawn:,} edges drawn, {edges_hidden:,} hidden; objects whose edges are not, part by part, "
      f"those of the faces towards the eye: {edges_differ}")
if worst_slack > 1:
    sys.exit("model.faces_front misjudges a face that is not nearly edge on")
if edges_differ:
    sys.exit("model.facing_edges does not keep the edges of the faces towards the eye, part by part")
