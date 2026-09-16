# filmation

A reimplementation of Ultimate Play The Game's "Filmation" engine — the
masked-sprite blitter behind isometric games like *Knight Lore*. Imported from
its own project tree (it was previously debugged under DeZog/CSpect); this copy
builds and runs against this emulator.

Unlike the other examples here it is a real, multi-file program, which is the
point of it being in the tree: `filmation.s` is the entry source and `INCLUDE`s
four others, so the SLD it produces maps addresses into five different files.
That is exactly the case a single flat line map gets wrong, and the regression
tests in `cpp-core/tests/symbol_tests.cpp` cover it.

## Build and run

Launch **"ZX Spectrum: Filmation"** from the Run and Debug view. The
`preLaunchTask` assembles it first, so editing any `.s` file and relaunching
runs what you just wrote. To build it by hand:

```powershell
.\.venv-win\Scripts\python.exe examples\filmation\build.py
```

Add `--debug-room` to print the room number in the top-left corner, for
finding your way about; the ordinary build leaves it out.

That needs `sjasmplus` — `tools/sjasmplus/sjasmplus.exe`, or anywhere on PATH.
It writes `output/filmation.sna` (from the `SAVESNA` at the bottom of
`filmation.s`), plus the `.sld` the debugger maps source lines with and a
`.lst` listing. `output/` is gitignored; everything in it is regenerated.

## Source layout

`filmation.s` is the entry point and includes the rest in order:

- **filmation.s** — `ORG`, screen setup, the demo loop (`start:`), the
  coordinate→screen-address routines (`screen_address`/`pixelAddress`) and the
  two 256-entry Y→address lookup tables.
- **sprite.s** — sprite tables and the width-specific blit routines:
  `sprite_jump_table` trampolines into `sprite_blit_N_of_M`, and
  `sprite_rotate_table` holds 8×512 bytes of precomputed bit-shifted values so
  a sub-byte X offset costs a table lookup rather than a shift loop.
- **object.s** — the object pipeline: `object_update` computes a bounding box
  and, when the sprite needs a sub-byte X shift, rotates it into that object's
  own shift buffer; `objects_draw_all` walks the object list, clips against the
  view extent and dispatches into the blitter.
- **vid_buff.s** — `vid_buff_copy_1`..`_8`, pushing the compact `view_buffer`
  out to real screen memory and handling the screen's third-based row
  addressing. Which one runs depends on the region width; see `copy_routines`.
  (`vid_buff_blit_5` alongside them reads an interleaved mask/data source and is
  not reachable from `copy_routines`.)
- **shift.s** — currently empty; included for future use.
- **sprite_data.s** — generated, not hand-written. `build.py` regenerates it by
  running `sprites.py` over `sprite_data.bin` whenever either is newer. Don't
  hand-edit it.

The central trick is that the blitter is unrolled and jump-tabled: rather than
branching on width/shift/height at runtime, an index is computed into a table
of specialised routines and jumped straight into. Most of the cleverness is in
address arithmetic, not control flow.

## What it does

`start:` fills the attribute area, places the scene and paints it once, then
loops over the moving objects, redrawing only the area each of them disturbs.

The scene is ten objects. Nothing authors the draw order — it is derived from
`U`, `V` and `Z`; see **Depth sorting** below.

| object | sprite | size | U, V, Z | box |
|---|---|---|---|---|
| `object_pillar` | 43 | 3×42 | 30, 66, 0 | 12, 12, 30 |
| `object_block1`..`6` | 20 | 4×28 | 90, 54, Z = 0, 12, … 60 | 16, 16, 12 |
| `object_player` | 44 | 4×29 | 60, V 20→110, 0 | 16, 16, 13 |
| `object_ghost` | 40 | 3×19 | a square, see below | 12, 12, 7 |
| `object_walker` | 4 | 3×23 | U 40→130, 70, 0 | 12, 12, 11 |

Positions are **world** coordinates, not screen ones. The player walks one floor
axis, which on screen is an isometric diagonal — up-and-right along V.

The ghost walks a **square** around the block stack: out along U, out along V,
back along U, back along V, one unit per frame, 60 to a side. Only one axis moves
at a time, so its screen position shifts a single pixel across and at most one row
down per frame, which is what keeps the union of its old and new extents inside
`VIEW_BUF_WIDTH`.

That square is the sharpest test of the depth sort in the demo. The ghost's depth
key `U - V` runs from **−24** at the far corner to **+96** at the near one, while
the stack's six cubes sit at 36, 48, … 96 — so over one lap the sort has to carry
the ghost from behind the entire stack to in front of five of its cubes and back
again, continuously:

