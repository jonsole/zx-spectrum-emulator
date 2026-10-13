"""Checks stage 1 of the Spectrum version as a whole: the view flown along
the recorded flight (spectrum/stage1.s).

Both sides start from the game as StartGame leaves it, and each iteration
both put the plane where the recorded flight has it and do the view's part
of the main loop: the Z80's view_iteration, and view_iteration below on the
Python port with model/zx.py drawing. After every iteration the whole game
state and the canopy's screen bytes (rows 0 to 119) must match.

    python tests/test_zx_view.py [iterations]
"""

import statistics
import sys
import time

from harness import Check
import zx as zxprobe
from model import canopy, game, matrices, memory, visibility, zx
from model import names as n
from model.memory import M

sys.path.insert(0, str(zxprobe.ROOT / "spectrum"))
import build  # noqa: E402

HIDDEN_ROUNDS = 3
RELATED_BUSY = 35
CANOPY_SCREEN_ROWS = 120


def place_plane(entry):
    for name, value in zip(build.PLANE_STATE, entry):
        M[getattr(n, name)] = value


def view_iteration():
    """stage1.s's view_iteration, on the Python port."""
    M[n.previousListEnd] = M[n.linesToHideEnd]
    for axis in (2, 1, 0):
        M[n.matrixAxis] = axis
        matrices.project_axis_angle(axis)
    M[n.matrixNumber] = 0
    M[n.matrixAxis] = 0
    matrices.set_matrices()
    M[n.showRunwayDashes] = 0
    M[n.relatedPoints] = 0
    M[n.objectStatus:n.objectStatus + 40] = bytes(40)
    visibility.update_lines_to_show()
    M[n.mainLoopCounter] = (M[n.mainLoopCounter] + 1) & 0xFF
    for _ in range(HIDDEN_ROUNDS):
        if M[n.relatedPoints] < RELATED_BUSY:
            for _ in range(3):
                visibility.process_lines_to_hide()
    visibility.process_lines_to_show()
    canopy.draw_canopy_view()
    while M[n.previousListEnd] != M[n.linesToHideEnd]:
        x = (M[n.previousListEnd] + 1) & 0xFF
        line = M[n.linesToHide + x]
        M[n.previousListEnd] = x
        M[n.pointStatus + M[n.lineStartPointId + line]] = 0
        M[n.pointStatus + M[n.lineEndPointId + line]] = 0


def screen_rows(bitmap, rows):
    """The bitmap bytes of screen rows 0 to rows - 1, in row order."""
    return b"".join(bytes(bitmap[zx.address(0, y):zx.address(0, y) + 32]) for y in range(rows))


def main():
    iterations = int(sys.argv[1]) if len(sys.argv) > 1 else build.FLIGHT_COUNT
    flight = build.recorded_flight()
    screen = zx.Screen()
    screen.install()
    game.wire_hooks()
    game.load_image()
    game.start_game()
    c = Check("view_iteration (recorded flight)")
    times = []
    started = time.time()
    with zxprobe.Spectrum() as z:
        table = z.address("flight_table")
        for i in range(iterations):
            entry = flight[i * 15:(i + 1) * 15]
            place_plane(entry)
            view_iteration()
            z.call("place_plane", hl=table + i * 15)
            out = z.call("view_iteration")
            times.append(out["t"])
            got = z.get_state(bytearray(M))
            diffs = zxprobe.compare_state(M, got)
            z80_screen = z.peek(0x4000, 6144)
            if screen_rows(z80_screen, CANOPY_SCREEN_ROWS) != screen_rows(screen.bitmap, CANOPY_SCREEN_ROWS):
                diffs.append(("canopy screen", "model/zx.py", "differs"))
            c.compare(f"iteration {i}", [], diffs)
            if diffs:
                with open(zxprobe.ROOT / "output" / "view_mismatch.scr", "wb") as f:
                    f.write(z80_screen + bytes(768))
                break
    ok = c.report()
    if times:
        print(f"      {statistics.mean(times):,.0f} T-states an iteration on average "
              f"({statistics.mean(times) / 69888:.1f} frames), {max(times):,} at most; "
              f"{time.time() - started:.0f} s")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
