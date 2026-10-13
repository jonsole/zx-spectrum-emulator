# aviator

A port of Geoff Crammond's *Aviator* (Acornsoft, 1983, BBC Micro) to the 48K
Spectrum, being built from Mark Moxon's fully documented disassembly at
[aviator.bbcelite.com](https://aviator.bbcelite.com) (source on
[GitHub](https://github.com/markmoxon/aviator-source-code-bbc-micro)).

**Where it stands.** The original runs in Python as a reference, and the
whole game has been ported to Python and matches the original byte for byte,
iteration after iteration, over three scripted flights (a tour, a flight
with the Theme's aliens and the guns, and a crash followed by a new game). A
renderer draws the Python port's game on a Spectrum screen, in the layout
the Z80 version has.

The Z80 version has its first stage: the 3D view, flown along a recorded
stretch of the tour flight. Its state and its canopy's screen bytes match
the Python port's after every one of the stretch's 520 iterations. A frame
of the view takes 397,000 T-states on average (5.7 of the TV's 50 Hz
frames), so it runs at about 8.8 frames a second, and 560,000 at most; the
BBC game, flight model and all, runs at about 9. The flight model, the keys,
the dashboard's dials, the Theme and the sound are still to come.

## The approach

The Spectrum version is meant to fly like the BBC one: the same flight
model, the same world, the same Theme, the same numbers. So it is built in
three layers, each checked against the one before.

1. **The original, running in Python** (`bbc/`). A 6502 interpreter runs the
   real game binary, on a BBC Micro reduced to what Aviator touches: the
   keyboard, the clock, the joystick, sound requests, a few VDU commands to
   set up the screen, the dashboard image load, and one timer read for
   random numbers. Its screen memory renders to a PNG. This is the exact
   reference: whatever it does, the original does.
2. **The Python port** (`model/`). The game rewritten routine by routine in
   plain Python, working on the original's memory layout so its state can
   be compared byte for byte with the original's at any moment. Each
   module's docstring explains its part of the game. The drawing and the
   sound go to hooks, in the BBC's coordinates; `model/zx.py` draws them on
   a Spectrum screen.
3. **The Spectrum version** in Z80 (`spectrum/`), checked against the
   Python port: the same memory state, and the same screen bytes as
   `model/zx.py`.

What has to change on the Spectrum is the screen and the sound; the rest is
the original's design.

- **The screen.** The BBC uses Mode 5, 160x256 in four colours, and hides
  each redraw by drawing the new view in one colour while the old one shows
  in the other, then swapping them in the palette (see the "flicker-free
  animation through colour cycling" deep dive). The Spectrum has no palette,
  so the canopy is drawn into a buffer and copied to the screen when the BBC
  would swap. The layout keeps the BBC's proportions: Mode 5's 160x256
  scales to the Spectrum's 256x192 with the same picture shape (x by 8/5,
  rows by 3/4), so the 160-row canopy becomes 120 rows (character rows 0 to
  14) and the 96-row dashboard 72 (rows 15 to 23). Lines are drawn between
  their mapped end points at the Spectrum's own resolution.
- **The dashboard picture** is for now the BBC's image mapped across pixel
  by pixel, which keeps every line but makes the numerals blobby; a picture
  drawn for the Spectrum's resolution would look better.
- **The keys.** The BBC's keys where they exist, with an Interface II
  joystick as well. The BBC's analogue joystick has no Spectrum equivalent.
- **The sound.** The beeper, to be designed.

The 48K is enough. The BBC game is about 20K, code and data; the Spectrum
has about 41K free after its screen.

## Acornsoft's files

Aviator is Acornsoft's, and Mark Moxon's repository is published without a
licence, so none of it is committed here. `acornsoft.py` fetches what is
needed from a pinned commit of his repository the first time anything runs,
checks it against known hashes, and caches it in `data/` (gitignored): the
game binary from the original disc, the dashboard image, the annotated
source and its assembly listing (for every label's address). The Python port
reads the game's tables (the 3D world, the sine table and so on) from the
binary in memory, as the original does, and the Spectrum build will take
them from the same place; none of them are written into this code.

`source.py` prints routines from the annotated source compactly, which is
the quickest way to read one:

```powershell
.\.venv-win\Scripts\python.exe examples\aviator\source.py "ProjectPoint*"
```

## Running it

```powershell
.\.venv-win\Scripts\python.exe examples\aviator\bbc\run.py --iterations 1300 --keys "270-271:T 272-360:E 345-346:B" --every 100
.\.venv-win\Scripts\python.exe examples\aviator\run_model.py --iterations 1300 --keys "270-271:T 272-360:E 345-346:B" --every 100 --bbc
```

The first runs the original for 1,300 iterations of its main loop and saves
what the screen shows every 100 iterations, in `output/`. The second runs
the Python port and saves what the Spectrum would show; `--bbc` runs the
original beside it and puts the two side by side. The keys script holds T
(engine on) at iteration 270, E (more throttle) from 272 to 359, and B
(brakes off) at 345 ("lo-hi:KEY", keys joined by "+"). The tank is empty at
the start and fills while the engine is off, which takes about 260
iterations; with full throttle the plane takes off by itself at about
iteration 650.

`bbc/run.py --clock cycles` runs the BBC's clock from the 6502's cycle count,
as the real machine would; by default it advances a fixed step each time it
is read, so every iteration does the same work and runs can be compared. On
the BBC each main-loop iteration takes about 222,000 cycles at 2 MHz, so the
game runs at about 9 frames a second.

## The Spectrum version

It is being built in three stages:

1. **The view** (done): the maths, the matrices, the points, the
   projection, which lines are visible, the clipping and the line drawing,
   and the copy to the screen, flown along iterations 600 to 1119 of the
   tour flight as the Python port flies them (`spectrum/stage1.s`). There
   is no flight model yet, so the plane is put where the recording has it.
2. The flight model, the keys and an Interface II joystick, and the
   dashboard.
3. The Theme (the aliens and the bullets), scoring, crashes and the sound.

```powershell
.\.venv-win\Scripts\python.exe examples\aviator\spectrum\build.py
```

builds `output/aviator.z80`, which flies the recorded stretch round and
round. Like everything else it reads Acornsoft's files from `data/`, and it
writes the original's data into generated files in `output/`, which are not
committed.

**Memory.** The original's data sits where it was on the BBC, plus $8000
(`spectrum/layout.py`): its tables and variables keep their relations, the
labels keep their names, and a moment of the original or of the Python port
goes into the Spectrum's memory region by region to be checked. The Z80 code
fills the gaps between the regions, where the 6502 code was, with the rest
from $5B00 to $7FFF; the tables of its own (quarter squares, the screen
mapping, the canopy buffer and its extents) go above $D800.

**The arithmetic** gives exactly the original's results, quirks and all
(see "Notes on the original"): products by quarter squares, or by the
original's own table of nibble products where it multiplies by nibbles;
the projection's division as the original works it out, nibble by nibble.

**The picture.** Lines are drawn into a buffer of the canopy's 114 rows and
copied to the screen where the BBC would swap colours, with the frame laid
over the edge bytes. The line drawer notes the first and last byte it drew
in on each row, and the copy takes, row by row, only the bytes this view or
the last one drew in, so a view of a few hundred pixels takes about 26,000
T-states to show, where copying the whole buffer's 3,648 bytes with LDIR
would take 77,000 before clearing it. A shallow line, as most of the view's
are, is drawn by eight copies of a pixel's step, one for each bit of a
byte, which gather a byte's pixels in a register.

`tests/zx_profile.py` shows where an iteration's time goes, by routine or
instruction by instruction, from cpp-core's `snapshot_probe`.

## Tests

```powershell
.\.venv-win\Scripts\python.exe examples\aviator\tests\run_all.py           # everything, about 25 minutes
.\.venv-win\Scripts\python.exe examples\aviator\tests\run_all.py --quick   # the routines only
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_game.py theme   # one whole flight
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_m6502.py        # the 6502 core
```

`test_m6502.py` runs Klaus Dormann's 6502 functional test (fetched into
`data/`; it is GPL-3). The others check the Python port against the
original:

- each module's routines (`test_<module>.py`), on random and exhaustive
  inputs where they are pure, and otherwise on moments recorded at the
  routine's entry during the scripted flights (`tests/recorder.py`),
  replayed through both, plus synthetic moments built from recorded ones
  for what the flights don't reach (hits on aliens, stalls, crashes,
  landings);
- the whole game (`test_game.py`): starting up from the original's binary,
  and then each of the flights in `recorder.FLIGHTS`, both sides given the
  same keys, clock and timer values, with all memory compared after every
  iteration.

The Z80 version is checked against the Python port in cpp-core's
`snapshot_probe` (build it with `cpp-core\build.ps1 -Release -Target
snapshot_probe`):

```powershell
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_zx_view.py      # stage 1 as a whole, about 30 seconds
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_zx_maths.py     # and its parts
```

`test_zx_maths.py`, `test_zx_points.py`, `test_zx_project.py` and
`test_zx_visibility.py` call each routine on the inputs recorded at the
original's routine during the tour flight, and on random ones where it is
pure, and compare the results and the state with the Python port's, giving
each routine's T-states. `test_zx_view.py` flies the recorded stretch on both
sides and compares the whole game state and the canopy's screen bytes after
every iteration.

Left out of the comparisons are the zero-page temporaries (which the port
keeps in Python variables), the stack, the screen (except the two bytes the
game reads back), and the bytes of the BBC's line drawer that it rewrites
for each line, which only the drawer reads.

The recordings contain the game's memory, so they are cached in
`data/recordings/`; the first run of a test that needs one flies the flight,
which takes a minute or two.

## Layout

| Path | What |
|---|---|
| `acornsoft.py` | Fetches and checks Acornsoft's files; the label table |
| `source.py` | Prints routines from the annotated source |
| `run_model.py` | Runs the Python port and saves Spectrum screens |
| `bbc/m6502.py` | The 6502 interpreter |
| `bbc/beeb.py` | The BBC Micro around it: OS stand-ins, VIA timer, Mode 5 rendering |
| `bbc/run.py` | Runs the original with a key script and saves screens |
| `model/game.py` | The port's main loop, start-up and a flight's end |
| `model/maths.py`, `matrices.py`, `points.py`, `project.py` | The arithmetic, the rotation matrices, points in 3D, the projection |
| `model/visibility.py`, `clip.py`, `canopy.py` | Which lines are visible, clipping them to the canopy, drawing the view |
| `model/flight.py`, `controls.py` | The flight model; the keys and the key logger |
| `model/dashboard.py` | The dials, the horizon, the radar and the fuel gauge |
| `model/theme.py`, `scoring.py` | The guns and the aliens; scores and flying skills |
| `model/memory.py`, `names.py`, `hardware.py`, `sound.py`, `events.py` | The memory, its labels, the BBC's hardware as replaceable sources, sound requests, a flight's end |
| `model/zx.py` | The Spectrum screen the Z80 version draws |
| `spectrum/build.py`, `layout.py` | Builds the Z80 version; where it keeps the original's data |
| `spectrum/aviator.s` | The memory map, and the modules in it |
| `spectrum/maths.s`, `matrices.s`, `points.s`, `project.s` | The arithmetic, the matrices, points in 3D, the projection |
| `spectrum/visibility.s`, `clip.s`, `canopy.s`, `view.s` | Which lines are visible, clipping, the canopy view, drawing and showing it |
| `spectrum/stage1.s` | Stage 1's driver: the view along the recorded flight |
| `tests/` | The checks of the port against the original, and the recorder |
| `tests/zx.py`, `test_zx_*.py` | The checks of the Z80 version against the port |
| `tests/zx_profile.py`, `zx_breakdown.py`, `zx_shots.py` | Where its time goes; screens of it running |

## Notes on the original

Things found while porting, which the source's commentary doesn't say or
gets wrong; the module docstrings have more.

- The right-hand canopy corner's address, called `row1_char39_0` in the
  source, is character 38 (x 152-155).
- Point 32's z is never set: DrawHalfHorizon writes only its x and y, so
  the clipper reads whatever z it last had.
- DivideScaled counts some carries twice, after `BCC`/`INY` pairs; ScaleDown
  limits its shifts from 7, not 0.
- The erases are ANDs, not EORs: the canopy's with the hidden colour's
  whole-byte pattern, the dashboard's with the inverted pixel mask.
- UpdateDash7To11 never reaches indicator 11, the thrust: the flight model
  redraws that when the thrust changes.
- The flaps' pitching moment uses flapsStatus where the drag's low byte
  should be; the elevator gets neither the dead zone nor the instant
  centring that the rudder and ailerons do.