| leg | movement | depth key | position in the list |
|---|---|---|---|
| out along U | | 38 → 94 | 3 → 7 |
| out along V | | 94 → 34 | 7 → 2 |
| back along U | | 34 → −22 | 2 → 1 |
| back along V | | −22 → 38 | 1 → 3 |

The six blocks are a stack: identical U and V, Z rising by `BLOCK_RISE`. The
sprite is 28 rows and its top face is a 32×16 diamond, leaving 12 rows of side —
so a rise of 12 puts each cube exactly on the one below. That 12 is also the
cube's `SIZE_Z`, which is what makes consecutive cubes *abut* rather than
overlap: `[0,12)` and `[12,24)` are disjoint, so U and V overlap alone and the
depth comparison comes out authoritative on Z. `U + V = 144` puts the stack at
screen x 128, the middle of the screen and a byte boundary, so none of them
needs a shift buffer.

`object_walker` is a third mover, added to find where the engine runs out of
frame rather than to look good — it crosses the stack along U at a V that puts
its dirty rectangle on the cubes for most of its run. See **Cost** below.

`object_table` lists every object; the startup loops walk that rather than the
`NEXT` chain, which now belongs to the sorted list and is empty during placement.
Note that `objects_draw_all` sets `IX` to its own `.next_object`, so
`redraw_object` returns with `IX` destroyed and the loops keep their own copy
across the call — getting that wrong sends the Z80 into screen memory.

## Depth sorting

[depth.md](depth.md) walks through `depth.s` routine by routine, with worked
examples; this section is the summary.

Draw order is a permanent invariant of the list, not something recomputed. When
an object moves it is unlinked and re-inserted in one pass; an object whose
step is zero costs one `OR` and nothing else. There is no sort.

This is Head Over Heels' design. Knight Lore instead rebuilds a list of dirty
objects every frame and repeatedly scans for one that nothing occludes, draws it
and restarts from the head — O(n²) at best, and since a "draw that one first"
decision discards the scan and restarts with a new candidate, O(n³) worst case,
bounded only by an 8-entry cycle stack.

**The comparator.** `depth_cmp` compares two solid boxes. On any axis where they
do *not* overlap, that axis's coordinate is part of the key; where they do
overlap the axis says nothing and contributes nothing. That single rule is
exactly Head Over Heels' seven-case dispatch table — their key is always the sum
over the non-overlapping axes — with no dispatch at all, and the eighth case
(all three overlapping, i.e. interpenetration) falls out as the empty sum.

The *signs* are ours, not theirs. `object_place` sends `+U` down the screen and
`+V` up it, so the projection's null direction — which for an orthographic
projection is the depth axis — is `(1,-1,1)`, and depth is **`U - V + Z`**. Head
Over Heels' `U + V + Z` comes from a projection where both floor axes descend.

**Two return values.** `depth_cmp` returns both an ordering (carry) and whether
that ordering is *authoritative* — true exactly when one axis separates the
boxes. The insert scan needs this because isometric depth is genuinely
non-transitive: A in front of B in front of C in front of A is constructible, so
there is no total order to sort by. The scan's insertion point therefore *lags*
its cursor: a merely-guessed ordering advances the cursor but is not trusted
enough to commit to.

**The list is doubly linked purely so unlink is O(1).** The reverse chain is
never used for drawing. `PREV` does not point at the previous object — it points
at the `NEXT` *field* that points at us, which is that object's own address
(`NEXT` is at offset 0) or `object_list` itself for the head. That removes the
"am I the head?" branch from both unlink and insert. Never dereference it as a
record.

**The dirty gate** is the step itself. `depth_step` adds a step to `U`, `V`
and `Z` and re-sorts only if the step was not zero, so the question is asked at
the one moment the answer is known. It must be the step really applied, which
for a character is the clamped `D`/`E` rather than the record's spent `DU`/`DV`
— see [depth.md](depth.md). It gates on the *world* position: the null
direction is `(1,-1,1)`, so `U+1, V-1, Z+1` changes an object's depth with no
screen movement at all.

**No extra repainting is needed.** A relink is a single-element permutation, so
it preserves the relative order of every other pair — two objects that did not
move cannot swap. An object's position in the list can only affect pixels it
covers, so the union of its old and new extents, which `redraw_moved` already
repaints, is exactly sufficient.

## Isometric world coordinates

`object_place` projects an object's `U`, `V`, `Z` to the screen, after Knight
Lore's `calc_pixel_XY` at `$D6C9`:

```
screenX = U + V - WORLD_X_ORIGIN
baseY   = WORLD_Y_ORIGIN - ((V - U + 128) >> 1) - Z
```

