# exile

An Exile-like for the 48K Spectrum: not a port of Peter Irvin and Jeremy
Smith's BBC Micro game, but a game in its spirit -- a big cave planet, a
jetpack with real momentum, and (to come) creatures and objects that obey the
same physics as you do. This is the first prototype: the planet and the
astronaut, nothing else yet.

Keys: **Q** thrust, **A** push down, **O** left, **P** right.

## Build and run

Launch **"ZX Spectrum: Exile-like"** from the Run and Debug view; its
`preLaunchTask` builds first. By hand:

```powershell
.\.venv-win\Scripts\python.exe examples\exile\build.py
```

It needs `sjasmplus`, found the same way as filmation's build (`SJASMPLUS`,
`tools/sjasmplus/`, then PATH). It writes `output/exile.sna`, with
`exile.sld`, `exile.lst` and `exile.sym` beside it. `output/` is gitignored.

No game data comes from anywhere but this folder -- there is nothing of the
original Exile in it.

## How it works

**The planet is worked out, not stored.** `world.txt` is a coarse map, 32 x
32 regions of sky, cave, rock, water and built masonry, each 128 pixels
square. Under it is a lattice of 256 x 256 *corners*, each rock or open: a
corner takes the kind of its region, but looked up from a point nudged a few
corners off along a smooth random walk, so the straight edges between regions
become wandering cave walls. Masonry and chambers skip the nudge and stay
straight. Between every four corners is a 16 x 16 pixel tile, one of sixteen
shapes chosen by which corners are rock (marching squares), drawn with a
rounded edge -- so walls run diagonally and curve rather than step. The
whole planet is 4096 x 4096 pixels from 1K of map and two 256-byte tables.

`world.py` is the reference for the rule, in the same integer arithmetic the
Z80 uses. `preview.py` draws the whole planet (`output/world.png`) or a
stretch of it at full size (`--at TX TY`) without running the game.

**Drawing.** The landscape is one colour, cyan. The view is 32 x 20
characters; it moves in whole characters, so every cell on screen is a
quarter of one tile and drawing it is an eight-byte copy. There is no back
buffer: the astronaut is taken off by redrawing the 3 x 3 cells he covered,
and drawn masked, with a black outline, in bright yellow -- the colour of the
cells he is in, which is where the Spectrum's colour clash shows.

**The astronaut** has a position in pixels plus a byte of fraction, and a
velocity in 8.8 fixed point. Each frame adds gravity, thrust and drag, then
moves him a pixel at a time along each axis, testing points round his body
against the tiles' collision masks -- which are the drawn rock itself, to
the pixel. With his feet down he walks up steps of up to two pixels, so he
can climb gentle slopes. Hitting a wall or landing hard bounces him back at a
quarter of the speed.

**The view jumps**, as Exile's did: when he comes within 48 pixels of a side
or 32 of the top or bottom, it recentres on him and is redrawn.

| Source | What |
|---|---|
| `exile.s` | Memory map, start-up, the main loop, the interrupt |
| `world.s` | The corner rule and the tile shapes under the view |
| `render.s` | Drawing the view and single cells; screen addressing |
| `player.s` | Keys, forces, collision, the view following him, his sprite |
| `hud.s` | The panel: position, and frames per pass of the main loop |
| `world.txt` | The coarse map |
| `world.py`, `tiles.py`, `sprites.py` | The rule, the tile art and masks, the sprite and its pre-shifts |
| `build.py`, `preview.py`, `png.py` | Build, preview, and a PNG writer with no dependencies |

## Where it stands

Measured in this emulator, in T-states (a frame is 69,888):

| | |
|---|---|
| A view jump (`render_view`) | about 276,000 -- four frames: 100K working out the corners, the rest drawing 640 cells |
| A frame of play (physics, sprite off and on, panel) | about 34,000 -- 50 frames a second, with half a frame spare |

Checked by assembling it and driving it headless from the emulator core:
the corner and tile windows match `world.py` exactly, every landscape pixel
on screen matches `tiles.py`, and over long random key sequences his body
never ends up inside rock.

Not done yet, roughly in the order they are worth doing:

- **Smooth scrolling.** The jumps cost four frames each. A view that scrolls a
  character at a time from a buffer, at 25 frames a second, is the likely
  next step; working out only the corners a jump does not already have would
  roughly halve the jump either way.
- **Objects**: things to pick up, carry and throw, with mass, sharing the
  astronaut's physics -- and Exile's trick of keeping only the nearby ones
  live and parking the rest in a compact list.
- **Creatures**, and something to shoot them with.
- **Water and wind**, which world.txt already marks out.
- Tile variety: more than one texture, so different parts of the planet look
  different.
- The panel uses the ROM's character set and is blank without a ROM.
