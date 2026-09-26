"""Check the painter's frames against shared/isogeom.py's model, and time them.

The built engine (output/painter.bin, the memory from $4000 up as it runs)
draws each frame in SkoolKit's simulator, routine by routine, and the result
is compared with the model:

1. Without sprites, for each view and a spread of focus cells: the places
   read_view leaves, against isogeom.places(); and the screen paint leaves,
   against isogeom.render()'s buffer, every byte -- once painted on each
   screen: bank 5 at $4000, and bank 7 at $C000 (the simulator's memory is
   flat, so there it paints over the map's copy, which read_view has finished
   with).
2. With the demo's sprites: the figure walking by the columns, under the
   bridge and round the house, with the view following it and then held
   still, and three more standing about -- against isogeom.render() with the
   same sprites, pixel for pixel. The same walk as rays/check.py's.

The T-states each routine took come from the simulator's clock, so the timings
are exact rather than estimated. ULA contention is not simulated; everything
that runs is in bank 2, but painting is to a screen, which on a real 128K is
contended: these are the times without it.

    python painter/build.py && python painter/check.py
"""
from __future__ import annotations

import sys
from pathlib import Path

from skoolkit import CSimulator
from skoolkit.simulator import Simulator
from skoolkit.simutils import SP, T

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "shared"))
import isogeom                                                    # noqa: E402
from build import OUT, find_label, read_blocks, read_map, read_sprites   # noqa: E402

RETURN = 0x5B00     # a return address nothing else runs: the printer buffer
ROUTINES = ["view_update", "read_view", "sort_places", "order_sprites", "clear_back", "paint",
            "show_back"]


def machine() -> tuple:
    memory = bytearray(65536)
    memory[0x4000:] = (OUT / "painter.bin").read_bytes()
    sld = OUT / "painter.sld"
    labels = {name: find_label(sld, name)
              for name in ROUTINES + ["view_number", "focus_x", "focus_y", "make_place_tables",
                                        "back_high", "show_next", "sprites"]}
    return memory, labels