U and V are the two floor axes, Z is height, and the halving of `V - U` is the
2:1 isometric lozenge — a step along one floor axis moves a whole pixel across
and half a pixel down. The `+128` before the *logical* shift is a bias so a
negative `V - U` survives it, exactly as Knight Lore does.

Knight Lore renders into a linear buffer that `update_screen` (`$D56F`) copies
to the display **upside down**, so its pixel Y counts up from the bottom and
lands on the sprite's base. We draw straight into screen layout, so the row is
flipped back here — which is why Z is subtracted rather than added, and why
`object_update` now takes `B` as the sprite's **base** row and derives the top
as `base - height`. That is what makes `Z = 0` mean "standing on the floor".

`WORLD_X_ORIGIN`/`WORLD_Y_ORIGIN` are Knight Lore's `$80` and `$68` in spirit:
they say where the world origin lands on screen, and are ours to pick.

**Objects without a shift buffer must keep `U + V` a multiple of 8.** In world
coordinates a static object no longer lands on a byte boundary by luck, and an
object with no buffer cannot be rotated. `object_update` refuses rather than
rotating into a null pointer — it draws byte-aligned, up to 7 pixels left of
true. The origin is itself a multiple of 8, so keeping the sum aligned keeps
such objects exact.

The two static objects are placed **once**, before the loop: `objects_draw_all`
only ever reads a record, so their extents, blit index and sprite pointer stay
valid frame after frame. The two movers are updated every frame from a `MOVER`
record (`x`, `dx`, `min`, `max`) by `mover_step`.

## Redrawing only what moved

Nothing draws the whole screen. The objects are spread far enough apart that no
single view could hold them — the view buffer is `VIEW_BUF_WIDTH` bytes across
and the scene is most of the screen — so the loop redraws **per moved object**:

```
for each mover:
    extent_save         remember the extent it has now
    mover_step          move it
    object_update       recompute its extent
    redraw_moved        repaint the union of the two
```

`redraw_moved` sets `view_x_extent`/`view_y_extent` to the union of where the
object was and where it now is, then `redraw_view` clears just those rows of
the buffer, calls `objects_draw_all`, and copies the region to the screen. The
old half of the union erases the previous image; the new half draws it where it
is. Because `objects_draw_all` composites **every** object intersecting the
region, anything the mover passed over is put back in the same pass — which is
what makes the pillar and block reappear intact behind it.

The opening screen is built by placing all four objects and then calling
`redraw_object` (the same path, with no previous extent) once for each.

### The buffer is 8 x 64

The buffer's shape is the hard limit on how big a single object can be, so both
dimensions have to clear the whole sprite set:

- **Width.** A byte-aligned sprite spans *w* bytes and a shifted one *w+1*, and
  the union of two positions one pixel apart is never wider than *w+1*. The
  widest sprite in the set is 5 bytes, so a region peaks at 6 columns.
- **Rows.** The tallest sprite is 64 rows — the castle door arch; the forest
  one is 52.

It used to be 5 x 51, which failed both: the two door arches wrapped round the
end of the buffer and corrupted their own top and bottom, and the 5-byte block
had nowhere to put a shifted sixth column. 8 x 64 clears both with the stride a
power of two, which is what makes the row address a shift rather than a
multiply. Six columns would be tight enough to work and no cheaper: 6 x 64 is
384 bytes, still over a page, so the second page has to be handled either way,
and the multiply-by-6 costs more than the multiply-by-8 saves.

At 512 bytes the buffer no longer fits one page, so `inc e` will not address it
on its own. It does not have to, though. Rows are 8 bytes on an 8-byte boundary,
so the only address in the buffer where `E` wraps is a row start: everything
strictly inside a row stays `inc e`, and the row advance is the one step that
carries into `D`. `sprite_blit` folds the last column's step into that advance
rather than landing on the row's last byte at all — nothing is read between
them — which makes the crossing free and the walk cheaper than the stride it
covers. `objects_draw_all` gets the row address with three doublings and an
`rl d` that shifts a pre-halved base back up with the carry underneath it, which
is why `view_buffer` is `ALIGN 512`: it needs `high view_buffer` to be even.

One bound is left: `rows * width` must stay under 256, because the `vid_buff_*`
routines use `B` as the row counter while `LDI` decrements `BC` — a borrow out
of `C` would silently eat a row. That would now be reachable (64 × 8 is 512), so
the copy resets `C` every row rather than rely on the total.

The region width varies, so the copy is dispatched through `copy_routines`:
`vid_buff_copy_1..8`, one per column count.

