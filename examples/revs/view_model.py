"""Reference model of the Revs track view, in Python.

Follows the BBC routines described on revs.bbcelite.com closely enough to be
the oracle for the Z80 engine's geometry:

* yaw: GetObjYawAngle -- octant, normalise both deltas so the larger has bit 7
  of its high byte set, 256 * smaller / larger, the arctanY table, then into
  a 16-bit angle (256 units a turn in the high byte), relative to the player.
* pitch: GetObjPitchAngle -- T = 256 * (|dy| / 8) / distance, visible while
  T < 128, track line = 60 +/- T, where distance is GetObjectDistance's
  alpha-max-plus-beta-min.
* verge width: scaleUp * 2^(scaleDown - vergeScale) yaw units, which is a
  25, 50 or 100-unit physical width.
* which segments: GetSegmentAngles' steps back from 32 segments ahead
  (13, 6, 3, then 1 at a time).

Screen mapping is the Spectrum's: x = 128 + yaw / 40 (the BBC's 40-unit
field of view across 256 pixels), track lines 0 (bottom) to 79 (top).
"""

import math

import track_data as td
from track_model import Track

ARCTAN = [int(0.5 + math.atan(i / 256) * 256 / math.atan(1)) for i in range(256)]
SEGMENT_STEPS = [13, 6, 3] + [1] * 13          # 16 entries, front to back
VIEW_LINES = 80
HORIZON = 60