def call(memory: bytearray, address: int) -> tuple[bytearray, int]:
    """Run a routine to its RET; the memory after, and the T-states it took."""
    memory = bytearray(memory)
    sp = 0xC000 - 2
    memory[sp:sp + 2] = RETURN.to_bytes(2, "little")
    simulator = (CSimulator or Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
    simulator.registers[SP] = sp
    simulator.run(address, RETURN)
    return bytearray(simulator.memory[:65536]), simulator.registers[T]


def screen_rows(memory: bytearray, base: int) -> list[bytes]:
    """The view's lines and columns on the screen at `base`."""
    rows = []
    for line in range(isogeom.SCREEN_FIRST_LINE, isogeom.SCREEN_FIRST_LINE + len(isogeom.SHOWN_ROWS)):
        address = base | ((line & 0xC0) << 5) | ((line & 7) << 8) | ((line & 0x38) << 2)
        rows.append(bytes(memory[address + 1:address + 31]))
    return rows


def model_rows(buffer: bytearray) -> list[bytes]:
    return [bytes(buffer[row * 32 + 1:row * 32 + 31]) for row in isogeom.SHOWN_ROWS]


def report(name: str, timings: dict, frames: list) -> None:
    total = 0
    for routine in ROUTINES:
        values = timings[routine]
        average = sum(values) / len(values)
        total += average
        print(f"  {routine:13} {min(values):7} - {max(values):7} T-states, {average:9.0f} average")
    print(f"  {'frame':13} {min(frames):7} - {max(frames):7} T-states, {total:9.0f} average, "
          f"about {total / 69888:.1f} TV frames")


def check_views(cells: bytes, blocks: list, base: bytearray, labels: dict) -> int:
    """1. Every view, no sprites, on both screens."""
    failures, timings, frames = 0, {name: [] for name in ROUTINES}, []
    focuses = [(64, 64), (40, 40), (90, 90), (70, 60), (45, 80), (0, 0), (127, 127)]
    for view in range(4):
        low_x, high_x, low_y, high_y = isogeom.focus_limits(view)
        for fx, fy in focuses:
            for back in (0x40, 0xC0):
                memory = bytearray(base)
                memory[labels["view_number"]] = view
                memory[labels["focus_x"]] = fx
                memory[labels["focus_y"]] = fy
                memory[labels["back_high"]] = back
                # The engine clamps the focus; so does the model, here.
                focus = (min(max(fx, low_x), high_x), min(max(fy, low_y), high_y))
                frame = 0
                for name in ROUTINES:
                    memory, tstates = call(memory, labels[name])
                    timings[name].append(tstates)
                    frame += tstates
                    if name == "read_view":
                        got = list(memory[0xB300:0xB300 + isogeom.PLACES])
                        want = isogeom.places(cells, view, focus)
                        if got != want:
                            wrong = [p for p in range(isogeom.PLACES) if got[p] != want[p]]
                            print(f"view {view} focus {focus}: {len(wrong)} places differ, "
                                  f"first {wrong[0]}: engine {got[wrong[0]]}, model {want[wrong[0]]}")
                            failures += 1
                frames.append(frame)
                want = model_rows(isogeom.render(cells, view, focus, blocks))
                got = screen_rows(memory, back << 8)
                bad = [i for i in range(len(want)) if got[i] != want[i]]
                if bad:
                    print(f"view {view} focus {focus}, screen at ${back << 8:04X}: {len(bad)} lines "
                          f"differ, first line {bad[0] + isogeom.SCREEN_FIRST_LINE}")
                    failures += 1
                # show_back hands the other screen over, and asks for a switch.
                if memory[labels["back_high"]] != back ^ 0x80 or memory[labels["show_next"]] == 0xFF:
                    print(f"view {view} focus {focus}: show_back left back_high "
                          f"${memory[labels['back_high']]:02X}, show_next ${memory[labels['show_next']]:02X}")
                    failures += 1
    runs = 4 * len(focuses) * 2
    print(f"{runs - failures} of {runs} frames match the model" if failures
          else f"All {runs} frames match the model, pixel for pixel")
    report("views", timings, frames)
    return failures


def check_sprites(cells: bytes, blocks: list, base: bytearray, labels: dict) -> int:
    """2. The demo's sprites, the view following the figure and then held."""
    pictures = list(read_sprites().values())
    still = [(52, 70, 5, 1), (77, 60, 4, 1), (75, 80, 0, 0)]
    path = [(48, 72), (50, 72), (52, 72), (52, 71), (53, 69), (55, 68), (60, 66), (66, 63),
            (70, 61), (72, 60), (76, 61), (80, 62), (82, 66), (78, 74), (75, 79), (74, 82),
            (70, 88), (66, 92)]
    path = [(x, y, x, y) for x, y in path]
    path += [(x, 72, 60, 70) for x in range(52, 60)] + [(59, y, 60, 70) for y in range(71, 66, -1)]
    low_x, high_x, low_y, high_y = isogeom.focus_limits(0)
    failures, timings, frames = 0, {name: [] for name in ROUTINES}, []
    for step, (x, y, fx, fy) in enumerate(path):
        back = 0x40 if step % 2 == 0 else 0xC0
        memory = bytearray(base)
        sprites = [(x, y, 0, 0)] + still
        for n, (u, v, h, picture) in enumerate(sprites):
            memory[labels["sprites"] + 4 * n:labels["sprites"] + 4 * n + 4] = bytes((u, v, h, picture))
        memory[labels["view_number"]] = 0
        memory[labels["focus_x"]], memory[labels["focus_y"]] = fx, fy
        memory[labels["back_high"]] = back
        focus = (min(max(fx, low_x), high_x), min(max(fy, low_y), high_y))
        frame = 0
        for name in ROUTINES:
            memory, tstates = call(memory, labels[name])
            timings[name].append(tstates)
            frame += tstates
        frames.append(frame)
        want = model_rows(isogeom.render(cells, 0, focus, blocks,
                                         [(u, v, h, pictures[p]) for u, v, h, p in sprites]))
        got = screen_rows(memory, back << 8)
        bad = [i for i in range(len(want)) if got[i] != want[i]]
        if bad:
            line = bad[0]
            column = next(i for i in range(30) if want[line][i] != got[line][i])
            print(f"figure at {(x, y)}, focus {focus}: {len(bad)} lines differ; first line "
                  f"{line + isogeom.SCREEN_FIRST_LINE}, column {column + 1}: model "
                  f"{want[line][column]:08b}, engine {got[line][column]:08b}")
            failures += 1
    print(f"{len(path) - failures} of {len(path)} frames with sprites match the model"
          if failures else f"All {len(path)} frames with sprites match the model, pixel for pixel")
    report("sprites", timings, frames)
    return failures


def main() -> int:
    cells = read_map()
    blocks = read_blocks()
    base, labels = machine()
    base, _ = call(base, labels["make_place_tables"])
    failures = check_views(cells, blocks, base, labels)
    failures += check_sprites(cells, blocks, base, labels)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
