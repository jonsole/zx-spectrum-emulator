"""The track as data: Revs sections and segment vectors expanded into the
16-bit coordinates of every segment's inner and outer verge.

This is the reference the Z80 engine is checked against, so it follows the
BBC rules exactly (see the "building a 3D track from sections and segments"
deep dive): a section starts at its own 16-bit coordinates; a curved section
adds its own segment vector for each segment, a straight one adds the same
vector each time; the outer verge is the inner one plus four times the
segment's outer vector, at the same height -- except a section's first
segment, which takes both verges from the section's own coordinates
(GetTrackSegment and GetSectionCoords). A straight's segments show
black-and-white verges except numbers 1 to 9, which keep the section's
colours.
"""

from dataclasses import dataclass

import track_data as td


def s8(b: int) -> int:
    return b - 256 if b >= 128 else b


def s16(v: int) -> int:
    v &= 0xFFFF
    return v - 65536 if v >= 32768 else v


@dataclass
class Section:
    number: int
    xi: int
    yi: int
    zi: int
    xo: int
    zo: int
    curved: bool
    flags: int
    first_vector: int
    size: int


@dataclass
class Segment:
    section: int
    xi: int
    yi: int
    zi: int
    xo: int
    zo: int
    flags: int


class Track:
    def __init__(self, data: bytes):
        self.data = data
        count = data[td.SECTION_COUNT] // 8
        self.sections = []
        for n in range(count):
            a = data[td.SECTION_DATA + 8 * n: td.SECTION_DATA + 8 * n + 8]
            b = data[td.SECTION_FLAG + 8 * n: td.SECTION_FLAG + 8 * n + 8]
            self.sections.append(Section(
                n,
                s16(a[1] << 8 | b[1]), s16(a[2] << 8 | b[2]), s16(a[3] << 8 | b[3]),
                s16(a[4] << 8 | b[4]), s16(a[6] << 8 | b[6]),
                bool(b[0] & 1), b[0], b[5], b[7]))
        self.length = int.from_bytes(data[td.TRACK_LENGTH:td.TRACK_LENGTH + 2], "little")
        self.segments = []
        for sec in self.sections:
            xi, yi, zi = sec.xi, sec.yi, sec.zi
            v = sec.first_vector
            for k in range(sec.size):
                if k == 0:
                    xo, zo = sec.xo, sec.zo
                else:
                    xi += s8(data[td.SEGMENT_XI + v]); yi += s8(data[td.SEGMENT_YI + v]); zi += s8(data[td.SEGMENT_ZI + v])
                    xo, zo = xi + 4 * s8(data[td.SEGMENT_XO + v]), zi + 4 * s8(data[td.SEGMENT_ZO + v])
                    if sec.curved:
                        v += 1
                flags = sec.flags
                if not sec.curved and not 1 <= k <= 9:
                    flags &= 0b11111001
                self.segments.append(Segment(sec.number, xi, yi, zi, xo, zo, flags))
        assert len(self.segments) == self.length, (len(self.segments), self.length)


if __name__ == "__main__":
    # python track_model.py [track]: plots the track from above into
    # output/track.png, curves orange and straights blue, sections numbered.
    import sys
    from pathlib import Path
    from PIL import Image, ImageDraw
    t = Track(td.fetch(sys.argv[1] if len(sys.argv) > 1 else "silverstone"))
    xs = [s.xi for s in t.segments] + [s.xo for s in t.segments]
    zs = [s.zi for s in t.segments] + [s.zo for s in t.segments]
    sc = 800 / max(max(xs) - min(xs), max(zs) - min(zs))
    im = Image.new("RGB", (820, 820), "white"); d = ImageDraw.Draw(im)
    P = lambda x, z: (10 + (x - min(xs)) * sc, 810 - (z - min(zs)) * sc)
    for i, s in enumerate(t.segments):
        n = t.segments[(i + 1) % len(t.segments)]
        col = (220, 120, 0) if s.flags & 1 else (0, 80, 220)
        d.line([P(s.xi, s.zi), P(n.xi, n.zi)], fill=col)
        d.line([P(s.xo, s.zo), P(n.xo, n.zo)], fill=col)
    for sec in t.sections:
        d.text(P(sec.xi, sec.zi), str(sec.number), fill="black")
    out = Path(__file__).resolve().parent / "output"
    out.mkdir(exist_ok=True)
    im.save(out / "track.png")
    gaps = [i for i, s in enumerate(t.segments) if abs(t.segments[(i + 1) % len(t.segments)].xi - s.xi) > 300]
    print(len(t.sections), "sections", len(t.segments), "segments; jumps between consecutive segments >300 units at", gaps)
