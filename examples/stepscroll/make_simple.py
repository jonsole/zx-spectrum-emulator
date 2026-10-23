"""Simple tiles: straight-edged terrain with a 2-pixel solid line, at every
gradient -- flat, 1:1, 1:2, 2:1, 1:3, 3:1 and vertical walls -- in two
blocks, one climbing (simple_up) and one falling (simple_down). Each begins
and ends with the plain block's first and last 24 pixels, so that it sits
beside the map's other surface blocks and their tiles see what they always
have there.

Each block's picture is drawn from its ground line: sky above, rock (the
checker) below, and the 2 pixels of rock nearest the sky solid. It is then
cut into tiles where a move of 2 pixels changes something, as build.py's
coverage check counts it: every byte that a move up, down, left or right
changes, at every fine position, is in a tile. The tiles never overlap: each
byte column is cut into whole runs of rows, at most 24 (the blitters'), with
an even number of rows and an odd bottom line; up to 3 neighbouring columns
whose runs are the same share a tile. Each tile carries its shift-in strip,
the 6 pixels the world has just left of it. Tiles that come out alike are
one tile.

    python examples/stepscroll/make_simple.py [--map]

writes the two blocks into blocks.json and their tiles into tiles.json, in
groups by the gradient they are cut from; with --map, also puts them on the
map in place of the top row's two "plain" pages.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import tileset as G  # noqa: E402
import world as WD  # noqa: E402

PAGE = 256
STRIP = G.STRIP
MAX_ROWS = 24
EDGE = 159          # the rock's top where the blocks meet their neighbours, as theirs

JOIN = 24           # pixels at each end that are the plain block's
LINE = 2            # the solid line's thickness, in pixels

# The climbing block's ground: (gradient name, run in pixels, rise in pixels),
# left to right; a rise up the screen is negative y. "wall" is a step of
# its rise in no run, down the screen. The falling block is this mirrored.
UP = [("flat", 24, 0), ("1x1", 16, 16), ("flat", 8, 0), ("1x2", 32, 16), ("flat", 8, 0),
      ("2x1", 16, 32), ("flat", 8, 0), ("1x3", 48, 16), ("flat", 8, 0), ("3x1", 8, 24),
      ("flat", 16, 0), ("wall", 0, 104), ("flat", 64, 0)]


def ground(segments):
    """The surface's line for each pixel column, and the gradient each column
    belongs to."""
    y = EDGE
    x = 0
    line = np.zeros(PAGE, int)
    kind = [""] * PAGE
    for name, run, rise in segments:
        if run == 0:
            y += rise           # a wall: the line jumps between two columns
            kind[x - 1] = kind[x] = "wall"
            continue
        for i in range(run):
            # Up the screen by rise over the run, a row for every run / rise pixels
            # across, from the left: a 1:2 slope 0, 0, 1, 1, 2, 2 ...
            line[x + i] = y - (rise * i) // run
            kind[x + i] = kind[x + i] or name
        y -= rise
        x += run
    assert x == PAGE and y == EDGE, (x, y)
    return line, kind


def picture(line, plain):
    """Sky above the line, rock below, the rock's 2 pixels nearest the sky
    solid; the first and last JOIN pixels the plain block's (`plain`, its
    page's pixels)."""
    ys, xs = np.mgrid[0:PAGE, 0:PAGE]
    rock = ys >= line[None, :]
    # Near the sky: within LINE pixels across or down of a sky pixel.
    sky = ~rock
    near = np.zeros_like(rock)
    for d in range(1, LINE + 1):
        near[:, :-d] |= sky[:, d:]
        near[:, d:] |= sky[:, :-d]
        near[d:, :] |= sky[:-d, :]
        near[:-d, :] |= sky[d:, :]
    checker = (xs + ys) % 2 == 0
    out = np.where(rock, np.where(near, 1, checker.astype(int)), 0).astype(np.uint8)
    out[:, :JOIN] = plain[:, :JOIN]
    out[:, PAGE - JOIN:] = plain[:, PAGE - JOIN:]
    return out


