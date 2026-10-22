"""Jetman's frames, read from the player's own copy of Lunar Jetman
(Ultimate, 1983) at build time: nothing of the game is in this repository.

The snapshot holds the game encoded: its loader (USR 23424, $5B80) decodes
$7FFF-$FBFF in place and jumps to $8000. That loader is run here in
SkoolKit's simulator, as far as $8000, and the frames are read from where
the game keeps them (game-disassemblies/notes/lunarjetman/notes.md): each a
height byte, then a row of 2 bytes (left, right) for each, bottom row first,
16 pixels wide. They are given here in that same form, in the order
FRAMES names them.

    python jetman_sprite.py [path]      # prints the frames, to look at
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

DEFAULT = Path(os.path.expanduser("~")) / "Downloads" / "Lunar_Jetman_1983_Ultimate_Play_The_Game.z80"
LOADER = 0x5B80         # USR 23424: decodes the game
GAME = 0x8000           # where the decoded game starts

# Name and address of each frame (the game's own), in the order stepscroll
# numbers them: walking left A, B, C, right A, B, C (legs together, half
# stride, full stride); flying left, right, two exhaust frames each.
FRAMES = [
    ("walk_left_a", 0xBCC2), ("walk_left_b", 0xBCEF), ("walk_left_c", 0xBD1C),
    ("walk_right_a", 0xBD49), ("walk_right_b", 0xBD76), ("walk_right_c", 0xBDA3),
    ("fly_left_1", 0xBDD0), ("fly_left_2", 0xBE01),
    ("fly_right_1", 0xBE32), ("fly_right_2", 0xBE63),
]
WALK_ROWS = 22
FLY_ROWS = 24


def memory(path: Path) -> list[int]:
    """The game's 64K as it is once its loader has decoded it."""
    from skoolkit.snapshot import Snapshot
    from skoolkit.simulator import Simulator
    snap = Snapshot.get(str(path))
    mem = list(snap.memory[0:0x10000])
    sim = Simulator(mem, {"SP": 0x5FF8})
    sim.run(LOADER, GAME)
    return mem


def frames(path: Path = DEFAULT) -> list[tuple[str, list[tuple[int, int]]]]:
    """[(name, [(left byte, right byte) a row, bottom row first])]."""
    mem = memory(path)
    out = []
    for name, address in FRAMES:
        height = mem[address]
        want = WALK_ROWS if name.startswith("walk") else FLY_ROWS
        if height != want:
            raise ValueError(f"{path}: {name} at ${address:04X} is {height} rows, not {want}: "
                             f"not the Lunar Jetman this was made from")
        rows = [(mem[address + 1 + 2 * i], mem[address + 2 + 2 * i]) for i in range(height)]
        out.append((name, rows))
    return out


def ink_columns(found) -> tuple[int, int]:
    """The leftmost and rightmost pixel columns any frame has ink in."""
    columns = [x for _, rows in found for left, right in rows
               for x in range(16) if ((left << 8 | right) >> (15 - x)) & 1]
    return min(columns), max(columns)


if __name__ == "__main__":
    found = frames(Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT)
    for name, rows in found:
        print(name)
        for left, right in reversed(rows):
            print("   " + "".join("#" if ((left << 8 | right) >> (15 - x)) & 1 else "." for x in range(16)))
    print("ink in columns", ink_columns(found))
