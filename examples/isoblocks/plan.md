# Plan: an isometric block engine for the 128K

Status: **stage 1 works, is faster, and has a second renderer to compare, 2026-09-25** (uncommitted). The painter now draws onto the 128K's two screens, with no copy. This file is the brief
for the sessions that do the work: what is decided, what is proposed, and what
is still the user's to choose.

## Stage 1: done

`python build.py` makes `output/demo.z80` (128K): Q/A/O/P move the view about
maps/test.json, 1-4 turn it. `python check_render.py` draws 28 frames -- four
views, seven foci, some far off the map for the camera to pull back in -- in
SkoolKit's simulator and compares each with isogeom.py's model: the places,
and every byte of the screen. All 28 match.

Measured (T-states per frame, the simulator's clock; the live profiler agrees
to within the scene): on the test map 276k on average; on **Antescher's own
map**, loaded into a local build only, 259k-370k averaged over the four views
at the four places Ant Attack was profiled at -- where Ant Attack takes
498k-585k with six heights to our eight. Split at the busiest place (the
pyramid): reading and sorting 77k, painting 216k (CPIR scanning about 70k of
it, blocks the rest), copying and clearing 94.5k.

## Speed-ups: done (2026-09-25)

Each step checked by check_render.py (every frame still identical to the
model, pixel for pixel) and timed; the last also checked live, 60 frames
compared with the model on a running emulator with its interrupts on.

| On Antescher's map, average of 4 views | stage 1 | now | Ant Attack |
|---|---|---|---|
| The gate | 259k | 225k | 498k |
| The middle | 290k | 260k | 523k |
| The pyramid | 370k | 318k | 555k |
| The far corner | 284k | 258k | 585k |

On the test map the average frame went from 276k to 232k, and a live walk
about it from 324k to 293k a frame.

- **Blocks covered whole are left out** (sort_places). The place a row up
  holding something higher, and the two a half-row down holding something as
  high, cover a block exactly; with all three, it is not drawn. It cannot
  change the picture, since what covers a block is painted later.
- **No CPIR passes.** One pass over the places sorts them into sixteen lists,
  a height and a page each, already in painting order; painting walks the
  lists. The painter's cost follows the blocks drawn, not heights x 512.
- **Filled cells swap register sets** (read_view): the place and the step a
  height up live in the other set, so reaching solid is an EXX.

Tried and taken out: **drawers that leave out part of a block.** A drawer per
set of covering places, generated from the picture, drew only the bytes the
covers would not paint over. It drew less (painting fell about 7k on
average), but choosing among eight meant testing all three covers for every
block, where whole-block culling stops at the first uncovered side -- and on
Antescher every place got slower (the pyramid 327k to 342k).

Where the frame goes now, at the pyramid: copying and clearing 94.5k (fixed),
painting 131k (a block is 775 T-states of drawer and about 145 around it),
sorting 45k, reading 63k. What is left is harder won:

- **Copying**, 16 T-states a byte. POPping the buffer and PUSHing to the
  screen would be about 13, but the unrolled code for 128 lines runs to
  6K, and an interrupt's pushes onto the screen have to land somewhere they
  are painted over -- possible if the lines are written bottom-up.
- **Clearing only what was drawn**, and copying only rows that changed: a
  win for sparse views, nothing for the dense ones that set the frame rate.
- **The block picture.** Its outline makes 12 of its 32 bytes part-clear
  (28 T-states each against 10). Art with fewer would draw faster.

## The ray renderer: a prototype (2026-09-25)

The user pointed at Tom Harte's Isometric-Ray-Cast
(github.com/TomHarte/Isometric-Ray-Cast): no overdraw, a ray per pair of
triangles, the map shifted so that one byte holds a whole line of sight. Its
repository has no licence file; the user says it is public domain. The
prototype was written from its README, again for isoblocks' axes, before its
source was read; none of its code is used.

- `raycast.py` is the model. `check_ray.py` first proves the rules: painting
  every cube of the map with a block made of the same triangles gives the same
  picture as the rays, pixel for pixel (9 views of 9). Then it runs the Z80
  (`engine/ray.s`, `demo/ray_demo.s`) against the model: 21 frames of 21,
  pixel for pixel, including a walk where most tiles are left as they were.
