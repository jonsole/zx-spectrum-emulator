# exile

An Exile-like for the 48K Spectrum: not a port of Peter Irvin and Jeremy
Smith's BBC Micro game, but a game in its spirit -- a big cave planet, a
jetpack with real momentum, and (to come) creatures and objects that obey the
same physics as you do. This is the first prototype: a planet built from
hand-placed blocks, scrolling smoothly, and the astronaut, nothing else yet.

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

**Scrolling.** The view, 256 x 128 pixels (the top 16 character rows, the
panel below), follows him smoothly: a pixel at a time up and down, four
pixels at a time across, keeping him in the middle. It runs at 25 frames a
second -- every other frame the whole view is copied to the screen.

The copy is the PUSH method: the view lives in a back buffer, and a screen
line is copied by pointing SP at the buffer and POPping sixteen bytes into
all eight register pairs, then pointing SP at the screen and PUSHing them
back -- the fastest way a Z80 has of moving bytes. The code is the same few
lines unrolled, written by `build.py` into `output/blit.s`; the 128 lines
take about 69,000 T-states.

That is most of a frame, so the copy has to race the beam. It may start any
time from the beam reaching the top of the view -- the program reads the
floating bus, port 0xFF, which returns 0xFF while the beam is in the border
-- to about 44,000 T-states into the frame: always behind the beam on this
frame, so nothing the beam has still to show changes under it, and ahead of
it on the next, so the next frame shows the new picture whole. His physics
runs before the copy, in what would otherwise be time spent waiting for the
beam. A +2A or +3, which has no floating bus, falls back on waiting about as
long as the top border.

**Four pixels across.** A Spectrum byte is eight pixels, so moving the view
less than a character means shifting every byte -- far too slow to do to the
whole view every frame. Instead there are two buffers: BUF0 holds the view
on whole characters, BUF4 the same four pixels on, each byte the right half
of one character and the left half of the next. On a whole character the
copy reads BUF0, half way through one BUF4. Two-pixel steps would take four
buffers, and with a 16K map there is not the memory.

Each buffer scrolls itself, so nothing is redrawn that has not just come into
view. A buffer is a ring of 128 rows of 48 bytes: the view's 32 columns, and
the first 16 of them again, so each sixteen-byte half of a screen line runs
on unbroken from wherever the view starts. Moving down a pixel writes one
new line into both buffers -- BUF4's made from BUF0's with one RLD a byte.
Moving four pixels across writes one new column, always into the buffer that
is not being shown: right onto half way through a character, BUF0 moves on a
column; right onto a whole one, BUF4 does. A column goes through unrolled
copies (`output/columns.s`), BUF4's ORed from the blocks pre-shifted four
pixels each way (`block_hi`, `block_lo`).

A pass can afford a column and three lines, or six lines, or two columns,
but not all at once, so the view catches him up in turns: normally a step
across when he has moved on one, with fewer lines that pass; and when it has
fallen far behind (he moves up to six pixels a pass), it spends a pass
catching up whichever way it is further behind.

**The astronaut** is drawn into the buffer before the copy and taken out
after it, so the copy carries him and he never flickers: masked, with a
black outline, in bright yellow -- the colour of the cells he is in, which
is where the Spectrum's colour clash shows. His colour moves just after the
copy, before the beam reaches him, so colour and pixels change together.

He has a position in pixels plus a byte of fraction, and a velocity in 8.8
fixed point. Each 50th of a second -- twice a pass, before the copy -- adds gravity, thrust
and drag, then moves him a pixel at a time along each axis. A step can only
take him into rock through the row or column of his body he steps into, so
that edge is all a step tests, against the blocks' collision masks: a row
from `block_mask`, a column from `block_cols`, which holds each block's
solidity column by column as 16-bit words. With his feet down he walks up
steps of up to two pixels, so he can climb slopes. Hitting a wall or landing
hard bounces him back at a quarter of the speed.

**Memory.** It is nearly all used. The stack from 0x5B00 (sjasmplus's
start-up stack sits at 0x5D58); the map, whole, at 0x5E00 to 0x9DFF; the two
buffers, 6K each, at 0x9E00 to 0xCDFF; code and tables from 0xCE00 up to the
interrupt table at 0xFE00, with a few hundred bytes free. What is read
hardest -- the buffers, the code, the blocks -- is above 0x8000, out of the
memory the ULA contends for.

| Source | What |
|---|---|
| `exile.s` | Memory map, start-up, the main loop, the interrupt |
| `map.s` | Finding a block in the map |
| `render.s` | The two scrolling buffers, filling them, him in them, his colour, waiting for the beam |
| `player.s` | Keys, forces, collision, where the view should be |
| `hud.s` | The panel: position, and frames per pass of the main loop |
| `map.txt`, `blocks.png`, `blocks.json` | The planet and its blocks |
| `planet.py`, `blocks.py` | Reading and checking them |
| `sprites.py` | The astronaut, and his pre-shifted copies |
| `build.py`, `preview.py` | Build (including the unrolled copy and column fills), and draw the map without the game |
| `seed_map.py`, `seed_regions.txt`, `make_blocks.py` | How the first map and block set were made |

## Where it stands

Measured in this emulator, in T-states (a frame is 69,888, a pass two):

| | |
|---|---|
| The copy (`blit_view`) | about 69,000 |
| A new line, in both buffers | about 5,500 |
| A new column | 10,000 to 17,000, depending on the buffer and whether the column is held twice |
| His physics, one 50th of a second | 7,000 to 13,000 |
| A whole pass | under 140,000 -- 25 frames a second -- on over 99% of passes in long random runs; the rest take a third frame |

Checked by assembling it and driving it headless from the emulator core:

- every pixel and colour of the view on screen, and every byte of both
  buffers, matches `map.txt` drawn with `blocks.png`, at whole-character and
  half-character positions;
- over thousands of passes of random keys no pixel of his body was ever in
  anything solid;
- every frame the emulator displayed while scrolling over rock showed the
  view from one position only -- no frame was torn. The same check, run with
  the wait for the beam taken out, finds a third of the frames torn, so it
  does see tearing when there is some.

This emulator does not model the ULA's memory contention, and the copy writes
to the screen while it is being displayed -- on a real Spectrum it will be
slower, and whether it still stays ahead of the beam needs checking on
contended timing.

Not done yet, roughly in the order they are worth doing:

- **A map editor.** `map.txt` is edited as text, with `preview.py` to see it;
  a block-painting editor in VS Code, like filmation's room designer, would
  be kinder.
- **Objects**: things to pick up, carry and throw, with mass, sharing the
  astronaut's physics -- and Exile's trick of keeping only the nearby ones
  live and parking the rest in a compact list.
- **Creatures**, and something to shoot them with.
- **Water and wind.** Water blocks are drawn but do nothing yet.
- The panel uses the ROM's character set and is blank without a ROM.