The clear is sized to the region for the same reason. Blanking all 512 bytes
would cost 2816T every region, twice what the old 256-byte buffer did, and the
rows past the region are never read. `push de` is one byte, so where the run of
pushes is entered decides how much it clears — enter it `rows * 4` pushes from
the end. A 30-row region costs 1320T, under what the old flat clear cost.

## Building a room

The example no longer draws one hand-copied room. It builds any of Knight
Lore's 128 from the game's own data.

Knight Lore does not store rooms as lists of objects. It stores **templates**,
and a room is four bytes plus a handful of indices naming them. Room $B3 is:

```
room_B3:            DB      $06, 4, 0
                    DB      BG_ARCH_N, BG_ARCH_E, BG_ARCH_S, BG_WALLS_0
```

an attribute byte, a scenery count, an object-byte count, and four indices --
which expand to exactly the 19 objects that used to be pasted into
`filmation.s`. The attribute byte carries the room's colour in bits 0-2 and its
shape in bits 3 up; there are three shapes, `64 x 64 x 128` and two narrower
ones, and only the floor changes.

**Scenery** templates carry their own positions, so a piece is
`sprite, U, V, Z, size U, size V, size Z, flags` -- our object record almost
field for field, which makes the expansion a copy. **Object** templates carry
no position at all, so one block template serves every block in the castle;
their positions come from the room, one packed byte each, three bits of U,
three of V and two of Z, unpacked in `room_unpack`.

### Numbering sprites the game's way

The templates name Knight Lore's graphic numbers, so `sprite_table` is indexed
by those rather than by our own: 256 entries, several of which point at the
same bitmap. The game's table at `$7112` maps 186 valid graphics onto the 103
sprites we hold, and `graphic_map.bin` carries that mapping. At 512 bytes the
table no longer fits the `ld h,high sprite_table` a 128-entry one allowed, so
`object_update` doubles a pre-halved base instead -- the same trick the view
buffer's row address uses, and it needs the same `ALIGN 512`.

### Adjustments are harvested, not ported

Every sprite is nudged a few pixels so its artwork lines up with its logical
position. Knight Lore picks those inside **29 different per-graphic update
routines** -- it is behaviour, not a table -- so `adj.py` takes the values
rather than the code, driving a running game and reading the pairs out of live
object records. Ten rooms cover all 50 (graphic, mirrored) pairs the castle
uses. The result reproduces all 19 of room $B3's adjustments exactly.

Forcing a room needs no register writes: the frame loop ends with `JP $AFBD` at
`$B085`, one instruction past the room-entry call, so pointing it at `$AFBA`
makes the game rebuild whatever room `$5C10` names, every frame.

### What is not clipped

An object whose top runs off the screen is **dropped**. `MIN_Y` is a single
byte, so `base - height` wraps when a sprite is taller than its base row; the
region that implies is hundreds of rows tall, and the offset into the view
buffer overflows the one carry the row address can take, which puts the blit
outside the buffer entirely. It found this by overwriting the room templates.

Rooms with tall stacks lose a few objects to this. Clipping a sprite against
row 0 -- clamping the extent and starting the bitmap that many rows in -- is
the fix, and it has to work through the rotation path too, so it is its own
piece of work rather than a guard.

Foreground objects are placed but inert: no monster moves and nothing
animates. Placement is room generation; behaviour is not.

### The pipeline

Nothing here is hand-written:

| | |
|---|---|
| `kl_extract.py` | run once against your own game; writes `room_data.bin`, `graphic_map.bin`, `font.bin` and `specials.bin` (where the collectables start, and the order the wizard wants them) |
| `rooms.py` | `room_data.bin` -> `room_data.s`, and reports the fullest room, which sizes the object pool |
| `sprites.py` | `sprite_data.bin` + `graphic_map.bin` -> `sprite_data.s` |
| `adj.py` | a running game -> `sprite_adj.s` (committed: it cannot be rebuilt without the game) |

`build.py` regenerates the first three. The room data and the adjustment tables
live in contended memory at `$6000`: they are read when a room is built and
never again, which is where the game itself kept them.

## Mirroring

A wall running along U and the same wall running along V are one graphic seen
from two sides, and only one of them is stored. That is not a nicety — it is
most of why the artwork fits at all. Room $B3 has 19 objects drawn from 8
graphics, and **10 of those objects are mirrored**; six of the eight graphics
serve both orientations.

The mirror is horizontal, about the screen's vertical axis. Row order does not
enter into it, so nothing here has to know that `sprites.py` already turned
Ultimate's bottom-up rows the right way up. Knight Lore also has a vertical
flip, but no object in the game ever asks for one — every site touching the
flags byte uses `$40` — and only one sprite in our set (`sprite_014`, 4x32, not
used in this room) is stored upside down. So `sprite_flip_h` is all there is.

