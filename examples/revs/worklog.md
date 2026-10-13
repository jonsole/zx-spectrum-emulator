# Revs road engine for the 48K Spectrum: work log

As of 12 October 2026.

A road engine for the 48K Spectrum, written in Z80 from Geoff Crammond's BBC Micro Revs design, now draws Silverstone in three frames an update (16.7 a second) all the way round. It lives in `examples/revs` of the zx-spectrum-emulator repository.

## Where it stands

The engine lives in `examples/revs`. It is the first stage of the plan: the track, drawn in native Z80, from a camera that drives itself round Silverstone. There is no car, no driving model and no cockpit yet.

- **Speed:** every update takes three frames, which is **16.7 updates a second**. The target was 12 to 15. Over a lap, the median work per update is about 187,700 T-states against a three-frame budget of 209,664, and the worst, in the tightest corner, 205,600.
- **Picture:**
  - a solid black road;
  - red-and-white or black-and-white kerbs, 25, 50 or 100 units wide as the track data says;
  - dithered grass;
  - white sky.
  - The kerb stripes move with the track. The camera turns smoothly through corners.
- **Correctness:** the screen matches Python models of both the BBC routines and the Z80's own stages, byte for byte where the model is exact. No frame shows two half-drawn views.
- **Memory:** about 32K of the 48K is in use. About 10K is free, the largest pieces 3.5K at `$7210` and 2K at `$A800`.
- **Runs on:** a 48K or 128K Spectrum, since it needs the floating bus. It does not run on the +2A or +3.

The work was done on branch `ccr-a5725d0e-ey56yb` and is now on `master`.

## What was done

Before the engine, the existing slow Spectrum port of BBC Revs was profiled, and its TAP was patched where the time went. That showed a port of the BBC's 6502 maths would not get anywhere near the speed needed. So the engine was started again in native Z80, keeping the BBC design but doing the maths the Spectrum's way.

The work, newest first. Each row is one commit on the branch:

| Commit | What it did | Frames per update |
| --- | --- | --- |
| — | A first object: a sign beside the track, its parts painted over each line inside compose, which has no buffer to draw into afterwards. About 1,000 T-states a covered line; a known limit for the synchronised build. | 3 (more with the sign close) |
| — | Ran unsynchronised by default: no wait for the frame or the beam, so updates come as the work allows. `--define SYNCED` for the old way, which the tests use. | ~2.7 |
| — | Keys to drive the camera (Q/A speed, O/P sideways, or an Interface II stick); kerbs fixed close to the camera (the list's last point kept below the view, the road's far end closed); stripes out to 12 segments. | 3 |
| — | Set up an edge's segments with each point's x read from the list once and kept in the instruction that loads it, the rest of a side's state patched in too; a rightward and a leftward copy of the line loop; the error term counted down. Median −7.3K. | ~3 → 3 |
| — | Started compose below the sky when it is blank and stays so (`compose_skip`), with `wait_for_beam` waiting for the beam to get past it too. Median −3.1K. | ~3 |
| `02d194d` | Made the road solid black, as on the BBC. A black kerb mark now runs into the road and the white marks show as dashes. | ~3 |
| `f7bde4c` | Turned the camera smoothly through corners. Its look target is interpolated from three segments ahead to four. Its position is interpolated between segment centres, which can be more than 127 units apart. | ~3 |
| `92a7a4e` | Kept the distant kerb stretches one colour, so they no longer flicker as the camera passes each segment. | ~3 |
| `b1ddce9` | Drew the road in three frames. The next update's first points are worked out while compose waits for the beam, the beam is found by reading the floating bus, and each verge's two edges are drawn in one pass. | 3.05 → ~3 |
| `597c386` | Stopped compose getting ahead of the beam after it skips lines. Wrote the verge projection out in full for each side. | 3.27 → 3.05 |
| `960f0aa` | Found out-of-order marker lines while composing, instead of checking every line first. Moved the camera update into the wait for the beam. | 4 → 3.27 |
| `12910c1` | Drew the road in four frames instead of six. Compose writes straight onto the screen behind the beam, and the projection's maths is done by table. | 6 → 4 |
| `d05af4a` | The first working engine: the track data expanded to every segment, verge points by yaw and pitch, and edges as colour changes filled to the right. | 6 |

