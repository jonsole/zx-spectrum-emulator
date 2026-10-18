"""Check the built game against the Python model, pass for pass.

The game (output/jetrun.bin, memory from 0x4000 as built) runs in SkoolKit's
simulator, routine by routine, and after each the memory is compared with
the model:

1. full_render at views all over the world, against model.full_render,
   every byte of the play area;
2. a life's start: life_state against Game.start's state, then the
   landscape (landscape_full: the full render, then Cyberun's renderer down
   to the view), the sprite and the attributes;
3. a journey of a few thousand passes -- walking up hills, flying, falling
   down the shaft into the cavern and round it -- each pass restore_sprite,
   place_sprite, landscape_pass, mend_sprite and move with the controls set,
   against the model's: every byte of the screen and attributes, and the
   astronaut's and the view's state. The landscape itself is Cyberun's
   renderer (ADR 0007), which the model does not imitate: the model takes
   the Z80's screen and attributes after landscape_pass (Cyberun's
   colour_piece colours the cells along the surfaces). Every 100 passes the
   screen is also
   compared, with the sprite taken off, with a fresh landscape_full at the
   same view and the bytes that differ counted: Cyberun's renderer is not
   exact at the view's edges, and mend_sprite cannot see a landscape byte
   written over the sprite that happens to equal what the sprite left there
   (it then keeps the old byte as what lies under it), so this is reported,
   not failed;
4. the whole game from its start, with the frame interrupt: every pass must
   begin exactly two frames after the last (ADR 0003), and the step graphics
   that Cyberun's blitters read with SP must never be left changed by the
   interrupt's push (isr in jetrun.s).

T-states come from the simulator's clock; a pass has two frames, 139,776
T-states. ULA contention is not simulated.

    python examples/jetrun/build.py && python examples/jetrun/check.py
"""
from __future__ import annotations

import random
import sys
from pathlib import Path

from skoolkit import CSimulator
from skoolkit.simulator import Simulator
from skoolkit.simutils import SP, T

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
OUT = HERE / "output"
sys.path.insert(0, str(HERE))
import game as G    # noqa: E402
import model as M   # noqa: E402
import world as W   # noqa: E402

RETURN = 0x5B00         # a return address nothing runs: the printer buffer
PASS_T = 2 * 69888


def symbols() -> dict[str, int]:
    table = {}
    for line in (OUT / "jetrun.sym").read_text().splitlines():
        if ": EQU " in line:
            name, value = line.split(": EQU ")
            table[name.strip()] = int(value, 16)
    return table


class Z80:
    def __init__(self):
        memory = bytearray(65536)
        memory[0x4000:] = (OUT / "jetrun.bin").read_bytes()
        self.sym = symbols()
        self.sim = (CSimulator or Simulator)(memory, state={"iff": 0, "im": 1, "tstates": 0})
        self.memory = self.sim.memory

    def call(self, name: str) -> int:
        """Run a routine to its RET; the T-states it took."""
        sp = 0x7FFE
        self.memory[sp] = RETURN & 0xFF
        self.memory[sp + 1] = RETURN >> 8
        self.sim.registers[SP] = sp
        start = self.sim.registers[T]
        self.sim.run(self.sym[name], RETURN)
        return self.sim.registers[T] - start

    def byte(self, name: str, offset: int = 0) -> int:
        return self.memory[self.sym[name] + offset]

    def word(self, name: str, offset: int = 0) -> int:
        return self.byte(name, offset) | self.byte(name, offset + 1) << 8

    def poke(self, name: str, value: int) -> None:
        self.memory[self.sym[name]] = value & 0xFF

    def poke_word(self, name: str, value: int) -> None:
        self.poke(name, value)
        self.memory[self.sym[name] + 1] = (value >> 8) & 0xFF

    def screen(self) -> bytes:
        return bytes(self.memory[0x4000:0x5800])

    def attrs(self) -> bytes:
        return bytes(self.memory[0x5800:0x5B00])

    def state(self) -> dict:
        signed = lambda v: v - 0x10000 if v & 0x8000 else v
        return {
            "ax": self.byte("ax") | self.word("ax", 1) << 8,
            "ay": self.byte("ay") | self.word("ay", 1) << 8,
            "vx": signed(self.word("vx")), "vy": signed(self.word("vy")),
            "on_ground": bool(self.byte("on_ground")), "facing": self.byte("facing"),
            "frame": self.byte("frame"), "view_x": self.word("view_x"),
            "view_y": self.word("view_y"),
        }


