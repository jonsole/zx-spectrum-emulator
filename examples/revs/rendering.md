# How the Revs road is drawn

As of 12 October 2026.

The Spectrum redraws the road about 17 times a second. Each time, it works out where the camera is, which bits of kerb the camera can see, and where those land on the screen. Then it paints the screen one line at a time, just behind the TV's beam, so you never see a half-drawn picture. The seven steps below follow one redraw in order. The addresses, tables and code-level detail are in the [Reference](#reference) section after them. [README.md](README.md) has how to build and run the engine and how fast it is, and [worklog.md](worklog.md) how it got this way.

## 1. The track

The track is unpacked once, when the program starts, into 1,024 slices, each one recording where the two kerbs are. The code calls the kerbs *verges*, as the BBC game does.

The data is the original BBC game's file for Silverstone, 1,849 bytes. It describes the circuit as 24 sections, each a straight or a corner, and a table of small steps from one slice to the next. Unpacking it means starting each section at its stored position and adding one step at a time.

Each slice is about 120 units long and is stored as five numbers and a byte of flags:

| What | Stored as |
| --- | --- |
| Right kerb (the inner one, as the cars go clockwise) | its x and z |
| Left kerb (the outer one) | its x and z |
| Height of the road | one y, shared by both kerbs: the road is level from side to side |
| Flags | corner or straight; whether the left kerb is red-and-white; whether the right one is |

x and z are the position on the ground, like map coordinates, and y is height. All three are in the BBC game's units, each a signed 16-bit number. Round Silverstone, x and z stay between about −24,000 and +21,000, and y between 2,000 and 3,709.

The numbers are built up by adding steps:

- Each section starts from a position stored in the file.
- Each following slice adds a small step to the right kerb: one signed byte each for x, y and z.
- The left kerb isn't stepped on its own. It is the right kerb plus four times a second step that points across the track, which gives the track its width of about 350 units.
- A corner uses a new pair of steps for every slice, which is what makes it turn. A straight keeps the same pair throughout.
- On a straight, only slices 1 to 9 keep red-and-white kerbs, so the red appears where the straight leaves a corner.

That takes 11K of memory. In return, nothing about the track has to be worked out again while driving.

## 2. The camera

The camera drives itself down the middle of the track, 500 units above the road. There is no steering yet.

It moves 5/8 of a slice per redraw, so a lap is 1,639 redraws. It points at a spot three to four slices ahead, and that spot moves along smoothly with it. So the view turns gradually into a corner instead of jerking round once per slice.

## 3. Picking the points it can see

For each kerb, the program picks up to 16 points to draw through, from far away to close up. It spaces them widely in the distance and closely near the camera.

It starts 32 slices ahead. It steps back 13 slices, then 6, then 3, then one slice at a time until it is two slices behind the camera. Far away, a slice is only a pixel or two deep on screen, so the big steps lose nothing. Close up, each slice covers many screen lines, so every one is used.

The 16 points picked on each kerb, by slices from the camera (`o`), with the track straightened out, two characters a slice:

```
slices from the camera:
-2  0                   10    13          19                        32
o-o-o-o-o-o-o-o-o-o-o-o-o-----o-----------o-------------------------o  right kerb
o-o-o-o-o-o-o-o-o-o-o-o-o-----o-----------o-------------------------o  left kerb
    ^ camera
|<- one slice apart ->|   3      6                   13
```

A kerb's list stops at the first point the camera can't see: below the bottom of the picture, or off to the side once the points are level with the camera. One extra point, a quarter of the way towards the hidden one, carries the kerb down to the edge of the picture.

## 4. Where each point lands on the screen

Each point gets a position on screen across and a screen line up or down, and the kerb at that point gets a width.

- **Across** (x, 0 to 255) comes from the angle between where the camera points and where the point is. Straight ahead is x = 128, and the picture is 56 degrees wide.
- **Up or down** (a line from 0 at the bottom to 79 at the top, with the horizon on line 60) comes from how far the point is below the eye, divided by how far away it is. The further away a point is, the closer to the horizon it sits.
- **The kerb's width** on screen is its real width (25, 50 or 100 units), shrunk by the distance in the same way.

The Z80's own points for the camera at slice 301 (`o`), on the road picture: a character per 4 pixels across, a row per 4 lines. Far points sit near the horizon and the middle; near ones lower down and further out. Each kerb's last point is off the side of the picture.

```
+----------------------------------------------------------------+  line 79
|                                :                               |
|                                :                               |
|                                :                               |
|                                :                               |
|----------------------------------------------------------------|  horizon, line 60
|                          o o   : o o                           |
|                        o       :      o                        |
|                    o o         :        oo                     |
|                  oo            :          o o                  |
|                o               :               o               |
|            o                   :                 o             |
|                                :                               |
|        o                       :                       o       |
|                                :                               |
|o                               :                              o|
|                                :                               |
|                                :                               |
|                                :                               |
|                                :                               |
|                                :                               |
+----------------------------------------------------------------+  line 0
 x = 0                                                   x = 255
```

Those are all divisions, and the Z80 has no divide instruction. Dividing by hand takes hundreds of cycles, and every point needs several. So the program uses logarithms, the way a slide rule does:

1. Look up the log of each number in a table.
2. Subtract the two logs.
3. Look the result back up to turn it into the answer.

Every division becomes two lookups, a subtraction and a lookup, and the answers come out within a pixel or two.

### The conversion, step by step

For a kerb point (x, y, z), with the camera at (cx, cy, cz) facing `heading`:

