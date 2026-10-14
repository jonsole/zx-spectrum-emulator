# fast3d

Fast 3D for the Z80: signed multiplication, a rotation matrix from three
angles, rotating and projecting vertices, and drawing lines, clipped to a
window. With them comes a demo, a wireframe cube or icosahedron turning and
swinging in close on the 128K, clipped to a window. The same
routines for the BBC Micro's 6502, with the same arithmetic, are in
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
| `make_matrix` | `angle_x`, `angle_y`, `angle_z` | `matrix` (9 bytes, row by row), and rotate's code | 3,814 |
| `rotate` | HL -> vertex | `rot_x`, `rot_y`, `rot_z` | 1,241 |
| `project` | `rot_*`, `zoff` | B = x, C = y (256 x 192, y down), or carry if off the screen | ~860 |
| `divide` | HL signed, C = 1..255 | HL = HL / C, or carry if it will not fit a byte | 333..453 |
| `transform` | HL -> vertices, DE -> points, B = count | x, y for each, y = $FF if off the screen | ~2,370 a vertex |
| `draw_line` | (B, C) to (D, E); `screen_high` $00 or $80 | the pixels, on $4000 or $C000 | ~60 a pixel along x, ~82 along y |
| `clear_box` | B rows from row C, E bytes from column D | blank | ~11 a byte, plus ~75 a row |
| `project_wide` | `rot_*`, `zoff` | HL = x, DE = y, 16-bit, on the screen or off it; carry if Z is 0 | ~1,400 (70 when Z is 0) |
| `divide_wide` | HL signed, C = 1..255 | HL = HL / C, held to ±16,383 | 418..1,107 |
| `transform_wide` | as `transform` | x, y as 16-bit words; x = $8000 if at or behind the eye | |
| `set_window` | B, C = left, top; D, E = right, bottom | lines clip to that, inclusive | |
| `clip_line` | `clip_x0`, `clip_y0`, `clip_x1`, `clip_y1`, 16-bit | B, C, D, E for `draw_line`, or carry if none of it is in the window | 537 inside; ~1,400 outside; ~3,550 cut at one end; ~8,950 at both |
| `crossing_x`, `crossing_y` | DE = the edge; the line's ends | HL = where the line crosses it | ~2,240 (1,221..3,142) |
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
- **An unrolled line.** Each of the four ways a line can go (along x or y, to
  the left or the right) is eight blocks, one for each bit of a byte. A pixel
  is then one `SET b,(HL)`. `draw_line` pushes the address of the first
  pixel's block and `RET`s into it.

## The demo

```
python build.py      # -> output/demo.z80, a 128K snapshot, with its SLD
```

or **ZX Spectrum: fast3d demo** in VS Code. A cube or an icosahedron turns
about all three axes; SPACE changes which. It also swings in from 400 units
to 110 and out again, close enough that most of it is beyond the window
(columns 24..231, rows 16..175, with a frame round it). Every edge is
clipped to the window. Each frame is drawn on the screen
that isn't being shown, then shown at the next interrupt. Before drawing, it
clears only the box the object filled on that screen last time.

Far off, a frame takes about 82,000 T-states for the cube (8 vertices, 12
edges) and 191,000 for the icosahedron (12 and 30). Up close it takes up to
195,000 and 348,000. The lines are much longer then, the box to clear fills
most of the window, and about a third of the edges cross an edge of the
window. That is from about 25 frames a second down to 8 for the cube, before
ULA contention, which the simulator does not model.

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
- the demo, 580 frames of `draw_frame` (a whole swing in and out for each
  object), whole screens against the model's picture of the same frame. It
  writes every other one to `output/demo.gif`.

`model.clip_line` is itself held to exact geometry by `clip_geometry.py`,
on 400,000 random lines and windows. Every clipped end must be within 0.75
of a pixel of the true line, along x or y, and no line with any part of
itself in the window may be left out:

```
python clip_geometry.py
```

The demo also runs on the emulator itself. `cpp-core`'s `snapshot_probe` can
load `output/demo.z80` and measure its main loop, from the instruction after
its `HALT` (`frame` + 4) to the `HALT` (`frame` + 3):

```
load output/demo.z80
runto 804F 10
work 804F 804E 580 70908
```

Over a whole swing of the cube, in and out, that gave 82,831..200,502
T-states an update, 143,951 the median. That agrees with the simulator, and
both screens it left held one framed cube and nothing else.

## Not done

- **Clipping to the eye.** A line is clipped to the window, but an edge
  with an end at or behind the eye (Z = 0) is still left out: that needs
  clipping in 3D, to a near plane, before projecting.
- **Hidden lines.** The objects are wireframes, with every edge drawn.
- **Contention.** The timings are for uncontended memory. On a real Spectrum,
  `draw_line` and `clear_box` write to the screen, which is contended memory,
  and will run slower.
- **Faster projection.** `project` divides twice (about 400 T-states each). A
  reciprocal table and a multiply could beat it, but only with less precision.