def model_state(game: G.Game) -> dict:
    return {"ax": game.ax, "ay": game.ay, "vx": game.vx, "vy": game.vy,
            "on_ground": game.on_ground, "facing": game.facing, "frame": game.frame,
            "view_x": game.view_x, "view_y": game.view_y}


def first_difference(got: bytes, want: bytes) -> str:
    k = next(i for i in range(len(got)) if got[i] != want[i])
    return f"offset {k} (0x{0x4000 + k:04X}): got {got[k]:08b}, want {want[k]:08b}"


def play_area(z: Z80) -> bytes:
    return bytes(z.memory[0x4000 + M.screen_offset(c, y)]
                 for y in range(M.PLAY_TOP, M.PLAY_TOP + M.PLAY_H)
                 for c in range(M.FIRST_COLUMN, M.LAST_COLUMN + 1))


def check_full(world: W.World, z: Z80, count: int) -> None:
    rng = random.Random(7)
    worst = 0
    for n in range(count):
        vx = rng.randrange(0, world.world_w, 2)
        vy = rng.randrange(0, world.world_h - M.PLAY_H + 1, 2)
        z.poke_word("view_x", vx)
        z.poke_word("view_y", vy)
        worst = max(worst, z.call("full_render"))
        screen = M.Screen()
        M.full_render(world, screen, vx, vy)
        got = play_area(z)
        if got != screen.play_area():
            sys.exit(f"full_render at view ({vx}, {vy}): differs at {first_difference(got, screen.play_area())}")
    print(f"1. full_render: {count} views, every byte as the model; at most {worst} T-states")


def take_screen(z: Z80):
    """The model's landscape step: the Z80's screen and attributes as they
    now are."""
    def landscape(game: G.Game) -> None:
        game.screen.pixels[:] = z.screen()
        game.attrs[:] = z.attrs()
    return landscape


def fresh_difference(z: Z80) -> int:
    """How many play-area bytes differ from a fresh landscape_full at the
    same view, run on a copy of the machine with the sprite taken off: so
    this also checks that mend_sprite kept what lies under it."""
    copy = Z80()
    copy.memory[:] = z.memory[:]
    copy.call("restore_sprite")
    before = play_area(copy)
    copy.call("landscape_full")
    return sum(a != b for a, b in zip(before, play_area(copy)))


def compare(z: Z80, game: G.Game, what: str) -> None:
    if z.screen() != bytes(game.screen.pixels):
        M.screen_png(game.screen, OUT / "check-want.png")
        got = M.Screen()
        got.pixels[:] = z.screen()
        M.screen_png(got, OUT / "check-got.png", other=game.screen)
        sys.exit(f"{what}: screen differs at {first_difference(z.screen(), bytes(game.screen.pixels))}; "
                 f"view ({game.view_x}, {game.view_y}); see output/check-*.png")
    if z.attrs() != bytes(game.attrs):
        sys.exit(f"{what}: attributes differ at {first_difference(z.attrs(), bytes(game.attrs))}")


# The journey: (controls, passes).
R, L, U = G.RIGHT, G.LEFT, G.UP
JOURNEY = [
    (0, 10), (R, 220), (R | U, 50), (R, 100), (0, 60), (L, 120), (U, 25), (0, 50),
    (R, 1000),                              # east to the shaft, and down it
    (0, 80), (R, 260), (R | U, 40), (R, 80), (0, 60), (L, 200), (L | U, 60), (0, 120),
]