Along the way, some things were produced that are not in the repository:

- videos of the camera going round Silverstone, rendered from the emulator;
- an answer on memory use.

The repo-level files were updated with the engine:

- `CHANGELOG.md` has an entry under Unreleased.
- The README's docs table and `docs/project-layout.md` list the example.
- `.vscode/launch.json` gains **ZX Spectrum: Revs road**, with a `revs.build` task in `tasks.json`.

## How the engine works

### At startup

`track.s` expands Silverstone's 1,849-byte data file into the coordinates of all 1,024 segments, as `GetTrackSegment` does:

- inner and outer verge x and z;
- height;
- flags.

The BBC builds 40 segments at a time as the car moves. The Spectrum has room for all of them: 11K at `$C000` to `$EBFF`. After that, a segment is an index into five arrays.

### Each update

The main loop is:

```
main_loop: call verges_finish   ; the rest of the verge points
           call edges_build     ; markers for every edge crossing
           halt                 ; frame interrupt
           call camera_update
           call verges_begin    ; the next update's first 4 points
           call wait_for_beam   ; floating bus
           call compose_screen  ; sort and fill, onto the screen
           call fps_show
           jr main_loop
```

The stages are:

1. **Camera** (`camera.s`). The camera is a fraction of the way along the track's centre line, 500 units up. It looks at the point the same fraction of the way from three segments ahead to four. The four centres it needs are cached, and only change when the camera passes a segment. This stands in for a driving model.
2. **Verge points** (`verges.s`). This follows `GetSegmentAngles` and `GetVergeAndMarkers`. Both verges are projected together, a segment at a time, sharing its flags and height.
   - It starts 32 segments ahead, then steps back by 13 and 7 segments, then one at a time. That gives up to 16 points a side, and stripes out to 12 segments (the BBC steps 13, 6 and 3, with stripes to 9).
   - Each point gets a yaw (screen x), a pitch (track line), and a verge-mark width of 25, 50 or 100 units scaled by distance.
   - The list stops at the first point below the view, or outside the field of view once the points come back towards the camera. There is one last try a quarter of the way to that point.
3. **Edges** (`edges.s`). This follows `DrawTrack`. Four edges are drawn through the points:
   - left verge outer to inner;
   - road;
   - right verge;
   - grass.

   Wherever an edge crosses a track line, it writes a marker into that line's 32-byte record at `$EC00`, meaning "from this x rightwards, this pattern". A verge's two edges share points and lines, so a side is drawn in one pass. The line-stepping loop runs entirely in registers. Its step and pattern are patched into the instructions.
4. **Compose** (`compose.s`). For each of the 80 track lines, the markers are taken in x order and the line is filled between them in whole bytes, straight onto the screen.
   - The edge byte mixes the old and new patterns.
   - Runs of whole bytes go through a jump into an unrolled fill.
   - A line whose markers came out of x order is sorted and restarted.
   - An empty line filled the same as last time is skipped, but padded to the time the beam takes for a row.

### The maths

There is no division at run time. Every ratio is 2^(log a − log b):