- The Z80 reads a **ray map**, the nearest height on each line of sight, made
  by the build; walks the diamonds along the shifted map's rows, where each
  reads two cells, not four; has a fast path for open floor; writes
  triangles, then makes each character cell's tile number with
  T xor ((T xor B) and $0F) and copies only tiles that changed.

On Antescher's map, view 0, T-states a frame:

| | painter | rays, walking | rays, cold |
|---|---|---|---|
| The gate | 215k | 144k | 247k |
| The middle | 269k | 178k | 252k |
| The pyramid | 310k | 199k | 256k |
| The far corner | 272k | 136k | 253k |

Walking -- the view moving a cell at a time, as it does in play -- the rays
are 1.35 to 2 times the painter's speed; a cold frame, every tile redrawn
(after a jump), is about the same. Live, on the test map, a walk ran at about
145k a frame against the painter's 293k. The cast is about 83k whatever the
scene; the rest is copying changed tiles, 240 T-states each.

What it costs, and what is not done:

- **The look.** Faces are flat patterns by triangle -- a top, a left face and
  a right face -- so there are no per-block outlines, and a wall reads as one
  solid shape. The patterns are in raycast.PATTERNS; the tiles are generated
  from them.
- **One view.** The shifted map, and the ray map, suit one viewing direction.
  Four views need four ray maps (64K) -- room enough on a 128K.
- **A moving map** has to update the ray map as well: when a cube is set or
  cleared, the nearest height on its line of sight may change. That is one
  byte: a cube is on exactly one line of sight, so it is the nearest height
  of that line's 8 cells, recomputed.
- **Sprites**: see below.

### Tom Harte's source, read (2026-09-25)

`src/cast.asm`, `drawtiles.asm` and `scroll.asm`, at commit 6d48476
(2023-03-16). How his version differs from ours:

- **Casting a diamond.** He reads four cells of the swizzled map (front,
  left, right, back), each through a highest-bit table, stepping between them
  with address macros (24-54 T-states each), and picks each half's colour by
  comparing the highest bits. We read a ray map the build has already
  reduced to the nearest height, and, walking along a row, share two of the
  four reads with the diamond before. A full cast of ours costs less a
  diamond.
- **He does not cast a whole view each frame.** The triangle map is kept
  between frames. A scroll moves it with LDIR/LDDR (1,568 bytes for his 24
  rows) and casts only the row or column that came into view, in each of
  eight directions. With no scroll, nothing is cast. **This is what ours is
  missing**: ray_cast recasts the whole view, 83k, every frame, even when the
  view has not moved.
- **Drawing tiles** is the same as ours: the tile number made from three
  triangle bytes, each pre-shifted by band parity, compared with what is on
  screen, and the tile copied only if it differs. (His tiles are 8
  consecutive bytes; ours are one row a page. It comes to the same.)
- **Changing the map** is one byte in his swizzled map, since a cube is on
  exactly one line of sight -- and so, for us, one ray-map byte as well.

### His code as the base (2026-09-25)

The user chose to take his code and optimise it, rather than add his
scrolling to ours. `engine/harte_cast.s`, `harte_tiles.s`, `harte_scroll.s`
and `harte_macros.s` are his files; each says what isoblocks changed.
`engine/ray_view.s` is ours: it clamps the focus and picks, each frame, one of
his eight moves, a whole cast, or nothing. `engine/ray.s`, our own renderer,
is no longer built.

To run on isoblocks, his code needed only sjasmplus syntax and fitting: the
map is ours, shifted, with U mirrored (his x is our V, his y is 127 - U);
the tiles are ours, drawn from raycast.PATTERNS in his tile order; the view
is 16 rows. As it came, it matched the model in every frame, all eight moves
included. Then, each step checked the same way:

| T-states | as ported | cheaper map steps | no tiles when still | tile loop | unrolled copy |
|---|---|---|---|---|---|
| Whole cast | 205.6k | 138.0k | | | 138.0k |
| A move of a cell: cast | 33-47k | 29-40k | | | 25-35k |
| A move of a cell: tiles | 70-96k | | | 60-87k | 60-87k |
| A move of a cell: frame | 104-144k | 100-136k | | 90-128k | 86-123k |
| View standing still | 60.0k | | 0.3k | | 0.3k |

