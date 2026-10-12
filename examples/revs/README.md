# revs

A road engine for the 48K Spectrum, written in Z80 from scratch, in the
manner of Geoff Crammond's *Revs* (Acornsoft, 1985, BBC Micro). It uses
Mark Moxon's fully documented disassembly at
[revs.bbcelite.com](https://revs.bbcelite.com) as a design guide. The plan is
to build up to a game a feature at a time. So far there is the first step:
the track, drawn from a camera that drives itself round Silverstone.

It is the BBC design throughout, with Spectrum maths underneath:

- the same track data and the same angles;
- the same choice of which points to project;
- the same verge widths and colours;
- the same way of drawing edges as colour changes filled to the right.

What changes is how the numbers are worked out. Divisions are done with log
tables, there are lookup tables wherever there is memory for them, and the
screen is a monochrome bitmap rather than a four-colour mode.

[rendering.md](rendering.md) walks through how the road is drawn, from the
track data to the bytes in screen memory, in plain steps; its Reference
section has the detail, with a worked example.
[worklog.md](worklog.md) is the longer story: what was done in what order,
the decisions and the alternatives, the bugs, the checks, and what is still
to do.

## Build and run

Launch **"ZX Spectrum: Revs road"** from the Run and Debug view. Its
`preLaunchTask` assembles the program first. To build it by hand:

```powershell
.\.venv-win\Scripts\python.exe examples\revs\build.py
```

That needs `sjasmplus`: `tools/sjasmplus/sjasmplus.exe`, anywhere on PATH, or
the path in the `SJASMPLUS` environment variable. It writes
`output/revs.z80`, a version 3 snapshot that starts at `start`, plus
`revs.sld` for source-level debugging and a `revs.lst` listing. Everything in
`output/` is regenerated.

The track itself is Acornsoft's, so like the ROMs it is never committed. The
first build fetches the annotated track source from revs.bbcelite.com. It
reassembles the original 1,849-byte data file from it and checks it against
the file's own checksum, then caches it in `data/` (gitignored).
`python track_data.py silverstone --from page.html` does the same from a
saved copy of the page, for a machine without the network.

The digit in the bottom-left corner is how many frames the last update took.

## How it works

Each update runs four stages. They are interleaved round the frame
interrupt, because compose has to wait for the beam (see below):

1. **`camera.s`** moves the camera a fraction of a segment along the middle
   of the track, 500 units above it. It looks at the point the same fraction
   of the way from three segments ahead to four, so it turns smoothly through
   a corner. One segment ahead is not enough, because a new section restarts
   from its own coordinates and can skew a single step. This stands in for a
   driving model until there is one.
2. **`verges.s`** builds a list of points for each verge (after
   `GetSegmentAngles` and `GetVergeAndMarkers`). The two verges are done
   together, a segment at a time, sharing its flags and height.
   - It starts 32 segments ahead, then steps back by 13, 6 and 3 segments,
     then one at a time.
   - Each point gets a yaw angle and a track line (`maths.s`, after
     `GetObjYawAngle`, `GetObjectDistance` and `GetObjPitchAngle`).
   - Each point gets a verge mark: 25, 50 or 100 units wide, by the
     section's flags, in alternating segments of white and red or black.
   - The list stops at the first point that cannot be seen: below the view,
     or outside the field of view once the points have started coming back
     towards the camera. There is one last try a quarter of the way to that
     point.
3. **`edges.s`** draws the four verge edges through those points, as
   `DrawTrack` does: left verge, road, right verge, grass. Wherever an edge
   crosses a track line it leaves a marker saying "from this x rightwards,
   this colour". An edge off the left still sets the colour its lines start
   with. A verge's two edges go through the same points on the same lines,
   so they are drawn in one pass per side.
4. **`compose.s`** sorts each line's markers by x and fills between them in
   whole bytes, straight onto the screen. This is the BBC's trick of filling
   while it copies (`DrawTrackBytes`), taken one step further: with no
   buffer there is nothing to copy. It runs top to bottom, starting once the
   beam has drawn the view's top row, and it is slower than the beam, so the
   beam never catches it: every row is rewritten after the beam has shown
   it, and a frame never shows two half-views. A line with no markers that
   is filled the same as last time (most of the sky) is left alone, but
   still takes as long as the beam takes over a row, so compose never gets
   ahead of it.

The order within an update is:
1. the rest of the verge points;
2. the edges;
3. HALT for the frame interrupt;
4. the next camera position, and the next update's first four verge points;
5. compose.

The work in step 4 is time compose would otherwise spend waiting for the
beam. Then `wait_for_beam` reads the floating bus, which on a 48K is
whatever the ULA is fetching from the screen. The rows above the view hold
nothing but a colour attribute used nowhere else, so any other value means
the beam has reached the view. Step 4 is bounded so that compose starts in
time to finish before the beam comes round again.

`track.s` expands the track data into every segment's coordinates once, at
startup. A section's first segment takes its coordinates from the section;
each later segment adds the current segment vector, and the outer verge is
four times the outer vector beyond the inner one (`GetTrackSegment`). The
BBC builds 40 segments at a time into a buffer as the car moves. All 1,024
segments of Silverstone fit in 11K of a 48K machine.

The screen maps the BBC's 40-unit field of view across 256 pixels, so a
point's x is 128 plus its yaw angle over 40. The 80 track lines put the
horizon at line 60, as the BBC does.

### Where the Spectrum differs

- **Division by logarithms.** Every ratio the BBC gets from a
  shift-and-subtract division (`Divide16x16`, `DivideX`) is
  2^(log2 a − log2 b) here. `log16` looks a 16-bit value's log up in a
  12-bit table, and an antilog table with a page per whole part turns it
  back in one lookup. The distance (`GetObjectDistance`) is a correction to
  the larger delta's log, looked up by the same ratio that gives the angle.
  The verge width comes from the distance log too.
- **Fill patterns instead of colours.** The road is solid black, as on the
  BBC, so a black verge mark runs into it and the white marks show as dashes.
  Grass and the other verge colours are dither patterns: white, a quarter
  (grass), a half (red). Odd lines use each pattern rotated two places.
- **Distant verge colours.** The BBC colours every verge mark by its
  segment's parity, and colours the far stretches between points 13, 6 and
  3 segments apart the same way. Those stretches swapped between white and
  red each time the camera passed a segment, which made the distance flicker.
  Here a stretch of more than one segment takes the red or black, so only
  the marks close enough to draw one at a time alternate, and they move
  with the track. At about one segment an update (around 170 mph at three
  frames an update) the two-segment stripe pattern is sampled once a stripe,
  and appears to swap or run backwards, as any striped thing filmed at that
  rate would.
- **Lookup tables** for the arctangent (the BBC's own `arctanY`, times 32),
  the logs and antilogs, the distance correction, and yaw to screen x. They
  are generated by `tables.py` at build time; 19K of them.

### Memory

| Address | What |
|---|---|
| `$6000` | the 12-bit log table: 4K of low bytes, 4K of high |
| `$8000` | code |
| `$A000` | eight pages of lookup tables |
| `$A800` | the track data file, as the BBC loads it; read once at startup |
| `$B000` | eight pages of antilogarithms |
| `$BA00` | the two verge point lists |
| `$C000` | every segment's coordinates: five arrays of 1,024 words |
| `$E800` | every segment's flags |
| `$EC00` | the edge markers: a 32-byte record per track line, 128 of them (lines above the view are written but never read) |
| `$FDF0` | the stack, downwards; the IM 2 jump at `$FDFD` and its table at `$FE00` |

## Speed

On the emulator, which does not model contended memory, nearly every update
takes three frames: 16.7 updates a second. Measured in the profiler over 40
updates on Silverstone:

| Stage | T-states |
|---|---|
| verges (projection), in two parts | 53,000 |
| edges | 78,000 |
| compose, onto the screen | 65,000 |
| camera | 5,000 |

Over a whole lap at the camera's speed (1,639 updates of 160/256 of a
segment), the work from one frame interrupt to the next HALT is 200,000
T-states at the median and 215,000 at the 99th percentile, against three
frames' 209,664. 207 updates (12.6%) take a fourth frame, nearly all of
them in corners, where the camera sees more of the track. The worst needs
219,000. The tests' speed check measures this (see below).

The first working version took six frames, about 420,000 T-states. These
changes made the difference:

- composing straight onto the screen instead of into a buffer copied after;
- log and antilog tables in place of shifting loops;
- the projection written out in full for each verge, which are done
  together;
- both of a verge's edges drawn in one pass;
- the next update's first points worked out while compose waits for the
  beam;
- hot loops in registers, with their constants patched into the
  instructions;
- unrolling, short cuts for the commonest divisions, and skipping lines
  that haven't changed.

For comparison, the BBC's main loop adds 9/100 of a second to the lap timer
each time round, so the original runs at about 11 updates a second with
everything else in the game going on too: the cars, the dashboard, the
driving model and the sound. Those have to fit in the remaining time here.
What costs most now:

- **Per marker:** about 350 T-states between drawing it and filling from
  it, about 145 markers a frame.
- **Per point projected:** about 1,600 T-states, 27 points a frame.
- **Per edge segment pair set up:** about 820 T-states including the two
  divisions, 22 pairs a frame.

## Checking it

`tests/run_tests.py` builds the engine, runs it in cpp-core's
`snapshot_probe`, and checks it against models of what it should do:

```powershell
cpp-core\build.ps1 -Release -Target snapshot_probe
.\.venv-win\Scripts\python.exe examples\revs\tests\run_tests.py
```

It takes about 25 seconds. Name checks to run only those (`run_tests.py
screen compose`); `--no-build` uses `output/` as it is. The checks:

| Check | What it compares | Passes when |
|---|---|---|
| `maths` | `log16`, `yaw_angle`, `pitch_line` and `verge_width`, called on their own with random arguments, against exact values and `view_model.py`'s BBC routines | logs within 2/256, angles within 96 units, distances within 1.2%, lines within one, widths within 2% |
| `verges` | the Z80's verge point lists against `view_model.py`'s from the same camera, at a dozen places round the track | the same points and colours, within 3 pixels across and a line up or down |
| `screen` | the view on the screen against `tests/screen_model.py`, a model of the edge and compose stages, fed the Z80's own point lists | byte for byte |
| `compose` | `compose_screen` on marker records with a third of the lines shuffled out of x order, against the same records filled in order | byte for byte |
| `beam` | every write to the view over 200 updates, with the first frame able to show it worked out from where the beam was | all of an update's writes show in the same frame |
| `speed` | the T-states from each frame interrupt to the next HALT over a lap at the camera's speed | the median fits in three frames; the 99th percentile, the worst and the number needing a fourth frame are reported |

`view_model.py` is a Python model of the BBC routines, written from the
disassembly's documentation. It also draws the reference view from any
segment (`python view_model.py 300` writes `output/view.png`), and
`track_model.py` plots the whole track from above. The screen model is
written from what the edge and compose stages are meant to do, so the Z80
and the model are never checked against each other's output. Every
constant the screen model needs (the list addresses, the view's size, the
fill patterns) is read from the build's symbols.

Each check was shown to catch a bug planted for it:
- **`compose`:** `sort_line` clobbering the screen pointer.
- **`maths` and `verges`:** verge marks twice as wide.
- **`screen`:** the edge stepper rounding from the wrong end.
- **`beam`:** twelve verge points before the beam wait instead of four.

The `screen` check uses the Z80's own point lists, so it passed with the
doubled widths. That is the split intended: geometry is `verges`' job.

## Not done yet

- **Driving.** The camera drives itself, with no steering, speed or
  car.
- **The cockpit.** No dashboard, mirrors or wheel.
- **Everything else in Revs:** the other cars, signs and objects by the
  track, the horizon and its hills, laps and timing, sound, menus.
- **Other tracks.** Only Silverstone's standard data format is
  read. The four extra tracks use a hook-driven variant that `track_data.py`
  does not take.
- **Colour.** The view is monochrome. Attribute colour (green grass, blue
  sky) has to be fitted round the 8×8 attribute grid.
- **Contended memory.** Timing is not checked against real contended
  memory, which the emulator does not model. On the real machine,
  compose's writes to the screen would be slowed while the beam is drawing.
  Compose has to finish each row before the next frame's beam reaches it.
  It starts about 20,000 to 23,000 T-states after the interrupt and takes about
  65,000, against a limit of about 105,000.
- **The floating bus.** `wait_for_beam` needs it, so this runs on the 48K
  and 128K, not the +2A or +3.
