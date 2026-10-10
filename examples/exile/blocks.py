"""The block set: blocks.png, blocks.json, and the bytes the game draws from.

blocks.png is the art, eight blocks to a row, each 16 x 16 inside a one-pixel
magenta frame. A pixel's colour says two things at once -- whether it is
drawn, and whether it is solid:

    black    open      not drawn, not solid -- the cave
    white    ink       drawn, and solid
    grey     solid     not drawn, but solid -- rock between the texture's lines
    green    decor     drawn, but not solid -- grass, water, things in front

blocks.json names the blocks, in the sheet's order, and gives each the
character map.txt places it with. Block 0 must be the empty one. Up to 64
blocks: the game finds a block's bytes as number * 32, in 2K.
"""

import json
from pathlib import Path

from PIL import Image

HERE = Path(__file__).resolve().parent
SHEET = HERE / "blocks.png"
LEGEND = HERE / "blocks.json"

BLOCK_PX = 16
PER_ROW = 8
PITCH = BLOCK_PX + 2          # a block and its frame
MAX_BLOCKS = 64

COLOURS = {
    "open": (0, 0, 0),
    "ink": (255, 255, 255),
    "solid": (96, 96, 96),
    "decor": (0, 192, 0),
}
FRAME = (255, 0, 255)
BY_COLOUR = {rgb: name for name, rgb in COLOURS.items()}

DRAWN = {"ink", "decor"}
SOLID = {"ink", "solid"}


def _origin(n):
    return 1 + (n % PER_ROW) * PITCH, 1 + (n // PER_ROW) * PITCH


def blank_sheet():
    """Every slot framed and empty, so the room left for new blocks shows."""
    rows = MAX_BLOCKS // PER_ROW
    sheet = Image.new("RGB", (PER_ROW * PITCH, rows * PITCH), FRAME)
    for n in range(MAX_BLOCKS):
        put_block(sheet, n, [["open"] * BLOCK_PX for _ in range(BLOCK_PX)])
    return sheet


def put_block(sheet, n, pixels):
    ox, oy = _origin(n)
    for y, row in enumerate(pixels):
        for x, name in enumerate(row):
            sheet.putpixel((ox + x, oy + y), COLOURS[name])


class BlockSet:
    """The sheet and legend, read and checked."""

    def __init__(self, sheet=SHEET, legend=LEGEND):
        self.legend = json.loads(Path(legend).read_text())
        if not self.legend or self.legend[0]["char"] != " ":
            raise ValueError("blocks.json: block 0 must be the empty block, char ' '")
        if len(self.legend) > MAX_BLOCKS:
            raise ValueError(f"blocks.json: {len(self.legend)} blocks, at most {MAX_BLOCKS}")
        self.chars = {}
        for n, entry in enumerate(self.legend):
            c = entry["char"]
            if len(c) != 1 or c == "|" or c in self.chars:
                raise ValueError(f"blocks.json: block {n} ({entry['name']}): char {c!r} "
                                 "must be one character, not '|', and not used before")
            self.chars[c] = n
        image = Image.open(sheet).convert("RGB")
        self.pixels = []
        for n, entry in enumerate(self.legend):
            ox, oy = _origin(n)
            rows = []
            for y in range(BLOCK_PX):
                row = []
                for x in range(BLOCK_PX):
                    rgb = image.getpixel((ox + x, oy + y))
                    if rgb not in BY_COLOUR:
                        raise ValueError(f"blocks.png: block {n} ({entry['name']}) pixel "
                                         f"({x}, {y}) is {rgb}, which is none of the four "
                                         "block colours")
                    row.append(BY_COLOUR[rgb])
                rows.append(row)
            self.pixels.append(rows)

    def drawn(self, n):
        return [[p in DRAWN for p in row] for row in self.pixels[n]]

    def solid(self, n):
        return [[p in SOLID for p in row] for row in self.pixels[n]]

    def graphics_bytes(self):
        """32 bytes a block, for render.s: its four character cells, top-left,
        top-right, bottom-left, bottom-right, eight rows apiece -- cell by cell
        because the renderer draws a cell at a time."""
        out = bytearray()
        for n in range(len(self.legend)):
            pix = self.drawn(n)
            for cy in range(2):
                for cx in range(2):
                    for r in range(8):
                        out.append(_byte(pix[cy * 8 + r][cx * 8:cx * 8 + 8]))
        return bytes(out)

    def mask_bytes(self):
        """32 bytes a block, for player.s's collisions: sixteen rows of two
        bytes, left then right -- row-major because a test asks about one
        pixel."""
        out = bytearray()
        for n in range(len(self.legend)):
            m = self.solid(n)
            for r in range(BLOCK_PX):
                out.append(_byte(m[r][0:8]))
                out.append(_byte(m[r][8:16]))
        return bytes(out)


def _byte(bits):
    v = 0
    for b in bits:
        v = v << 1 | int(b)
    return v