- **`log16`** looks a 16-bit value up in a 12-bit log table: 4K of low bytes at `$6000` and 4K of high at `$7000`. The high byte is reached with one `set 4,h`.
- **`exp8`/`exp16`** turn a log back in one lookup. The antilog table at `$B000` has a page per whole part.
- **Yaw.** An octant table and an arctangent table (the BBC's `arctanY` × 32) indexed by 256·small/large.
- **Distance.** The larger delta's log plus a correction looked up by the same ratio.
- **Pitch.** T = 2^(log|dy| + 5·256 − log d).
- **Verge width.** exp16(LOG2_WIDTH − scale·256 − log d).
- **Yaw to x.** Tables with the screen centre's +128 folded in. The BBC's 40-unit field of view maps across 256 pixels, and the horizon is on line 60 of 80, as on the BBC.

### Timing against the beam

Compose writes the visible screen with no back buffer, so it must never be overtaken by the beam.

- The 16 character rows above the view are empty, with an attribute (`$3A`) used nowhere else.
- `wait_for_beam` reads the floating bus until it sees something other than `$FF`, 0 or `$3A`. That means the ULA has reached the view.
- Compose is slower than the beam, so it always writes a row after the beam has shown it. The new view appears whole on the next frame.
- The work done before the wait (camera and the first four verge points) is bounded, so that compose starts in time. It starts at about 20 to 24K T-states after the interrupt, against a limit of about 38K.

## Decisions

| Decision | Alternatives | Why |
| --- | --- | --- |
| **Native Z80, BBC design** ("same design, Spectrum maths") | Speed up the existing port; invent a new engine | The port carried 6502-shaped maths. The BBC design is well documented and produces the right look, so it was kept: the same track data, angles, point choice, verge widths and edge-filling method. |
| **Logs and antilogs instead of division** | Shift-and-subtract division, as `Divide16x16` does | A table lookup and a subtraction cost tens of T-states; a 16-bit division costs hundreds. The 12-bit log table keeps errors within about 2 pixels of the BBC's numbers. It costs 8K for the log table and 2K for the antilog table. |
| **Expand every segment at startup** | Build 40 segments at a time as the BBC does | Silverstone's 1,024 segments fit in 11K. Projection becomes a table read, and there is no per-update segment building. |
| **Compose straight onto the screen, behind the beam** | Draw into a buffer and copy it after | The copy alone cost most of a frame. Writing behind the beam avoids tearing without a second buffer, and saves 6K of RAM. This was the largest single gain: six frames to four with the tables. |
| **Find the beam on the floating bus** | Fixed delay after HALT; IM 2 timing alone | A delay has to allow for the worst case. The floating bus says exactly when the ULA reaches the view, so the time before it can be used for real work. The cost is that it rules out the +2A and +3. |
| **Split the verge work round the interrupt** | Do all of it before HALT | The first four points of the next update fill time compose would otherwise spend waiting. `VB_EARLY` is 4 because a fifth made the first update start compose too late (33.7K T-states). |
| **One raster pass per side** | One pass per edge, as on the BBC | A verge's two edges go through the same points on the same lines. One pass shares the division and line stepping. |
| **Monochrome dither patterns** | Attribute colour from the start | The bitmap gives the BBC's per-pixel edges; attributes are 8×8 cells. The patterns are white, a quarter (grass) and a half (red). Odd lines rotate the pattern two places so it does not form vertical stripes. Colour is left for later. |
| **Solid black road** | A dithered grey road | Asked for, and it is what the BBC does. A black kerb mark then merges with the road, so the white marks read as dashes. |
| **Steady colour for distant kerbs** *(a deviation from the BBC)* | BBC rule: colour by segment parity everywhere | The far stretches span 13, 6 or 3 segments, so their parity flipped every time the camera passed a segment, and the distance flickered. Stretches longer than one segment now take the red or black. Only the near, one-segment marks alternate, and those move with the track. |
| **Interpolated camera target** | Look one segment ahead; step the heading per segment | The heading jumped once per segment, which made the kerbs swing left and right in corners. One segment ahead is also skewed where a new section restarts from its own coordinates. Interpolating three to four segments ahead is smooth. |
| **Self-modifying hot loops** | Keep constants in memory or the stack | The raster and compose loops run out of registers. Patching the step, count, `INC`/`DEC HL` and pattern into the code saves a memory read per line. |
| **Track data never committed** | Check in the data file | It is Acornsoft's. The build fetches the annotated source from revs.bbcelite.com, reassembles the file and verifies its checksum. The result is cached in the gitignored `data/`. |

## Speed

The road takes 90% of a three-frame update. T-states per update by stage, averaged over a lap by `tests/profile.py` (48K timing, without contention):

| Stage | T-states |
|---|---|
| Verges (projection), in two parts | 53,000 |
| Edges | 67,000 |
| Compose, onto the screen | 61,000 |
| Camera | 6,600 |
| **Total** | **189,500** |
| Three frames | 209,664 |

That leaves about 20,000 T-states for the rest of the game at the median, and 4,000 in the worst corner.

A frame is 69,888 T-states, so three frames is 16.7 updates a second. The request was 12 to 15. The BBC original runs at about 11 updates a second: its main loop adds 9/100 s to the lap timer each time round.

### How it got there

- The first working version took **six frames**, about 420,000 T-states.
- Composing onto the screen and the log tables brought it to **four**.
- Finding unsorted lines on the fly and moving the camera into the wait brought it to **3.27** on average.
- Writing the projection out per side and padding skipped lines brought it to **3.05**.
- The early verge points, the floating bus and one pass per side brought it to **three**, with a fourth frame only in some corners.
- Leaving an edge alone once it has gone off the right of the screen heading right took the corners that needed a fourth frame from 12.6% of updates to 1.3%.
- A profile by instruction over a lap (`tests/profile.py`) showed two things. Edge segments average about four lines, so setting one up cost as much as drawing its lines. And compose padded twenty blank sky lines an update just to stay behind the beam. Starting compose below the sky and setting segments up more cheaply took the median from 198,200 to 187,700, and no update needs a fourth frame.

### Over a whole lap

The tests' speed check runs the camera once round at its own speed: 1,639 updates of 160/256 of a segment. The work from one frame interrupt to the next HALT is:

- 187,700 T-states at the median;
- 201,100 at the 99th percentile;
- 205,600 at worst.

None takes a fourth frame. Before the changes found by profiling it was 59 (3.6%), all in the tightest corners, where most of the track is in view, at a median of 198,200. Before edges that had gone off the right stopped being stepped, it was 207 (12.6%), with a median of 200,200. Halving the log table then cost 1,600 T-states a redraw (it had been 22 updates and 196,600).

The scratch measurement before the camera was smoothed ran 1,100 updates at about one segment each. It gave 202,000, 213,000 and 218,000, with 118 over. At half a segment an update, which lingers longer in corners, 320 took a fourth frame. That was measured once and is not part of the tests.

### Where the time goes now

- **Per marker:** about 330 T-states from drawing it to filling from it. There are about 145 a frame.
- **Per point projected:** about 1,600 T-states. There are 27 a frame.
- **Per edge segment pair set up:** about 1,300 T-states including its two divisions. There are 22 a frame, and they cross about four lines each, so this is as much as drawing them.
- **Compose's padding:** about 17 lines an update below the sky are unchanged and padded to about 245 T-states each.

### What this means for the game

The road alone fills three frames, so everything Revs adds has to fit in a fourth:

- the driving model;
- the other cars;
- the dashboard;
- the sound.

That gives 4 frames, 12.5 updates a second, still inside the 12 to 15 asked for, and faster than the BBC's 11. It leaves about 90,000 T-states at the median for everything else, and about 74,000 in the worst corner. Further savings on the road (see Still to do) buy more room.

## Bugs found and fixed

| Bug | What it did | Fix |
| --- | --- | --- |
| Pitch returned early on a valid point | A `scf; ret c` in the pitch routine took the "below the view" exit on points that were in view. | Corrected the flag test. |
| Yaw low byte divided wrongly | The fractional part of the yaw was scaled against the wrong byte, and points jittered sideways. | Divide the full 16-bit value. |
| Segment centre overflowed | Averaging inner and outer verge coordinates overflowed 16 bits on parts of the track. | A `midpoint` routine that halves before adding. |
| `sort_line` clobbered DE | Sorting an out-of-order line lost the screen pointer, and the rest of the frame was drawn in the wrong place. It was latent until a shuffled-marker test hit it. | `push de`/`pop de` round the sort. |
| One-frame tear after skipped sky lines | Skipping unchanged lines let compose get ahead of the beam, so a frame showed half of each view. The beam check found 59 of 60 updates bad. | Skipped lines are padded to a row's time (about 245 T-states). 0 of 200 bad afterwards. |
| First update hung, after skipping the sky | `wait_for_beam` waited for something non-blank below the skipped sky, and on the first update the whole screen is blank. The tests timed out. | The wait gives up after the time the beam takes to cross the rows that can be skipped. |
| First update overran | Doing five verge points before the beam wait made the first compose start at 33.7K T-states, too late to stay behind the beam. | `VB_EARLY` set to 4. |
| Kerbs swung left and right in corners | Two causes: the camera's heading changed once per segment, not smoothly, and `lerp` used only the low byte of a difference. That failed once segment centres were more than 127 units apart. | Interpolated look target from three to four segments ahead; 16-bit `lerp`. |
| Kerb stripes flickered back and forth | Far stretches of 13, 6 or 3 segments took their colour from segment parity, which flipped every time the camera moved a segment. | Stretches of more than one segment are drawn steady red or black. |
| Macro parameter clashes | sjasmplus substituted macro parameters inside other names (`COLOUR` inside `ECOL`), and the wrong code assembled silently. | Renamed the parameters so none is a substring of another name. |
| Relative jumps out of range | Unrolling and inlining pushed `JR` targets beyond ±127 bytes. | `JP` where needed. |

The test tools had bugs of their own, which gave wrong results until fixed:

- Tests ran against stale snapshots after labels moved. They now always rebuild their snapshot first.
- A HALT search broke after a comment changed.
- A timing measurement misread the PC at a HALT, which the emulator reports as the address after it. It also used a hard-coded HALT address that moved.

The checks have since been rebuilt as `tests/run_tests.py` (see How it is checked).

## How it is checked

Each check compares the Z80 with something independent of it: a model written from the BBC documentation, or a model of the Z80's own stages fed the Z80's own inputs.

| Check | Compares | Result |
| --- | --- | --- |
| `view_model.py` (in the repo) | A Python model of the BBC routines (`GetSegmentAngles`, `GetVergeAndMarkers`, the projection) against the Z80's verge point lists, at a dozen points round the track | Every point within 2.6 pixels across and 1 line up or down; colours match. `python view_model.py 300` draws the reference view. |
| Maths test | `log16`, `exp8`, `exp16`, yaw, pitch and verge width, called directly in the Z80, against exact values | Within the 12-bit table's error |
| Screen model | A model of the Z80's edge and compose stages, fed the Z80's point lists, against the Z80's screen | 12 of 12 views identical, byte for byte |
| Compose shuffle | The markers in a third of the lines shuffled out of order, so compose has to sort them | Identical screen |
| Beam check | Every write to the view over a full lap, with the first frame able to show each one worked out from where the beam was | All of an update's writes appear in the same frame; no tearing |
| Work time | T-states from each frame interrupt to the next HALT, over a lap | The lap figures in Speed |
| Camera trace and video | Camera position and heading per update; colour GIFs of a lap | Smooth heading, steady kerbs |

All of these are in the repository now: `tests/run_tests.py` runs them against the engine in cpp-core's `snapshot_probe`, in about 25 seconds (the engine's README has the commands). The camera trace and the videos are the exception: they are for looking at, not checking. Each check was shown to fail on a bug planted for it.

