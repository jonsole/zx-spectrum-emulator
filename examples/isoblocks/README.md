# isoblocks

An isometric block engine for the 128K Spectrum: a city of blocks on a
128 x 128 map, eight heights, drawn from any of four sides. It is our own
code and our own art, written from what the
[Ant Attack disassembly](https://jonsole.github.io/zx-spectrum-disassemblies/antattack/)
showed about how Sandy White's 1983 engine works -- the map with a bit per
height, the projection, and painting the view by height with no depth test.
None of his code or graphics is used.

[plan.md](plan.md) is where it is going and what has been decided. So far
(stage 1) it draws a still map, and a demo moves and turns the view.

There are two renderers, to compare. The **painter** (`demo.z80`) paints
whole blocks lowest first, leaving out those covered whole, straight onto the
hidden one of the 128K's two screens, then switches screens; any block
picture will do. The **ray renderer** (`ray_demo.z80`) is built on
[Tom Harte's Isometric-Ray-Cast](https://github.com/TomHarte/Isometric-Ray-Cast)
-- his caster, tile drawer and scrolling, used as public domain, fitted to
isoblocks' map and made quicker. Each triangle of a fixed grid shows the
nearest cube on the lines of sight around it; the build works those colours
out for every diamond of the map, with his rule, so casting a triangle is a
read and a mask. The triangles are kept from frame to frame: when the view
moves a cell they slide along and only what has come into view is cast; and
only the character cells that changed are drawn, by compiled tiles. Flat-shaded faces, one view so far. Its demo has sprites: a figure
you walk about, which goes behind blocks and in front of them, and three more
standing still. plan.md has the measurements.

## Building and checking

```
python build.py          # -> output/demo.z80 and output/ray_demo.z80, with SLDs
python check_render.py   # the painter: every frame against the Python model, and timed
python check_ray.py      # the rays and sprites: the rules against the painter, the Z80 against the model
```

`build.py` needs Pillow and sjasmplus (the repository's copy in
`tools/sjasmplus/` is found automatically); `check_render.py` needs SkoolKit,
which is in the repository's venv. Load `output/demo.z80` into the emulator
with its SLD for source-level debugging. Q, A, O and P move the view along
the map's y and x; 1 to 4 turn it.

## What is where

| File | What |
|---|---|
| [engine/layout.s](engine/layout.s) | the numbers, and where everything lives in memory |
| [engine/view.s](engine/view.s) | the camera: which view, where it is centred, kept on the map |
| [engine/read_view.s](engine/read_view.s) | reads the cells in view and sorts them by height, in one pass |
| [engine/paint.s](engine/paint.s) | paints the places onto the hidden screen, lowest height first |
| [engine/present.s](engine/present.s) | the two screens: clears the hidden one, and switches to it at the interrupt once it is painted |
| [isogeom.py](isogeom.py) | the same geometry in Python: the view tables are made from it, and it is the model the check draws with |
| [art/blocks.png](art/blocks.png), [art/blocks.json](art/blocks.json) | the block picture, one per pair of views; the build turns each into an unrolled drawer |
| [maps/test.json](maps/test.json) | the demo's map, as named boxes of heights |
| [demo/demo.s](demo/demo.s) | the painter's demo |
| [engine/harte_cast.s](engine/harte_cast.s), [engine/harte_tiles.s](engine/harte_tiles.s), [engine/harte_scroll.s](engine/harte_scroll.s), [engine/harte_macros.s](engine/harte_macros.s) | the ray renderer: Tom Harte's caster, tile drawer, scrolling and map-address macros, each saying what isoblocks changed |
| [engine/ray_view.s](engine/ray_view.s) | the ray view: the focus, and which of his moves (or a whole cast, or nothing) each frame needs |
| [raycast.py](raycast.py) | the ray renderer's model, which check_ray.py holds the Z80 to |
| [engine/ray_sprites.s](engine/ray_sprites.s) | sprites for the ray renderer, depth-tested against what the rays found |
| [art/sprites.png](art/sprites.png), [art/sprites.json](art/sprites.json) | the sprite pictures: a figure and a ball |
| [demo/ray_demo.s](demo/ray_demo.s) | the ray renderer's demo: Q, A, O and P walk the figure, and the view follows |

A map is JSON: named boxes, each setting (or with `"cut"` clearing) a range
of heights over a rectangle of cells, in the order listed. The view never
reads off the edge of the map -- the camera is held back instead -- so a map
keeps an empty border of about 22 cells for the view to show.
