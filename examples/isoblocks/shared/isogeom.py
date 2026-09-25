"""The geometry of an isoblocks view, and a model of how the engine draws one.

build.py makes the engine's view tables from this, so the Z80 and the model
cannot disagree about which cells a view reads or where they land; and
check_render.py draws frames with render() and compares them, pixel for pixel,
with what the engine drew. The model is written for clarity, the Z80 for
speed, and the check is what keeps the two saying the same thing.

The rules, from the Ant Attack disassembly (Sandy White, 1983), in isoblocks'
own terms:

- A map cell is a byte, one bit per height, 0-7.
- The view is 16 rows of 32 places. A row is two half-rows of 16: the second
  half-row sits a byte (8 pixels) across and 4 pixel rows down from the first,
  so the places tile like bricks, 16 pixels wide.
- In view 0 a half-row is 16 cells along the diagonal (+1, +1); the second
  half-row starts one cell on in y; the next row starts at (-1, +1) from the
  last. The other views are the same turned a quarter at a time.
- A block at height h in the cell read into place c is drawn at place
  c - 32h: a height up is a row of places up the screen. So READ_ROWS = 16 + 7
  rows of cells are read, for the tops of tall blocks behind the view.
- Each place shows the topmost block landing on it. Blocks are painted lowest
  height first, and within a height top to bottom -- a painter's algorithm.
"""
from __future__ import annotations

MAP_SIZE = 128
HEIGHTS = 8
VIEW_ROWS = 16
PLACES = VIEW_ROWS * 32
READ_ROWS = VIEW_ROWS + HEIGHTS - 1

# The model paints into a buffer: 32 bytes a row. A block's image is 16 rows
# tall, so the bottom row of places reaches row 8 x 15 + 4 + 15 = 139. The
# engine paints the same picture straight onto a screen, 4 lines lower: buffer
# rows 12-139, bytes 1-30, are the view, at screen lines 16-143, columns 1-30.
# The rows above hold the tops of the farthest places; the columns either side
# are margins for blocks to overhang into.
BUFFER_ROWS = 144
SHOWN_ROWS = range(12, 140)
SHOWN_BYTES = range(1, 31)
SCREEN_FIRST_LINE = 16

# View 0's three steps, and the cell the view is centred on: place row 8,
# column 8 of the first half-row.
ALONG, SECOND, NEXT_ROW = (1, 1), (0, 1), (-1, 1)
FOCUS = (0, 16)                     # 8 x ALONG + 8 x NEXT_ROW


def turn(vector: tuple[int, int], view: int) -> tuple[int, int]:
    """A step in view 0's terms, turned a quarter `view` times."""
    x, y = vector
    for _ in range(view % 4):
        x, y = -y, x
    return x, y


def cell_offset(view: int, a: int, b: int, r: int) -> tuple[int, int]:
    """Where the a'th cell of half-row b of row r is, from the view's start."""
    x = a * ALONG[0] + b * SECOND[0] + r * NEXT_ROW[0]
    y = a * ALONG[1] + b * SECOND[1] + r * NEXT_ROW[1]
    return turn((x, y), view)


def start_from_focus(view: int) -> tuple[int, int]:
    """The first cell a view reads, relative to the cell it is centred on."""
    fx, fy = turn(FOCUS, view)
    return -fx, -fy


def focus_limits(view: int) -> tuple[int, int, int, int]:
    """(min x, max x, min y, max y) for the focus, so no cell read is off the map."""
    sx, sy = start_from_focus(view)
    xs, ys = [], []
    for r in range(READ_ROWS):
        for b in range(2):
            for a in range(16):
                dx, dy = cell_offset(view, a, b, r)
                xs.append(sx + dx)
                ys.append(sy + dy)
    return (-min(xs), MAP_SIZE - 1 - max(xs), -min(ys), MAP_SIZE - 1 - max(ys))


def map_step(vector: tuple[int, int]) -> int:
    """A step between cells as a step between map addresses: 128 bytes a row."""
    return vector[1] * MAP_SIZE + vector[0]


def view_steps(view: int) -> tuple[int, int, int]:
    """(along a half-row, row start to second half-row, row start to next row)."""
    return (map_step(turn(ALONG, view)), map_step(turn(SECOND, view)),
            map_step(turn(NEXT_ROW, view)))


def places(cells: bytes, view: int, focus: tuple[int, int]) -> list[int]:
    """Each place's topmost block, as the height plus one, or 0 for none."""
    sx, sy = start_from_focus(view)
    sx += focus[0]
    sy += focus[1]
    result = [0] * PLACES
    for r in range(READ_ROWS):
        for b in range(2):
            for a in range(16):
                dx, dy = cell_offset(view, a, b, r)
                bits = cells[(sy + dy) * MAP_SIZE + sx + dx]
                c = r * 32 + b * 16 + a
                for h in range(HEIGHTS):
                    p = c - 32 * h
                    # A later cell reaching the same place is always a higher
                    # block, so it simply replaces what is there.
                    if bits >> h & 1 and 0 <= p < PLACES:
                        result[p] = h + 1
    return result


def place_address(p: int) -> int:
    """Where place p's block image starts in the buffer, as a byte offset."""
    row, half, column = p >> 5, (p >> 4) & 1, p & 15
    return (8 * row + 4 * half) * 32 + 2 * column + half


def render(cells: bytes, view: int, focus: tuple[int, int], blocks: list) -> bytearray:
    """The render buffer after a frame: blocks[view & 1] is 16 rows of
    (mask, bits) byte pairs, mask bits set where the block is clear."""
    buffer = bytearray(BUFFER_ROWS * 32 + 64)
    block = blocks[view & 1]
    marks = places(cells, view, focus)
    for value in range(1, HEIGHTS + 1):
        for p in range(PLACES):
            if marks[p] == value:
                address = place_address(p)
                for row in range(16):
                    for byte in range(2):
                        mask, bits = block[row][byte]
                        at = address + 32 * row + byte
                        buffer[at] = (buffer[at] & mask) | bits
    return buffer


def rasterise(boxes: dict) -> bytes:
    """A map from its JSON boxes: each sets (or, with "cut", clears) the bits
    of its heights in its cells, in the order they are listed."""
    cells = bytearray(MAP_SIZE * MAP_SIZE)
    for box in boxes.values():
        low, high = box["z"]
        bits = sum(1 << h for h in range(low, high + 1))
        for y in range(box["y"], box["y"] + box["d"]):
            for x in range(box["x"], box["x"] + box["w"]):
                if box.get("cut"):
                    cells[y * MAP_SIZE + x] &= ~bits & 0xFF
                else:
                    cells[y * MAP_SIZE + x] |= bits
    return bytes(cells)
