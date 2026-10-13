"""The objects that stand on or beside the track, as parts: one place for the
build (which writes them out as assembler, output/objects.s.gen) and the
tests (whose model projects them independently of the Z80).

An object is parts of one colour, each a rectangle on the object's own grid:
heights up from its foot, and offsets across from its centre line. The car
is the BBC's object type 4, the standard car, from its objectTop,
objectBottom, objectLeft, objectRight and objectColour tables as documented
at revs.bbcelite.com: a 65-by-65 grid from -32 to 32, which here is shifted
up by 17 so that its lowest edge (the tyres' bottoms, at -17) is the foot.
Its four-edge part -- the sidepods, white either side of a red middle -- is
three parts here, the middle first so that the pods' edges stay on top.

As on the BBC, a part's left and right edges are a pixel in its edge colour,
where that differs from its fill: they are what shows a black wing against
a black road. Colours are the BBC's logical ones, which each type maps to
the Spectrum's patterns: the BBC gives every driver's car its own, and on a
monochrome screen with a black road the car reads best grey, with a white
body.

A grid unit is `unit_x` track units across and `unit_y` up. The Z80 does not
multiply: build.py writes each measurement as the log of its size on screen
at a distance of one, 256 * log2, from which the distance's log is taken
and the antilog looked up -- across, a track unit at distance d is
2^23 / 32000 / d pixels, as a verge mark's width is; up, it is 32 / d track
lines, as the pitch is.

The car is about a quarter of the road's 349 units wide, as Revs' cars look,
and its grid unit is 0.62 of a unit across in screen height, as the BBC's
view gives: its 40 yaw units fill a narrower screen (160 pixels, 4 to a yaw
unit, where the Spectrum has 6.4) of double-width pixels.
"""

import math
from dataclasses import dataclass

# Colours, as patterns.s numbers them.
GRASS, ROAD, BLACK, RED, WHITE, SKY = range(6)
# The BBC's logical object colours.
BBC_BLACK, BBC_RED, BBC_WHITE, BBC_GREEN = range(4)

PX_PER_UNIT = 2 ** 23 / 32000       # pixels across a track unit at distance 1
LINES_PER_UNIT = 32                 # track lines up a track unit at distance 1
LOG_ZERO = -64 * 256                # maths.s: the log of nothing
NO_EDGE = 255


@dataclass
class Part:
    bottom: int                     # grid units up from the foot
    top: int
    left: int                       # grid units across from the centre line
    right: int
    fill: int                       # a BBC logical colour
    edge: int | None = None         # the left and right edges', if not the fill


@dataclass
class ObjectType:
    name: str
    unit_x: float
    unit_y: float
    palette: dict                   # BBC logical colour -> patterns.s colour
    parts: list


CAR_WIDTH = 90                      # track units: the grid's 52 across
CAR_UNIT = CAR_WIDTH / 52
SIGN_PALETTE = {BBC_BLACK: BLACK, BBC_RED: RED, BBC_WHITE: WHITE, BBC_GREEN: GRASS}
CAR_PALETTE = {BBC_BLACK: BLACK, BBC_RED: WHITE, BBC_WHITE: RED, BBC_GREEN: GRASS}

TYPES = [
    # The sign: a black post and a red board above it, in track units.
    ObjectType("sign", 1, 1, SIGN_PALETTE, [
        Part(0, 200, -12, 12, BBC_BLACK),       # post, up to the eye's height
        Part(200, 450, -92, 92, BBC_RED),       # board
    ]),
    # The BBC's standard car, seen from behind, in its drawing order.
    ObjectType("car", CAR_UNIT, CAR_UNIT * 0.62 * PX_PER_UNIT / LINES_PER_UNIT, CAR_PALETTE, [
        Part(16, 20, -6, 6, BBC_WHITE, BBC_BLACK),      # 0: helmet
        Part(12, 16, -12, 12, BBC_RED),                 # 1: body
        Part(12, 14, -16, 16, BBC_RED),                 # 2: sidepods' red middle
        Part(12, 14, -26, -16, BBC_WHITE, BBC_BLACK),   #    left sidepod
        Part(12, 14, 16, 26, BBC_WHITE, BBC_BLACK),     #    right sidepod
        Part(0, 12, -26, 26, BBC_WHITE, BBC_BLACK),     # 4: tyres and gearbox
        Part(12, 18, -1, 1, BBC_BLACK, BBC_WHITE),      # 5: roll hoop
        Part(20, 23, -16, 16, BBC_BLACK, BBC_WHITE),    # 6: rear wing
    ]),
]


def log_size(value: float, per_unit: float) -> int:
    """256 * log2 of a measurement's size on screen at distance 1."""
    if value == 0:
        return LOG_ZERO
    return round(256 * math.log2(abs(value) * per_unit))


def colours(t: ObjectType, p: Part) -> tuple[int, int]:
    """A part's fill and edge as patterns.s colours, the edge NO_EDGE when
    it has none or it is the fill's."""
    fill = t.palette[p.fill]
    edge = NO_EDGE if p.edge is None else t.palette[p.edge]
    return fill, (NO_EDGE if edge == fill else edge)


def source() -> str:
    """The object types as assembler: for each, its part count, then each
    part's bottom, top, left and right as logs (dw), a byte whose bits 0 and
    1 say the left and right are left of the centre line, its fill colour
    and its edge colour (NO_EDGE for none)."""
    lines = ["; Generated by object_types.py: the objects' parts. Not committed."]
    for t in TYPES:
        across, up = t.unit_x * PX_PER_UNIT, t.unit_y * LINES_PER_UNIT
        lines.append(f"obj_type_{t.name}:")
        lines.append(f"    db {len(t.parts)}")
        for p in t.parts:
            flags = (1 if p.left < 0 else 0) | (2 if p.right < 0 else 0)
            fill, edge = colours(t, p)
            lines.append(f"    dw {log_size(p.bottom, up)},{log_size(p.top, up)},"
                         f"{log_size(p.left, across)},{log_size(p.right, across)}")
            lines.append(f"    db {flags},{fill},{edge}")
    return "\n".join(lines) + "\n"