def check_journey(world: W.World, z: Z80) -> None:
    game = G.Game(world)
    for a in range(0x4000, 0x5B00):     # start's clear
        z.memory[a] = 0
    z.call("power_on_colour")
    z.call("life_state")
    t = z.call("landscape_full")
    game.start(take_screen(z))
    t += z.call("place_sprite")
    compare(z, game, "a life's start")
    if z.state() != model_state(game):
        sys.exit(f"a life's start: state {z.state()}, want {model_state(game)}")
    print(f"2. a life's start: screen, attributes and state as the model; {t} T-states")

    draws, landscapes, moves, apart = [], [], [], []
    passes = 0
    rows_seen = set()
    for keys, count in JOURNEY:
        for _ in range(count):
            t = z.call("restore_sprite")
            game.restore_sprite()
            compare(z, game, f"pass {passes}: restore_sprite")
            t += z.call("place_sprite")
            game.place_sprite()
            compare(z, game, f"pass {passes}: place_sprite")
            land = z.call("landscape_pass")
            take_screen(z)(game)
            t += z.call("mend_sprite")
            game.mend_sprite()
            compare(z, game, f"pass {passes}: mend_sprite")
            if passes % 100 == 0:
                apart.append(fresh_difference(z))
            draws.append(t + land)
            landscapes.append(land)
            z.poke("controls", keys)
            moves.append(z.call("move"))
            game.move(keys)
            if z.state() != model_state(game):
                sys.exit(f"pass {passes}: move with controls {keys}: state {z.state()}, "
                         f"want {model_state(game)}")
            rows_seen.add((game.ay >> 8) // W.PAGE_H)
            passes += 1
    print(f"3. a journey of {passes} passes: screen, attributes and state as the model "
          f"every pass; the astronaut reached page rows {sorted(rows_seen)}")
    print(f"   landscape_pass {min(landscapes)}-{max(landscapes)} T-states, "
          f"{sum(landscapes) / len(landscapes):.0f} average")
    print(f"   whole draw     {min(draws)}-{max(draws)} T-states, {sum(draws) / len(draws):.0f} average")
    print(f"   move           {min(moves)}-{max(moves)} T-states, {sum(moves) / len(moves):.0f} average")
    worst = max(d + m for d, m in zip(draws, moves))
    print(f"   worst pass {worst} T-states of {PASS_T} ({100 * worst / PASS_T:.0f}%)")
    print(f"   against a fresh landscape_full every 100 passes, bytes differing: {apart}")


def _key_tracer(simulator, keys: set):
    from skoolkit.kbtracer import KEY_BITS
    from skoolkit.trace import Tracer

    class KeyTracer(Tracer):
        def read_port(self, registers, port):
            if port & 1:
                return 0xFF
            result = 0xFF
            for key in keys:
                half_row, bits = KEY_BITS[key]
                if port & half_row == 0:
                    result &= bits
            return result

    return KeyTracer(simulator, 0, 0, 0, [0] * 16, 0, False)


# The game played with interrupts: (Interface II keys held, passes).
PLAY = [((), 20), (("7",), 300), (("7", "9"), 60), (("7",), 900), ((), 60), (("6", "9"), 80), ((), 100)]


def check_interrupts() -> None:
    from skoolkit import read_bin_file
    from skoolkit.simutils import PC

    z = Z80()
    rom = REPO / "roms" / "48.rom"
    if rom.exists():
        z.memory[:0x4000] = read_bin_file(str(rom))
    keys: set = set()
    sim = z.sim
    sim.set_tracer(_key_tracer(sim, keys))
    draw = z.sym["draw_pass"]
    lo, hi = z.sym["cyberun.graphics"], z.sym["cyberun.graphics_end"]
    copy = z.sym["graphics_copy"]
    pc, starts, passes = z.sym["start"], [], 0
    for held, count in PLAY:
        keys.clear()
        keys.update(held)
        for _ in range(count):
            budget = 4 * PASS_T if passes else 40 * PASS_T      # the first after a life's start
            sim.trace(pc, draw, 0, sim.registers[T] + budget, True, None, None, None, None, None)
            pc = sim.registers[PC]
            if pc != draw:
                sys.exit(f"4. with interrupts: pass {passes} never began (PC 0x{pc:04X})")
            starts.append(sim.registers[T])
            sim.trace(pc, -1, 1, sim.registers[T] + PASS_T, True, None, None, None, None, None)
            pc = sim.registers[PC]
            passes += 1
            if bytes(z.memory[lo:hi]) != bytes(z.memory[copy:copy + hi - lo]):
                k = next(i for i in range(hi - lo) if z.memory[lo + i] != z.memory[copy + i])
                sys.exit(f"4. with interrupts: pass {passes}: the step graphics changed at 0x{lo + k:04X}")
    gaps = [b - a for a, b in zip(starts[1:], starts[2:])]
    late = [g for g in gaps if abs(g - PASS_T) > 100]
    if "free_run" in z.sym:
        print(f"4. with interrupts, free-running (build.py --free-run): {passes} passes, "
              f"{min(gaps)}-{max(gaps)} T-states apart, {sum(gaps) / len(gaps):.0f} average; "
              f"the step graphics never changed")
        return
    print(f"4. with interrupts: {passes} passes, {len(gaps) - len(late)} of {len(gaps)} began two frames "
          f"after the last ({min(gaps)}-{max(gaps)} T-states apart); the step graphics never changed")
    if late:
        sys.exit(f"   {len(late)} passes were late")


def main() -> None:
    world = W.load()
    world.validate()
    check_full(world, Z80(), 20)
    check_journey(world, Z80())
    check_interrupts()


if __name__ == "__main__":
    main()