- **Cheaper map steps and reads.** His address macros keep x and y
  wrapping round the map, at 24-54 T-states a step, and each of a diamond's
  four reads went through a highest-bit table. Our view never reads off the
  map, so the steps are plain arithmetic (6 or about 26), and the map holds
  the nearest height + 1 already, which his cast compares the same.
- **No tiles when nothing was cast**: if the view has not moved, no triangle
  has changed, and no tile can have.
- **The tile loop**: only columns 1-30 (0 and 31 are black on black), and
  an unchanged tile costs one JR Z. His kept the screen pointer moving a
  column at a time on both paths.
- **The copy on a move**: sixteen LDIs (or LDDs) in a loop, entered part way
  for the remainder, instead of LDIR (16.6 T-states a byte against 21).

Against our own renderer: ours cast the whole view every frame, 83k, and a
move cost about 180k all told; his, now, costs 86-123k for a move and 0.3k
standing still. His whole cast is still dearer than ours was (138k against
83k) -- ours walked along the map's rows, sharing two of a diamond's four
reads with the one before -- but it is only needed after a jump. Not done:
that sharing in his rows, which would bring the whole cast down; and
nothing yet updates his map when the map changes (one byte a cube).

Sprites (below) were refitted to his layout: tile numbers and tiles as his,
output_map as RAY_SHOWN was, the depth test reading his map (+1 for a step
back along U, it being mirrored).

### Steady frames, and the second round (2026-09-25)

**The user wants steady frame times**: a game's pace follows its frame, so
skipping work when nothing has changed makes it lurch between still and
busy frames. So ray_tiles no longer returns early when nothing was cast: it
checks every tile every frame. (A skip for sprites when nothing had moved
was tried and taken out for the same reason.) The one difference left
between a still frame and a move is his cast, which has nothing to do when
the view has not moved. The target is the busy frame: a move with four
sprites in view inside two TV frames (141.8k T-states), for a steady 25
frames a second.

Then, each checked against the model (48 engine frames, 36 with sprites):

- **Edge columns cast half a diamond.** His columns keep one triangle of
  each diamond they cast, so cast_left_half and cast_right_half read three
  lines of sight, not four, and decide once: about 2k less a column.
- **Triangle rows a page apart** (build.py, the ray layout: $9F00 + 256r).
  A tile's three triangles are INC H apart instead of ADD HL,BC, and the
  tile it shows sits on its bottom triangles' page, SET 5,L away, instead
  of through IX: a tile left as it was costs 76 T-states, not 96. The
  scroll copies are a row at a time (SLIDE), costing about what one LDIR
  did.
- **Compiled tiles.** Each of the 124 different tiles is code storing its
  8 bytes down the screen (LD (HL),n, or LD (HL),B/C/E for $00, $AA and
  $55, INC H between), reached through a jump table by his tile number. The
  sprite buffers now keep a cell's rows a page apart like the screen's, so
  the same code draws a tile into a buffer, and the 1K tile table is gone.
  The code is packed into the unused parts of the triangle pages, with the
  sprite tables, the interrupt routine and the stack.

| T-states | before the round | now |
|---|---|---|
| A move of a cell, no sprites | 85.6-123.0k | 72.9-97.8k |
| The view still | 48.6k | 38.4k |
| Every tile redrawn | 165.1k | 123.8k |
| A move with four sprites in view | about 160-171k | 126.4-147.2k |

The four-sprite moves were over the 141.8k target only on the diagonals, by
up to 5.4k.

**Colours worked out by the build.** His cast_diamond compared four heights
to choose each half's colour -- about 230 T-states a triangle in his edge
columns. The choice depends only on the map, so build.py makes it once, by
his rule (his_colours), and his map now holds the answers: each byte the
colours of the diamond whose front line it is, the left half's in bits 7 and
4, the right half's in 6 and 3. A triangle is a read and AND $90 (with ADD
A,A first for a right half), and his rows and columns are single passes with
no calls. The heights, which only the sprites need, are a second map in bank
4; ray_cast pages bank 0 (the colours) in at $C000, ray_sprites_prepare
bank 4. Changing a block later will mean one height and the colours of the
four diamonds around its line of sight. Checked: all 48 engine frames and 36
sprite frames match, and live on the emulator, where the paging is real.

