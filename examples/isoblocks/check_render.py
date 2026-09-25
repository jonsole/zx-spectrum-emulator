"""Check the engine's frames against isogeom.py's model, and time them.

For each view and a spread of focus cells, the built engine (output/demo.bin,
the memory from $4000 up as it runs) draws a frame in SkoolKit's simulator,
routine by routine, and the result is compared with the model:

- the places read_view leaves, against isogeom.places();
- the screen paint leaves, against isogeom.render()'s buffer, every byte --
  once painted on each screen: bank 5 at $4000, and bank 7 at $C000 (the
  simulator's memory is flat, so there it paints over the map's copy, which
  read_view has finished with).

The T-states each routine took come from the simulator's clock, so the timings
are exact rather than estimated. ULA contention is not simulated; everything
that runs is in bank 2, but painting is to a screen, which on a real 128K is
contended: these are the times without it.

    python build.py && python check_render.py
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

from skoolkit import CSimulator
from skoolkit.simulator import Simulator
from skoolkit.simutils import PC, SP, T

import isogeom
from build import OUT, find_label, read_blocks

RETURN = 0x5B00     # a return address nothing else runs: the printer buffer
ROUTINES = ["view_update", "read_view", "sort_places", "clear_back", "paint", "show_back"]


def machine() -> tuple:
    memory = bytearray(65536)
    memory[0x4000:] = (OUT / "demo.bin").read_bytes()
    sld = OUT / "demo.sld"
    labels = {name: find_label(sld, name)
              for name in ROUTINES + ["view_number", "focus_x", "focus_y", "make_place_tables",
                                        "back_high", "show_next"]}
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


def main() -> int:
    cells = isogeom.rasterise(json.loads((Path(__file__).parent / "maps" / "test.json")
                                         .read_text(encoding="utf-8"))["boxes"])
    blocks = read_blocks()
    base, labels = machine()
    base, _ = call(base, labels["make_place_tables"])
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
            want_buffer = isogeom.render(cells, view, focus, blocks)
            want = [bytes(want_buffer[row * 32 + 1:row * 32 + 31]) for row in isogeom.SHOWN_ROWS]
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
    total = 0
    for name in ROUTINES:
        values = timings[name]
        average = sum(values) / len(values)
        total += average
        print(f"  {name:12} {min(values):7} - {max(values):7} T-states, {average:9.0f} average")
    print(f"  {'frame':12} {min(frames):7} - {max(frames):7} T-states, {total:9.0f} average, "
          f"about {total / 69888:.1f} TV frames")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