### One copy, mirrored where it lies

`sprite_flip_h` mirrors a sprite **in place** and records which way round it
now is in bit 0 of the sprite's own header. Objects share the bytes; nobody
keeps a second copy. Knight Lore does the same thing in `flip_sprite` ($D6EF).
The alternative — building mirrored copies into an arena at room load — costs
about 1.2 KB for this room alone and grows with every room, which gives back
exactly what mirroring was for.

The header has room for the flag because byte 0 is the blit index,
`(width - 2) * 32`, so bits 5-7 are the width class and bits 0-4 are spare.
Knight Lore keeps the same state in the same byte at bit 6, which is part of
the width field for us. Anything using byte 0 as a jump-table index masks it
with `BLIT_IDX_MASK` first; the width unpack does not need to, since it rotates
the class down and masks with 7 on the way past.

`sprite_flip_h` makes two passes over each row: the first reverses the bits of
every byte where it lies, the second swaps the columns end for end. Splitting
them is what keeps the second free of a special case for an odd middle column —
widths 1, 3 and 5 all occur — because a column with no partner is simply never
reached, and the first pass has already dealt with it.

### Sharing means checking at render time

Because the bytes are shared, an object that draws a graphic unmirrored can find
that another object has mirrored it since. So the orientation is checked **when
the object is about to be rendered**, not when it is placed. Two places do it:

- `object_update`, before the width is read and before `shift_sprite` rotates. A
  rotated copy is private to one object and nothing looks at it again, so it has
  to be taken from the orientation that object asked for.
- `redraw_orient`, walking the list immediately before `objects_draw_all`, for
  every object still drawing from the shared graphic.

`FLAGS` bit 5 says which of the two an object is: set by `shift_sprite`, cleared
on the byte-aligned path. `redraw_orient` skips the shifted ones — their
`SPRITE_L/H` points into a private buffer, so `SPRITE - 2` is not a sprite
header at all. For an unshifted object it is, because `SPRITE` is the record
plus 2 and records are `ALIGN 4`, so the two `dec l` cannot borrow.

`FLAGS` bit 0 is the orientation the object wants, in the same bit position as
`SPRITE_FLIPPED` in the header, so comparing them is a plain `XOR`.

### Why not inside `objects_draw_all`

That is where the check belongs by rights, and it will not fit. The routine
repurposes `SP` as its record pointer and reads the record as a sequential run
of `POP`s: `pop iy` takes NEXT, so `IY` holds the *next* object rather than this
one, and the record is reachable only through `SP`. `FLAGS` lands in `E` and the
sprite address in `HL'`, on opposite sides of a `jp (hl)` through
`sprite_jump_table` and an `exx`. `redraw_orient` runs at the same point in the
frame with a normal stack and free registers, and leaves the hot loop alone.

It applies the same extent cull `objects_draw_all` does. Without it, every object
in the room would be dragged into whichever orientation it wanted on every single
region, and objects sharing a graphic in opposite orientations would mirror it
back and forth for nothing.

### What it costs

Painting the room went from 301,113 T to 373,598 T, a one-off 24% on the opening
screen: 15 mirrors during the draw against a floor of about 11 (a graphic must be
turned once for each run of objects wanting the same side), plus `redraw_orient`
walking 19 objects for each of 19 regions.

Steady state is the cull walk, roughly 1.3 kT per region, and nothing else —
mirrors only happen when two objects sharing a graphic in **opposite**
orientations fall inside the **same** region. Dirty-rectangle redraw makes that
much rarer than it is in Knight Lore, which repaints every dirty object every
frame. This room never hits it: the three copies of graphic 71 are far apart.

Placement costs 14 mirrors, which is exactly the number of times the requested
orientation differs from the last one asked for, walking `room_data` in order.

## Shift buffers, one per movable object

An object at a sub-byte X offset is drawn by rotating its sprite into a buffer
first, and that rotated copy has to survive until the object is blitted —
which happens after *every* object has been updated. So the buffer cannot be
shared: with one between them, the last object to shift would overwrite what
the others had prepared, and they would all draw its bitmap.

Each movable object therefore carries its own buffer, as a `BUF_L`/`BUF_H`
pointer in its `OBJ` record. `object_update` rotates into that buffer and
points the object's `SPRITE_L/H` at it.

An object that is only ever drawn byte-aligned never reaches the shifting path
at all — its `SPRITE_L/H` point straight at the sprite's own bitmap — so it
needs no buffer and carries a null pointer. The pillar and block here allocate
nothing.

Records are declared with the `object_record` macro:

```
object_pillar:      object_record   0,           0,                   12, 12, 30
object_player:      object_record   OBJ_MOVABLE, player_shift_buffer, 16, 16, 13
```

