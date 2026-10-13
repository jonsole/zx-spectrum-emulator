# revs

A road engine for the 48K Spectrum, written in Z80 from scratch, in the
manner of Geoff Crammond's *Revs* (Acornsoft, 1985, BBC Micro). It uses
Mark Moxon's fully documented disassembly at
[revs.bbcelite.com](https://revs.bbcelite.com) as a design guide. The plan is
to build up to a game a feature at a time. It got as far as the track,
drawn from a camera you drive round Silverstone, with a sign beside it and
a car parked on it.

**Stopped, 13 October 2026.** The engine works, but the 48K has no room
for the rest of the game. The road alone takes about 32K; the BBC fits its
whole game -- road, driving model, nineteen other cars, dashboard and sound
-- in about 23.4K, and about 9K is left here, in pieces. If it is picked up
again, the two ways to make room that were priced are a ring of 64 segments
in place of the 11K expanded segment table (about 8K back, for about 700
T-states a redraw), or the 128K. `handover.md` has the state it stopped in.

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
[handover.md](handover.md) is where to start if you are picking the engine
up: where it stands, how to work on it, the rules the code depends on, what
has been tried, and what to do next.
[worklog.md](worklog.md) is the longer story: what was done in what order,
the decisions and the alternatives, the bugs, the checks, and what is still
to do.

## Build and run

Launch **"ZX Spectrum: Revs road"** from the Run and Debug view. Its
`preLaunchTask` assembles the program first. To build it by hand:

```powershell
.\.venv-win\Scripts\python.exe examples\revs\build.py
.\.venv-win\Scripts\python.exe examples\revs\build.py --define SYNCED
```

By default the engine runs unsynchronised: each update starts as soon as
the last one ends, and compose paints wherever the beam is, so a frame can
show the top of one update and the bottom of the next. Updates then come as
fast as the work allows rather than every third frame, and the tearing is
mild. `--define SYNCED` builds it to wait for the frame interrupt and the
beam instead, so that no frame shows two updates; the tests build it that
way, since the `beam` and `speed` checks are about it.

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

Until there is a driving model, the keys drive the camera:

| Keys | Interface II (either stick) | Does |
|---|---|---|
| Q | up | faster, up to a segment an update (about 170 mph) |
| A | down | slower, down to a standstill |
| O | left | move left |
| P | right | move right |

Sideways is square to the way the camera looks, so it slides across the
track without turning, as far as about the track's edge. The view from
beside a kerb costs more to draw than the view down the middle: over a lap
at the left edge the median update is about 198,600 T-states, and 13 of
1,639 take a fourth frame.

## How it works

Each update runs four stages. They are interleaved round the frame
interrupt, because compose has to wait for the beam (see below):

1. **`camera.s`** moves the camera a fraction of a segment along the middle
   of the track, 200 units above it, about a car's height, as a driver's eye
   is. It looks at the point the same fraction
   of the way from three segments ahead to four, so it turns smoothly through
   a corner. One segment ahead is not enough, because a new section restarts
   from its own coordinates and can skew a single step. This stands in for a
   driving model until there is one.
2. **`verges.s`** builds a list of points for each verge (after
   `GetSegmentAngles` and `GetVergeAndMarkers`). The two verges are done
   together, a segment at a time, sharing its flags and height.
   - It starts 32 segments ahead, then steps back by 13 and 7 segments,
     then one at a time from 12 ahead, so the kerb's stripes reach 12
     segments out. The BBC steps 13, 6 and 3, and its stripes stop at 9.
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
the beam has reached the view. Compose leaves the sky alone when it is blank
and stays blank (`compose_skip`), so it starts below it, and then
`wait_for_beam` also waits for the beam to get past the sky: for a pattern
byte rather than a blank one, or for as long as the beam takes to cross
twenty rows, whichever comes first. Step 4 is bounded so that compose
starts in time to finish before the beam comes round again.

`track.s` expands the track data into every segment's coordinates once, at
startup. A section's first segment takes its coordinates from the section;
each later segment adds the current segment vector, and the outer verge is
four times the outer vector beyond the inner one (`GetTrackSegment`). The
BBC builds 40 segments at a time into a buffer as the car moves. All 1,024
segments of Silverstone fit in 11K of a 48K machine.

The screen maps the BBC's 40-unit field of view across 256 pixels, so a
point's x is 128 plus its yaw angle over 40. The 80 track lines put the
horizon at line 60, as the BBC does.

### Objects

There are two (`objects.s`): a sign, a black post and a red board, beside
the right verge at segment 12, and a car parked on the track at segment 24,
just left of the middle. The car is the BBC's standard car, object type 4,
from its part tables at revs.bbcelite.com: helmet, body, sidepods, tyres
and gearbox, roll hoop and rear wing, drawn in the BBC's order, each part's
left and right edges a pixel in an edge colour as the BBC draws them. The
types are in `object_types.py`, which `build.py` turns into assembler with
every measurement already a log, so that scaling a part to its distance is
a subtraction and an antilogarithm. Objects are drawn far to near, so that
a nearer one is painted over a farther one. On a black road the car reads
best grey with a white body (BBC white as the half tone, BBC red as white);
the BBC gives each driver's car its own colours.

As on the BBC, an object is parts of one colour on a scaffold scaled by its
distance, not a bitmap: a scaled bitmap would want a copy for every size.
The BBC draws its objects into its screen buffer after the track. Here
there is no buffer, and compose paints the screen the viewer is looking at,
so drawing over the finished view would show a frame of road where a car
should be. Instead:

- Before the HALT, `objects_build` projects the sign with the same maths as
  a verge point, and turns each part into a block on the screen: its
  lines, its first byte, how many bytes, the masks of its end bytes, and its
  pattern for even and odd lines (`obj_parts`).
- The calls in compose's unrolled code for the lines those parts cover are
  pointed at `cs_obj_odd` and `cs_obj_even`. They let compose fill the line
  with road as usual, then paint the parts on it over the road, before
  compose goes on to the next line. Each line is finished before the beam
  comes back to it.
- A line painted that way is marked in `cs_last` so that it is drawn again
  next update, to take the object away if it has moved. The top one is
  marked before compose, so `compose_skip` starts no lower than it.

It costs about 1,000 T-states for every line an object covers: painting
it, pointing compose's calls and back, and redrawing road that would
otherwise have been skipped. The sign close up covers 24 to 35 lines, about
29,000 T-states. In the default unsynchronised build that only slows those
updates. In the synchronised build it can make compose run past the beam's
return and tear, a known limit: the `beam` check is run from past the
objects. Drawing objects as markers in compose's own pass would cost about
half.

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
  segment's parity, and colours the far stretches between points several
  segments apart the same way. Those stretches swapped between white and
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
| `$6000` | the 12-bit log table's fractions, 4K; at `$7000` three small tables for its whole parts; free from `$7210` to `$7FFF` |
| `$8000` | code |
| `$A000` | eight pages of lookup tables |
| `$A800` | `objects.s` and the objects' parts (`object_types.py`) |
| `$B000` | eight pages of antilogarithms |
| `$BA00` | the two verge point lists |
| `$BC00` | the objects' parts on the screen, each update |
| `$C000` | every segment's coordinates: five arrays of 1,024 words |
| `$E800` | every segment's flags |
| `$EC00` | the edge markers: a 32-byte record per track line, 128 of them (lines above the view are written but never read); until `markers_init`, the track data file as the BBC loads it, for `build_track` |
| `$FDF0` | the stack, downwards; the IM 2 jump at `$FDFD` and its table at `$FE00` |

## Speed

On the emulator, which does not model contended memory, every update takes
three frames: 16.7 updates a second. Averaged over a lap by
`tests/profile.py` (see below):

| Stage | T-states |
|---|---|
| verges (projection), in two parts | 53,000 |
| edges | 67,000 |
| compose, onto the screen | 61,000 |
| camera | 6,600 |

Over a whole lap at the camera's speed (1,639 updates of 160/256 of a
segment), the work from one frame interrupt to the next HALT is 187,700
T-states at the median and 201,100 at the 99th percentile, against three
frames' 209,664. The worst, in the tightest corner, is 205,600, so none
takes a fourth frame. The tests' speed check measures this (see below).

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
  that haven't changed;
