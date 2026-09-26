# isoblocks

An isometric block engine for the 128K Spectrum: a city of blocks on a
128 x 128 map, eight heights. It is our own code and our own art, written
from what the
[Ant Attack disassembly](https://jonsole.github.io/zx-spectrum-disassemblies/antattack/)
showed about how Sandy White's 1983 engine works -- the map with a bit per
height, the projection, and painting the view by height with no depth test.
None of his code or graphics is used.

[plan.md](plan.md) is where it is going and what has been decided, with every
measurement.

## Two versions, one demo

The same demo is built two ways, to compare the renderers. On the test map, a
figure that Q, A, O and P walk a cell along the map's y and x, with the view
following it, and three more sprites standing about: a ball on a column, one
on the bridge, and a figure in the courtyard of the house.

- **The painter** (`painter/`) reads the view, sorts it by height in one pass,
  leaves out blocks covered whole, and paints whole blocks lowest first
  straight onto the hidden one of the 128K's two screens, switching screens
  at the interrupt -- so it never tears. A sprite is painted in the turn a
  block in its cell would have, so nothing needs a depth test. Any block
  picture will do (the blocks have outlines), and the engine can turn the
  view four ways, though the demo does not.
- **The ray renderer** (`rays/`) is built on
  [Tom Harte's Isometric-Ray-Cast](https://github.com/TomHarte/Isometric-Ray-Cast)
  -- his caster, tile drawer and scrolling, used as public domain, fitted to
  isoblocks' map and made quicker. Each triangle of a fixed grid shows the
  colours the build worked out for its diamond; the triangles are kept from
  frame to frame, slid along when the view moves and only the new edge cast,
  and only the character cells that change are drawn, by compiled tiles.
  Sprites are depth-tested per triangle. Flat-shaded faces and one view; on
  the checks' walk with the sprites, a frame takes about a third less time
  than the painter's (107k T-states against 169k). It draws in place, so a
  fast move can tear for a frame.

## Building and running

From `examples/isoblocks`:

```
python painter/build.py    # -> painter/output/painter.z80, with its SLD
python rays/build.py       # -> rays/output/rays.z80, with its SLD
python painter/check.py    # the painter against its model, every frame, and timed
python rays/check.py       # the rays' rules against the painter, the Z80 against its model
```

Each build needs Pillow and sjasmplus (the repository's copy in
`tools/sjasmplus/` is found automatically); the checks need SkoolKit. All are
in the repository's venv. Load a `.z80` into the emulator, with its `.sld`
beside it for source-level debugging.

## What is where

| Path | What |
|---|---|
| [shared/demo.s](shared/demo.s) | the demo both versions run: the sprites and the keys |
| [shared/maps/test.json](shared/maps/test.json) | the demo's map, as named boxes of heights |
| [shared/art/](shared/art/) | the block picture (`blocks.png`, one per pair of views) and the sprite pictures (`sprites.png`: a figure and a ball) |
| [shared/isogeom.py](shared/isogeom.py) | the painter's geometry and its model, sprites included |
| [shared/raycast.py](shared/raycast.py) | the ray renderer's model |
| [shared/common.py](shared/common.py) | what both builds share: sjasmplus, the SLD, the map, the sprite pictures, the .z80 |
| [painter/demo.s](painter/demo.s), [painter/build.py](painter/build.py), [painter/check.py](painter/check.py) | the painter's program, build and check |
| [painter/engine/layout.s](painter/engine/layout.s) | the numbers, and where everything lives in memory |
| [painter/engine/view.s](painter/engine/view.s) | the camera: which view, where it is centred, kept on the map |
| [painter/engine/read_view.s](painter/engine/read_view.s) | reads the cells in view and sorts them by height, in one pass |
| [painter/engine/paint.s](painter/engine/paint.s) | paints the places onto the hidden screen, lowest height first, the sprites in their turns |
| [painter/engine/sprites.s](painter/engine/sprites.s) | the painter's sprites: each one's turn and place, and drawing it |
| [painter/engine/present.s](painter/engine/present.s) | the two screens: clears the hidden one, and switches to it at the interrupt once it is painted |
| [rays/demo.s](rays/demo.s), [rays/build.py](rays/build.py), [rays/check.py](rays/check.py) | the ray renderer's program, build and check |
| [rays/engine/cast.s](rays/engine/cast.s), [tiles.s](rays/engine/tiles.s), [scroll.s](rays/engine/scroll.s), [map_steps.s](rays/engine/map_steps.s) | Tom Harte's caster, tile drawer, scrolling and map-address macros, each saying what isoblocks changed |
| [rays/engine/ray_view.s](rays/engine/ray_view.s) | the ray view: the focus, and which of his moves (or a whole cast, or nothing) each frame needs |
| [rays/engine/ray_sprites.s](rays/engine/ray_sprites.s) | the ray renderer's sprites, depth-tested against the heights |

A map is JSON: named boxes, each setting (or with `"cut"` clearing) a range
of heights over a rectangle of cells, in the order listed. The view never
reads off the edge of the map -- the camera is held back instead -- so a map
keeps an empty border of about 22 cells for the view to show.
