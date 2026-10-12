# Revs road engine: handover

As of 12 October 2026. This is for whoever picks the engine up next: what it
is, how to work on it, what is known to be true, what has been tried, and
what to do next. The other documents go deeper:

| Document | For |
|---|---|
| [README.md](README.md) | Building, running, the pipeline in brief, memory, speed, the tests |
| [rendering.md](rendering.md) | How the road is drawn: a plain walkthrough of one redraw, then the full reference with a worked example |
| [worklog.md](worklog.md) | How it got here: every commit, the decisions and their alternatives, the bugs found |

## What it is

A road engine for the 48K Spectrum, in Z80, built from Geoff Crammond's BBC
Micro *Revs* as documented at [revs.bbcelite.com](https://revs.bbcelite.com).
It is the first step of a game. So far there is only the track:

- Silverstone is drawn from a camera that drives itself round it.
- There is no car, no driving model, no cockpit and no sound.
- The picture is monochrome: a black road, red-and-white or black-and-white
  kerbs, dithered grass and a white sky.

The design is the BBC's: the same track data, angles, choice of points,
verge widths and edges-as-colour-changes. The arithmetic is the
Spectrum's: log tables instead of division. And the screen is painted
directly, just behind the TV beam, with no back buffer.

## Where it stands

**Speed.** A redraw takes three TV frames, 16.7 a second. Over a lap at the
camera's speed (1,639 redraws), measured by the tests' `speed` check:

| | T-states |
|---|---|
| Median work, interrupt to HALT | 198,155 |
| 99th percentile | 212,187 |
| Worst | 216,582 |
| Three frames' budget | 209,664 |
| Redraws needing a fourth frame | 59 of 1,639 (3.6%), all in the tightest corners |

By stage, at the median:

| Stage | T-states | Starts at |
|---|---|---|
| Camera | ~6,600 | 100 |
| First 4 segments of verge points | ~16,300 | 6,700 |
| Compose (painting the screen) | ~64,500 | 23,000 |
| The rest of the verge points | ~37,400 | 87,900 |
| Edges | ~72,900 | 125,300 |

**Memory.** About 32K of 48K is used. About 10.5K is free:

| Where | Size |
|---|---|
| `$7210`–`$7FFF` | 3.5K |
| `$A800`–`$AFFF` | 2K, once `build_track` has run |
| `$97CE`–`$9FFF` | 2K |
| `$5B00`–`$5FFF` | 1.25K |
| `$BC00`–`$BFFF` | 1K |
| `$B800`–`$B9FF` | 0.5K |
| `$7110`–`$71FF` | 240 bytes |

The worklog's Memory section has the full map.

**Correctness.** All six checks in `tests/run_tests.py` pass:
- the screen is identical, byte for byte, to a model of the edge and compose
  stages at 12 places round the track;
- the verge points are within 2.6 pixels and a line of a model of the BBC
  routines;
- no redraw is ever shown half-drawn.

## Working on it

```powershell
cpp-core\build.ps1 -Release -Target snapshot_probe     # once, for the tests
.\.venv-win\Scripts\python.exe examples\revs\build.py   # assemble
.\.venv-win\Scripts\python.exe examples\revs\tests\run_tests.py   # about 25 s
```

- **Running it:** **ZX Spectrum: Revs road** in VS Code builds and runs it.
  The digit bottom left is the frames the last redraw took.
- **Track data:** fetched from revs.bbcelite.com on the first build and cached
  in `data/`. It is Acornsoft's, so it is never committed (gitignored, like
  `roms/`).
- **Assembler:** sjasmplus: `tools/sjasmplus/sjasmplus.exe`, on PATH, or
  `SJASMPLUS`.
- **Testing changes:**
  - Run the tests after every change. Five checks compare against models; the
    sixth, `speed`, measures.
  - To see where time goes, profile. `snapshot_probe`'s `work` command times
    any stretch of the main loop from the interrupt (see `tests/probe.py`).
    The emulator's own profiler works too.
  - Change one thing at a time and measure it: several ideas below looked
    good on paper and weren't.
- **Before relying on the probe on Windows:** it was only built with GCC
  (`-Wall -Wextra -Werror`). The first `build.ps1` build of `snapshot_probe`
  is its first time through MSVC's `/W4 /WX`.

## Rules the code depends on

These are easy to break without noticing. Most are commented where they
apply.

- **Compose must stay behind the beam.**
  - It paints the visible screen top to bottom and starts once the beam has
    passed row 16 (`wait_for_beam`, on the floating bus).
  - Every line must take at least 224 T-states, which is why skipped lines
    are padded to about 245.
  - It must finish each row before the next frame's beam reaches it, about
    105,500 T-states for the bottom row.
  - The `beam` check fails if either rule breaks: with no padding, 59 redraws
    in 60 tear.
