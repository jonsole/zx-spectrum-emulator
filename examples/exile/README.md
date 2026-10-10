# exile

An Exile-like for the 48K Spectrum: not a port of Peter Irvin and Jeremy
Smith's BBC Micro game, but a game in its spirit -- a big cave planet, a
jetpack with real momentum, and (to come) creatures and objects that obey the
same physics as you do. This is the first prototype: a planet built from
hand-placed blocks, and the astronaut, nothing else yet.

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

## Building the planet

The planet is a grid of **blocks**, 16 x 16 pixels each, placed by hand:
128 x 128 of them, 2048 pixels each way, about 8 x 13 screens. Two files
make it, and both are meant to be edited:

**`map.txt`** -- the planet, one character per block, a row per line between
two `|`s (so an editor that strips trailing spaces cannot shorten a row).
Lines that do not start with `|` are comments. Change a character, rebuild,
and the planet has changed. `preview.py` draws the whole map to
`output/map.png` (add `--grid` for a line round every block, `--scale 4` to
see it all at once), so you can look at an edit without running the game.

**`blocks.png` and `blocks.json`** -- the block set. The PNG is the art,
eight blocks to a row, each in a magenta frame; slots up to 64 are drawn
empty, ready to paint in. A pixel's colour says both what is drawn and what
is solid:

| Colour | Drawn | Solid | For |
|---|---|---|---|
| black | no | no | open space |
| white | yes | yes | rock's lines |
| grey | no | yes | rock between the lines |
| green | yes | no | grass, water: things in front |

The astronaut collides with exactly the white and grey pixels. `blocks.json`
lists the blocks in the sheet's order -- block 0 must be the empty one --
and gives each a name and the character `map.txt` places it with.

The blocks to start with:

| Char | Block | Char | Block |
|---|---|---|---|
| (space) | empty | `#` | rock |
| `L` `J` | slopes, solid lower left / lower right | `F` `7` | slopes, solid upper left / upper right |
| `_` `^` | rock, bottom / top half | `[` `]` | rock, left / right half |
| `` ` `` `'` | small corners, upper left / upper right | `,` `.` | small corners, lower left / lower right |
| `=` | brick | `%` | earth |
| `+` | metal plate | `~` | water (not solid yet) |
| `"` | grass | | |

To add one: paint it into a free slot of `blocks.png`, add an entry to the
end of `blocks.json` with a character no other block uses (not `|`), and use
that character in `map.txt`. The build stops, naming the block and pixel or
the map line and column, on a colour that is not one of the four, a
character that is no block, or a row of the wrong length.

The map was seeded from the caves the first prototype generated
(`seed_map.py`, from the coarse regions in `seed_regions.txt`), so there is
something to edit rather than a blank planet. Both scripts are kept for the
record and refuse to overwrite their files without `--force` --
`make_blocks.py` drew the first block set the same way.

## How it works

**Drawing.** The landscape is one colour, cyan; things drawn but not solid
are drawn in it too. The view is 32 x 20 characters; it moves in whole
characters, so every cell on screen is a quarter of one block and drawing it
is an eight-byte copy, straight from the map. There is no back buffer: the
astronaut is taken off by redrawing the 3 x 3 cells he covered, and drawn
masked, with a black outline, in bright yellow -- the colour of the cells
he is in, which is where the Spectrum's colour clash shows.

**The astronaut** has a position in pixels plus a byte of fraction, and a
velocity in 8.8 fixed point. Each frame adds gravity, thrust and drag, then
moves him a pixel at a time along each axis, testing every pixel of his
body, 8 x 15, against the blocks' collision masks. With his feet down he
walks up steps of up to two pixels, so he can climb slopes. Hitting a wall
or landing hard bounces him back at a quarter of the speed.

**The view jumps**, as Exile's did: when he comes within 48 pixels of a side
or 32 of the top or bottom, it recentres on him and is redrawn.

**Memory.** Code and tables from 0x8000; the map, whole, at 0xB800 to
0xF7FF; the stack and the interrupt table above it. About 6.5K is free
below the map.

| Source | What |
|---|---|
| `exile.s` | Memory map, start-up, the main loop, the interrupt |
| `map.s` | Finding a block in the map |
| `render.s` | Drawing the view and single cells; screen addressing |
| `player.s` | Keys, forces, collision, the view following him, his sprite |
| `hud.s` | The panel: position, and frames per pass of the main loop |
| `map.txt`, `blocks.png`, `blocks.json` | The planet and its blocks |
| `planet.py`, `blocks.py` | Reading and checking them |
| `sprites.py` | The astronaut, and his pre-shifted copies |
| `build.py`, `preview.py` | Build, and draw the map without the game |
| `seed_map.py`, `seed_regions.txt`, `make_blocks.py` | How the first map and block set were made |

## Where it stands

Measured in this emulator, in T-states (a frame is 69,888):

| | |
|---|---|
| A view jump (`render_view`) | about 176,000 -- two and a half frames, drawing 640 cells |
| A frame of play (physics, sprite off and on, panel) | up to about 36,000 -- 50 frames a second, with half a frame spare |

Checked by assembling it and driving it headless from the emulator core:
every landscape pixel on screen matches `map.txt` drawn with `blocks.png`,
and over long random key sequences no pixel of his body ends up in anything
solid.

Not done yet, roughly in the order they are worth doing:

- **Smooth scrolling.** The jumps cost two and a half frames each. A view
  that scrolls a character at a time from a buffer, at 25 frames a second,
  is the likely next step.
- **A map editor.** `map.txt` is edited as text, with `preview.py` to see it;
  a block-painting editor in VS Code, like filmation's room designer, would
  be kinder.
- **Objects**: things to pick up, carry and throw, with mass, sharing the
  astronaut's physics -- and Exile's trick of keeping only the nearby ones
  live and parking the rest in a compact list.
- **Creatures**, and something to shoot them with.
- **Water and wind.** Water blocks are drawn but do nothing yet.
- The panel uses the ROM's character set and is blank without a ROM.