`SHIFT_BUFFER_MAX` (416) is the worst case across this whole sprite set —
sprite 71, 3 bytes × 52 rows, needing `(width + 1) * 2 * height`. Sprites 5
bytes wide are not in that figure because they cannot be shifted at all:
`object_update` bumps `BLIT_IDX` by one width-class for the overflow column,
and `96 + 32` is past the end of `sprite_jump_table`. An object that only ever
uses one known sprite can be given exactly `(width + 1) * 2 * height` instead.


## Changed since the import

`object_update` computed `MAX_X` by adding the sprite record's first byte to
`MIN_X`. That byte is the *blit index*, `(width-2)*32`, not a width in bytes —
`sprites.py` changed the encoding and this was never updated — so `MAX_X` came
out far too large for anything wider than 2 bytes.

It survived on the right, where `extent_intersect` saturates and an over-large
`MAX_X` just reads as "extends past the edge". It did not survive elsewhere:
the overlap is taken as the smaller of the sprite width and the distance to
the view edge, so a **3-byte sprite at the view's left edge** got an overlap of
5 (the view width). The blit dispatch is `4 + overlap*4 + BLIT_IDX`, which for
overlap 5 in the 3-byte group lands on `sprite_jump_table` **padding** — it
jumps into `DB 0,0,0,0`, runs on through the `DW` as code, and a stray `PUSH`
writes over the object record, because `SP` is still pointing into it.

`MAX_X` is now `MIN_X + width`, exclusive, with the width unpacked back out of
the blit index; the shift path bumps it by one alongside the `BLIT_IDX` bump,
for the overflow column. This is a fix to the engine, not just to the demo —
it is a divergence from the original project tree.

Two further engine changes, both in `object.s`:

- `OBJ` gained `BUF_L`/`BUF_H`, and `object_update` now rotates into the
  object's own buffer instead of one shared `shift_buffer DS 512`. The shared
  buffer is gone. The new fields sit after `SPRITE_H`, so the sequence of
  `POP`s `objects_draw_all` reads a record with is untouched.
- An `object_record` macro and an `OBJ_MOVABLE` flag, so a record declares its
  own chaining, movability and buffer rather than being a bare `DW` plus
  padding.

## Cost

These figures were taken on the **demo scene**, which had three movers walking
around a stack of cubes. That scene is gone -- the example now draws a static
Knight Lore room -- and they predate both the 8 x 64 view buffer and mirroring,
so treat them as a profile of the drawing path rather than of what runs today.
The current numbers for the room are under "The buffer is 8 x 64" and
"Mirroring" above.

Measured on a cycle-accurate bus trace of one main-loop iteration, with three
movers: **95,494 T-states, or 1.37 of a 69,888 T frame.** With two movers it was
78,549 T (1.12 frames).

| | share |
|---|---|
| masked blits (14 survivors) | 32% |
| `object_update` (sprite rotation) | 32% |
| clip arithmetic + dispatch | 6% |
| view buffer -> screen copies | ~8% |
| `depth_cmp` | 7% |
| buffer clears | 5% |
| cull (16 of 30 object visits rejected) | 1.5% |

Two things worth knowing from that:

**The engine is shift-limited on how many things can move, not blit-limited.**
Each extra mover costs ~15,000 T of fixed overhead — rotation 10,100, buffer
clear 1,570, relink ~2,600, placement ~700 — plus ~2,300 T for every object its
dirty rectangle overlaps. Just over half of the marginal cost is the rotation.
In absolute terms the blits are the biggest single item; in *marginal* terms the
rotation is.

**The parts that can be optimised, have been.** The cull rejects an object for
75–133 T, near the floor for reading two extents through SP and four compares.
The clip path measures 394 T against 390 T hand-counted from the source, so
there is no slack in it. The blit runs at 36 T per composited byte, which is the
Z80's floor for a masked write (Head Over Heels' equivalent is 52 T, because it
keeps mask and data in separate planes and pays the pointer arithmetic).

Pre-shifting sprites would remove the rotation entirely, but only for objects
whose sprite does not change: pre-computing all eight alignments costs eight
rotations, so it pays only if an animation frame survives more than eight
movement steps. A character animating every two to four frames would do *more*
work, not less, regardless of how much memory was available for it.

These timings are **uncontended** — `cpp-core` does not model ULA memory
contention yet. The correction is small here because everything except the
screen writes lives above `0x8000`; the stack is explicitly moved to
`STACK_TOP` at startup for the same reason, since `SAVESNA` otherwise leaves it
at `0x5D56`, inside the contended window.

## Collision detection — notes for later

