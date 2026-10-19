"""stepscroll's graphics, in world/steps.json: what the display list draws.

Every graphic is drawn exactly as it is here, by a tile's entry naming it in
tiles.json (world.py, build.py): the step, and whatever sky, rock, margin
rows and spare bytes round it a move needs. Nothing is added to them.
They began as what build.py used to make from Cyberun's step graphics
(cyberun_steps.py), and are edited, added to and organised in the
stepscroll designer (vscode/, or the standalone page it builds; issue #25).

The graphics are in named groups -- by the direction of the step they draw,
to begin with -- and every graphic has a name of its own. A graphic is a
bitmap, rows from the top, '#' a set pixel and '.' a clear one, a whole
number of bytes wide (at most 3, the widest blitter) and an even number of
rows high (at most 16), as the blitters go up a row pair at a time.

Every graphic is drawn at four fine positions, shifted 0, 2, 4 and 6 pixels
right. What comes in on the left is its shiftIn strip: 6 pixels a row, the
last 2, 4 or all 6 of them (build.py's graphic). They began as what was just
left of the graphic in the world.
"""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

HERE = Path(__file__).resolve().parent
STEPS_JSON = HERE / "world" / "steps.json"
TILES_JSON = HERE / "world" / "tiles.json"
PIXELS = {"#": 1, ".": 0}
STRIP = 6               # pixels the furthest shift brings in


class GraphicsError(Exception):
    pass


@dataclass(frozen=True)
class Graphic:
    name: str
    group: str
    bits: tuple         # rows from the top, each a tuple of 0/1
    shift_in: tuple     # the strip shifting brings in on the left, a row each, STRIP pixels
    width: int          # bytes
    height: int         # rows


@dataclass(frozen=True)
class Graphics:
    groups: dict        # group name -> [graphic names in order]
    graphics: dict      # graphic name -> Graphic


def parse(doc: dict) -> Graphics:
    groups = {}
    graphics = {}
    for gname, group in doc["groups"].items():
        names = []
        for name, g in group["graphics"].items():
            if name in graphics:
                raise GraphicsError(f"steps.json: graphic {name} is in groups {graphics[name].group} and {gname}")
            rows = g["rows"]
            if (not rows or len(rows) % 2 or len(rows[0]) % 8 or len(rows[0]) == 0
                    or any(len(r) != len(rows[0]) or set(r) - set(PIXELS) for r in rows)):
                raise GraphicsError(f"steps.json: graphic {name}: rows must be an even number of rows of a "
                                    f"whole number of bytes of '#' or '.'")
            bits = tuple(tuple(PIXELS[ch] for ch in r) for r in rows)
            strip = g.get("shiftIn", ["." * STRIP] * len(rows))
            if len(strip) != len(rows) or any(len(r) != STRIP or set(r) - set(PIXELS) for r in strip):
                raise GraphicsError(f"steps.json: graphic {name}: shiftIn must be a row of {STRIP} '#' or '.' "
                                    f"for each of its {len(rows)} rows")
            shift_in = tuple(tuple(PIXELS[ch] for ch in r) for r in strip)
            graphics[name] = Graphic(name, gname, bits, shift_in, len(rows[0]) // 8, len(rows))
            names.append(name)
        groups[gname] = names
    return Graphics(groups, graphics)


def load(path: Path = STEPS_JSON) -> Graphics:
    return parse(json.loads(path.read_text(encoding="utf-8")))


def format_doc(doc: dict) -> str:
    """The file's layout: a bitmap's rows one to a line, so that a pixel
    edited is a line changed. vscode/steps_model.js writes the same."""
    lines = ["{"]
    if "$schema" in doc:
        lines.append(f'  "$schema": {json.dumps(doc["$schema"])},')
    lines.append('  "groups": {')
    gnames = list(doc["groups"])
    for i, gname in enumerate(gnames):
        group = doc["groups"][gname]
        lines.append(f"    {json.dumps(gname)}: {{")
        if "direction" in group:
            lines.append(f'      "direction": {json.dumps(group["direction"])},')
        lines.append('      "graphics": {')
        names = list(group["graphics"])
        for j, name in enumerate(names):
            g = group["graphics"][name]
            lines.append(f"        {json.dumps(name)}: {{")
            if "shiftIn" in g:
                lines.append('          "shiftIn": [')
                lines.append(",\n".join(f"            {json.dumps(r)}" for r in g["shiftIn"]))
                lines.append("          ],")
            lines.append('          "rows": [')
            lines.append(",\n".join(f"            {json.dumps(r)}" for r in g["rows"]))
            lines.append("          ]")
            lines.append("        }" + ("," if j < len(names) - 1 else ""))
        lines.append("      }")
        lines.append("    }" + ("," if i < len(gnames) - 1 else ""))
    lines += ["  }", "}", ""]
    return "\n".join(lines)


def format_tiles(doc: dict) -> str:
    """tiles.json's layout: a tile's plain fields on its first line, then
    each list (pieces, entries) an item to a line. vscode/steps_model.js
    writes the same."""
    flat = dict(separators=(", ", ": "))
    lines = ["{"]
    if "$schema" in doc:
        lines.append(f'  "$schema": {json.dumps(doc["$schema"])},')
    lines.append('  "tiles": {')
    names = list(doc["tiles"])
    for i, name in enumerate(names):
        tile = doc["tiles"][name]
        comma = "," if i < len(names) - 1 else ""
        plain = [k for k in tile if not isinstance(tile[k], list)]
        lists = [k for k in tile if isinstance(tile[k], list)]
        lines.append(f"    {json.dumps(name)}: {{")
        parts = []
        if plain:
            parts.append(["      " + ", ".join(f"{json.dumps(k)}: {json.dumps(tile[k])}" for k in plain)])
        for k in lists:
            items = tile[k]
            if not items:
                parts.append([f"      {json.dumps(k)}: []"])
                continue
            block = [f"      {json.dumps(k)}: ["]
            block += ["        " + json.dumps(v, **flat) + ("," if j < len(items) - 1 else "")
                      for j, v in enumerate(items)]
            block.append("      ]")
            parts.append(block)
        for j, block in enumerate(parts):
            if j < len(parts) - 1:
                block[-1] += ","
            lines += block
        lines.append("    }" + comma)
    lines += ["  }", "}", ""]
    return "\n".join(lines)