- **Work before compose is bounded.** The camera and the first `VB_EARLY` (4)
  segments run before compose. With 5, the first redraw started compose too
  late. With 12, 157 of 200 tore.
- **The frame interrupt lands inside compose** every redraw, and pushes 4
  bytes below SP. Any code that points SP into the screen or the marker
  records must keep those 4 bytes harmless:
  - `edges_build` header pushes;
  - compose's empty-line fill, which writes its first 4 bytes after
    restoring SP. That was a real bug, fixed in `8038d97`.
- **Floating bus.** `wait_for_beam` needs a 48K or 128K. The +2A and +3 have
  none.
- **Markers per line.** At most 14 (`MAX_MARKS`). Lines 80–127 have records
  that are marked full once, so edges running off the top write nowhere.
- **Edge order.** Edges are drawn left to right (left kerb outside, left kerb
  road edge, right kerb road edge, right kerb outside). Compose's sort keeps
  equal x in creation order, so the later edge wins at the same x.
- **sjasmplus macros substitute parameter names inside other words:** a
  parameter `COLOUR` breaks `ECOL`. Name parameters so none is a substring
  of another name.
- **Snapshots:** while halted, the emulator reports PC as the address after
  the HALT. The tests use the label `main_loop.wait_frame` on the HALT; keep
  it.
- **Timing is uncontended.** The emulator doesn't model contended memory, so
  all T-state figures are what an uncontended 48K would do. On a real 48K,
  compose's screen writes would be slowed.

## Tried and measured: don't redo these

| Idea | What was found |
|---|---|
| Fill compose's runs with PUSH | Plain fills are only 21% of compose (about 13K T-states). The frame interrupt lands in compose, so PUSH filling must run right to left and handle each row's first 4 bytes apart. Net gain about 3–5K; not done. |
| Step a kerb's two edges in one loop | The edge loop already uses every fast register. The second edge's state would sit in IX/IY at 8–15 T-states an access. About 28 T-states a line saved, 3–5K overall; not done. |
| Read compose's markers with POP | Saving and restoring SP every line, and the counter it needs, cancel the gain: about 1K net; not done. |
| Skip lines whose markers didn't change | Only 4.5% of lines with markers repeat between redraws; not done. |
| Stop stepping an edge gone off the right, heading right | Done (`8e5c9f3`): median −3.7K, four-frame redraws 207 → 22. |
| Drop the log table's 4K of high bytes | Done (`95c9f6f`): 3.8K freed, for +1.6K T-states median and 22 → 59 four-frame redraws. Revert that one commit to trade the memory back for the speed. |

## What to do next

Roughly in order. The worklog's "Still to do" has the full list.

1. **Driving model.** Speed, steering, the car's position across the track,
   heading. It replaces the self-driving camera (`camera.s`). The projection
   already takes any position and heading.
2. **Pitch.** BBC Revs moves the whole view up and down with a pitch angle
   (nose lift under acceleration and braking, jumps, bumpy grass). Here it is
   one subtraction in the pitch step, in `verges.s` and `pitch_line`.
3. **Facing backwards or sideways.** The maths is ready, but the point picker
   always takes slices from 32 ahead to 2 behind. Revs keeps its verge tables
   as the driver's left and right and lays out its section list differently
   when the car faces backwards. Needed once the car can spin.
4. **Cockpit and dashboard.** The rows below the view are free for it.
5. **Other cars, signs, laps and timing, sound, menus.**
6. **Colour.** Attribute colour (green grass, blue sky) fitted round the 8×8
   cells.
7. **Speed headroom.** Everything above must fit in a fourth frame. The
   remaining small speed-ups, each estimated, none tried:
   - keep the verge-point variables in registers (2–4K);
   - a table for x >> 3 in compose's marker loop (1–2K);
   - a quarter-square multiply in the camera (about 1.5K).
8. **Other tracks.** The four extra BBC tracks use a hook-driven data format
   that `track_data.py` doesn't read.
9. **Tooling.**
   - The tests aren't in CTest, since they need sjasmplus and the track data.
   - `snapshot_probe` hasn't been built with MSVC.

## Online copies

Two private documents in the owner's Claude workspace have online versions:
- `rendering.md`, as a walkthrough tab and a reference tab, matches the
  repository at the time of writing.
- The work log there is an earlier snapshot, from before the tests and the
  latest speed and memory changes.

The repository copies are the ones to keep up to date.