Not implemented. Written down while the profiling was fresh, because the design
is more constrained than it looks and one piece of it already exists.

### It is already latent in `depth_cmp`

`depth_cmp` counts separating axes in `B` and returns `ld a,b / dec a`:

| separating axes | `A` | meaning |
|---|---|---|
| 0 | `$FF` | **all three axes overlap — the boxes interpenetrate** |
| 1 | `$00` | the ordering is authoritative |
| 2 | `$01` | heuristic |
| 3 | `$02` | heuristic |

So `A = $FF` already uniquely identifies a collision, on exact world-space UVZ
boxes, and we compute it on every comparison and discard it.

That is not a quirk of this port. Knight Lore's ordering routine dispatches a
27-entry table on the three axis tests, and index 13 — overlap on all three
axes — is `objs_coincide` at `$CFE1`, which is exactly where "you walked into a
pickup" is detected: if either object is a collectable (`$60`..`$66`) it is
replaced with its collect animation on the spot. Collision falls out of depth
sorting.

The catch is coverage: `depth_cmp` only runs during a relink, and only against
the candidates that scan happens to visit. It is a source of free collision
*hints*, not a collision system.

### Any broad phase must be in WORLD space, not screen space

The obvious optimisation is to bin objects into screen sections, give each a
bitmask of the sections it touches, and reject pairs whose masks `AND` to zero.
A mask rather than a section *number*, so that an object straddling a boundary
sets both bits and `AND` means "share a section".

For collisions that must be binned on **U and V**, not on screen position. Two
sprites can overlap heavily on screen while being far apart in the world — that
is the entire point of the projection, and it is the common case — so a
screen-space mask would pass almost every pair and filter nothing.

### The numbers

Exact two-axis extent overlap, measured from the cull in `objects_draw_all`:
**75 T** to reject on the first axis, **133 T** having tested both, of which
about 48 T is list-walk overhead. The pure test is **~90 T**, and it is that
cheap only because the extents are already in the record and `pop` fetches an
axis for 10 T; written with `ld a,(iy+d)` instead it is ~140 T.

A mask test, both masks adjacent so one `pop` gets them and our own hoisted
into immediates the way `depth_cmp_setup` does:

```
pop bc                10   both masks at once
ld a,c / and <ourU>   11
jr z,miss              7   -- rejected for 28 T
ld a,b / and <ourV>   11
jr z,miss              7
```

**~46 T for both axes, ~28 T to reject on the first**, or ~27 T from a packed
array with no pointer chasing. Maintenance is ~150 T per moved object per frame
to recompute the masks from the extents.

Break-even is around `3.4 x movers` tests per frame:

- **The existing cull: never worth it.** 13 tests a frame against a rectangle;
  the upkeep eats the saving.
- **N-squared collision: comfortably worth it.** 13 objects is 78 pairs — about
  7,000 T exact against ~3,600 T masked, so ~3,400 T saved for ~450 T of upkeep,
  and the gap widens quadratically as objects are added.

A mask test is conservative — sharing a section is not overlapping — so it is a
filter in front of the exact test, never a replacement.

### When it is wanted

1. Split the three interval tests out of `depth_cmp` into a routine that answers
   only "do these boxes overlap". The arithmetic is already written.
2. Add world-space U/V section masks as the broad phase in front of it.
3. Optionally harvest `A = $FF` from the relink scan, remembering it only covers
   pairs that scan visits.

Deliberately not built yet: there is no consumer, so the upkeep would be pure
loss, and broad-phase filtering only starts paying once there are enough
pairwise tests to filter.


## The menu

`menu.s` is the screen the game starts and restarts at -- `start` calls
`menu_run` before anything else, and losing the last life comes back through
`start`, so the end screens lead back to the menu the way the game's own do.

Eight lines, in `end_show`'s shape: an attribute, a character row and column,
then the characters with the last carrying bit 7. The text, the colours and the
positions are the game's own (`menu_text`, `menu_colours` and `menu_xy` at
`$BDA2`), its bottom-up pixel coordinates converted to our rows and columns --
its `($58,$9F)` is our row 4, column 11. The last line is ours: the game prints
its copyright there, which would be false on this build.

Keys 1 to 4 choose the input method and 5 turns directional control over; the
chosen method flashes, and so does the toggle while it is on, which is bit 7 of
the line's attribute. 5 is a toggle rather than a choice, so it debounces. 0
starts the game.

The choice goes into `menu_mode`, in the layout the game keeps at `$5BA4`: the
method in bits 1 and 2, directional control in bit 3. **Nothing reads it yet.**
`player_step` still has Q, A, O and P wired straight in -- which is what
directional control on the keyboard amounts to -- so at the moment the menu
records a choice the game does not act on. Reading it means the input pass:
Kempston on port `$1F`, the cursor keys, Interface II, and the game's own
turn-and-walk scheme where left and right turn the knight rather than move him.