def norm_divide(small: int, large: int) -> int:
    """256 * small / large on the normalised high bytes, as the BBC does."""
    while large < 0x8000:
        large <<= 1
        small <<= 1
    v = large >> 8
    a = small >> 8
    if a == v:
        return None
    return min(255, small // v)


# The yaw of an exact diagonal, by the signs of (dx, dz).
DIAGONAL = {(False, False): 0x20, (True, False): 0xE0, (False, True): 0x60, (True, True): 0xA0}


def yaw_angle(dx: int, dz: int):
    """16-bit yaw of (dx, dz) from the +z axis, and the octant's small angle M."""
    ax, az = abs(dx), abs(dz)
    if ax == az:
        return DIAGONAL[(dx < 0, dz < 0)] << 8, 255
    if ax > az:
        t = norm_divide(az, ax)
        if t is None:
            return DIAGONAL[(dx < 0, dz < 0)] << 8, 255
        m = ARCTAN[t]
        a = m * 32
        if (dx < 0) == (dz < 0):
            a = -a
        a += 64 * 256 if dx >= 0 else -64 * 256
    else:
        t = norm_divide(ax, az)
        if t is None:
            return DIAGONAL[(dx < 0, dz < 0)] << 8, 255
        m = ARCTAN[t]
        a = m * 32
        if (dx < 0) != (dz < 0):
            a = -a
        if dz < 0:
            a -= 128 * 256
    return a & 0xFFFF, m


def distance(dx: int, dz: int, m: int) -> int:
    big, small = max(abs(dx), abs(dz)), min(abs(dx), abs(dz))
    if m < 103:
        return big + (small >> 3)
    return big - (big >> 3) + (small >> 1)


def pitch_line(dy: int, dist: int):
    """Track line of a point dy above the eye at the given distance, or None."""
    ady = abs(dy) >> 3
    if dist == 0 or ady >= dist:
        return None
    t = 256 * ady // dist
    if t >= 128:
        return None
    return HORIZON + t if dy >= 0 else HORIZON - t


def signed(a: int) -> int:
    a &= 0xFFFF
    return a - 65536 if a >= 32768 else a


class View:
    def __init__(self, track: Track, eye_height: int = 500):
        self.t = track
        self.eye = eye_height

    def camera(self, seg: int, frac: float = 0.0, lateral: float = 0.5, yaw_offset: int = 0):
        """A camera on segment `seg`, `frac` of the way to the next, across the
        track by `lateral` (0 = inner verge, 1 = outer), facing along it."""
        n = len(self.t.segments)
        a, b = self.t.segments[seg % n], self.t.segments[(seg + 1) % n]
        def point(s):
            return (s.xi + (s.xo - s.xi) * lateral, s.yi, s.zi + (s.zo - s.zi) * lateral)
        pa, pb = point(a), point(b)
        x = pa[0] + (pb[0] - pa[0]) * frac
        y = pa[1] + (pb[1] - pa[1]) * frac
        z = pa[2] + (pb[2] - pa[2]) * frac
        # Heading along the track over a few segments: a single step can
        # be skewed where a new section restarts from its own coordinates.
        pc = point(self.t.segments[(seg + 3) % n])
        heading, _ = yaw_angle(int(pc[0] - pa[0]), int(pc[2] - pa[2]))
        return int(x), int(y) + self.eye, int(z), (heading + yaw_offset) & 0xFFFF

    def project(self, cam, x, y, z):
        cx, cy, cz, heading = cam
        dx, dz = x - cx, z - cz
        yaw, m = yaw_angle(dx, dz)
        dist = distance(dx, dz, m)
        rel = signed(yaw - heading)
        line = pitch_line(y - cy, dist)
        return rel, line, dist

    def verge_points(self, cam, seg: int):
        """Per side, the visible list of (inner yaw, outer yaw, line, colour)
        from far to near, as GetSegmentAngles builds it."""
        n = len(self.t.segments)
        sides = {}
        for side in ("right", "left"):
            pts = []
            s = seg + 32
            closest = None
            prev = None
            for i, step in enumerate([0] + SEGMENT_STEPS[:15]):
                s -= step
                sg = self.t.segments[s % n]
                # Driving clockwise the right verge is the inner one.
                if side == "right":
                    x, y, z = sg.xi, sg.yi, sg.zi
                else:
                    x, y, z = sg.xo, sg.yi, sg.zo
                rel, line, dist = self.project(cam, x, y, z)
                if closest is None or dist <= closest[0]:
                    closest = (dist, i)
                past_closest = i > closest[1]
                visible = line is not None and line >= 0 and not (past_closest and abs(rel) >= 20 * 256)
                if not visible:
                    # GetSegmentAngles' last try: a quarter of the way from the
                    # previous (visible) point towards this one.
                    if prev is not None:
                        qx, qy, qz = (prev[0] + (x - prev[0]) // 4, prev[1] + (y - prev[1]) // 4,
                                      prev[2] + (z - prev[2]) // 4)
                        qrel, qline, qdist = self.project(cam, qx, qy, qz)
                        if qline is not None and qline >= 0:
                            pts.append((qrel, qrel + (pts[-1][1] - pts[-1][0]), qline, pts[-1][3]))
                    break
                prev = (x, y, z)
                flags = sg.flags
                red = bool(flags & (4 if side == "right" else 2))
                curved = flags & 1
                both_red = (flags & 6) == 6
                both_black = (flags & 6) == 0
                verge_scale = 5 if both_black else (4 if (curved or both_red) else 3)
                width = (1 << 23) // max(1, dist << verge_scale)
                outer = rel + width if side == "right" else rel - width
                colour = (2 if (s % n) & 1 else (1 if red else 0))
                pts.append((rel, outer, line, colour))
            sides[side] = pts
        return sides

    def render(self, cam, seg: int):
        """A 256 x 80 frame: 0 grass, 1 road, 2 verge black, 3 verge red,
        4 verge white, 5 sky.

        Drawn the BBC way: each of the four verge edges is a polyline of line
        segments (far to near), rasterised into a per-line marker buffer that
        says "from this pixel rightwards, use this colour"; then each line is
        filled left to right from its markers, starting with the colour of
        the last marker left of the screen (or grass, or sky above the
        horizon).
        """
        sides = self.verge_points(cam, seg)
        markers = [dict() for _ in range(VIEW_LINES)]    # x (0..255) -> colour
        # Left of the screen only the marker nearest x = 0 matters: it is the
        # colour each line starts with. Ties go to the edge drawn later.
        background = [None] * VIEW_LINES                  # (x, colour)
        def to_x(yaw):
            return 128 + yaw / 40

        def mark(x, y, c):
            if not 0 <= y < VIEW_LINES or x >= 256:
                return
            if x < 0:
                if background[y] is None or x >= background[y][0]:
                    background[y] = (x, c)
            else:
                markers[y][x] = c

        def edge(pts, which, colour_of, left_side):
            pts = [(to_x(p[which]), p[2], colour_of(p)) for p in pts]
            for (ax, al, _), (bx, bl, c) in zip(pts, pts[1:]):
                # Step one pixel at a time along the longer axis, marking each
                # pixel the edge passes through.
                n = int(min(4096, max(abs(bx - ax), abs(bl - al)))) + 1
                for k in range(n + 1):
                    f = k / n
                    mark(int(round(ax + (bx - ax) * f)), int(round(al + (bl - al) * f)), c)
            # Below its lowest point an edge has left the screen on its own
            # side: off the left it still sets the colour lines start with.
            if left_side and pts:
                lowest = min(p[1] for p in pts)
                c = min(pts, key=lambda p: p[1])[2]
                for y in range(0, lowest):
                    mark(-10 ** 6, y, c)

        left, right = sides["left"], sides["right"]
        verge = lambda p: 2 + p[3]
        # Left to right, as DrawTrack does: left verge start, left track
        # start, right verge start, right grass start.
        edge(left, 1, verge, True)
        edge(left, 0, lambda p: 1, True)
        edge(right, 0, verge, False)
        edge(right, 1, lambda p: 0, False)
        img = []
        for y in range(VIEW_LINES):
            m = markers[y]
            colour = 5 if y >= HORIZON else 0
            if background[y] is not None:
                colour = background[y][1]
            row = []
            for x in range(256):
                if x in m:
                    colour = m[x]
                row.append(colour)
            img.append(row)
        return img


PALETTE = [(0, 160, 0), (40, 40, 40), (0, 0, 0), (220, 0, 0), (240, 240, 240), (80, 160, 255)]


def save(img, path, scale=3):
    from PIL import Image
    im = Image.new("RGB", (256, VIEW_LINES))
    px = im.load()
    for y in range(VIEW_LINES):
        for x in range(256):
            px[x, VIEW_LINES - 1 - y] = PALETTE[img[y][x]]
    im.resize((256 * scale, VIEW_LINES * scale), Image.NEAREST).save(path)


if __name__ == "__main__":
    # python view_model.py [segment] [eye height]: renders the view from the
    # middle of the track at that segment into output/view.png and prints
    # each side's verge points.
    import sys
    from pathlib import Path
    t = Track(td.fetch("silverstone"))
    v = View(t, eye_height=int(sys.argv[2]) if len(sys.argv) > 2 else 500)
    seg = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    cam = v.camera(seg)
    out = Path(__file__).resolve().parent / "output"
    out.mkdir(exist_ok=True)
    save(v.render(cam, seg), out / "view.png")
    for side, pts in v.verge_points(cam, seg).items():
        print(side, [(p[0], p[2]) for p in pts])
