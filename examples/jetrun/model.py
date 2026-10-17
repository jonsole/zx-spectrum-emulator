"""Jetrun's reference model of the screen: the layout, the checker, and the
full render the Z80 must draw at a life's start.

The play area is 28 x 20 characters of the Spectrum's screen, x 8-231 and
y 24-183. The view is the world point at its top-left pixel; a world pixel
(wx, wy) is drawn at screen x = wx - view_x + 8, y = wy - view_y + 24. Rock
is Cyberun's checker -- $55 on odd screen lines and $AA on even ones, a
pixel set where x + y is even -- and sky is black, so a move of the view by
an even number of pixels leaves both looking the same.

Each pass the landscape is drawn by Cyberun's own renderer (ADR 0007), which
is not modelled here: check.py takes its screen from the Z80. What is
modelled is the full render, every pixel of the play area from the world's
crossings, which the Z80 draws before Cyberun's renderer takes over.

    python examples/jetrun/model.py          # output/model.png, a full render
"""
from __future__ import annotations

import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import world as W  # noqa: E402

PLAY_LEFT = 8           # screen x of the play area's first pixel
PLAY_TOP = 24           # screen y of its first row
PLAY_W = W.PAGE_W
PLAY_H = W.PAGE_H
FIRST_COLUMN = PLAY_LEFT // 8           # 1
LAST_COLUMN = FIRST_COLUMN + PLAY_W // 8 - 1   # 28


def screen_offset(column: int, y: int) -> int:
    """The byte's offset from 0x4000 in the Spectrum's screen layout."""
    return ((y & 0xC0) << 5) | ((y & 7) << 8) | ((y & 0x38) << 2) | column


def rock_pixel(x: int, y: int) -> int:
    """The checker: 1 where x + y is even (any frame of reference whose
    origin is even, even, gives the same pattern)."""
    return (x + y + 1) & 1


class Screen:
    def __init__(self):
        self.pixels = bytearray(6144)

    def play_area(self) -> bytes:
        return bytes(self.pixels[screen_offset(c, y)]
                     for y in range(PLAY_TOP, PLAY_TOP + PLAY_H)
                     for c in range(FIRST_COLUMN, LAST_COLUMN + 1))


def full_render(world: W.World, screen: Screen, vx: int, vy: int) -> None:
    """Every pixel of the play area, from the world's crossings."""
    for y in range(PLAY_H):
        wy = vy + y
        for c in range(PLAY_W // 8):
            byte = 0
            for b in range(8):
                wx = vx + c * 8 + b
                if world.is_rock(wx, wy) and rock_pixel(wx, wy):
                    byte |= 0x80 >> b
            screen.pixels[screen_offset(FIRST_COLUMN + c, PLAY_TOP + y)] = byte


def screen_png(screen: Screen, path: Path, scale: int = 2, other: Screen | None = None) -> None:
    """The whole screen in black and white; with `other`, the pixels that
    differ from it in red."""
    from PIL import Image

    image = Image.new("RGB", (256, 192))
    px = image.load()
    for y in range(192):
        for c in range(32):
            at = screen_offset(c, y)
            byte = screen.pixels[at]
            theirs = other.pixels[at] if other else byte
            for b in range(8):
                on, was = byte & (0x80 >> b), theirs & (0x80 >> b)
                px[c * 8 + b, y] = (255, 0, 0) if bool(on) != bool(was) else \
                    ((255, 255, 255) if on else (0, 0, 0))
    image.resize((256 * scale, 192 * scale), Image.NEAREST).save(path)


if __name__ == "__main__":
    world = W.load()
    world.validate()
    screen = Screen()
    full_render(world, screen, 0, W.PAGE_H * 2 - 40)
    (HERE / "output").mkdir(exist_ok=True)
    screen_png(screen, HERE / "output" / "model.png")
    print("wrote output/model.png")