| T-states | before | now |
|---|---|---|
| A move's cast (slide, and the new edge) | 25.1-30.8k | 20.2-21.1k |
| A move, no sprites | 72.9-97.8k | 67.4-88.4k |
| A whole cast (a jump) | 137.5k | 46.1k |
| A move with four sprites in view | 126.4-147.2k | 118.9-138.4k |

Every move with four sprites is now inside two TV frames. What is left of a
move's cast is nearly all the slide (about 17k, LDI at 16 T-states a byte).
Next, if more room is wanted: the sprites (about 9.5k each) -- sort them once
a frame, trim a cell's setup and a strip's, and skip a picture's empty rows.

### Sprites for the rays (2026-09-25)

With no painting order to thread them into, sprites are depth-tested against
what the rays found (`engine/ray_sprites.s`, `raycast.render_with_sprites`).
A sprite stands in a cell at a height, like a cube, and its 16 x 16 picture
goes where that cube's would. If its top is diamond (c_s, r_s) at height h, it
is r_s + 3h deep; a triangle of band k whose winning nearness is n is
k + n - 3 deep. The sprite's pixels show there if n is 0 or
n < r_s + 3h + 3 - k. check_ray.py proves the rule: 60 of 60 sprites whose
picture is a block look exactly like that block put in the map. The Z80 then
matches the model in 18 of 18 frames: a figure walking past columns, under
the bridge and round the house, with three more sprites standing still.

Each frame, between ray_cast and ray_tiles, every character cell a sprite
touches is built in a buffer: its tile, then the sprites, farthest first.
Its tile is marked as shown, so ray_tiles leaves it alone, and the buffers
are written after ray_tiles. So a cell is written once and nothing flickers.
A cell that had a sprite last frame is marked to be redrawn.

What made it quick:

- **One test per line of sight.** Down a strip, a band's side line is the
  band before's own line, and its line above is the band before that's.
  The nearness offsets (3v, 3v - 1, 3v - 2) fall by one a band, just as the
  sprite's margin does. So each line has a single test when it is a band's
  own: it is empty, or 3v < deep - k. A band shows if its line and the two
  before passed. For a strip, that is one read and one compare per band,
  stepping +128 and -1 through the ray map with no multiply. A cell's three
  triangles come out of the last five tests with two ANDs.
- **A slot per cell** (RAY_SLOTS, beside RAY_SHOWN) says which buffer a cell
  has this frame, instead of searching the list.
- **An unrolled blend**, buffer xor ((buffer xor ink) and sprite and
  showing), 74 T-states a row. It works because each picture is stored with
  8 empty rows either side, so a cell never has to clip.

`ray_sprites_prepare`, the demo's four sprites (one to four on screen), in
T-states a frame:

| | least | most | average |
|---|---|---|---|
| First version: three triangle tests per cell, a list search, per-row arithmetic | 37k | 73k | 62.5k |
| Now | 16.5k | 30.8k | 24.1k |

Writing the buffers out takes another 2k. The whole frame on the test walk
averages 205k, down from 246k; most of it is ray_tiles (96k) and ray_cast
(83k). Limits: 4 sprites, and 24 cell buffers of 10 bytes, all in one page
(a sprite touches at most 6 cells). More sprites need more buffers, and a
cell past the last is left without its sprite.

## The painter on two screens (2026-09-25)

The painter no longer has a render buffer. It paints straight onto whichever
of the 128K's two screens is hidden (bank 5 at $4000, or bank 7 paged in at
$C000 over the map once read_view is done with it), and the interrupt
routine switches screens when a frame is ready. So the 69k copy is gone, and
the switch always falls between TV frames, where the copy used to race the
beam. `engine/present.s` has `clear_back` (wait for the last switch, page
bank 7 in if it is the hidden one, PUSH-clear the view) and `show_back` (page
the map back, ask for the switch).

- **Drawers in screen layout.** Each picture has two generated drawers: a
  first half-row's block starts 4 lines into a character row, and a second
  half-row's at the top of one, so each knows where it crosses character rows.
  Within a character row a line down is INC H (4 T-states, where the buffer
  took ADD HL,DE at 11). A crossing costs about 40, with a test for the next
  third.
