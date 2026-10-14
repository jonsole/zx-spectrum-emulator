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

The Z80 version is the whole game: the 3D view, the flight model, the keys
and an Interface II joystick, the dashboard, the Theme's aliens and guns,
scoring, crashes and new games, and the sound on the beeper. Flying four
scripted flights side by side with the Python port, its whole game state
and its whole screen match the port's after every frame, as does every
routine of the flight model and the Theme on the port's own test cases.
Flying itself, it takes about 426,000 T-states a frame (6.1 of the TV's 50
Hz frames), so it runs at about 8.2 frames a second; the BBC runs at about
9. It has not been optimised beyond the view yet, and about 5.7K of memory is
left.

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
- **The dashboard picture** is drawn for the Spectrum's resolution
  (`model/zx_dash.py`), in the BBC's layout: its lines one pixel thick
  through the mapped centres of the BBC picture's pixels, its numerals and
  letters in a 3 x 5 font of its own, and nothing anywhere a hand, a bar or
  the joystick cross can rub out, which the Spectrum's 3 rows for the BBC's
  4 would otherwise let happen. The marks the game rewrites are drawn the
  same way.
- **The keys.** The BBC's keys where they exist, with an Interface II
  joystick as well (see "Flying it"). The BBC's analogue joystick has no
  Spectrum equivalent.
- **The sound.** The BBC plays its sounds on a sound chip; the Spectrum's
  beeper sounds only while the CPU works it, so the sound is played from
  the frame interrupt, a little each frame (see "Flying it").

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

It was built in three stages: the view (the maths, the matrices, the
points, the projection, which lines are visible, the clipping, the line
drawing and the copy to the screen); then the flight model, the keys and
the dashboard; then the Theme, scoring, crashes and the sound.

```powershell
.\.venv-win\Scripts\python.exe examples\aviator\spectrum\build.py
```

builds `output/aviator.z80`, the game, which the **ZX Spectrum: Aviator**
launch configuration builds and runs. Like everything else it reads
Acornsoft's files from `data/`, and it writes the original's data into
generated files in `output/`, which are not committed.

### Flying it

The plane starts on the runway with the engine off and an empty tank,
which fills while the engine is off (about five seconds). T starts the
engine, E opens the throttle, B lets the brakes off, and with full throttle
the plane takes off by itself.

| Keys | |
|---|---|
| L / SYMBOL SHIFT | Stick forward (dive) / back (climb) |
| S / D | Bank left / right |
| A / ENTER | Rudder left / right |
| W / E | Throttle down / up |
| T | Engine on and off |
| U, B, F | Undercarriage, brakes, flaps |
| SPACE | Fire (on the runway: start the Theme) |
| I | Gun sights |
| P | The scores |
| X | End the flight, on the ground |
| ENTER | A new game, after a flight ends |

An Interface II joystick (keys 6 to 0) works the stick and fires. The BBC's
TAB, for its analogue joystick, and 7 and 8, for the volume, have no keys.

The sound is a first cut, played from the frame interrupt
(`spectrum/sound.s`): the engine is a click train, up to one a frame, that
speeds up with the throttle and the airspeed, as the BBC's engine buzz rises
in pitch; the beep for points and the wings' strain, the stall warning, the
guns, an alien exploding and touching down are short bursts of tone or noise
each frame while they last, and a crash is a second of noise.

### How it is put together