1. **Across the screen.**
   - Take the ground offsets dx = x − cx and dz = z − cz.
   - `yaw_angle` turns them into the point's compass bearing from the camera, with 65,536 units to a full turn. It uses the BBC game's arctangent table, looked up with a ratio found by logs.
   - Subtract the camera's heading to get the angle off straight ahead.
   - **Screen x = 128 + angle / 40.**
2. **Distance.** The same routine gives an approximate ground distance, the BBC's "alpha max plus beta min". It is the larger offset plus an eighth of the smaller, or seven-eighths of the larger plus half the smaller once the angle is wider. That is a cheap stand-in for √(dx² + dz²).
3. **Up or down the screen.**
   - Take dy = y − cy, the point's height relative to the eye, which is 500 units above the road.
   - T = 256 × (|dy| / 8) / distance.
   - **Line = 60 + T** for a point above the eye, **60 − T** for one below.
4. **Kerb width.** The kerb's real width, 25, 50 or 100 units, is divided by the same distance.

This isn't a textbook perspective projection: screen x is proportional to the angle itself, not its tangent. Across a 56° picture the difference is under a couple of pixels at the edges.

### How flexible the camera is

The camera's position and heading are completely free. Of what isn't, roll is left out of BBC Revs too. Pitch, and a car facing backwards or sideways, are in Revs and not built here yet; both belong with the driving model.

|  | Here | In BBC Revs |
| --- | --- | --- |
| Position (x, z) | Free. It doesn't have to be on the centre line, so a driving model can put the car anywhere across the track. | Free |
| Eye height | Free. It is the road height + 500 now. | Free |
| Heading (turning left or right) | Free: any angle, just subtracted from each bearing. | Free |
| Pitch (looking up or down) | Not yet. The horizon is fixed on line 60. | Yes. A pitch angle is taken off every point's pitch, moving the whole view, horizon included, up or down. It comes from the nose lifting under acceleration and dipping under braking, jumps and drops, bumpy grass, and the car's tilt on a sloping slice. It is smoothed so the horizon doesn't judder. Adding it here is one subtraction in the up-or-down step. |
| Roll (banking) | No | No. Revs only has pitch and yaw: "the simulation does not extend to rolling the car". |
| Facing backwards or sideways | Not yet (see below) | Yes. Revs keeps track of which way the car faces along the track, flags when it is sideways, and turns the cached angles as it spins. |
| Track in the mirrors | No | No. The wing mirrors show only a block for the nearest car behind, sized by its distance and placed by its angle. |

Facing backwards needs no change to the maths. What changes is which slices get picked. Here they are always from 32 ahead to 2 behind, and the field of view is only checked from the closest point on. That suits a camera facing roughly along the track. Revs keeps its kerb tables as the driver's left and right rather than inner and outer, and lays out its list of track sections differently when the car faces backwards. This version will need the same when the driving model lets the car spin.

