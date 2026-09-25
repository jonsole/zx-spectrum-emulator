"""Check the ray-cast model against the painter, and the engine against both.

1. The rules. raycast.py decides each triangle from three lines of sight; the
   painter paints whole blocks in its order. Painting every cube of the map
   with raycast.flat_block() -- a block made of the same triangles and
   patterns -- must give the same picture, pixel for pixel, as the rays. The
   painter here has no view to fall off the edge of: it paints every cube in
   the map, lowest height first, then top to bottom, then left to right.

    python check_ray.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import isogeom
import raycast

HERE = Path(__file__).resolve().parent


def painted(cells: bytes, focus: tuple[int, int], block: list) -> list[bytes]:
    """Screen lines 8-135, columns 1-30, painting every cube in the map.

    A cube at (u, v, h) goes where the painter's view 0 would put it: read
    into place a + 16b + 32R of the view whose first cell is S, and drawn a
    row of places up per height."""
    sx, sy = isogeom.start_from_focus(0)
    sx += focus[0]
    sy += focus[1]
    first, last = 8, 136
    width = 8 * 34
    canvas = [bytearray(width) for _ in range(last - first + 16)]   # pixels, 0/1
    cubes = []
    for v in range(isogeom.MAP_SIZE):
        for u in range(isogeom.MAP_SIZE):
            bits = cells[v * isogeom.MAP_SIZE + u]
            if not bits:
                continue
            du, dv = u - sx, v - sy
            b = (dv - du) % 2
            R = (dv - du - b) // 2
            a = du + R
            for h in range(isogeom.HEIGHTS):
                if bits >> h & 1:
                    x = 16 * a + 8 * b
                    y = 8 * (R - h) + 4 * b - 4
                    if -16 < x < width and first - 16 < y < last:
                        cubes.append((h, y, x))
    cubes.sort()
    for h, y, x in cubes:
        for row in range(16):
            line = y + row - first
            if not 0 <= line < last - first:
                continue
            for byte in range(2):
                mask, bits = block[row][byte]
                for bit in range(8):
                    px = x + 8 * byte + bit
                    if 0 <= px < width and not mask & (0x80 >> bit):
                        canvas[line][px] = 1 if bits & (0x80 >> bit) else 0
    lines = []
    for line in range(last - first):
        row = bytearray()
        for column in range(1, 31):
            byte = 0
            for bit in range(8):
                if canvas[line][8 * column + bit]:
                    byte |= 0x80 >> bit
            row.append(byte)
        lines.append(bytes(row))
    return lines


def check_rules(cells: bytes, focuses: list) -> int:
    shifted = raycast.shift_map(cells)
    block = raycast.flat_block()
    failures = 0
    for focus in focuses:
        want = painted(cells, focus, block)
        got = raycast.render(shifted, focus)
        bad = [i for i in range(len(want)) if want[i] != got[i]]
        if bad:
            line = bad[0]
            column = next(i for i in range(30) if want[line][i] != got[line][i])
            print(f"focus {focus}: {len(bad)} lines differ; first line {line + 8}, column "
                  f"{column + 1}: painter {want[line][column]:08b}, rays {got[line][column]:08b}")
            failures += 1
    print(f"{len(focuses) - failures} of {len(focuses)} views: the rays paint what the painter paints"
          if failures else f"All {len(focuses)} views: the rays paint what the painter paints, pixel for pixel")
    return failures


RETURN = 0x5B00        # a return address nothing else runs: the printer buffer
RAY_ROUTINES = ["ray_update", "ray_cast", "ray_tiles"]


def ray_limits() -> dict:
    """The focus limits build.py wrote for the engine, so both clamp alike."""
    limits = {}
    for line in (HERE / "output" / "ray_tables.s").read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] == "EQU" and parts[0].startswith("RAY_"):
            limits[parts[0]] = int(parts[2])
    return limits


def check_engine(cells: bytes, focuses: list) -> int:
    """2. The engine: each frame in the simulator, against the model, pixel
    for pixel -- one after another on the same memory, so that the tiles it
    leaves alone because they have not changed are checked too."""
    from skoolkit import CSimulator
    from skoolkit.simulator import Simulator
    from skoolkit.simutils import SP, T
    from build import OUT, find_label

    memory = bytearray(65536)
    memory[0x4000:] = (OUT / "ray_demo.bin").read_bytes()
    sld = OUT / "ray_demo.sld"
    labels = {name: find_label(sld, name)
              for name in RAY_ROUTINES + ["ray_forget", "ray_focus_x", "ray_focus_y"]}
    limits = ray_limits()
    shifted = raycast.shift_map(cells)

    def call(address: int) -> int:
        nonlocal memory
        sp = 0xC000 - 2
        memory[sp:sp + 2] = RETURN.to_bytes(2, "little")
        simulator = (CSimulator or Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
        simulator.registers[SP] = sp
        simulator.run(address, RETURN)
        memory = bytearray(simulator.memory[:65536])
        return simulator.registers[T]

    call(labels["ray_forget"])
    failures, timings, frames = 0, {name: [] for name in RAY_ROUTINES}, []
    for focus in focuses:
        memory[labels["ray_focus_x"]] = focus[0]
        memory[labels["ray_focus_y"]] = focus[1]
        clamped = (min(max(focus[0], limits["RAY_MIN_X"]), limits["RAY_MAX_X"]),
                   min(max(focus[1], limits["RAY_MIN_Y"]), limits["RAY_MAX_Y"]))
        total = 0
        for name in RAY_ROUTINES:
            tstates = call(labels[name])
            timings[name].append(tstates)
            total += tstates
        frames.append(total)
        want = raycast.render(shifted, clamped)
        got = []
        for line in range(8, 136):
            address = 0x4000 | ((line & 0xC0) << 5) | ((line & 7) << 8) | ((line & 0x38) << 2)
            got.append(bytes(memory[address + 1:address + 31]))
        bad = [i for i in range(len(want)) if want[i] != got[i]]
        if bad:
            print(f"engine, focus {clamped}: {len(bad)} screen lines differ, first line {bad[0] + 8}")
            failures += 1
    print(f"{len(focuses) - failures} of {len(focuses)} engine frames match the model"
          if failures else f"All {len(focuses)} engine frames match the model, pixel for pixel")
    for name in RAY_ROUTINES:
        values = timings[name]
        print(f"  {name:10} {min(values):7} - {max(values):7} T-states, "
              f"{sum(values) / len(values):9.0f} average")
    print(f"  {'frame':10} {min(frames):7} - {max(frames):7} T-states, "
          f"{sum(frames) / len(frames):9.0f} average, about {sum(frames) / len(frames) / 69888:.1f} TV frames")
    return failures


def main() -> int:
    cells = isogeom.rasterise(json.loads((HERE / "maps" / "test.json").read_text(encoding="utf-8"))["boxes"])
    low_x, high_x, low_y, high_y = isogeom.focus_limits(0)
    focuses = [(64, 64), (40, 40), (90, 90), (70, 60), (45, 80), (60, 95), (85, 50),
               (low_x, low_y), (high_x, high_y)]
    failures = check_rules(cells, focuses)
    # The engine: the same places, then a walk, a cell at a time, the way the
    # view moves in play -- where most tiles stay as they were. Then each of
    # the eight moves that slide the triangles along, three times, and the
    # view standing still.
    walk = [(50 + step, 50 + step // 2) for step in range(12)]
    tour = [(64, 64)]
    for dx, dy in ((1, 0), (1, 1), (0, 1), (-1, 1), (-1, 0), (-1, -1), (0, -1), (1, -1)):
        for _ in range(3):
            tour.append((tour[-1][0] + dx, tour[-1][1] + dy))
    tour += [tour[-1]] * 2
    failures += check_engine(cells, focuses + walk + tour)
    failures += check_sprite_rule(cells)
    failures += check_engine_sprites(cells)
    return 1 if failures else 0



def block_picture() -> list:
    """raycast.flat_block() as a sprite picture: (opaque, ink) 16-bit rows."""
    rows = []
    for (mask0, bits0), (mask1, bits1) in raycast.flat_block():
        rows.append(((~mask0 & 0xFF) << 8 | (~mask1 & 0xFF), bits0 << 8 | bits1))
    return rows


def check_sprite_rule(cells: bytes, trials: int = 60) -> int:
    """3. The sprite rule. A sprite whose picture is a block must look exactly
    like a block put in the map there -- one drawn by the sprite rule, the
    other by the rays, which the painter has already vouched for."""
    import random
    rng = random.Random(1)
    picture = block_picture()
    size = isogeom.MAP_SIZE
    failures = done = 0
    while done < trials:
        focus = (rng.randint(40, 90), rng.randint(40, 90))
        u, v, h = focus[0] + rng.randint(-10, 10), focus[1] + rng.randint(-10, 10), rng.randint(0, 5)
        if cells[v * size + u] >> h & 1:
            continue                        # a sprite cannot be inside a block
        done += 1
        with_block = bytearray(cells)
        with_block[v * size + u] |= 1 << h
        want = raycast.render(raycast.shift_map(bytes(with_block)), focus)
        got = raycast.render_with_sprites(raycast.shift_map(cells), focus, [(u, v, h, picture)])
        if want != got:
            failures += 1
            if failures <= 3:
                line = next(i for i in range(len(want)) if want[i] != got[i])
                print(f"sprite at {(u, v, h)}, focus {focus}: differs from line {line + 8}")
    print(f"{trials - failures} of {trials} block-shaped sprites look like blocks"
          if failures else f"All {trials} block-shaped sprites look exactly like blocks")
    return failures


def check_engine_sprites(cells: bytes) -> int:
    """4. Sprites in the engine: frames with a figure walking about, past and
    behind blocks, and three more standing still, against the model, pixel
    for pixel -- one after another, so the cells a sprite leaves have to be
    put back."""
    from skoolkit import CSimulator
    from skoolkit.simulator import Simulator
    from skoolkit.simutils import SP, T
    from build import OUT, find_label, read_sprites

    memory = bytearray(65536)
    memory[0x4000:] = (OUT / "ray_demo.bin").read_bytes()
    sld = OUT / "ray_demo.sld"
    routines = ["ray_update", "ray_cast", "ray_sprites_prepare", "ray_tiles", "ray_sprites_show"]
    labels = {name: find_label(sld, name)
              for name in routines + ["ray_forget", "ray_sprites_forget", "ray_focus_x", "ray_focus_y", "ray_sprites"]}
    limits = ray_limits()
    shifted = raycast.shift_map(cells)
    pictures = list(read_sprites().values())

    def call(address: int) -> int:
        nonlocal memory
        sp = 0xC000 - 2
        memory[sp:sp + 2] = RETURN.to_bytes(2, "little")
        simulator = (CSimulator or Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
        simulator.registers[SP] = sp
        simulator.run(address, RETURN)
        memory = bytearray(simulator.memory[:65536])
        return simulator.registers[T]

    call(labels["ray_forget"])
    call(labels["ray_sprites_forget"])
    still = [(52, 70, 5, 1), (77, 60, 4, 1), (75, 80, 0, 0)]
    # The figure walks by the columns, under the bridge, round the house, with
    # the view following it -- then a cell at a time with the view held still,
    # so the cells it leaves are put back with no tiles drawn otherwise.
    path = [(48, 72), (50, 72), (52, 72), (52, 71), (53, 69), (55, 68), (60, 66), (66, 63),
            (70, 61), (72, 60), (76, 61), (80, 62), (82, 66), (78, 74), (75, 79), (74, 82),
            (70, 88), (66, 92)]
    path = [(x, y, x, y) for x, y in path]
    path += [(x, 72, 60, 70) for x in range(52, 60)] + [(59, y, 60, 70) for y in range(71, 66, -1)]
    # Nothing moving at all, which does nothing; then moving on from it.
    path += [(59, 67, 60, 70)] * 3 + [(58, 67, 60, 70), (58, 67, 61, 70)]
    # The simulator's memory is flat, so its OUTs to $7FFD page nothing: put
    # at $C000 the map each routine pages in -- the heights for the sprites,
    # his map of colours for the rest.
    colours = bytes(memory[0xC000:])
    heights = (OUT / "harte_heights.bin").read_bytes()
    failures, times = 0, {name: [] for name in routines}
    for x, y, fx, fy in path:
        sprites = [(x, y, 0, 0)] + still
        for n, (u, v, h, picture) in enumerate(sprites):
            memory[labels["ray_sprites"] + 4 * n:labels["ray_sprites"] + 4 * n + 4] = bytes((u, v, h, picture))
        memory[labels["ray_focus_x"]], memory[labels["ray_focus_y"]] = fx, fy
        for name in routines:
            memory[0xC000:] = heights if name == "ray_sprites_prepare" else colours
            times[name].append(call(labels[name]))
        focus = (min(max(fx, limits["RAY_MIN_X"]), limits["RAY_MAX_X"]),
                 min(max(fy, limits["RAY_MIN_Y"]), limits["RAY_MAX_Y"]))
        want = raycast.render_with_sprites(shifted, focus,
                                           [(u, v, h, pictures[p]) for u, v, h, p in sprites])
        got = []
        for line in range(8, 136):
            address = 0x4000 | ((line & 0xC0) << 5) | ((line & 7) << 8) | ((line & 0x38) << 2)
            got.append(bytes(memory[address + 1:address + 31]))
        bad = [i for i in range(len(want)) if want[i] != got[i]]
        if bad:
            line = bad[0]
            column = next(i for i in range(30) if want[line][i] != got[line][i])
            print(f"figure at {(x, y)}: {len(bad)} lines differ; first line {line + 8}, column "
                  f"{column + 1}: model {want[line][column]:08b}, engine {got[line][column]:08b}")
            failures += 1
    print(f"{len(path) - failures} of {len(path)} frames with sprites match the model"
          if failures else f"All {len(path)} frames with sprites match the model, pixel for pixel")
    for name in routines:
        values = times[name]
        print(f"  {name:20} {min(values):7} - {max(values):7} T-states, {sum(values) / len(values):9.0f} average")
    totals = [sum(times[name][i] for name in routines) for i in range(len(path))]
    print(f"  {'frame':20} {min(totals):7} - {max(totals):7} T-states, {sum(totals) / len(totals):9.0f} average")
    return failures


if __name__ == "__main__":
    sys.exit(main())
