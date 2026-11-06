# A Manic Miner player

Manic Miner on the end of an API, and a search that finds a way through its
caverns. It follows the shape of
[elite-agent](https://github.com/8bitkick/elite-agent), which plays BBC Elite
from the machine's RAM: the player reads the game's own variables and plays
only by the keys it holds down. A lab replays what it found, and a test proves
the fast path is the same game.

It runs on `cpp-core`, headless, at about 500 passes of the game's main loop
a second a thread. A real 48K manages about 16.

## Getting it running

The ROM and the game are not committed.

```sh
# the 48K ROM, as for the rest of the emulator
cp <your 48.rom> roms/48.rom

# the game: assembled from SkoolKit's disassembly (pip install skoolkit)
python agents/manicminer/make_game.py          # -> agents/manicminer/game/mm.bin

# build: the tools are in the zx_tools group
cd cpp-core
.\build.ps1 -Release -Target mm_explore        # also mm_lab, mm_tests
# or, anywhere with CMake:
cmake -B build-rel -DCMAKE_BUILD_TYPE=RelWithDebInfo && cmake --build build-rel --target mm_explore mm_lab mm_tests
```

`--game <file>` takes a `.sna` or `.z80` instead, such as the one
game-disassemblies' `build_manicminer.py` makes.

## The tools

| Tool | What it does |
|---|---|
| `mm_explore <cavern>\|all` | Searches for a route through a cavern and writes `routes/cavernNN.route` once a replay from the cavern's start confirms it |
| `mm_lab bench [seconds] [threads]` | Passes a second, on one thread and on all of them |
| `mm_lab play <route>...` | Replays routes: the outcome, the passes, the items and the air left |
| `mm_lab film <route> <out.rgb>` | The screen after every pass, as raw frames for ffmpeg |
| `mm_lab random <cavern> [tries]` | The random player's baseline |
| `mm_tests` | The wrapper's tests (CTest; skips without the ROM and the game) |

A GIF of a route:

```sh
mm_lab film routes/cavern00.route c0.rgb
ffmpeg -f rawvideo -pix_fmt rgb24 -s 256x192 -r 16 -i c0.rgb \
  -vf "scale=512:384:flags=neighbor,split[a][b];[a]palettegen=max_colors=16[p];[b][p]paletteuse" c0.gif
```

## How it works

**One step is one pass of the main loop** (`LOOP`, 34574). The guardians move,
Willy moves, the items are collected and the screen is drawn. The player
chooses one of six moves for each pass: nothing, left, right, jump, or jump
left or right (O, P and SPACE). A pass ends back at `LOOP`, or at `MANDEAD`
(a death, or the air running out) or at `NXSHEET` (through the portal). Every
address is a label in Richard Dymond's
[disassembly](https://github.com/skoolkid/manicminer), and `mm_game.h` names
them.

**The game never waits for the frame interrupt.** Its interrupts are off, and
nothing it does depends on time. So the emulator can run it as fast as it
likes, and contention is switched off.

**Fast mode.** Seven eighths of a pass is four `LDIR` block copies: the empty
cavern into the screen buffer, and the screen buffer onto the screen. The
emulated Z80 copies them a byte at a time, which is slow. In fast mode (the
default) the host does each of the game's `LDIR`s in one go. Memory, BC, DE,
HL, the flags and PC end up exactly as the Z80 would leave them; only the time
taken and R differ, and the game reads neither. That makes it 4.6 times
quicker. `mm_tests` plays six caverns both ways in lockstep and compares the
game after every pass.

**Saving the game is cheap.** At the top of the main loop, everything that
changes as a cavern is played lies between 24064 and 40191: the cavern's
buffers (crumbled floors included), the variables and the stack. Saving and
restoring that 16 KB slice is the whole game, and `mm_tests` checks it.

**The search** (`mm_explore`) is
[Go-Explore](https://arxiv.org/abs/1901.10995)'s first phase, which is how
Montezuma's Revenge was first beaten. It keeps an archive of *cells*: where
Willy has stood on the ground, to 8 pixels, and which items he holds. Each
cell keeps the saved game and the moves that reached it. Each round it picks
a cell, favouring those tried less often and those with more items. It
restores the game there, plays 20 to 80 random moves (each held for a few
passes), and adds any cell reached that is new, or reached in fewer passes
than before. Manic Miner has no randomness, so the route to a cell replays
exactly from the cavern's start. Each thread runs its own search; the first
route found wins.

A random player gets nowhere: in Central Cavern it dies within 150 passes or
so, with nothing collected.

## Results

Routes found so far are in [`routes/`](routes/). Each is a text file: the
cavern, then one character a pass (`.` `L` `R` `J` `<` `>`).

## The player interface

`mm_player.h` is elite-agent's `player_frame()`, one call a pass: a `Player`
is told when a cavern starts, then asked for a move each pass. It may read
anything in the game (`Game::view()`, `Game::peek()`). `RoutePlayer` replays a
route and `RandomPlayer` is the baseline. A hand-written player or a small
network goes here.

## Next

- Routes for every cavern, then one game played through all twenty on the
  routes, with the game's own lives.
- Shorter routes: keep searching after the first one, for more air left.
- A player that isn't a recording: learn from the routes (behaviour cloning),
  or tune a small network by evolution against the lab, as elite-agent did.
- A "fair" player that sees only the screen, as elite-agent's Fair mode does.
- On the board: retro-spectrum puts this machine in the Next's FPGA. A small
  player reading its SRAM would play the real thing, as elite-agent's does on
  the RP2350.
