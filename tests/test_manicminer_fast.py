"""game-disassemblies/scripts/build_manicminer_fast.py: the dirty-span patch
must not change what
the game draws, only how much of it gets copied.

Each patched build is dropped into the same cavern in the same state as stock
and stepped in lockstep, one main-loop iteration at a time, with identical
keyboard input. At the top of every iteration the whole of RAM is compared.
The patch changes which bytes are copied and when the loop runs, never what
the game computes, so every game variable, both pixel buffers and the display
file must match byte for byte -- including for the frame-locked build, where
HALT only changes how long a pass takes.

Skipped unless the snapshots have been built -- they are derived from the
copyrighted game and are never committed. See
game-disassemblies/scripts/build_manicminer.py and build_manicminer_fast.py.
"""
from pathlib import Path

import pytest

from zxspectrum.core.machine import Spectrum48K

PROJECT_ROOT = Path(__file__).resolve().parent.parent
# The builds that produce these moved to their own repository, checked out here
# as the game-disassemblies submodule, so their output lands inside it. Without
# this the paths still resolve, find nothing, and the whole module skips --
# which looks exactly like "you have not built Manic Miner yet".
MM = PROJECT_ROOT / "game-disassemblies" / "game_disassembly" / "manicminer"
ROM_PATH = PROJECT_ROOT / "roms" / "48.rom"
STOCK = MM / "mm.sna"
# Both patched builds: free-running, and locked to the frame interrupt.
PATCHED = {"free-running": MM / "mm-fast.sna", "frame-locked": MM / "mm-sync.sna"}

# Addresses of the routines the harness steers through, from the disassembly.
PLAYTUNE, STARTGAME, NEWSHT, LOOP = 0x92DC, 0x8684, 0x8691, 0x870E
# Manic Miner's stack lives at 0x9CFE. Both builds sit at the top of the main
# loop with the same SP, so anything below it is dead space holding whatever
# each build last pushed -- different call depths, identical game state.
STACK_LO, STACK_HI = 0x9C00 - 0x4000, 0x9CFE - 0x4000
# The patch's code and tables, and MESSINTRO's relocated text.
PATCH_LO, PATCH_HI = 0x9D00 - 0x4000, 0xA000 - 0x4000
MESS_LO, MESS_HI = 0x5B00 - 0x4000, 0x5C00 - 0x4000

ITERATIONS = 12

pytestmark = pytest.mark.skipif(
    not (STOCK.exists() and ROM_PATH.exists() and all(p.exists() for p in PATCHED.values())),
    reason="needs roms/48.rom plus mm.sna, mm-fast.sna and mm-sync.sna (not committed)",
)


def _label(name: str) -> int:
    for line in (MM / "mm.sld").read_text(encoding="utf-8").split("\n"):
        parts = line.split("|")
        if len(parts) > 7 and parts[6] == "F" and parts[7].strip() == name:
            return int(parts[5])
    raise AssertionError(f"{name} not found in mm.sld")


def _boot(rom: bytes, image: bytes, cavern: int) -> Spectrum48K:
    """The stock build, parked at the top of the main loop in `cavern`."""
    m = Spectrum48K()
    m.load_rom(rom)
    m.load_snapshot(STOCK.read_bytes())          # for the registers, SP and IM
    m.write_memory(0x4000, image)
    # Skip the title screen and its theme tune: run START's setup, then drop
    # into STARTGAME with the demo flag clear so Willy is under our control.
    m.breakpoints = {PLAYTUNE}
    assert m.run(2_000_000) == "breakpoint"
    regs = m.registers
    regs.pc = STARTGAME
    m.set_registers(regs)
    m.write_memory(_label("DEMO"), b"\x00")
    m.breakpoints = {LOOP}
    assert m.run(5_000_000) == "breakpoint"
    m.write_memory(_label("SHEET"), bytes([cavern]))
    regs = m.registers
    regs.pc = NEWSHT                              # NEWSHT reads SHEET
    m.set_registers(regs)
    assert m.run(5_000_000) == "breakpoint"
    return m


@pytest.mark.parametrize("build", sorted(PATCHED))
@pytest.mark.parametrize("cavern", [0, 4, 13])
def test_patched_build_draws_exactly_what_the_stock_build_draws(cavern, build):
    rom = ROM_PATH.read_bytes()
    stock_image = STOCK.read_bytes()[27:]
    fast_image = PATCHED[build].read_bytes()[27:]

    differs = {i for i in range(len(stock_image)) if stock_image[i] != fast_image[i]}
    assert differs, f"{PATCHED[build].name} is identical to stock -- it is stale"
    # Everything outside the patch's own two regions has to agree. Those
    # regions are excluded by address rather than by comparing the images,
    # because a patch byte that happens to equal the stock byte underneath it
    # is still live patch state once the game runs.
    compared = [
        i for i in range(0xC000)
        if i not in differs                      # the hooks: code, never written
        and not (PATCH_LO <= i < PATCH_HI)
        and not (MESS_LO <= i < MESS_HI)
        and not (STACK_LO <= i < STACK_HI)
    ]

    stock = _boot(rom, stock_image, cavern)

    # Transplant that exact game state into the patched build. Nothing the game
    # writes lives at the differing addresses, bar the span tables and the
    # frame counter; the overlay sets the tables to "every column of every
    # row", so this is the state the patched build would have reached itself.
    ram = bytearray(stock.read_memory(0x4000, 0xC000))
    for i in differs:
        ram[i] = fast_image[i]
    fast = Spectrum48K()
    fast.load_rom(rom)
    fast.write_memory(0x4000, bytes(ram))
    fast.set_registers(stock.registers)
    fast.breakpoints = {LOOP}

    # Alternate walking and jumping so Willy moves, falls and lands.
    keys = ["p", "p", "p", "space", "o", "o", "o", "space"]
    for n in range(1, ITERATIONS + 1):
        key = keys[(n // 3) % len(keys)]
        for m in (stock, fast):
            m.keyboard.key_up_all()
            m.keyboard.key_down(key)
            assert m.run(5_000_000) == "breakpoint", f"iteration {n}: lost the main loop"

        a = stock.read_memory(0x4000, 0xC000)
        b = fast.read_memory(0x4000, 0xC000)
        wrong = [i for i in compared if a[i] != b[i]]
        assert not wrong, (
            f"{build}, cavern {cavern}, iteration {n}: {len(wrong)} bytes differ, first at "
            + ", ".join(f"0x{i + 0x4000:04X}" for i in wrong[:8])
        )