**Memory.** The original's data sits where it was on the BBC, plus $8000
(`spectrum/layout.py`): its tables and variables keep their relations, the
labels keep their names, and a moment of the original or of the Python port
goes into the Spectrum's memory region by region to be checked. The 3D code
and the sound fill gaps between the regions, where the 6502 code was; the
rest of the game is at $6000 to $7FFF, with starting up below it; the
tables of its own (quarter squares, the screen mapping, the canopy buffer
and its extents, the dashboard's rows and marks) and the keys go above
$D000. About 5.7K is left, in pieces: 1.8K at $D100, 900 bytes at $CB00,
700 above $F944 (below the stack), 470 at the end of the $8D00 gap, 450 at
$E640, 400 at $7E6A, and smaller ones (`aviator.s` has the map).

**Inputs** go through `spectrum/inputs.s`: the keys are read once a pass of
the main loop into a page with a byte for each BBC key code, and the clock
and the random timer each through a routine. The tests switch it to their
own keys, a clock that goes up 3 centiseconds a read and a fixed timer
sequence, so the Z80 and the Python port see the same; its scripted mode
plays the tour's keys a pass at a time with the real clock, so the game
flies itself, which is what `tests/zx_profile.py` profiles.

**The dashboard** is the BBC's: every hand, bar and radar blip is the
original's vector line, drawn on the Spectrum between the mapped ends of
its first and last pixels; the fixed marks the original rewrites whole
bytes of, and the four lamps, are lists of screen bytes `build.py` works
out from `model/zx.py`.

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

`tests/zx_profile.py` shows where a frame's time goes, by routine or
instruction by instruction, from cpp-core's `snapshot_probe`; the biggest
shares are rotating points (about a quarter), the projection's division and
drawing the view and the dashboard.

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
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_zx_game.py tour    # a whole flight, about 2 minutes
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_zx_flight.py       # the flight model
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_zx_theme.py        # the Theme and scoring
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_zx_view.py         # the view alone
.\.venv-win\Scripts\python.exe examples\aviator\tests\test_zx_maths.py        # and its parts
```

`test_zx_game.py` starts both sides from the original's binary as its
loader leaves it and flies a key script on both, with the same keys, clock
and timer: `recorder.FLIGHTS`' tour, theme and crash, and `controls`, which
works the undercarriage, the flaps, the gun sights and the scores and
sweeps every control. After starting and after every frame, the whole game
state and the whole screen must match `model/zx.py`'s. `test_zx_flight.py`
and `test_zx_theme.py` run each routine on the cases `test_flight.py` and
`test_theme.py` check the port against the original with: the recorded
moments, random inputs, and moments made to reach what the flights don't
(stalls, landings, crashes, turbulence, alien hits and explosions, the
bridge and the town), comparing the state, the result, the sounds asked for
and the timer reads. `test_zx_maths.py`, `test_zx_points.py`,
`test_zx_project.py` and `test_zx_visibility.py` do the same for the view's
routines, and `test_zx_view.py` flies a recorded stretch of the tour through
the view alone (`spectrum/stage1.s`), comparing the canopy's screen after
every frame. `zx_game_debug.py` finds where a game test's first mismatch
comes from, step by step.

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
| `model/zx.py`, `zx_dash.py` | The Spectrum screen the Z80 version draws; its dashboard picture |
| `spectrum/build.py`, `layout.py` | Builds the Z80 version; where it keeps the original's data |
| `spectrum/aviator.s` | The memory map, and the modules in it |
| `spectrum/maths.s`, `matrices.s`, `points.s`, `project.s` | The arithmetic, the matrices, points in 3D, the projection |
| `spectrum/visibility.s`, `clip.s`, `canopy.s`, `view.s` | Which lines are visible, clipping, the canopy view, drawing and showing it |
| `spectrum/inputs.s`, `controls.s`, `flight.s` | The keys, clock and timer; the controls; the flight model |
| `spectrum/dashboard.s`, `scoring.s`, `theme.s` | The dashboard; the score and the tests of skill; the guns and the aliens |
| `spectrum/game.s`, `sound.s` | Starting, the main loop and a flight's end; the beeper |
| `spectrum/stage1.s` | The view's part of the main loop alone, for its test |
| `tests/` | The checks of the port against the original, and the recorder |
| `tests/zx.py`, `test_zx_*.py` | The checks of the Z80 version against the port |
| `tests/zx_profile.py`, `zx_breakdown.py`, `zx_shots.py`, `zx_game_debug.py` | Where its time goes; screens of it running; finding a game test's first mismatch |

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
