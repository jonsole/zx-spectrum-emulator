"""ULA: screen decode, border color, and frame interrupt timing.

No memory contention / T-state-accurate ULA race modeling in v1 (see plan
doc) -- this is a functionally-correct decode of the display file, not a
cycle-perfect raster model.
"""
from __future__ import annotations

import numpy as np

from zxspectrum.core.memory import Memory

SCREEN_WIDTH = 256
SCREEN_HEIGHT = 192
BITMAP_BASE = 0x4000
BITMAP_SIZE = 0x1800
ATTR_BASE = 0x5800
ATTR_SIZE = 0x300

FRAME_TSTATES = 69888  # 48K Spectrum: one interrupt per frame at ~50Hz

# index bit0 -> Blue, bit1 -> Red, bit2 -> Green (standard ULA attribute encoding)
_LEVEL_OFF = 0x00


def _color(index: int, bright: bool) -> tuple[int, int, int]:
    level = 0xFF if bright else 0xCD
    r = level if index & 0b010 else _LEVEL_OFF
    g = level if index & 0b100 else _LEVEL_OFF
    b = level if index & 0b001 else _LEVEL_OFF
    return (r, g, b)


BORDER_COLORS = [_color(i, False) for i in range(8)]


def pixel_addr(x: int, y: int) -> int:
    """Address of the byte holding column x (rounded to its 8-pixel group), row y."""
    return (
        BITMAP_BASE
        | ((y & 0b11000000) << 5)
        | ((y & 0b00000111) << 8)
        | ((y & 0b00111000) << 2)
        | (x >> 3)
    )


def attr_addr(x: int, y: int) -> int:
    col = x >> 3
    row = y >> 3
    return ATTR_BASE + row * 32 + col


class ULA:
    def __init__(self) -> None:
        self.border = 0  # 0-7
        self.flash_state = False  # toggles ~twice/sec at a higher layer

    def decode_screen(self, memory: Memory) -> np.ndarray:
        """Decode the display file into an (H, W, 3) uint8 RGB array."""
        out = np.zeros((SCREEN_HEIGHT, SCREEN_WIDTH, 3), dtype=np.uint8)
        for y in range(SCREEN_HEIGHT):
            for cx in range(32):
                x = cx * 8
                pixel_byte = memory.read(pixel_addr(x, y))
                attr = memory.read(attr_addr(x, y))
                ink = attr & 0x07
                paper = (attr >> 3) & 0x07
                bright = bool(attr & 0x40)
                flash = bool(attr & 0x80)
                if flash and self.flash_state:
                    ink, paper = paper, ink
                ink_rgb = _color(ink, bright)
                paper_rgb = _color(paper, bright)
                for bit in range(8):
                    on = bool(pixel_byte & (0x80 >> bit))
                    out[y, x + bit] = ink_rgb if on else paper_rgb
        return out
