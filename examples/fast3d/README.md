# fast3d

Fast 3D for the Z80: signed multiplication, a rotation matrix from three
angles, rotating and projecting vertices, drawing lines clipped to a
window, and a world of objects seen from a camera, with what is out of view
culled before any of its vertices is touched. With them comes a demo on the
128K, a flight through forty turning cubes and icosahedra. The same
routines for the BBC Micro's 6502, with the same arithmetic (objects and the
camera not yet), are in
[vs-code-bbc/examples/fast3d](https://github.com/jonsole/vs-code-bbc/tree/master/examples/fast3d).

`INCLUDE "fast3d.s"` anywhere in an sjasmplus program. It aligns its own
tables (2K of them, from a 512-byte boundary). It never touches IY, so the
ROM's interrupt routine can keep running.

## The numbers

| What | Form |
|---|---|
| An angle | a byte, 256 to the turn |
| A vertex | three signed bytes, -128..127 |
| A matrix entry | a signed byte, -127..127, with 127 standing for 1.0 |
| A rotated coordinate | the exact 16-bit sum `m0*x + m1*y + m2*z`: 128 times the rotated coordinate (times 127/128) |
| A projected coordinate | `rot / Z`, with `Z = (rot_z + zoff) >> 8` |

With `zoff = 128 * d`, the projection is `256 * x / (z + d)`: the eye is `d`
units from the object's centre and 256 units from the screen. `Z` must stay
within 1..255, which keeps the object in front of the eye: with the object
inside a sphere of radius `r`, choose `d` between `r + 2` and `512 - r`.

[model.py](model.py) defines every result exactly, and
[check.py](check.py) holds the Z80 to it.

## The routines

T-states were measured in SkoolKit's simulator on uncontended memory; see
[Checking](#checking).

| Routine | In | Out | T-states |
|---|---|---|---|
| `mul8s` | B, C signed | HL = B * C | 154 |
| `make_matrix` | `angle_x`, `angle_y`, `angle_z` | `matrix` (9 bytes, row by row), and rotate's code | 3,982 |
| `compute_matrix`, `install_matrix` | the same, in two: the entries, then HL -> 9 entries into rotate | | 2,932, 1,013 |
| `rotate` | HL -> vertex | `rot_x`, `rot_y`, `rot_z` | 1,241 |
| `project` | `rot_*`, `zoff` | B = x, C = y (256 x 192, y down), or carry if off the screen | ~860 |
| `divide` | HL signed, C = 1..255 | HL = HL / C, or carry if it will not fit a byte | 333..453 |
| `transform` | HL -> vertices, DE -> points, B = count | x, y for each, y = $FF if off the screen | ~2,370 a vertex |
| `draw_line` | (B, C) to (D, E); `screen_high` $00 or $80 | the pixels, on $4000 or $C000 | ~60 a pixel along x, ~53 along y; ~270 to start |
| `clear_box` | B rows from row C, E bytes from column D | blank | ~11 a byte, plus ~75 a row |
| `project_wide` | `rot_*`, `zoff` | HL = x, DE = y, 16-bit, on the screen or off it; carry if Z is 0 | ~1,400 (70 when Z is 0) |
| `divide_wide` | HL signed, C = 1..255 | HL = HL / C, held to ±16,383 | 418..1,107 |
| `transform_wide` | as `transform` | x, y as 16-bit words; x = $8000 if at or behind the eye | |
| `set_window` | B, C = left, top; D, E = right, bottom | lines clip to that, inclusive | |
| `clip_line` | `clip_x0`, `clip_y0`, `clip_x1`, `clip_y1`, 16-bit | B, C, D, E for `draw_line`, or carry if none of it is in the window | 537 inside; ~1,400 outside; ~3,550 cut at one end; ~8,950 at both |
| `crossing_x`, `crossing_y` | DE = the edge; the line's ends | HL = where the line crosses it | ~2,240 (1,221..3,142) |
| `set_camera` | `camera_x`, `_y`, `_z`, `camera_angles` | the camera's matrix, its transpose in rotate | 9,399 a frame |
| `cull_object` | IX -> an object | carry if out of view; else `view_t`, its centre in camera space | 298 out of the box; ~3,240 out roughly; ~8,190 in view (with `CULL_SKIP`; ~1,200 less an object culled without) |
| `object_matrix` | IX -> an object in view | `view_m` = Rc^T Ro | ~8,330 |
| `transform_object` | IX; D = the points' page, E = the first vertex's place on it | its vertices to 16-bit screen points, at any distance, in the page's four tables of 64 bytes: x low, x high, y low, y high | ~2,330 a vertex (~2,830 without mirrors) |
| `draw_line_clipped` | as `clip_line` | `clip_line`, then `draw_line` | |

### How they are quick

- **Multiplying by quarter squares.** `a*b = f(a+b) - f(a-b)`, where
  `f(n) = floor(n*n/4)` comes from a 1K table. `mul8s` biases both bytes by
  128 so that the 9-bit sum's top bit lands in the carry, and `RL H` turns the
  carry into the table's page.
- **The matrix is written into the code.** For a frame's rotations, each
  matrix entry `m` is fixed, so `make_matrix` writes `SQ_CENTRE - 128 + m` and
  `SQ_CENTRE - 128 - m` straight into `rotate`'s `LD HL,nn` instructions. A
  product is then `ADD HL,DE` (DE is the vertex coordinate + 128) and a 16-bit
  read, twice. Nine of those make the 1,241 T-states.
- **No multiplications in the matrix.** Every entry of `Rz Ry Rx` is a
  product of sines and cosines. Each product is a sum of sines of sums of the
  angles (`cos A cos B = (cos(A-B) + cos(A+B)) / 2`, and its relatives). So an
  entry is at most eight table lookups, all of them additions: a minus sign is
  half a turn more, and a cosine a quarter turn more. The table holds
  `2032 sin(a)`. An entry is rounded once, at the end, and the scale was chosen
  so that no entry can round past 127. Across all angles the entries are
  within 0.55 of 127 times the true value.
- **Clipping only where it is needed.** `clip_line` is Cohen-Sutherland:
  each end gets a code saying which of the window's edges it is beyond, so
  a line wholly inside, or wholly beyond one edge, is settled in a few
  hundred T-states. Only a line that crosses an edge pays for a crossing,
  found by a binary chop: `crossing_x` for a left or right edge,
  `crossing_y` for a top or bottom. From one end, a step toward the other is
  halved again and again, and taken whenever the line stays short of the
  edge. Each halving is one bit of how far along the line the edge is (a
  division step) and adds that much of the other coordinate (a
  multiplication step), all in registers, and it stops once the step is
  under half a pixel: about 12 halvings. The numbers start as 24 bits, but
  after all but the last nine halvings they fit 16, and those nine run at
  about 100 T-states each rather than 170. A crossing takes about 2,240
  T-states, some 40% quicker than the 16 x 16 multiply and 32 / 16 divide
  it replaced, and slightly less exact: a clipped end is within 0.75 of a
  pixel of the true line (0.21 on average), where the exact sum gave half a
  pixel. Every crossing is worked out from the line's own ends, never from
  an end already moved. A moved end has been rounded, and on a shallow line
  the slope would multiply that rounding.
  `project_wide` divides the quick way whenever the quotient fits a byte,
  which it does for anything on the screen or near it.
- **Objects for the price of rotates.** An object at P, turned by Ro, seen
  from a camera at C turned by Rc, has its vertex v at
  `Rc^T (P - C) + (Rc^T Ro) v` in camera space. With `Rc^T` installed in
  `rotate`, both come from rotations of signed bytes. T is two rotates, of
  P - C's high bytes and of its low bytes less 128, with the 128s put back
  by a constant `set_camera` works out: exact in 24 bits. M is three
  rotates, of the columns of Ro. A model's vertices are shared by its faces,
  so each is transformed once, and each edge is drawn once.
- **Mirrored vertices for nothing.** `M (-v)` is exactly `-M v`, so where a
  model has a vertex and its mirror, as every vertex of a cube or an
  icosahedron does, `transform_object` rotates the first and has the second
  as `T - M v`. `build.py` puts such pairs first and says how many there
  are (`MODEL_PAIRS`), and half the rotates go.
- **The matrix installed unrolled.** A picture installs a matrix in
  `rotate` ten times or so: the camera's, and each object's. Each of
  `install_matrix`'s eighteen operands is written by its own `LD (nn),HL`,
  1,013 T-states in all, where a loop through a list of addresses took 2,456.
- **Culling in three steps, each quicker than the next.** An object is left
  out when its bounding sphere is wholly nearer than NEAR, farther than FAR,
  or beyond one of the planes `|x| = z / 2`, `|y| = z / 2`: a 90-degree view,
  as wide as the screen and a little taller, so that the lines clip whatever
  it lets through. First, an object more than 10,400 units from the camera
  on any axis is out, for 367 T-states. Then a rough T from P - C's high
  bytes alone, a row at a time: depth first, so that an object behind the
  eye is out after one row (from 1,758 T-states), then x, then y, each
  tested with the sphere enlarged by the most the low bytes could add.
  Of what reaches this step out of view, 72% goes here, for about 2,290. Only
  what is left, near a plane or in view, gets the exact T and the exact
  tests. The answer is always the exact test's.
- **Skipping the cull.** With `CULL_SKIP` defined, an object the cull
  leaves out is not tested again until it could have come into view. The
  cull says how far past a plane the object was, its margin, and T, the
  object's centre in camera space, can only move so far in a picture:
  `T' - T = (M' - M)(P - C) + M'(C - C')` exactly, M the camera's matrix,
  so on any axis by at most `E D + 127 m`, with E the largest row sum of
  the change in M, D the object's largest distance on an axis and m the
  camera's move. That is arithmetic on the matrices as they are, so it
  holds whatever the camera does -- jump, spin, stand still -- and nothing
  is assumed about its speed. Each picture `cull_skip_bounds` measures the
  camera's change and tabulates the bound for each size D is held as (a
  two-bit mantissa and a power of two, chosen with a quarter's room above
  D, and an odometer limit for when the camera could have travelled that
  room); the program cuts every skipping object's margin by its bound and
  tests it again when nothing is left. In the demo's flight 25 of the 40
  objects are skipped a picture, for 260 T-states each instead of 2,000
  or more. model.py has the reasoning, and `check.py` holds the Z80 to it
  under a camera that jumps and swings. Nothing of this changes what is
  drawn.
- **Any distance.** Before dividing, `transform_object` shifts each vertex's
  camera-space position right by just enough to bring its depth into a
  byte, so the quick divide works out to the far plane (8,191 units) with
  the depth to 8 bits. Each coordinate is made in registers -- z first,
  since the shift and the divisor come from it -- shifted there, and
  handed straight to the divide; the loop keeps its vertex, count and the
  point it writes in the alternate registers, so nothing goes through
  memory that need not.
- **An unrolled line.** Each of the four ways a line can go (along x or y, to
  the left or the right) is a set of blocks, one for each bit of a byte. A
  pixel is then one `SET b,(HL)`. `draw_line` pushes the address of the first
  pixel's block and `RET`s into it. Along y every pixel steps down a row,
  and working out the next row on the Spectrum's screen cost as much as the
  pixel; so there the blocks are one for each bit *and row of the
  character cell*, laid out in chains that follow a step across, and seven
  rows in eight step down with `INC H` alone, only the eighth working out
  the next cell: 42 T-states a pixel instead of 75. build.py writes the
  blocks.

## The demo

```
python build.py                  # -> output/demo.z80, a 128K snapshot, with its SLD
python build.py --no-cull-skip   # the same, culling every object every picture
```

or **ZX Spectrum: fast3d demo** in VS Code. Forty cubes and icosahedra, each
turning, are scattered round a circle that the camera flies, about 32 units
a frame, turning gently of its own accord; O and P turn it more, Q and A
pitch it. Each frame every object is culled or drawn, and what is drawn is
clipped to a window with a frame round it (columns and rows 8 from each
edge). Each frame is drawn on the screen that isn't being shown, then shown
at the next interrupt: the interrupt routine writes port $7FFD when the
loop has asked it to. Meanwhile the loop goes on to the next frame's
arithmetic (`compute_frame`: the camera, culling, the matrices and every
drawn object's points, into a pool of pages), which touches no screen; by
the time that is done the flip has happened, and `render_frame` draws on
the screen it freed. Waiting for the flip before starting lost what was
left of a frame each time. Before drawing, it clears only the box drawn on
that screen last time: the box round the vertices of every object drawn,
held to the window. An object whose box is wholly inside the window, with
every vertex in front of the eye, has its edges drawn without clipping:
their ends go from `transform_object`'s points straight to `draw_line`.
Below the window's bottom left corner it shows pictures a second, to a
tenth, reckoned every ten pictures from the frames the interrupt counted
and drawn in the 48K ROM's font (ROM 1 is kept paged in for it).

Over a whole circle of the flight, between 1 and 10 of the 40 objects are
drawn a frame, 5.1 on average, and a frame takes 154,000..753,000
T-states, 467,000 on average, with nothing lost waiting for the flip:
about 7 frames a second on a 128K, before ULA contention (511,000 without
`CULL_SKIP`). Of an average frame (from the emulator's profiler), culling all
forty objects takes about 23%, about 3,300 T-states an object; the
matrices of those drawn 9%; their vertices 28%, more than half of it
projecting them; drawing their lines 15% and clipping those that need it
6%; and clearing the last box 8%.

![The demo's cube, a frame from check.py](demo.png)

## Checking

```
python build.py && python check.py
```

`check.py` runs the assembled routines in SkoolKit's simulator and compares
every result with `model.py`:

- `mul8s`, for all 65,536 pairs of signed bytes;
- `make_matrix`, for every x angle against a spread of y and z, plus 2,000
  random angle sets: 10,960 matrices;
- `rotate`, with each of those matrices, on all eight corners of the
  signed-byte cube (the largest sums) and four random vertices: 131,520
  rotations;
- `divide`, `project` and `transform`, on the edges of what fits and on random
  values;
- `draw_line`, all 6,144 bytes of the screen after each batch of lines, on
  both screens: 3,031 lines;
- `clear_box`;
- clipping: `divide_wide`, `project_wide` and `transform_wide`; then
  `clip_line` on 60,000 lines across random windows, from inside the window
  to 16,000 pixels beyond it, every end; and `draw_line_clipped`, every
  pixel;
- objects and the camera: `set_camera`, then `cull_object`, `object_matrix`
  and `transform_object` on 8,000 objects round 400 cameras, from 150 to
  20,000 units away: the camera's matrix, T, whether culled, M and every
  point;
- the demo, 256 frames of `draw_frame` (`compute_frame` then
  `render_frame`, a whole circle of the flight), whole
  screens against the model's picture of the same frame, and how many
  objects it drew. It writes every other one to `output/demo.gif`;
- the demo again, 240 frames with the camera moved between them at random
  -- small steps mostly, now and then a swing, a jump across the world or a
  leap out of it -- against the model's picture from the camera as it then
  stood, and `cull_skip_bounds`' table against the model's: the cull's
  skipping is only ever right, whatever the camera does.

`model.clip_line` is itself held to exact geometry by `clip_geometry.py`,
on 400,000 random lines and windows. Every clipped end must be within 0.75
of a pixel of the true line, along x or y, and no line with any part of
itself in the window may be left out:

```
python clip_geometry.py
```

And `cull_geometry.py` holds the objects and the camera to it, on 100,000
random scenes. T must be exactly `Rc^T (P - C)`. No object that has a vertex
the model would draw on the screen may be culled. And it measures how far
the points drawn are from the exact view (1.08 pixels on average, 8.9 at
worst, for objects as near as 40 units):

```
python cull_geometry.py
```

The demo also runs on the emulator itself, and its profiler measures the
real loop, interrupts, flips and all. Load `output/demo.z80` with its SLD,
run it, and profile with `compute_frame` as the period, so that a period is
a picture (`docs/mcp.md`):

```
profile {action: "start", period: "compute_frame"}
run                                   # a minute or so
profile {action: "get"}               # frames / periods.count: frames a picture
```

Over the first 103 pictures of the flight that gave 7.76 frames a picture,
where the loop that waited for each flip before starting the next picture's
arithmetic took 8.32: the same work, less half a frame of waiting a
picture.

## Not done

- **Clipping to the eye.** A line is clipped to the window, but an edge
  with an end at or behind the eye (Z = 0) is still left out: that needs
  clipping in 3D, to a near plane, before projecting. The demo's world keeps
  its objects 300 units from the camera's path for that reason.
- **Skipping side-culled objects.** An object culled by a side plane in
  the rough step keeps little margin -- the step's slack on `2t - z` is
  three times ROUGH, 670 units -- so it is skipped seldom; the exact T
  would give it more, at two rotates. What is skipped is mostly what is
  behind the camera.
- **Hidden lines.** The objects are wireframes, with every edge drawn.
- **Contention.** The timings are for uncontended memory. On a real Spectrum,
  `draw_line` and `clear_box` write to the screen, which is contended memory,
  and will run slower.
- **Faster projection.** `project` divides twice (about 400 T-states each). A
  reciprocal table and a multiply could beat it, but only with less precision.