Sources: the bbcelite deep dives on [pitch and yaw angles](https://revs.bbcelite.com/deep_dives/pitch_and_yaw_angles.html), [jumps and drops](https://revs.bbcelite.com/deep_dives/jumps_and_drops.html), [data structures for the track calculations](https://revs.bbcelite.com/deep_dives/data_structures_for_the_track_calculations.html) and [wing mirrors](https://revs.bbcelite.com/deep_dives/wing_mirrors.html).

## 5. Edges become colour changes

The kerbs' edges are turned into notes on each screen line saying where the colour changes. Nothing is drawn on the screen yet.

Each kerb has two edges, one next to the road and one next to the grass, so there are four edges in all. The program joins each edge's points with straight lines down the picture. Wherever an edge crosses one of the 80 screen lines, it leaves a note on that line: "from this x onwards, this colour". A line usually ends up with four notes, one per edge.

Reading a line's notes from left to right gives its colours. The line in the drawing below starts as grass, turns to kerb at x = 49, road at 59, kerb again at 196, and grass at 206.

Line 40 of that view, a character per 4 pixels: `.` grass, `K` kerb, `#` road.

| Note | From x | Colour |
|---|---|---|
| (start of line) | 0 | grass |
| 1 | 49 | kerb |
| 2 | 59 | road |
| 3 | 196 | kerb |
| 4 | 206 | grass |

```
............KKK##################################KK.............
```

## 6. Painting the screen, line by line

The screen is painted one line at a time, straight into the Spectrum's screen memory, from the top of the picture down.

For each line, the program sorts its notes by x and fills the space between them. Most of that is whole bytes, eight pixels at once, written as fast as the Z80 can store them. Only the byte where the colour changes is built dot by dot: the old colour to the left of the change, the new one from it rightwards.

The picture is black and white, so each colour is a pattern of dots:

| Colour | Pattern |
| --- | --- |
| Road | solid black |
| Black kerb | solid black, so it runs into the road and the white marks show as dashes |
| Red kerb | half the dots black |
| Grass | a quarter of the dots black |
| White kerb, sky | blank |

On alternate lines each pattern is shifted two dots along, so the dots don't line up into stripes.

A line with no notes is all one colour. If it is the same as last time, as most of the sky is, it is left alone.

## 7. Staying behind the TV beam

The program paints just behind the TV's beam, so each new picture appears all at once and you never see half of one and half of the last.

The TV draws the picture from top to bottom 50 times a second. The program paints straight onto the picture being shown, with no hidden copy. If it painted a line the beam had not yet reached, that frame would show the top of the new road over the bottom of the old one. So it waits until the beam has passed the top of the road picture, then paints downwards, a little slower than the beam. It finishes well before the beam comes round again.

One redraw to scale, in Z80 cycles (T-states) from the start of a TV frame. The times are the middle values over a lap of 1,639 redraws, measured in the emulator:

```
TV:   |------ frame 1 --------|------ frame 2 --------|------ frame 3 --------|
Z80:  ccfffffPPPPPPPPPPPPPPPPPPPPPPPrrrrrrrrrrrrreeeeeeeeeeeeeeeeeeeeeeeeewww
beam:       ======                  ======                  ======
```

| | Step | From | To |
|---|---|---|---|
| `c` | camera | 100 | 6,700 |
| `f` | first points | 6,700 | 23,000 |
| `P` | painting the screen | 23,000 | 87,400 |
| `r` | rest of the points | 87,900 | 125,300 |
| `e` | edges | 125,300 | 198,200 |
| `w` | wait for the next frame | 198,200 | 209,664 |
| `=` | the beam drawing the road picture, each frame | 17,900 | 35,700 |

Painting starts after the beam has drawn the road picture in frame 1 and ends before the beam draws it again in frame 2.

To find the beam, it uses a quirk of the 48K Spectrum called the *floating bus*. Reading a port that nothing answers returns whatever byte the TV circuitry is fetching from the screen at that moment. The two character rows above the road are kept blank, in a colour used nowhere else. So the first other value it reads means the beam has reached the road. The +2A and +3 have no floating bus, so this only works on the 48K and 128K.

One redraw takes three TV frames, which is 16.7 redraws a second. Only about one redraw in 28, in the tightest corners, takes four. The time the painting would otherwise spend waiting for the beam is used to start the next redraw's points.

## Reference

The same design in full: the memory each stage uses, the tables, the
routines and their registers, and a worked example traced through every
step. The BBC routine each part follows is named as it comes up, from Mark
Moxon's disassembly at [revs.bbcelite.com](https://revs.bbcelite.com).

### The pipeline

```
 track data file (1,849 bytes, Acornsoft's)      once, at startup
        |  build_track (track.s)
        v
 every segment's coordinates and flags           $C000-$EBFF
        |
        |   each update, about three frames:
        |
        |  camera_update (camera.s)       where the eye is, which way it looks
        v
 verge point lists, one per side                 $BA00, $BB00
        |  verges_begin / verges_finish (verges.s, with maths.s)
        v
 edge markers: per track line, "from x on, this pattern"   $EC00
        |  edges_build (edges.s)
        v
 screen memory, rows 16-95                       $4000-$57FF
           compose_screen (compose.s), behind the beam
```

Each stage writes a table, and only the next stage reads it:

- The **segment table** is the whole track in world coordinates.
- The **point lists** are the verges seen from the camera, as screen x and
  track line.
- The **marker records** are those verges' edges, one colour change at a
  time.
- The **screen** is the markers filled in, a byte at a time.

The tests (`tests/run_tests.py`) check the stages one at a time, against
models of what each table should hold.

### Units

| Quantity | Unit | Range |
|---|---|---|
| World x, y, z | the BBC's track units, signed 16-bit | Silverstone spans about −24,000 to +21,000 |
| A segment | about 120 units long | 1,024 of them round Silverstone |
| The track | about 350 units wide, inner verge to outer | |
| Verge marks | 25, 50 or 100 units wide | set by the section's flags |
| Yaw (heading, bearing) | 16-bit, 65,536 to a turn | 256 to a turn in the high byte, as the BBC counts |
| Field of view | ±20 in the yaw's high byte | 40/256 of a turn, 56° |
| Screen x | pixels, signed 16-bit while working | 0-255 on screen, 128 straight ahead |
| Track line | 0 at the bottom of the view, 79 at the top | the horizon is line 60 |
| Logarithms | 256 × log2, 8.8 fixed point | `log16` gives 0-4,095 |

Screen x is 128 + yaw / 40. That stretches the BBC's 40-unit field of view
across the Spectrum's 256 pixels, so a pixel is 40/65,536 of a turn.

A point's track line is 60 ± T, where T = 256 × (|dy| / 8) / distance. That
is `GetObjPitchAngle`'s pitch, with dy its height above or below the eye.
A point is out of sight once T reaches 128.

The view is 80 track lines, drawn on screen pixel rows 16 to 95. Track line
79 is on row 16, and line 0 is on row 95. Rows 0 to 15 are kept empty, so
that `wait_for_beam` can tell where the beam is (see
[Timing against the beam](#timing-against-the-beam)).

### 1. The track data file

The BBC loads a track as one 1,849-byte file at `&5300`.
- **Where it comes from:** `track_data.py` reassembles Silverstone's file
  from the annotated source on revs.bbcelite.com. It checks the result
  against the file's own checksum and caches it in `data/`, which is
  gitignored, because the data is Acornsoft's.
- **Where it goes:** `build.py` writes it into the snapshot at `$A800`,
  byte for byte.

The engine reads these parts of the file:

| Offset | What |
|---|---|
| `$000` | Section data, part 1: 8 bytes per section |
| `$100`-`$5FF` | Five 256-byte tables of segment vectors: inner x, y, z, outer x, z, as signed bytes |
| `$600` | Section data, part 2: 8 bytes per section |
| `$6FA` | The number of sections × 8 (Silverstone: 24 sections) |

A **section** is a straight or a curve. Its 8 + 8 bytes give:

- **Starting coordinates:** a 16-bit starting point for both verges, with
  the high bytes in part 1 and the low bytes in part 2. Bytes 1 to 4 and 6
  hold the inner x, y and z and the outer x and z.
- **Flags (part 2, byte 0):** bit 0 says the section is curved. Bits 1 and 2
  say the left and right verges are red-and-white rather than
  black-and-white.
- **First vector (part 2, byte 5):** the number of its first segment vector.
- **Size (part 2, byte 7):** how many segments it has.

A **segment vector** is the step from one segment to the next. A curve uses
a new vector for each segment, which is how it turns. A straight uses the
same one throughout.

### 2. Expanding the track: `build_track`

The BBC can't hold the whole track as coordinates. It builds 40 segments at
a time into a buffer as the car moves (`GetTrackSegment`,
`GetSectionCoords`). The Spectrum has the room, so `build_track` expands all
1,024 segments once, at startup, into five arrays of words and one of bytes:

| Address | Array |
|---|---|
| `$C000` | `SEG_XI`: inner verge x |
| `$C800` | `SEG_YI`: height, which both verges share |
| `$D000` | `SEG_ZI`: inner verge z |
| `$D800` | `SEG_XO`: outer verge x |
| `$E000` | `SEG_ZO`: outer verge z |
| `$E800` | `SEG_FLAGS`: the section's flags, per segment |

These are the BBC's rules, segment by segment:

- A section's first segment takes both verges from the section's own
  coordinates.
- Each later segment adds the current vector to the inner verge. The outer
  verge is the inner one plus four times the outer vector.
- A curve moves on to its next vector after each segment.
- A straight's segments keep the section's red verge flags only for segments
  1 to 9. The rest are black-and-white, so red kerbs appear only where a
  straight leaves a corner.

After this, the camera and the projection only index arrays: segment *n*'s
inner x is the word at `$C000 + 2n`. The cost is 11K of RAM.

### 3. The camera: `camera_update`

There is no driving model yet, so a camera drives itself along the middle of
the track. Two variables hold its position:
- `cam_seg` is the segment it is on.
- `cam_frac` is how far it is towards the next segment, in 256ths.

Each update adds `cam_speed` (160) to `cam_frac`, and a carry moves
`cam_seg` on. That is 1,639 updates a lap.

The camera works between four segment centres, each the midpoint of the
segment's two verges:
- C0 and C1: the current segment and the next.
- C3 and C4: three and four segments ahead.

They are cached against the segment they were worked out for. Moving on one
segment shifts them along, and only two new ones are worked out. A centre is
found with `midpoint`, which halves the difference rather than the sum,
because the sum of two coordinates can overflow 16 bits.

- **Position:** `cam_frac` of the way from C0 to C1, raised 500 units
  (`EYE_HEIGHT`).
- **Look target:** the same fraction of the way from C3 to C4.
- **Heading:** `yaw_angle` of the target from the position.

Interpolating the target as well as the position makes the heading turn
smoothly through a corner. Aiming at a fixed segment ahead made it jump once
a segment, and the kerbs swung left and right. Looking three segments ahead
rather than one gets past a quirk of the data: a new section restarts from
its own coordinates, which can skew a single step.

`lerp` does the interpolation as `DE + (HL − DE) × frac / 256` for any 16-bit
difference. It splits |d| × frac into its high and low bytes so that
`mul8`, an 8×8 multiply, is enough.

### 4. The arithmetic: logarithms instead of division

The BBC gets its ratios by shift-and-subtract division (`Divide16x16`,
`DivideX`). On a Z80 a 16-bit division costs hundreds of T-states, and each
verge point needs several. So every ratio here is a difference of
logarithms, and every product is a sum:

```
a / b  =  2 ^ (log2 a − log2 b)
```

Everything is by table. The tables are generated by `tables.py` at build
time and are page-aligned, so a lookup is H = page, L = index.

| Address | Table | Contents |
|---|---|---|
| `$6000` | `tbl_log12_lo` | the fraction (low byte) of 256 × log2(i), i = 0 to 4,095 |
| `$7000` | `tbl_log_he`, `tbl_log_hs`, `tbl_log_hl` | the whole part (high byte), which is floor(log2 i), the position of i's top bit: from E when D is 0, else from D (with 4 more after the shift for values of 4,096 or more). Three small tables instead of a second 4K |
| `$A000` | `tbl_xhi_lo`, `tbl_xhi_hi` | 128 + yaw-high-byte × 256 / 40: the screen x of a yaw's high byte, signed 16-bit |
| `$A200` | `tbl_xfrac` | the pixels a yaw's low byte adds: low × 256 / 40 / 256 |
| `$A300` | `tbl_mask` | `$FF >> (x & 7)`, indexed by x itself: a byte's pixels from x rightwards |
| `$A400` | `tbl_logft` | the distance correction (below) |
| `$A500` | `tbl_a32_lo`, `tbl_a32_hi` | 32 × the BBC's own `arctanY` table: the angle within an octant |
| `$A700` | `tbl_div3` | i / 3, for the edge stage's commonest division |
| `$B000` | `tbl_exp8` | floor(2^(n + f/256)), one page per whole part n = 0 to 7 |

Consecutive pages are used in step: xhi_lo, then xhi_hi, then xfrac, and
logft, then a32_lo, then a32_hi. The code moves from one to the next with
`INC H`.

These are the routines (`maths.s`):

- **`log16`**: 256 × log2 of a 16-bit value. Below 4,096 the fraction is
  one lookup and the whole part another, from the value's high byte (or its
  low byte when the high byte is 0). Above, the value's top 12 bits are
  looked up the same way, with 4 more in the whole part for the four bits
  dropped. The result is within 2/256 of
  exact. It is also a macro, `LOG16`, for the code that can't spare a call.
- **`exp8` / `exp16`**: the antilogarithm. The log's high byte picks a page
  of `tbl_exp8` and its low byte the entry, so 2^x for x below 8 is one
  lookup. `exp16` doubles the page-7 entry for bigger results.
- **`yaw_angle`**: the bearing of (dx, dz), and the log of its distance, as
  `GetObjYawAngle` and `GetObjectDistance` do it:
  1. **Octant.** Take absolute values and note three bits: dx negative, dz
     negative, and |dx| the larger. Together they are the octant.
  2. **Ratio.** T = 256 × smaller / larger, as
     `exp8(log16(smaller) − log16(larger) + 8 × 256)`.
  3. **Angle.** `tbl_a32[T]` is the angle within the octant.
  4. **Bearing.** A table of eight octants gives the quarter turn to add and
     whether to negate first.
  5. **Distance.** The BBC's distance is alpha-max-plus-beta-min: larger +
     smaller / 8 while the angle is small, else larger × 7/8 + smaller / 2.
     In logs that is log(larger) plus a correction that depends only on T,
     so it is `log16(larger) + tbl_logft[T]`, left in `ya_logd`.
- **`pitch_height` / `pitch_line`**: the track line.
  1. `pitch_height` keeps the sign of dy and log(|dy|) + 5 × 256. The 5 ×
     256 is the log of 256 / 8.
  2. `pitch_line` takes the distance's log off it to get log T.
     - log T of 7 × 256 or more means T ≥ 128, which is out of sight.
     - Otherwise it gives 60 + T or 60 − T, by the sign.
     - A line above 127, far above the view, is clamped to 127.
- **`verge_width`**: the screen width of a verge mark. The BBC's is
  2^23 / (distance × 2^vergeScale) yaw units. In logs that is one antilog:
  `exp16(LOG2_WIDTH − vergeScale × 256 − log d)`, where
  `LOG2_WIDTH` = 256 × (23 − log2 40) folds in the 40 yaw units a pixel.
- **`YAW_TO_X`**: a relative yaw to screen x. This is
  `tbl_xhi[high byte] + tbl_xfrac[low byte]`, with the +128 for the centre
  already in the first table.

The logs are good to about one part in 256. On screen that is a pixel or
two at worst, at the far end of the view, where a point's bearing is a
small difference of two large angles. Nothing here feeds physics. The
`maths` and `verges` tests hold it to that.

### 5. The verge points: `verges_begin` and `verges_finish`

This is `GetSegmentAngles` with `GetVergeAndMarkers`: for each side of the
track, the list of points its edges are drawn through, far to near.

#### Which segments

Both sides start 32 segments ahead of the camera. They step back 13
segments, then 7, then one at a time, up to 16 points in all (`vb_steps`).
The steps are big far away, where a segment is a pixel or two deep, and
small close up, where each one is many lines. The kerb's stripes can only
be drawn between points a segment apart, so they reach 12 segments out,
about as far as a stripe is still a line tall. The BBC steps 13, 6 and 3,
so its stripes stop at 9, and spends four points behind the camera, where
the view hardly ever reaches.

Both verges are walked together, a segment at a time, because they share
what is worked out per segment:

- **The flags,** and from them `vergeScale`:
  - 5 for black-and-white verges (marks 25 units wide);
  - 4 for red ones on a curve, or red on both sides (50);
  - 3 for a straight's red verge (100).

  The scale goes into `vb_wlog`, the log of the width with the distance
  still to be taken off.
- **The colours.**
  - Within the one-segment steps, odd segments are white (colour 4).
  - Even ones are red (3) or black (2), by that side's flag.
  - A point that ends a step of several segments is always red or black (see
    [Colours](#colours)).
- **The height.** The segment's height less the eye's goes through
  `pitch_height` once, for both sides.

#### Each point

`VB_POINT` is a macro with a copy for each side (`vr_point`, `vl_point`).
Each copy's state is at fixed addresses, and its coordinate arrays and
colour are constants in its instructions. The right verge is the inner one
(`SEG_XI`, `SEG_ZI`), since the cars drive clockwise. The left is the outer.
The maths of `yaw_angle`, `pitch_line` and `verge_width` is written out
inline rather than called, because this runs about 27 times an update.

For each point, `VB_POINT`:

1. Takes dx and dz from the camera, and its bearing and distance as
   `yaw_angle` does. It subtracts the camera's heading to get the yaw
   relative to straight ahead.
2. Keeps track of the closest point so far, by distance log. The list runs
   from 32 segments ahead to two behind the camera, so its points get closer
   and then, once they are level with the camera, farther again.
3. Works out the track line as `pitch_line` does. The point is out of sight
   if T ≥ 128 or the line is below 0.
4. Checks the field of view, but only from the closest point on. There, a
   point more than 20 yaw units off centre is out of sight. Before that, a
   point outside the field of view is kept, as `GetSegmentAngles` keeps it.
5. Gets the mark's width, `2 ^ (vb_wlog − log d)` pixels, and the screen x
   by `YAW_TO_X`. The outside edge is the x plus the width on the right, or
   minus it on the left.
6. Appends the 8-byte entry:

   | Offset | Field |
   |---|---|
   | +0 | x of the verge's track edge, signed 16-bit |
   | +2 | x of its outside edge, where the grass starts |
   | +4 | track line |
   | +5 | colour: 2 black, 3 red, 4 white |

A side's list ends at its first point out of sight. There is then one last
try, as the BBC makes it. A point a quarter of the way from the last point
kept towards this one is projected through the routines proper. If that one
is in sight, it is added with the last point's width and colour. This is
what carries an edge down to the bottom of the view rather than stopping
short of it.

The right list is at `$BA00` and the left at `$BB00`. They have counts
`vr_count` and `vl_count`.

#### Split round the interrupt

`verges_begin` does the first four segments (`VB_EARLY`) and `verges_finish`
the rest. The loop's state is all in memory between the two. The reason is
time: the first part runs straight after the frame interrupt, while compose
would otherwise be waiting for the beam (see
[Timing against the beam](#timing-against-the-beam)). Four leaves a margin.
With five, the first update started compose at 33,700 T-states, too late to
stay behind the beam. With twelve, 157 of 200 updates tear.

#### Colours

The BBC colours every mark by its segment's parity. That is right for the
near points, a segment apart, and they move with the track. But the far
points are 13 and 7 segments apart, and each colours a stretch with
several marks in it. By parity, those stretches swapped between white and
red each time the camera passed a segment, and the distance flickered. Here
they take the verge's red or black instead, so only the marks close enough
to draw one at a time alternate. This is the one place the engine
deliberately departs from the BBC.

### 6. A worked example

This is the camera at segment 301, 64/256 of the way to 302, from the tests'
segment-300 view:

- position (6374, 4044, 16905);
- heading `$7E60`, very nearly a half turn, facing −z.

The right list's first point is segment 333's inner verge, 32 segments
ahead, at (6359, 3647, 13089).

| Step | Working | Result |
|---|---|---|
| Deltas | dx = −15, dz = −3816, dy = 3647 − 4044 = −397 | |
| Octant | both negative, \|dz\| larger | add a half turn, don't negate |
| Logs | log16(3816) = 3046, log16(15) = 1000 | exact: 3045.8 and 1000.2 |
| Ratio | exp8(1000 − 3046 + 2048) = exp8(2) | T = 1 |
| Angle | tbl_a32[1] = 32 × arctanY(1) | 32 |
| Bearing | 32 + `$8000` | `$8020` |
| Distance | 3046 + tbl_logft[1] (0) | log 3046: 3,818 units; alpha-max-beta-min gives 3,818 |
| Relative yaw | `$8020` − `$7E60` | 448, right of centre |
| Screen x | tbl_xhi[1] + tbl_xfrac[`$C0`] = 134 + 4 | 138 (exact: 128 + 448/40 = 139.2) |
| Height log | log16(397) + 5 × 256 = 2210 + 1280 | 3490 |
| Pitch | exp8(3490 − 3046) = exp8(444) = floor(2^1.73) | T = 3; dy is negative, so line 60 − 3 = 57 |
| Width | flags `%101000`, both verges black: vergeScale 5; exp8(5888 − 1362 − 1280 − 3046) = exp8(200) | 1 pixel (exact 1.72) |
| Colour | a far point, a step of several segments, black verge | 2 |

The Z80's list entry for it is (138, 139, 57, 2).

### 7. The edges: `edges_build`

This is `DrawTrack`. Each verge has two edges, its track edge and its
outside edge, and each is a line through its side's points. Wherever an
edge crosses a track line it leaves a **marker**: "from this x rightwards,
this colour". The screen is never touched here.

#### The marker records

Every track line has a 32-byte record at `$EC00 + 32 × line`:

| Offset | Field |
|---|---|
| +0 | the offset of the next free marker: 4 + 2 × markers |
| +1 | the fill pattern the line starts with at x = 0 |
| +2 | the x that pattern was set from: the rightmost edge left of the screen so far, `$8000` for none |
| +4 | up to 14 markers: an x (0-255), then a fill pattern |

Markers hold the colour's 8-pixel fill pattern (`patterns.s`) rather than
the colour, so compose has nothing to look up.

`edges_build` first resets the 80 records' headers. It does this by pushes,
pointing SP at each header in turn: two pushes a line, unrolled. Lines below
the horizon start as grass and lines above as sky. An interrupt during this
pushes below SP. That lands either on a header about to be pushed over or on
the last marker slots of the record before, which are empty, so this needs
no DI.

Records exist for lines 80 to 127 too, above the view. An edge running off
the top still writes there, which saves the line loop a test. They are
marked full once, at startup, so nothing is ever added to them.

#### Four edges, left to right

The edges are drawn in the order `DrawTrack` uses, left to right across the
picture:

| Edge | Through | Colour to its right |
|---|---|---|
| left verge, outside | the left list's +2 | each point's verge colour |
| left verge, track edge | the left list's +0 | road |
| right verge, track edge | the right list's +0 | each point's verge colour |
| right verge, outside | the right list's +2 | grass |

Where two edges land on the same x, the one drawn later wins: compose's
sort keeps markers at the same x in the order they were made. The later
edge is the one further right in the picture.

A verge's two edges go through the same points, on the same track lines.
So one side is one pass, the `SIDE` macro (`edges_l`, `edges_r`). Each pair
of consecutive points is set up once, and only each edge's own division and
line loop are done twice. Stretches are short, about four lines on average,
so setting one up costs about as much as drawing its lines. `SIDE` keeps its
state in its own instructions, patched as it goes: each edge's x at the
last point, the lowest line so far, the record the stretch starts from. So a
point's two x values are read from the list once, in order. Each stretch between two points takes the nearer
point's colour.

#### One stretch of an edge: `raster`

Between a far point at line a and a nearer one at line b, the edge crosses
n = |b − a| lines. They are usually down, from the horizon towards the
bottom of the view, but up on a crest. It has to move dx = x_b − x_a in
that time.

`raster` divides once: |dx| = q × n + r. Then it steps the lines
Bresenham-fashion:

- x moves q pixels a line, plus one more whenever the error term,
  starting at n / 2 so x rounds to the nearest pixel, passes n. The Z80
  counts it the other way, down from (n − 1) / 2 by r a line, and moves x
  the extra pixel when it would go below zero. That is the same error,
  n − 1 less it. Then the carry is the subtraction's own borrow, with no
  compare against n.
- Each line it reaches gets a marker at x.
- A stretch marks n lines, not n + 1. Its last line is the next stretch's
  first, so the record pointer runs on from one to the next.
- Only a side's last stretch marks its last line as well.

This loop is the hottest code in the edge stage, so it lives in registers:

- **Main set:** HL = x, DE = the whole-pixel step, C = the error,
  B = lines left.
- **Alternate set:** HL' = the line's record, BC' = ±32 to the next one.
- **Patched into the instructions:** r, n and the pattern.
- **Two copies of the loop,** `raster_r` for an edge heading right and
  `raster_l` for one heading left. So the carry step's `INC HL` or `DEC HL`
  isn't patched in, and only the rightward copy has the test for having
  gone off the right.

`div16_8` makes the one division cheap for the usual cases. Most stretches
cross two to four lines, so n = 1, 2 and 4 are shifts or nothing, n = 3 is
a lookup in `tbl_div3`, and the rest are unrolled shift-and-subtract.

#### Off the edges of the screen

- **Off the right (x ≥ 256):** no marker. There is nothing to its right to
  colour.
- **Off the left (x < 0):** an edge there decides the colour the line starts
  with. Its pattern replaces the record's starting one if its x is the
  rightmost seen so far. Both are negative, so an unsigned compare against
  +2 does it, and `$8000` loses to anything.
- **Below a side's lowest point,** on the left: the left verge has left the
  screen sideways rather than through the bottom. Each line beneath it,
  down to line 0, that no edge has claimed starts as road
  (`raster_far_left`). The verge's colour is set first and the road's over
  it, the same left-to-right order as the edges.
- **A full line (14 markers):** later edges on it are dropped. A line
  normally has one marker per edge, four in all. More come only where an
  edge crosses the same line twice, as its points go up and back down over
  a crest or round a hairpin.

Here is line 40 of the example view (an even line), as edges left it:

```
record at $EC00 + 32 × 40:  0C 88 00 80 | 31 FF  3B FF  C4 FF  CE 88
                            |  |  |____|   |      |      |      |
          4 markers --------'  |  none     x=49   x=59   x=196  x=206
          starts grass (%10001000)         black  road   black  grass
                                           (left verge) (right verge)
```

### 8. Compose: `compose_screen`

This is the BBC's `DrawTrackBytes`, which fills between edges as it copies
the finished view to the screen. The Spectrum has no buffer to copy:
compose fills straight into screen memory, and that fill is the only write.

#### Screen layout

A Spectrum pixel row is 32 bytes. Row y is at:

```
$4000 | (y & $C0) << 5 | (y & 7) << 8 | (y & $38) << 2
```

so consecutive rows are 256 bytes apart within a character row. Compose is
unrolled, one call per track line. Each call carries that line's record
address and screen row address as constants, worked out by the assembler.
Line 79 is drawn first, on row 16, down to line 0 on row 95, except that
the sky is usually skipped (below). Every row is 32-byte aligned, so within
a line only E moves, and records are 32-byte aligned, so only C does.

#### Patterns

Each colour is an 8-pixel byte (`patterns.s`), with 1 for ink (black):

| Colour | Pattern | Looks |
|---|---|---|
| 0 grass | `%10001000` | a quarter |
| 1 road | `%11111111` | solid black, as on the BBC |
| 2 verge, black | `%11111111` | runs into the road |
| 3 verge, red | `%11001100` | a half |
| 4 verge, white | `%00000000` | paper |
| 5 sky | `%00000000` | paper |

On odd lines every pattern is rotated right two places, so a tone's dots
fall between those of the line above rather than forming columns. There
are two copies of the line code, `cs_line_odd` (with two `RRCA`s per
pattern) and `cs_line_even`.

#### One line: `CS_LINE`

The registers:

- BC: the next marker.
- DE: the next screen byte.
- H: the page of `tbl_mask`, with L the last marker's x.
- IXL: the current pattern.
- IY: the jump address into the fills.

From the start of the row, with the line's starting pattern current, for
each marker in turn:

1. **Order.** If its x is less than the last marker's (L), the line is out of
   order. That only happens where edges cross. `sort_line`, an insertion
   sort that keeps equal x in order, sorts the record, and the line starts
   again.
2. **Count.** The bytes from the current one up to and including the byte x
   falls in: (x >> 3) − (bytes done) + 1.
3. **Fill.** All but the last of those bytes take the current pattern
   whole. They are written by jumping into an unrolled run of
   `ld (de),a : inc e` pairs (`fill_runs`), entered so that exactly that
   many execute. The run ends by jumping back to build x's byte.
4. **x's own byte.** It is the current pattern left of x and the marker's
   pattern from x on:

   ```
   byte = cur ^ ((cur ^ new) & mask[x])
   ```

   `tbl_mask[x]` is `$FF >> (x & 7)`. It is indexed by x itself, so no
   AND is needed, and L can stay x for the order check. The marker's
   pattern becomes current.
5. **A shared byte.** If x's byte was already written by an earlier
   marker, it is mixed again from what is there:
   `byte = old ^ ((old ^ new) & mask[x])`.

After the last marker, the rest of the row is filled with the current
pattern through `fill_runs_last`, which returns.

Line 40 again. It is even, so patterns are unrotated:

| Bytes | Pixels | Written | Why |
|---|---|---|---|
| 0-5 | 0-47 | `88` × 6 | grass, the starting pattern |
| 6 | 48-55 | `FF` | `88 ^ ((88 ^ FF) & 7F)`: grass at pixel 48, black verge from 49 |
| 7 | 56-63 | `FF` | road from 59, black on black |
| 8-23 | 64-191 | `FF` × 16 | road |
| 24 | 192-199 | `FF` | black verge from 196 |
| 25 | 200-207 | `FC` | `FF ^ ((FF ^ 88) & 03)`: verge to 205, grass from 206 |
| 26-31 | 208-255 | `88` × 6 | grass |

Track line 40 is pixel row 16 + 79 − 40 = 55, at `$47C0`, and those are the
bytes the Z80 writes there.

#### Empty lines

A line with no markers is one pattern across. `cs_last` remembers, per
line, the pattern an empty line was last filled with, or `NOT_EMPTY`.

- **Unchanged:** if the line is still empty and has the same pattern, it is
  left alone. It still takes about 245 T-states, a little longer than the
  beam takes over a row (224), for the reason below.
- **Blank sky:** the lines at the top that are blank on the screen and stay
  blank (no markers, a pattern of 0, and 0 last time) are not visited at
  all. `compose_skip` looks at the lines from the horizon up and finds
  where compose should start, and `compose_from` jumps into the unrolled
  calls there. Over a lap that is 19 or 20 lines on every update but the
  first, about 4,900 T-states of padding, for 1,300 spent looking.
- **Changed:** it is filled by pointing SP at the row's end and pushing the
  pattern 14 times, 28 bytes. The first four bytes are stored separately
  after SP is put back. The pushes stop four bytes short because an
  interrupt pushes four bytes below SP, and those must land in this row.
  The stores come after because the frame interrupt does land in compose:
  stored first, its return address could have been left on screen.

### Timing against the beam

Compose writes the screen the viewer is looking at, with no back buffer. A
frame must never show half of one view and half of the next.

A 48K frame is 69,888 T-states from interrupt to interrupt. The ULA fetches
pixel row y from 14,336 + 224 × y, for 128 T-states, so the view's rows 16
to 95 are fetched from about 17,900 to 35,700. The rule compose keeps is to
write every row after the beam has fetched it in this frame and before it
fetches it in the next. Then all of one update's writes first appear
together, in the next frame.

- **After:** compose starts once the beam has reached the first row it
  will draw (`wait_for_beam`), and every line takes at least as long as the
  beam takes over a row. A line left alone is padded to about 245 T-states
  for this. So compose can't catch the beam up.
- **Before:** the bottom row must be done before the next frame's beam
  reaches it, about 105,000 T-states after the interrupt. Compose takes
  about 61,000, so it has to start by about 44,000. It starts at 22,500 to
  29,000.

`wait_for_beam` finds the beam on the **floating bus**. On a 48K, reading
a port no device answers returns whatever the ULA is fetching from screen
memory, or `$FF` when it is fetching nothing (the border, and the end of
each line).

- Rows 0 to 15 hold nothing but zero bytes. Their attributes are `$3A`,
  which nothing else on screen uses.
- So `in a,($FF)` returning anything other than `$FF`, 0 or `$3A` means the
  ULA is at row 16 or below.
- When the sky was skipped, it then waits for the beam to get past that
  too. The skipped rows are blank: zero bytes under the view's own
  attribute, `$38`. So a byte that is none of `$FF`, 0 and `$38` is the beam
  on a row with something on it, at or below the first row compose will
  draw. Nothing need be there yet (the first update's screen is blank), and
  a row of solid black reads as `$FF` like no row at all, so the wait gives
  up after the time the beam takes to cross twenty rows. By then it is past
  the sky whatever is on it.

This needs a 48K or 128K: the +2A and +3 have no floating bus.

An update runs like this:

```
T = 0       frame interrupt: the IM 2 handler counts frames
            camera_update                  ~6,600
            verges_begin: four segments    work compose would spend waiting
            compose_skip                   how much of the sky to leave alone
            wait_for_beam                  until the beam is below the sky
~23,000     compose_from                   ~61,000, behind the beam
~84,000     fps_show                       the digit bottom left
            verges_finish                  the rest of the points
            edges_build                    ~67,000
< 209,664   HALT: wait for the next interrupt, the start of the next update
```

Three frames is 16.7 updates a second. Over a lap the work takes 187,700
T-states at the median and 205,600 at worst, in the tightest corner, where
the camera sees most of the track: every update fits in three frames.

The `beam` test watches every write to the view over 200 updates and checks
this. Without the padding, 59 updates in 60 tore.

### Where to find things

| File | What |
|---|---|
| `track_data.py` | fetches, reassembles and verifies the track data file |
| `tables.py` | generates every lookup table |
| `build.py` | the generated sources, sjasmplus, and the .z80 snapshot |
| `revs.s` | the memory map and the main loop |
| `track.s` | `build_track` |
| `camera.s` | the self-driving camera, `lerp`, `seg_centre` |
| `maths.s` | `log16`, `exp8`, `exp16`, `yaw_angle`, `pitch_line`, `verge_width`, `YAW_TO_X` |
| `verges.s` | the verge point lists |
| `edges.s` | the marker records, `raster`, `div16_8` |
| `compose.s` | compose, `sort_line`, the fill runs |
| `screen.s` | the screen set-up, IM 2, `wait_for_beam`, the frame counter |
| `patterns.s` | the six fill patterns |
| `view_model.py`, `track_model.py` | Python models of the BBC routines and the track |
| `tests/` | the checks, and `screen_model.py`, a model of edges and compose |