## Memory

About **36K of the 48K** is used. Most of it is tables and the expanded track, which buy speed:

| Address | Size | What |
| --- | --- | --- |
| `$4000`–`$5AFF` | 6.75K | Screen and attributes |
| `$6000`–`$720F` | 4.5K | Log table: 4K of fractions, and three small tables for the whole parts |
| `$8000`–`$99CD` | about 6.5K | Code |
| `$A000`–`$A7FF` | 2K | Eight pages of lookup tables: yaw to x, arctangent, distance correction, masks, divide by 3 |
| `$A800` | 1.8K | The track data file, read once at startup and free after |
| `$B000`–`$B7FF` | 2K | Antilog table, a page per whole part |
| `$BA00`–`$BBFF` | 0.5K | The two verge point lists |
| `$C000`–`$E7FF` | 10K | Every segment's coordinates: five arrays of 1,024 words |
| `$E800`–`$EBFF` | 1K | Every segment's flags |
| `$EC00`–`$FBFF` | 4K | Edge markers: 32 bytes for each of 128 lines |
| `$FDF0` down |  | Stack; IM 2 jump at `$FDFD`, vector table at `$FE00` |

There is about 10K free:

- `$7210`–`$7FFF` (3.5K), and `$7110`–`$71FF` (240 bytes) beside the small log tables;
- `$A800`–`$AFFF` (2K) once `build_track` has run;
- `$5B00`–`$5FFF` (1.25K);
- `$99CE`–`$9FFF` (1.5K);
- `$B800`–`$B9FF` (0.5K);
- `$BC00`–`$BFFF` (1K);
- small gaps round the stack.