- leaving an edge alone once it has gone off the right of the screen
  heading right, which is most of what made corners slow;
- starting compose below the sky, and setting up an edge's segments with
  each point read once and its state patched into the code.

For comparison, the BBC's main loop adds 9/100 of a second to the lap timer
each time round, so the original runs at about 11 updates a second with
everything else in the game going on too: the cars, the dashboard, the
driving model and the sound. Those have to fit in the remaining time here.
What costs most now:

- **Per marker:** about 330 T-states between drawing it and filling from
  it, about 145 markers a frame.
- **Per point projected:** about 1,600 T-states, 27 points a frame.
- **Per edge segment pair set up:** about 1,300 T-states including the two
  divisions, 22 pairs a frame. Segments are short, about four lines, so
  this is as much as drawing their lines.

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
| `compose` | `compose_screen` on marker records with a third of the lines shuffled out of x order, against the same records filled in order, with the objects' parts painted over them | byte for byte |
| `objects` | every object's parts where it is in view, far to near, against `object_types.py`'s parts projected through `view_model.py` | within 3 pixels across and a line up or down |
| `beam` | every write to the view over 200 updates, from a stretch with no object in view, with the first frame able to show it worked out from where the beam was | all of an update's writes show in the same frame |
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

`tests/profile.py` says where the time goes, over the same lap as the
`speed` check: the T-states each routine takes an update, and the source
lines that take most, through `snapshot_probe`'s `profile` command, which
counts every instruction by its address. A macro's expansion all has the
one source line it was invoked from, so `--routine NAME` lists a routine
instruction by instruction instead, with how often each ran: that is how to
see inside `VB_POINT` or `CS_LINE`.

```powershell
.\.venv-win\Scripts\python.exe examples\revs\tests\profile.py
.\.venv-win\Scripts\python.exe examples\revs\tests\profile.py --routine raster div16_8
```

## Not done yet

- **Driving.** The camera drives itself, with no steering, speed or
  car.
- **The cockpit.** No dashboard, mirrors or wheel.
- **Everything else in Revs:** the other cars, the BBC's signs and corner
  markers (there is one test sign), the horizon and its hills, laps and
  timing, sound, menus.
- **Objects behind crests.** An object is drawn whether or not the road
  hides it; Silverstone is nearly flat.
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
