"""Find where the Spectrum's game first parts from the Python port's: fly
both to the iteration before the one test_zx_game.py reports, then run that
iteration's steps one at a time from the same state on both sides,
comparing after each.

    python tests/zx_game_debug.py tour 402
"""

import sys

import recorder
import zx as zxprobe
from test_zx_game import KEYS_DOWN, Sequence
from model import canopy, controls, dashboard, flight, game, hardware, matrices, memory, zx
from model import names as n
from model.memory import M


def steps():
    """update_flight_model's and apply_flight_model's parts, as (Z80 label,
    Python function) pairs."""
    def axes():
        for axis in (2, 1, 0):
            M[n.matrixAxis] = axis
            matrices.project_axis_angle(axis)
        M[n.matrixNumber] = 0
        M[n.matrixAxis] = 0
        matrices.set_matrices()
    return [
        ("move_axes", controls.move_axes),
        ("read_joystick", controls.read_joystick),
        ("move_throttle", controls.move_throttle),
    ]


def main():
    flight_name = sys.argv[1]
    target = int(sys.argv[2])
    keys_spec, _ = recorder.FLIGHTS[flight_name]
    ranges = recorder.parse_keys(keys_spec)
    screen = zx.Screen()
    screen.install()
    game.wire_hooks()
    clock = [0]

    def port_clock():
        clock[0] += 3
        return clock[0]

    hardware.clock = port_clock
    hardware.source = Sequence()
    with zxprobe.Spectrum() as z:
        z.poke("input_mode", [1])
        z.poke("test_clock", [0])
        z.poke("test_timer", [13])
        g = game.Game()
        z.call("start_game")
        for i in range(target):
            held = [k for lo, hi, ks in ranges if lo <= i < hi for k in ks]
            codes = {hardware.KEY_CODES[k] for k in held}
            hardware.keys = lambda code, codes=codes: code in codes
            page = bytearray(256)
            for code in codes:
                page[code] = 1
            z.poke(KEYS_DOWN, page)
            g.iterate()
            z.call("game_step")
        print(f"flown to iteration {target}")
        # The iteration's main loop, step by step, from the Python state.
        held = [k for lo, hi, ks in ranges if lo <= target < hi for k in ks]
        print("keys", held)
        codes = {hardware.KEY_CODES[k] for k in held}
        hardware.keys = lambda code, codes=codes: code in codes

        def run(label, func, before=None):
            z.put_state(M)
            if before:
                before()
            z.call("try_call", hl=z.address(label))
            func()
            diffs = zxprobe.compare_state(M, z.get_state(bytearray(M)))
            print(f"{label:24} {diffs}")
            return diffs

        def axes():
            for axis in (2, 1, 0):
                M[n.matrixAxis] = axis
                matrices.project_axis_angle(axis)
            M[n.matrixNumber] = 0
            M[n.matrixAxis] = 0
            matrices.set_matrices()

        from model import theme
        run("spawn_alien", theme.spawn_alien)
        run("update_key_logger", controls.update_key_logger)
        run("move_axes", controls.move_axes)
        run("read_joystick", controls.read_joystick)
        run("move_throttle", controls.move_throttle)
        for axis in (2, 1, 0):
            M[n.matrixAxis] = axis
            z.poke("matrixAxis", [axis])
            run("project_axis_angle", lambda: matrices.project_axis_angle(axis),
                before=lambda: z.poke("matrixAxis", [axis]))
        M[n.matrixNumber] = 0
        M[n.matrixAxis] = 0
        run("set_matrices", matrices.set_matrices)
        on_ground = M[n.onGround]
        if "bullets" in sys.argv:
            run("apply_flight_model", flight.apply_flight_model)
            run("update_dashboard", dashboard.update_dashboard)
            run("update_dash_7_to_11", dashboard.update_dash_7_to_11)
            print("before firing: firingStatus", M[n.firingStatus], "keyLoggerLo+5", M[n.keyLoggerLo + 5])
            run("fire_guns", theme.fire_guns)
            for name in ("xObjectLo", "xObjectHi", "yObjectLo", "yObjectHi", "zObjectLo", "zObjectHi"):
                print(name, [M[getattr(n, name) + i] for i in range(12, 16)])
            M[n.objectStatus:n.objectStatus + 40] = bytes(40)
            run("update_bullets", theme.update_bullets)
            print("objectStatus 12-15", [M[n.objectStatus + i] for i in range(12, 16)])
            return
        if "parts" not in sys.argv:
            run("apply_flight_model", flight.apply_flight_model)
            return
        flight_parts(z, run, on_ground)


def flight_parts(z, run, on_ground):
    """apply_flight_model's parts, from the same state each time."""
    set_ground = lambda: z.poke("afm_on_ground", [on_ground])
    run("apply_aerodynamics", lambda: flight.apply_aerodynamics(on_ground), set_ground)
    run("apply_flight_control", lambda: flight.apply_flight_control(on_ground), set_ground)
    run("scale_flight_forces", flight.scale_flight_forces, set_ground)
    run("apply_turn_and_thrust", lambda: flight.apply_turn_and_thrust(on_ground), set_ground)


if __name__ == "__main__":
    sys.exit(main())