That is not much for the rest of a game. The cars, the dashboard graphics and the other four tracks will need room. Room could come from:

- the marker records for the 48 lines above the view, which are written but never read (1.5K);
- making the segment arrays bytes where the range allows;
- a 128K machine's extra banks for track data.

## Still to do

Roughly in the order the plan would add them, one feature at a time.

### The game

- [ ] **Driving model.** Speed, steering, the car's position across the track and its heading. These replace the self-driving camera. The BBC's `ApplyDrivingModel` and its deep dives are the guide.
- [ ] **Cockpit.** Dashboard, rev counter, mirrors and the steering wheel. The rows below the view are free for it.
- [ ] **Horizon and hills.** The BBC tilts the view and draws a horizon line; the track's height is already in the segment data but the view is flat beyond it.
- [ ] **Other cars.** Projection and scaled sprites. This is the biggest cost still to come.
- [ ] **Signs and objects by the track.**
- [ ] **Laps and timing.** Start line, lap timer, best lap.
- [ ] **Sound.** Engine note through the beeper, on a 128K the AY.
- [ ] **Menus.** Practice, race and driver choices.
- [ ] **Other tracks.** The four extra BBC tracks use a hook-driven variant of the data format that `track_data.py` does not read yet.

### The engine

- [x] **Corners that need a fourth frame.** None does now over a lap (3.6% before compose skipped the sky and segment set-up got cheaper, 12.6% before that).
- [ ] **Time for the rest of the game.** The road should come down well below three frames if the game is to stay at four. Priced but not done: the verge points' variables in registers and the camera's values patched in (2.5–4K), `verges_begin` unrolled (2.5–3.5K), a jump on n in `div16_8` (1.5–2K), compose's x >> 3 by table (1.5–2.5K), a quarter-square multiply in the camera (1.5K), and a shorter path for an edge off the left (1–1.5K).
- [ ] **Stripes at about one segment an update.** At around 170 mph the two-segment kerb pattern is sampled once a stripe and seems to stand still or run backwards. A blend of red and white above some speed would hide it.
- [ ] **Colour.** Green grass and blue sky through attributes, fitted round the 8×8 grid.
- [ ] **Contended memory.** The emulator doesn't model it, so timing on a real 48K is unchecked. Compose's screen writes would be slowed while the beam is drawing.
- [ ] **+2A and +3.** `wait_for_beam` needs the floating bus. Those machines need another way to find the beam, such as a timed wait from the interrupt.
- [ ] **Memory** for the cars and the dashboard: see Memory for where it could come from.

### Tooling

- [x] **Automated tests in the repo.** `tests/run_tests.py`, run against the real emulator core through `snapshot_probe`. They are not part of CTest, since they need sjasmplus and the track data, as filmation's Z80 tests do.
- [ ] **A web page to watch it.** This was asked for and not done, because there is no Emscripten here to build the emulator for the browser. For now there are videos.
- [x] **Merge.** On `master`.
- [x] **A profiler.** `tests/profile.py`, through `snapshot_probe`'s `profile` command: T-states by routine and source line over a lap, or one routine instruction by instruction.
- [x] **`snapshot_probe` on Windows.** It builds clean with MSVC's `/W4 /WX`.

## Sources

- Mark Moxon's annotated disassembly of BBC Micro Revs, [revs.bbcelite.com](https://revs.bbcelite.com), in particular the deep dives on:
  - drawing the track view;
  - the track verges;
  - scheduling tasks in the main loop;
  - the track data file format.
- The code, in `examples/revs` on branch `ccr-a5725d0e-ey56yb` of `jonsole/zx-spectrum-emulator`:
  - its `README.md`, which describes the pipeline, memory and speed;
  - `view_model.py`, the Python reference.
