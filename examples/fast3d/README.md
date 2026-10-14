# fast3d

Fast 3D for the Z80: signed multiplication, a rotation matrix from three
angles, rotating and projecting vertices, and drawing lines. With them comes
a demo, a wireframe cube or icosahedron turning on the 128K. The same
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
- **An unrolled line.** Each of the four ways a line can go (along x or y, to
  the left or the right) is eight blocks, one for each bit of a byte. A pixel
  is then one `SET b,(HL)`. `draw_line` pushes the address of the first
  pixel's block and `RET`s into it.

## The demo

```
python build.py      # -> output/demo.z80, a 128K snapshot, with its SLD
```

or **ZX Spectrum: fast3d demo** in VS Code. A cube or an icosahedron turns
about all three axes; SPACE changes which. Each frame is drawn on the screen
that isn't being shown, then shown at the next interrupt. Before drawing, it
clears only the box the object filled on that screen last time.

A frame takes 66,000..92,000 T-states for the cube (8 vertices, 12 edges) and
151,000..163,000 for the icosahedron (12 and 30). That is 25 and about 17 frames
a second on a 128K, before ULA contention, which the simulator does not model.
The cube's frame goes on: about 45,000 T-states drawing its lines, 19,000 on
its vertices, 17,000 clearing and 4,000 on the matrix.

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
- the demo, 128 frames of `draw_frame`, whole screens against the model's
  picture of the same frame. It writes them to `output/demo.gif`.

The demo also runs on the emulator itself. `cpp-core`'s `snapshot_probe` can
load `output/demo.z80` and measure its main loop:

```
load output/demo.z80
runto 803D 10
work 803D 803C 100 70908
```

That gives 66,694..95,907 T-states an update, 87,401 the median: two frames
each.

## Not done

- **Clipping.** An edge with an end off the screen is left out, not clipped.
- **Hidden lines.** The objects are wireframes, with every edge drawn.
- **Contention.** The timings are for uncontended memory. On a real Spectrum,
  `draw_line` and `clear_box` write to the screen, which is contended memory,
  and will run slower.
- **Faster projection.** `project` divides twice (about 400 T-states each). A
  reciprocal table and a multiply could beat it, but only with less precision.