- **The view moved down a character row**, to lines 16-143, so that the
  blocks reaching above it (from line 4) land on screen memory, not in bank
  2. Everything outside the view is black on black, so what lands there
  never shows and never needs clearing.
- **The clear stays interrupt-safe.** It runs from the top of memory down,
  third 2, then 1, then 0, so what an interrupt pushes lands on bytes still
  to be cleared, or at the very end on character row 1, which is never
  shown. The interrupt routine may push up to 64 bytes; it pushes 10.
- **The switch is interrupt-safe too.** show_back leaves the $7FFD value in
  show_next, and the interrupt writes it. The main loop only writes $7FFD
  while no switch is waiting. clear_back waits for the switch before it
  clears the screen that was showing, but read_view and sort_places take
  longer than a TV frame, so it hardly ever has to.

check_render.py paints every frame onto each screen: 56 of 56 match the
model, pixel for pixel. Checked live as well, with interrupts on.

The same 18-step walk as the rays' sprite measurements, T-states a frame:

| | read and sort | paint | copy and clear | frame |
|---|---|---|---|---|
| Painter, buffer and copy | 81.9k | 73.8k | 94.5k | 250.8k (179k-382k) |
| Painter, two screens | 81.9k | 75.3k | 24.0k (clear only) | 181.9k (109k-315k) |
| Rays, no sprites | | | | 180.8k (149k-242k) |

The painter is now level with the rays on average, and it keeps what the rays
give up: any block art, all four views, and sprites at a few thousand
T-states each rather than 12k. Its worst frames are still worse (315k against
242k), because its cost follows the number of blocks.

Not measured: on a real 128K, banks 5 and 7 are contended, and painting now
reads and writes them where the copy only wrote. The emulator does not model
contention yet, so real hardware will give back part of the saving.

## Another engine looked at: Boom Bot (2026-09-25)

Mark Woodmass's Boom Bot (2007, 48K), inspired by Ant Attack, with its
source on Spectrum Computing (no licence given in it, so ideas only, with
credit). Its world is one byte a cell (heights 0-7, a floating-block flag,
pickups, and the player and robots written into the cell) on a 233 x 64 map
with 256-byte rows. It paints every non-empty cell back to front, with no
depth test and no hidden-block culling, into a linear buffer copied to a
224 x 128 window. What is worth taking:

- **Actors in the map's cells**: a cell's own bits say an actor stands there,
  and it is drawn right after that cell's block, so depth order comes free.
  Our painter's lists could carry sprites the same way.
- **Masks as immediates**, only on the pointed end lines of a block, with
  LDD for the solid lines. Our drawers already mask only the part-clear
  bytes; the saving is in art with fewer of them.
- **One renderer for four facings**, by patching the map-walk opcodes. Ours
  does it with a table of steps, which comes to the same.
- **Near rows culled by height**: rows near the bottom skip blocks too low to
  reach the window.

## Decided (2026-09-24)

1. **Our own engine.** New code and new art, written from what the Ant Attack
   disassembly showed about *how* such an engine works -- none of Sandy
   White's code or graphics. It needs no Ant Attack tape to build and can be
   published. The ideas it borrows are credited below.
2. **A library first, then a small demo.** The game it is for is not decided
   yet, so the engine must not assume one.
3. **128K.**
4. **8 heights**, **one kind of block** to begin with, **draw into a buffer and
   copy it out** (since replaced: the painter draws onto the hidden one of
   the two screens), and the name **isoblocks**.

## Decided while designing stage 1 (2026-09-24)

- **The camera never looks off the map.** The view origin is clamped so every
  cell the view reads is inside the 128 x 128 map; a map carries its own empty
  border. That takes the range test out of every cell read -- the hottest loop
  there is.
