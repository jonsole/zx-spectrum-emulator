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

The digit in the top-left corner is how many frames the last update took.

## How it works

Each update runs four stages, the last of them straight after the frame
interrupt:

1. **`camera.s`** moves the camera a fraction of a segment along the middle
   of the track, 500 units above it. It looks at the point three segments
   ahead; one segment is not enough, because a new section restarts from its
   own coordinates and can skew a single step. This stands in for a driving
   model until there is one.
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
   with. A segment's last line is the next one's first, so each edge is one
   pass through its points.
4. **`compose.s`** sorts each line's markers by x and fills between them in
   whole bytes, straight onto the screen. This is the BBC's trick of filling
   while it copies (`DrawTrackBytes`), taken one step further: with no
   buffer there is nothing to copy. It runs top to bottom, starting once the
   beam has drawn the view's top row, and it is slower than the beam, so the
   beam never catches it: every row is rewritten after the beam has shown
   it, and a frame never shows two half-views. A line with no markers that
   is filled the same as last time (most of the sky) is left alone.

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
- **Fill patterns instead of colours.** Grass, road and the verge colours
  are a grey ramp of dither patterns: white, a quarter, a half, three
  quarters, black. Odd lines use each pattern rotated two places.
- **Lookup tables** for the arctangent (the BBC's own `arctanY`, times 32),
  the logs and antilogs, the distance correction, and yaw to screen x. They
  are generated by `tables.py` at build time; 19K of them.

### Memory

| Address | What |
|---|---|
| `$6000` | the 12-bit log table: 4K of low bytes, 4K of high |
| `$8000` | code |
| `$A000` | seven pages of lookup tables |
| `$A800` | the track data file, as the BBC loads it; read once at startup |
| `$B000` | eight pages of antilogarithms |
| `$BA00` | the two verge point lists |
| `$C000` | every segment's coordinates: five arrays of 1,024 words |
| `$E800` | every segment's flags |
| `$EC00` | the edge markers: a 32-byte record per track line, 128 of them (lines above the view are written but never read) |
| `$FDF0` | the stack, downwards; the IM 2 jump at `$FDFD` and its table at `$FE00` |

## Speed

On the emulator, which does not model contended memory, an update takes
four frames: 12.5 updates a second. Measured in the profiler over 40
updates on Silverstone:

| Stage | T-states |
|---|---|
| verges (projection) | 65,000 |
| edges | 92,000 |
| compose, onto the screen | 72,000 |
| waiting for the beam to pass the view's top | 18,000 |
| camera | 5,000 |

That is about 252,000 of the four frames' 279,600. The first working
version took six frames, about 420,000 T-states. These changes made the
difference:

- composing straight onto the screen instead of into a buffer copied after;
- log and antilog tables in place of shifting loops;
- the two verges projected together;
- one pass per edge;
- hot loops in registers, with their constants patched into the
  instructions;
- unrolling, and skipping lines that haven't changed.

For comparison, the BBC's main loop adds 9/100 of a second to the lap
timer each time round, so the original runs at about 11 updates a second
with everything else in the game going on too. To leave room for that here,
the road needs to get to about three frames. What costs most now:

- **Per marker:** about 400 T-states between drawing it and filling from
  it, about 145 markers a frame.
- **Per point projected:** about 2,400 T-states, 27 points a frame.
- **Per edge segment set up:** about 700 T-states including its division,
  44 segments a frame.

## Checking it

There is no automated test in the tree yet. The engine was checked against
`view_model.py`, a Python model of the BBC routines. It gives the reference
view from any segment (`python view_model.py 300` writes `output/view.png`).
`track_model.py` plots the whole track from above.

- **Geometry.** At a dozen points round the track, every Z80 verge point
  matched the model's to within 2 pixels across and 1 line up or down. The
  pictures showed the same verges, red-and-white kerbs and hairpins.
- **Edges and compose.** A second model, of the Z80's own edge and compose
  stages, reproduced the Z80's screen byte for byte from the Z80's
  point lists.

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
  Compose has to finish each row before the next frame's beam reaches it,
  about 87,000 T-states from its start. It takes 72,000 now, so the margin
  is not large.
