"""The sixteen landscape tiles: what each looks like and where it is solid.

A tile is drawn, not stored as art: world.shape_field says where its rock is,
and the rock is filled with one 16 x 16 cobble texture that repeats with the
tile, so the texture runs on unbroken from tile to tile whatever their shapes.
A band just inside the rock's edge is drawn solid, which is what makes the cave
walls read as walls on a one-colour screen.

The collision mask is the rock itself, texture or not: the player stands on
what is drawn, to the pixel.
"""

from world import TILE_PX, shape_field

# How deep, in field units, the solid band along a rock edge runs. Along a
# straight edge the field falls from 1 to 0 across the tile, so 0.12 is about
# two pixels.
EDGE_BAND = 0.12

# Cobble seeds on the 16 x 16 torus the texture repeats on: one stone each.
# Picked by eye; what matters is that they are spread out and not on a grid.
STONES = [(3, 3), (11, 2), (7, 10), (14, 12)]


def _stone(x: int, y: int) -> int:
    """Which stone pixel (x, y) belongs to: the nearest seed, wrapping."""
    best, best_d = 0, 1 << 30
    for i, (sx, sy) in enumerate(STONES):
        dx = min((x - sx) % TILE_PX, (sx - x) % TILE_PX)
        dy = min((y - sy) % TILE_PX, (sy - y) % TILE_PX)
        d = dx * dx + dy * dy
        if d < best_d:
            best, best_d = i, d
    return best


def _texture(x: int, y: int) -> bool:
    """Ink in the rock's interior: the mortar between stones, plus a speck of
    shading on each stone's lower right so they read as lumps."""
    me = _stone(x, y)
    if _stone((x + 1) % TILE_PX, y) != me or _stone(x, (y + 1) % TILE_PX) != me:
        return True
    sx, sy = STONES[me]
    return ((x - sx) % TILE_PX, (y - sy) % TILE_PX) in ((1, 2), (2, 1), (2, 2))


def tile_pixels(shape: int) -> list[list[bool]]:
    rows = []
    for py in range(TILE_PX):
        row = []
        for px in range(TILE_PX):
            f = shape_field(shape, (px + 0.5) / TILE_PX, (py + 0.5) / TILE_PX)
            if f < 0.5:
                row.append(False)
            elif f < 0.5 + EDGE_BAND:
                row.append(True)
            else:
                row.append(_texture(px, py))
        rows.append(row)
    return rows


def mask_pixels(shape: int) -> list[list[bool]]:
    return [[shape_field(shape, (px + 0.5) / TILE_PX, (py + 0.5) / TILE_PX) >= 0.5
             for px in range(TILE_PX)] for py in range(TILE_PX)]


def _byte(bits: list[bool]) -> int:
    v = 0
    for b in bits:
        v = v << 1 | int(b)
    return v


def graphics_bytes() -> bytes:
    """All sixteen tiles for render.s, 32 bytes each: the tile's four
    character cells, top-left, top-right, bottom-left, bottom-right, eight
    rows apiece. Cell-by-cell because the renderer draws a cell at a time."""
    out = bytearray()
    for shape in range(16):
        pix = tile_pixels(shape)
        for cy in range(2):
            for cx in range(2):
                for r in range(8):
                    out.append(_byte(pix[cy * 8 + r][cx * 8:cx * 8 + 8]))
    return bytes(out)


def mask_bytes() -> bytes:
    """The collision masks, 32 bytes a tile: sixteen rows of two bytes, left
    then right -- row-major because a collision test asks about one pixel."""
    out = bytearray()
    for shape in range(16):
        m = mask_pixels(shape)
        for r in range(TILE_PX):
            out.append(_byte(m[r][0:8]))
            out.append(_byte(m[r][8:16]))
    return bytes(out)