- **Reading and sorting are one loop.** Each cell is read from the map with
  one add (the step between cells along a view's diagonal), and a cell with
  anything in it writes each of its heights straight into its place. There is
  no buffer of gathered cells and no second pass. The four views are one
  routine with three different steps.
- **The places have spare room either side** (seven rows of 32 below and
  above), so a height that lands outside the view is written there and never
  read, instead of being tested for.
- **The copy is interrupt-safe:** POP the buffer out, then PUSH zeros back
  from the top down. Whatever an interrupt pushes lands on bytes still to be
  cleared, so the game can keep its interrupts on for sound and pacing. (The
  copy has since gone; the clear on the hidden screen keeps the same rule.)

## What is borrowed, as ideas

From the Ant Attack disassembly (game-disassemblies, `build_antattack.py`),
credited to Sandy White's 1983 design:

- A map of cells, one byte a cell, one bit per height, so a wall is a column
  of set bits and the map can be changed at run time with a single XOR.
- Moving things written into the map, so that every collision -- walls,
  creatures, a bite -- is one map test.
- The projection: a cell (u, v) at height h is drawn 8(u + v) across and
  4(v - u) - 8h down, blocks 16 pixels wide.
- Drawing as a painter's algorithm over a table of places: sort the cells in
  view by height, paint the places lowest height first, and thread the sprites
  in by a running count, so that no sprite needs a depth test.

## Proposed design

Every number here is a starting point, to be measured in the emulator once it
runs; Ant Attack's frame was measured at 498-585k T-states, and the aim is
under 350k with the same view.

**Map.** 128 x 128 cells, a byte each, **8 heights** (Ant Attack uses 6),
16K: exactly one bank at $C000. A game can have up to five maps, one per spare
bank, and page between them.

**Memory.** Bank 2 ($8000-$BFFF) holds the engine, the render buffer, the
view tables and the game; the current map's bank is paged in at $C000 for the
whole of a frame. Sound runs from the interrupt on the AY, never as a busy
loop in the frame.

**The frame**, each stage built with what the Ant Attack profile taught:

| Stage | Ant Attack | Proposed |
|---|---|---|
| Read the cells in view | a CALL per cell, 80-93k | inline, stepping the map address by 129 along a diagonal, ~30k |
| Sort by height | six passes of 512, 110k | one pass in cell order, each block written to its place -- a later cell can only be a higher block, so it simply overwrites -- ~45k |
| Find the places to paint | CPIR, 81-85k | the same; it threads the sprites in for nothing |
| Paint blocks | unrolled code, 48-123k | the same idea, but the unrolled code is *generated* from a block picture by the build, so the art is editable |
| Copy to the screen, clear | LDIR, then a separate clear, 126k | one pass: POP a row, write it out, PUSH zeros back, ~80k |

**Art.** Blocks and sprites are our own, drawn as PNGs with a JSON beside them
(the repository's rule: committed data is editable, keyed by name). The build
turns each block picture into its unrolled drawer, one per pair of views.

**Objects.** A record per moving thing -- position, facing, fall count, flags,
frame -- and one movement routine for all of them: fall with a frame's grace,
jump, step up a one-block rise, stand on another object. Written fresh, to the
same rules.

**Pacing.** Unlike Ant Attack, the game loop waits for the frame interrupt, so
the game runs at the same speed however much is on screen. Faster drawing
buys time, not speed.

**Tests.** Unit tests per routine in `engine/tests`, run on the C++ core the
way the Filmation engine's are. The renderer is also checked whole: a scene
drawn by the engine compared with the same scene drawn by a Python model of it.

## Stages

1. **The renderer, on a still map.** Map in a bank, gather, sort, paint,
   copy; keys turn the view and move it. A test map in JSON. Measured in the
   emulator against the target.
2. **Objects and sprites.** Records, projection, the painter's threading, the
   movement rules, collisions through the map.
3. **A demo.** A small city, a character to walk about it, something to chase
   or collect; AY sound from the interrupt.
4. **Maybe a map editor**, in VS Code like the Filmation designer's, if the
   game that follows needs one.

## Open: the user's to choose

- **The name.** `isoblocks` is a placeholder.
- **Heights.** 8 costs one more painting pass a frame than 6, but buildings
  can be a third taller.
- **Kinds of block.** A map of height bits has room for only one kind of
  block. Walls of brick and walls of stone, or doors and windows, would need a
  second 16K layer (a kind per cell) and a drawer per kind.
- **The screen.** Settled 2026-09-25: the painter draws straight onto the
  hidden one of the 128K's two screens and switches at the interrupt (see
  "The painter on two screens").
