"""Where a stage 1 view iteration's T-states go: the iteration's steps called
one at a time on the Spectrum, along the recorded flight, and averaged.

    python tests/zx_breakdown.py [iterations]
"""

import statistics
import sys
from collections import defaultdict

import zx as zxprobe
from model import game, memory

sys.path.insert(0, str(zxprobe.ROOT / "spectrum"))
import build  # noqa: E402

FRAME = 69888


def main():
    iterations = int(sys.argv[1]) if len(sys.argv) > 1 else 100
    game.wire_hooks()
    game.load_image()
    game.start_game()
    totals = defaultdict(list)
    with zxprobe.Spectrum() as z:
        z.put_state(memory.M)
        flight = build.recorded_flight()
        steps = [("matrices", ["axis2", "axis1", "axis0", "set_matrices"]),
                 ("update_lines_to_show", ["update_lines_to_show"]),
                 ("process_lines_to_hide x9", ["process_lines_to_hide"] * 9),
                 ("process_lines_to_show", ["process_lines_to_show"]),
                 ("draw_canopy_view", ["draw_canopy_view"])]
        for i in range(iterations):
            for name, value in zip(build.PLANE_STATE, flight[i * 15:(i + 1) * 15]):
                z.poke(name, [value])
            for label, calls in steps:
                t = 0
                for name in calls:
                    if name.startswith("axis"):
                        t += z.call("project_axis_angle", af=int(name[-1]) << 8)["t"]
                    else:
                        t += z.call(name)["t"]
                totals[label].append(t)
            # The rest of view_iteration (the clears and the newly hidden
            # lines) is small; run the whole thing once to keep the state as
            # view_iteration leaves it would be wrong, so they are skipped.
    whole = sum(statistics.mean(v) for v in totals.values())
    for label, values in totals.items():
        m = statistics.mean(values)
        print(f"{label:28} {m:10,.0f} T  {100 * m / whole:5.1f}%  (max {max(values):,})")
    print(f"{'total':28} {whole:10,.0f} T  = {whole / FRAME:.1f} frames")


if __name__ == "__main__":
    sys.exit(main())
