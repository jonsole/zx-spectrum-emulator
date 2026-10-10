"""The player's sprite: the art, and the pre-shifted form player.s draws.

Each image is drawn facing right; facing left is its mirror. Every image is
stored eight times, shifted 0..7 pixels right into three bytes a row, so
drawing one at any x is a copy rather than a shift -- 768 bytes an image,
which 48K can spare for the player.

The mask is worked out, not drawn: it clears the ink and a one-pixel ring
round it, so the astronaut keeps a black outline against the rock behind him.
"""

W = 16
H = 16

# '#' is ink, anything else is clear. Body inside x 4..11, feet on row 15:
# player.s's collision points are placed to match.
STANDING = [
    "................",
    "......####......",
    ".....######.....",
    ".....###..##....",
    ".....######.....",
    "......####......",
    "..##########....",
    "..###.####.##...",
    "..###.####.##...",
    "..###.####.##...",
    "..##.######.....",
    ".....##..##.....",
    ".....##..##.....",
    ".....##..##.....",
    "....###..###....",
    "................",
]

# The same, with the jetpack lit: flame under the pack.
THRUSTING = STANDING[:11] + [
    "..##.##..##.....",
    "..#..##..##.....",
    "...#.##..##.....",
    "..#.###..###....",
    "................",
]

# Image order is what player.s indexes: facing * 2 + thrusting.
IMAGES = [STANDING, THRUSTING]


def _bits(art: list[str], mirror: bool) -> list[list[bool]]:
    rows = [[c == "#" for c in row] for row in art]
    if mirror:
        rows = [row[::-1] for row in rows]
    return rows


def _mask(ink: list[list[bool]]) -> list[list[bool]]:
    """True where the background shows through: not ink, and not next to it."""
    keep = []
    for y in range(H):
        row = []
        for x in range(W):
            near = False
            for dy in (-1, 0, 1):
                for dx in (-1, 0, 1):
                    yy, xx = y + dy, x + dx
                    if 0 <= yy < H and 0 <= xx < W and ink[yy][xx]:
                        near = True
            row.append(not near)
        keep.append(row)
    return keep


def _shifted(bits: list[bool], shift: int, fill: bool) -> list[int]:
    """A 16-pixel row moved `shift` right in 24 pixels, as three bytes."""
    wide = [fill] * shift + bits + [fill] * (24 - W - shift)
    out = []
    for b in range(3):
        v = 0
        for bit in wide[b * 8:b * 8 + 8]:
            v = v << 1 | int(bit)
        out.append(v)
    return out


def image_order() -> list[tuple[list[str], bool]]:
    """(art, mirrored) for each image index: right, right lit, left, left lit."""
    return [(art, mirror) for mirror in (False, True) for art in IMAGES]


def sprite_bytes() -> bytes:
    """Every image at every shift: 16 rows of mask, ink, mask, ink, mask, ink."""
    out = bytearray()
    for art, mirror in image_order():
        ink = _bits(art, mirror)
        keep = _mask(ink)
        for shift in range(8):
            for y in range(H):
                m = _shifted(keep[y], shift, True)
                d = _shifted(ink[y], shift, False)
                for i in range(3):
                    out += bytes((m[i], d[i]))
    return bytes(out)