The tune is `tune_menu`, the 98 notes of `menu_tune` at `$B253`, played once on
the way in by the `tune_play` the end screens already had; any key cuts it
short, which is what `play_audio_wait_key` does with its flag at `$5BD1`. Three
of its notes -- `$16`, `$24` and `$25` -- were not in `tune_notes`, and their
half periods and beat lengths come from the same frequency table at `$B332` as
the rest.

The whole thing costs 408 bytes.

## Space — possibilities not yet taken

Every region is close to full. These are savings that have been looked at and
priced but not made, each with what it would cost.

### `pixelAddress` through the ROM's PIXEL-ADD

The 48K ROM's PIXEL-ADD at `$22AA` computes the same screen address as
`pixelAddress`, but its first three instructions (`LD A,$AF / SUB B / JP C,$24F9`)
turn BASIC's PLOT coordinates round — Y counted up from the bottom, only the top
176 rows, anything else "Integer out of range". Entered at **`$22B0`**, past
that, it takes the row counted from the top in A and gives the same address for
all 192 rows: H = `010 y7y6 y2y1y0`, L = `y5y4y3 x7x6x5x4x3`.

```
pixelAddress:   ld      a,b
                jp      $22B0       ; PIXEL-ADD, past BASIC's range check
```

- **Saves** about 18 bytes of the code region.
- **Same contract** as far as the callers go: C, DE and HL as before, B comes
  back as it went in (it copies A into it). It returns A = x AND 7 where ours
  leaves A = L; none of the four callers reads A afterwards.
- **Speed** is the same to within the extra jump: a similar number of
  instructions, and the ROM is never contended.
- **Cost:** the game depends on the 48K ROM's layout. The 128K's 48 BASIC ROM
  has the routine at the same address; any other ROM would break it silently.

### One rotate table instead of two

`sprite_rotate_table` holds two pages for each shift 1..7 -- `x >> s`, and the
bits that fall out of it, `(x << (8 - s)) & 255` -- which is 3,584 bytes, and
`object_update`'s rotation loop toggles between them with `inc h` / `dec h`.

The two halves are disjoint parts of one rotation: `rotr(x, s)` has `x >> s` in
its low `8 - s` bits and the fallen-out bits in the top `s`. One page a shift
would hold both, 1,792 bytes instead of 3,584.

- **Saves** 1,792 bytes of the code region -- far more than anything else left.
- **Cost:** the loop gets the two halves out of one byte with a mask each, so
  every lookup grows an `and`, and `or (hl)` -- which merges a byte with its
  neighbour straight from the table today -- has to become a load, a mask and an
  or. That is roughly +20% on the rotation, which the profiler puts at about 13%
  of a busy room's turn: call it 2.5% of the frame rate.

### Cold code into the room builder's region

`$5B00..$5FFF` holds `room.s` and `glance.s` and has 42 bytes free; the code
region has 1,029. Both are RAM the same CPU reaches, so anything cold enough not
to mind contended memory can move down there -- `end_at`, `end_attr_at` and
`end_seen` are about the right size together. It buys the code region those 42
bytes and costs nothing but the churn of splitting a file. The tune's timing
code must NOT go: it counts T-states.

### Hand the arena out by what it is worth, not by build order

`shift_alloc` gives buffers out in the order things ask for them, which is the
order the room builder happens to place them in. Nothing weighs what a buffer
is worth to the thing asking. At 4,992 bytes sixteen rooms go a piece or two
short, and which pieces go without is an accident of the room data.

What a buffer saves is the rotation, every time that object is drawn -- so it
is worth most to whatever is drawn most:

| | drawn |
|---|---|
| the knight | every turn, plus every region another object drags across him |
| movers | every turn they move |
| things shoved or carried | while they are moving |
| scenery | once per region that reaches it |

The knight is already safe: `character_keep` takes his two buffers once at the
start and keeps them (see `shift_kept`). The rest are first come, first served.

A priority pass would mean giving the movers their buffers before the room's
scenery -- allocating in behaviour order, or letting `room_add` mark a piece as
worth one and doing a second pass for the rest. Then a short arena would cost
only a wall's redraw rather than a ball's every turn, and the arena could very
likely give back more than the 768 bytes the end screens took.

Measured today at 4,992: the worst room in the castle spends 2.2% of a turn
rotating at draw time ($97), most of the sixteen about 1%, and no room shows
anything wrong -- a refused piece still draws in the right place, only slower.