def needed(world_bits):
    """Every byte of the world that some move changes (build.py's changes):
    by move -- a pass's, up to 4 pixels across and 4 lines up or down in one
    go -- and fine position, what the world shows against what the move
    brings into its place."""
    cuts = {f: np.packbits(np.roll(world_bits, f, axis=1), axis=1) for f in (0, 2, 4, 6)}
    need = np.zeros(cuts[0].shape, bool)
    for mx, my in [(mx, my) for mx in (-4, -2, 0, 2, 4) for my in (-4, -2, 0, 2, 4) if (mx, my) != (0, 0)]:
        for fine in (0, 2, 4, 6):
            now = cuts[fine]
            shift = fine - mx       # before, the byte showed this many pixels in: maybe a byte along
            before = np.roll(cuts[shift % 8], shift // 8, axis=1)
            if my > 0:
                need[:-my] |= now[:-my] != before[my:]
            elif my < 0:
                need[-my:] |= now[-my:] != before[:my]
            else:
                need |= now != before
    return need


def runs(rows_needed):
    """A column's needed rows as tiles' row ranges: [(top, bottom)], each at
    most MAX_ROWS, an even number of rows, the bottom odd, not overlapping."""
    # Each band of needed rows on its own -- a tunnel's ceiling and floor are
    # two -- made whole row pairs ending on an odd line; bands that then meet
    # are one.
    bands = []
    y = 0
    while y < len(rows_needed):
        if not rows_needed[y]:
            y += 1
            continue
        top = y
        while y < len(rows_needed) and rows_needed[y]:
            y += 1
        bottom = y - 1
        top -= top % 2          # an even top line, so an odd bottom one
        bottom += 1 - bottom % 2
        if bands and top <= bands[-1][1] + 1:
            bands[-1] = (bands[-1][0], bottom)
        else:
            bands.append((top, bottom))
    out = []
    for top, bottom in bands:
        while bottom >= top:
            h = min(MAX_ROWS, bottom - top + 1)
            out.append((bottom - h + 1, bottom))
            bottom -= h
    return out


def main(on_map: bool) -> None:
    tiles_doc = json.loads(G.TILES_JSON.read_text(encoding="utf-8"))
    blocks_doc = json.loads((HERE / "world" / "blocks.json").read_text(encoding="utf-8"))
    map_doc = json.loads((HERE / "world" / "map.json").read_text(encoding="utf-8"))

    up_line, up_kind = ground(UP)
    lines = {"simple_up": (up_line, [k + "-up" if k not in ("flat", "wall") else k for k in up_kind]),
             "simple_down": (up_line[::-1].copy(), [k + "-down" if k not in ("flat", "wall") else k
                                                     for k in up_kind[::-1]])}
    places = {"simple_up": (1, 0), "simple_down": (1, 4)}

    # The world with the two blocks' pictures in their pages: the rest as the
    # world is now.
    world = WD.load()
    bits = np.unpackbits(world.bytes(), axis=1)
    pr, pc = next((r, c) for r, row in enumerate(map_doc["rows"]) for c, n in enumerate(row) if n == "plain")
    plain = bits[pr * PAGE:(pr + 1) * PAGE, pc * PAGE:(pc + 1) * PAGE].copy()
    pics = {}
    for name, (line, _) in lines.items():
        pics[name] = picture(line, plain)
        r, c = places[name]
        bits[r * PAGE:(r + 1) * PAGE, c * PAGE:(c + 1) * PAGE] = pics[name]
    need = needed(bits)

    made = {}               # (group, rows, strip) -> tile name
    groups = {}             # group -> {name: tile}
    for name, (line, kind) in lines.items():
        r, c = places[name]
        entries = []
        page_need = need[r * PAGE:(r + 1) * PAGE, c * 32:(c + 1) * 32]
        col_runs = [runs(page_need[:, k]) for k in range(32)]
        k = 0
        while k < 32:
            # Neighbouring columns with the same runs share tiles, up to 3 bytes.
            w = 1
            while w < 3 and k + w < 32 and col_runs[k + w] == col_runs[k]:
                w += 1
            group = "simple-" + kind[k * 8 + 4]
            for top, bottom in col_runs[k]:
                x0 = (c * PAGE) + k * 8
                y0 = r * PAGE + top
                rows = ["".join("#" if bits[y0 + i, x0 + b] else "." for b in range(8 * w))
                        for i in range(bottom - top + 1)]
                strip = ["".join("#" if bits[y0 + i, x0 - STRIP + b] else "." for b in range(STRIP))
                         for i in range(bottom - top + 1)]
                key = (group, tuple(rows), tuple(strip))
                if key not in made:
                    n = len(groups.setdefault(group, {})) + 1
                    made[key] = f"{group}-{n}"
                    groups[group][made[key]] = {"shiftIn": strip, "rows": rows}
                entries.append({"tile": made[key], "column": k, "bottom": bottom})
            k += w
        blocks_doc["blocks"][name] = {"entries": entries}
        print(f"{name}: {len(entries)} entries")
    for group, members in groups.items():
        tiles_doc["groups"][group] = {"tiles": members}
    print(f"{sum(len(m) for m in groups.values())} tiles in {len(groups)} groups")

    if on_map:
        for name, (r, c) in places.items():
            map_doc["rows"][r][c] = name
    G.TILES_JSON.write_text(G.format_doc(tiles_doc), encoding="utf-8")
    (HERE / "world" / "blocks.json").write_text(G.format_blocks(blocks_doc), encoding="utf-8")
    if on_map:
        rows = ",\n".join("    [" + ", ".join(json.dumps(n) for n in row) + "]" for row in map_doc["rows"])
        (HERE / "world" / "map.json").write_text(
            '{\n  "$schema": "./map.schema.json",\n  "rows": [\n' + rows + "\n  ]\n}\n", encoding="utf-8")

    # The world drawn from the tiles must be the pictures.
    world = WD.load()
    got = np.unpackbits(world.bytes(), axis=1)
    if on_map:
        for name, (r, c) in places.items():
            diff = int((got[r * PAGE:(r + 1) * PAGE, c * PAGE:(c + 1) * PAGE] != pics[name]).sum())
            print(f"{name}: {diff} pixels differ from its picture")


if __name__ == "__main__":
    main("--map" in sys.argv[1:])
