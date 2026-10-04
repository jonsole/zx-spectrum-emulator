# How the Filmation engine works

This is a technical account of the engine under `examples/filmation/engine`,
written for someone who already knows the Spectrum well: the screen layout,
the Z80's timings, contention, and the usual tricks with SP. It explains what
the engine does each turn, how its data is laid out, and why it is laid out
that way.

Four games are built on it: a remake of Ultimate's *Knight Lore* (48K), a
remake of *Pentagram* (48K), *Knight Lore 128K* (a bigger castle using both
games' art), and *Lightkeep*, a Fairlight-like game (128K). Their code is
beside the engine, in `examples/filmation/<game>/`.

Three other documents go deeper on one subject each, and this one links to
them rather than repeating them:

- [README.md](README.md) -- the integration reference: every file, the memory
  rules, and every name a game must supply.
- [depth.md](depth.md) -- depth sorting, with worked examples.
- [memory-128k.md](memory-128k.md) -- the 128K memory map.

The [Filmation README](../README.md) has the history: what changed from
Ultimate's original and what each change was measured against.

**Contents**

1. [The shape of it](#1-the-shape-of-it)
2. [The world and the screen](#2-the-world-and-the-screen)
3. [The object record](#3-the-object-record)
4. [Sprites](#4-sprites)
5. [Drawing](#5-drawing)
6. [Depth order](#6-depth-order)
7. [Movement and collision](#7-movement-and-collision)
8. [Characters](#8-characters)
9. [Time](#9-time)
10. [Memory](#10-memory)
11. [One turn, end to end](#11-one-turn-end-to-end)
12. [Building a game on it](#12-building-a-game-on-it)
13. [Things that bite](#13-things-that-bite)

---

## 1. The shape of it

A room is a few dozen **objects** -- walls, arches, blocks, monsters, the
knight's two halves -- each a 32-byte record in a pool. Each object has an
isometric box in world coordinates (U, V, Z) and a sprite drawn at the box's
projected position. The objects are kept in a linked list in depth order,
furthest first. Drawing walks that list and composites each sprite, masked,
into a small off-screen **view buffer**, which is then copied to the screen.

Nothing is drawn unless it has changed. When an object moves, the screen
rectangle it covered and the one it now covers are merged into one **dirty
region**. Only that region is cleared, recomposited from every object that
overlaps it, and copied out.

Five decisions shape everything else:

- **Interrupts are off for good.** The view clear, the draw walk, the blit,
  the rotation and the depth scan all use SP as a data pointer, because
  `POP` is the fastest way to read two bytes. An interrupt taken there would
  push its return address into a sprite. So `start` executes `DI` and never
  `EI`. Nothing waits for the frame interrupt, and timing is done by
  counting work (§9).
- **Sprites are composited, not XORed.** Every sprite has a mask. The view
  buffer is rebuilt for each region in depth order, so overlapping sprites
  are always correct.
- **The depth order is never sorted.** It is kept true as objects move: a
  record that moves is unlinked and scanned back in from where it now
  belongs. One that does not move costs nothing (§6).
- **Sub-byte positions are pre-rotated.** A sprite at an x that is not a
  multiple of 8 is rotated once into a buffer of its own. The buffer is
  reused until its graphic, its orientation or its shift changes (§4).
- **Everything is a plain `CALL` or `JP` to a label, and every setting is an
  `EQU`.** The engine is assembled into each game, so the split between the
  two costs nothing at run time.

---

## 2. The world and the screen

**Axes.** U and V lie on the floor; Z points up. The middle of a room is
U = V = 128. The floor reaches `room_half_u` and `room_half_v` either side of
that: 64 for a square room, 32 for a narrow one. Knight Lore's floor is at
Z = 128.

| Axis | On the screen |
|---|---|
| +U | right one pixel, down half a row: towards the viewer |
| +V | right one pixel, up half a row: away from the viewer |
| +Z | up one row |

Doorways are numbered north (+V), east (+U), south (−V), west (−U).

**Projection.** `object_place` (`object.s`) projects in eight bits:

```
x = U + V - 128 + ADJ_X                         left pixel column of the sprite
y = 40 - ((V - U + 128) >> 1) - Z - ADJ_Y       BASE: the row just below the sprite
```

The 128 added before the shift keeps `V − U` positive for `SRL`. The 40 is 296
mod 256: Knight Lore's own origin, 40 rows plus a whole wrap. `ADJ_X` and
`ADJ_Y` are a per-graphic **nudge** that lines the bitmap up with its box
(§4). `ADJ_Y` is subtracted because the artwork's Y counts upwards.

`y` is the **base**, the row just past the sprite's bottom, so an object's Z
stands it on the floor. The top is `base − height`. Everything wraps in eight
bits, as the original's arithmetic does: an x below 0 lands on the right of
the screen. Rooms are designed so nothing goes there.

`object_place` falls straight into `object_update`, which works out the
screen extents (§3) and the sprite to draw from (§4).

---

## 3. The object record

`ROOM_STRIDE` is 32. The pool is `ALIGN 32`, so every record's low byte is a
multiple of 32.

| Offset | Field | |
|---|---|---|
| 0-1 | `NEXT` | the next record, nearer the viewer; must be at offset 0 |
| 2, 3 | `MIN_Y`, `MAX_Y` | screen rows covered; `MAX` exclusive |
| 4, 5 | `MIN_X`, `MAX_X` | byte columns covered; `MAX` exclusive |
| 6 | `FLAGS` | see below |
| 7 | `BLIT_IDX` | (width − 2) × 16: an index into `sprite_jump_table` |
| 8 | `SHIFT` | sub-byte x, non-zero only when rotating at draw time |
| 9 | `CLIP_Y` | rows cut off above row 0 |
| 10-11 | `SPRITE` | the bitmap to draw: the sprite's, or a private buffer |
| 12-13 | `PREV` | the address of the `NEXT` field that points here |
| 14-15 | `BUF` | this object's rotation or copy buffer, or 0 |
| 16-18 | `U`, `V`, `Z` | the box's centre on the floor, and its base |
| 19-21 | `DU`, `DV`, `DZ` | signed step wanted this turn |
| 22-24 | `SIZE_U`, `SIZE_V`, `SIZE_Z` | half-widths on the floor, and the height |
| 25 | `GFX` | graphic number |
| 26, 27 | `ADJ_X`, `ADJ_Y` | the nudge |
| 28, 29 | `BEHAVIOUR`, `MOVE_STATE` | which mover runs it, and its state |
| 30, 31 | `DATA_1`, `DATA_2` | a mover's own; the homer keeps its sub-unit accumulators here |

**Why that order.** Bytes 0 to 11 are exactly what the draw walk needs, in
the order it needs them. It reads them with `LD SP,HL` and five `POP`s (§5).
`ASSERT`s in `object.s` pin the order. `PREV` comes after them so the walk
never has to skip it.

**`PREV` points at a field, not a record.** It holds the address of whichever
`NEXT` field names this record. That may be the list head, `object_list`,
itself. Unlinking is then two stores, with no special case for the first
record. Links step with `INC L`, which is why a `NEXT` field must never sit at
`$xxFF`; the 32-byte alignment guarantees that. The list ends at a `NEXT`
whose high byte is 0, since no record lives in page 0.

**`FLAGS`:**

| Bit | | |
|---|---|---|
| 7 | `OBJ_MOVABLE` | a character |
| 6 | `OBJ_BACKGROUND` | scenery nothing can be behind: unsorted, drawn first |
| 5 | `OBJ_SHIFTED` | `SPRITE` points at private rotated bytes |
| 4 | `OBJ_CACHE` | draw from a private copy (a contested graphic, §4) |
| 3 | `OBJ_SHARED_SHIFT` | the arena ran out: rotate at draw time |
| 2 | `OBJ_PASSABLE` | nothing collides with it |
| 1 | `OBJ_COPIED` | the private bytes are a straight copy, which twins may share |
| 0 | `OBJ_FLIP_H` | drawn mirrored; the same bit as the sprite header's `SPRITE_FLIPPED` |

**Extents.** `object_update` sets them from the projection:

- `MIN_X = x >> 3`, and `MAX_X = MIN_X + width`, plus one when rotated.
- `MIN_Y = base − height`. A top above row 0 clips to 0, and the lost rows go
  in `CLIP_Y`. A base past row 191 clips to 192. A sprite wholly below the
  screen gets an empty extent.
- Nothing clips at the left or right: rooms keep things on screen.

**A ninth graphic bit.** A game with more than 256 graphic numbers
(`GRAPHIC_COUNT > 256`; Lightkeep has 512) keeps bit 8 of the graphic in
bit 0 of `ADJ_Y`, and the y nudge doubled above it. `object_place` takes it
back with `SRA`. That code is assembled only in such a game, so the others
pay nothing for it ([Filmation README](../README.md#more-than-256-graphic-numbers)).

---

## 4. Sprites

### The record

Every sprite is `ALIGN 4`:

```
byte 0    (width - 2) * 16 | $80 if a frame of an animation | 1 if currently mirrored
byte 1    height in rows (at most 64)
then      rows, top row first: width pairs of (mask, data)
```

The width is 2 to 5 bytes (16 to 40 pixels), and 6 once rotated. Bits 4 to 6
of byte 0 are the width class, already scaled for the jump table. Bit 0 is
which way round the bytes are now (see [Mirroring](#mirroring)). The
`ALIGN 4` lets the code reach the width, the height and the first row with
`INC L` and `DEC L`.

The mask is stored **inverted**: a set bit keeps the screen. A byte is
composited as

```
pop hl          ; L = mask, H = data
ld a,(de)       ; the view buffer
and l           ; clear what the sprite covers
xor h           ; and put its pixels in
ld (de),a
```

That is `XOR`, not `OR`, and it gives the fourth colour the original art
uses. A data bit under a hole in the mask -- the sheets call it **stray** --
inverts what is behind it instead of drawing.

`scripts/sprite_source.py` writes these records from the game's
`art/sprites.png` and `metadata/sprites.json`. It trims blank bottom rows, and
folds the trim into the nudge so the sprite still stands in the same place.
(`sprites.json`'s `"bytes"` block describes Ultimate's packed original --
bottom-up rows, an uninverted mask -- which is what the extractor reads, not
what the engine draws.)

### The graphic table

A room names **graphic numbers**, not sprites. `sprite_table` holds one word
per graphic, pointing at its sprite. Several numbers may share one sprite,
and they are still different graphics: each has its own nudge, and some
numbers mean a state as well as a picture.

The table is `ALIGN 512`, which makes the lookup five instructions:

```
ld l,a                          ; the graphic
ld h,(high sprite_table) / 2
add hl,hl                       ; sprite_table + graphic * 2
```

That is why the table's high byte must be even. With 512 graphics, bit 8 adds
to H before the doubling.

### Nudges

A graphic's `ADJ_X` and `ADJ_Y` come from `room_adjust` (`room.s`), which runs
whenever a record's graphic or mirroring changes, before `object_place`.

- `sprite_adj_index` is page-aligned, a byte per graphic. It holds an offset
  into `sprite_adj_pairs`, a table of distinct (x, y) pairs. Knight Lore needs
  26 pairs for 186 graphics.
- Bit 7 of an entry says the mirrored nudge differs. The few graphics like
  that (Knight Lore's four doorway leaves) are found in `sprite_adj_mirror`,
  a short list of (graphic, pair).
- With 512 graphics there is a second index page two pages on, and each page's
  mirror list ends where the page starts and is read backwards.

Knight Lore's nudges were harvested from the running original by `adj.py`
rather than worked out. They are in `metadata/graphics.json`, where the graphic
map's Nudge dialog edits them.

### Mirroring

A U-facing wall and a V-facing wall are one bitmap mirrored. Rather than
keep a mirrored copy of every sprite (about 1.2 KB in room `$B3` alone),
`sprite_flip_h` (`sprite_flip.s`) **mirrors the bytes where they lie**:

- It reverses each row through `bit_reverse_table` (`ALIGN 256`) and toggles
  header bit 0.
- An object's `FLAGS` bit 0 is the way round it wants. One `XOR` with the
  header says whether the bytes are the wrong way. `object_update` and the
  draw walk check it, and flip when it disagrees.

Two objects in one room that want the same sprite opposite ways round would
flip it back and forth every draw. That once cost 85% of a turn in room `$88`.
`object_update` spots such contested graphics, marks the objects `OBJ_CACHE`,
and gives them a private copy, which twins with the same graphic share.

### Sub-byte shifts

A sprite at an x that is not a multiple of 8 has to be shifted right by
`x & 7`. The engine never shifts while compositing. Instead:

- **Pre-rotation.** `object_update` rotates the sprite once into a buffer of
  its own, one column wider. The buffer comes from the **rotation arena**
  (`shift_alloc`, `shift.s`; 4,992 bytes in Knight Lore, 4,288 in the 128K
  games), which is reset when a room is built.
  - A two-byte tag in the buffer -- graphic, then orientation and shift --
    skips the rotation when nothing has changed. A block standing still costs
    nothing.
  - An animated sprite's buffer has its rows rounded up to eights, so every
    frame fits.
  - The knight's two halves take two permanent buffers at the start of the
    game (`character_keep`), sized from his largest and tallest frames.
- **Rotating.** `object_update.rotate` uses `sprite_rotate_table`: seven
  shifts × two 256-byte pages, 3,584 bytes, `ALIGN 256`. Page A holds `x >> s`
  and page B the bits that fall out. A mask byte and a data byte go through
  together, and the bits vacated at the edges are forced to "keep the
  screen". It costs about 47 T a byte, 620 T a row.
- **Rotating at draw time.** When the arena is full, `shift_alloc` sets
  `OBJ_SHARED_SHIFT`. That object is then rotated at draw time into
  `shift_shared` (416 bytes, the largest sprite rotated) every time it is
  drawn. It is slow -- 19,500 T for a castle arch leaf -- but never fails. The
  arena size is a budget for keeping that rare.

---

## 5. Drawing

### Dirty regions

A **region** is a rectangle of screen rows and byte columns, kept as
`view_y_extent` and `view_x_extent`: two words, min in the low byte and max in
the high.

- `region_reset` makes it empty.
- `region_add` grows it to cover an object's extents.
- A move adds the object's extents before and after, so one region covers
  both where it was and where it is.
- `redraw_defer` holds a region back. If the next region overlaps it on both
  axes, and their union still fits the view buffer, the two merge. Otherwise
  the held region is drawn and the new one held instead.
- `redraw_flush`, at the end of a turn, draws whatever is left.

`mover_paint` (`mover.s`) is the whole pattern in one routine:

```
region_reset; region_add          ; where it was
depth_step                        ; re-sort, if it moved
room_adjust; object_place         ; where it is now
region_add; redraw_defer          ; where it is, merged with where it was
```

### The view buffer

The view buffer is 8 bytes by 64 rows, 512 bytes, `ALIGN 512`. A region is
composited into its top-left corner and copied to the screen from there.

- **Why 8 × 64.** The widest sprite is 5 bytes, 6 rotated, and the tallest is
  a 64-row castle arch. A power-of-two width makes a row's address a shift; a
  6-byte width would still cross a page and save nothing.
- **Why `ALIGN 512`.** The row address is made with one `RL D`:

  ```
  add a,a / add a,a / add a,a     ; y * 8, the third carry being bit 8
  ld d,(high view_buffer) / 2
  rl d                            ; D = high view_buffer + that carry
  add a,h                         ; + the column
  ld e,a
  ```

  This needs `high view_buffer` to be even. Inside a row, the code steps with
  `INC E` only; a carry can happen only at a row start.
- **Larger regions.** There are no strips: a region taller than 64 rows or
  wider than 8 bytes is never made. Merges that would exceed the buffer are
  refused. `redraw_screen`, which draws a whole room, draws it as 4 × 3 tiles
  of 8 × 64.

### `redraw_view`

This is the whole draw, for one region:

1. **Clear** the region's rows with the game's `view_clear` macro.
   - The 48K games use `view_clear_zeroes`: SP at the end of the rows, then
     `PUSH DE` with DE = 0, four a row, about 57 T a row.
   - The 128K games copy from a **backdrop** instead: a picture of the room's
     walls, captured once in bank 6 when the room is built. It costs 165 T a
     row, but only where a column has backdrop, and the walls then need never
     be drawn.
2. **Composite** every object that overlaps the region, in depth order:
   `objects_draw_all`.
3. **Copy** the region to the screen: `vid_buff_copy`.
4. **Fall through** into the game's `redraw_hook`. That redraws whatever the
   game keeps straight on the screen, such as Knight Lore's panel, and that
   the region just wiped. `redraw.s` must be followed directly by the hook,
   and the game asserts it.

### The draw walk

`objects_draw_all` (`object.s`) walks the depth list once per region, with SP
as the read pointer. It uses both register banks, so one keeps the y extent
and the other the x extent. In outline:

```
ld sp,hl / pop hl          ; HL = NEXT
pop bc                     ; C = MIN_Y, B = MAX_Y        -> reject if outside the region
exx / pop bc               ; C' = MIN_X, B' = MAX_X      -> reject if outside the region
  extent_intersect (x)     ; overlap, start in the region, start in the sprite
  extent_intersect (y)     ; rows, and the view buffer address
pop de                     ; E = FLAGS, D = BLIT_IDX
pop ix                     ; IXL = SHIFT, IXH = CLIP_Y
jp (hl)                    ; into sprite_jump_table + BLIT_IDX: rows skipped * width
.x_adjust: pop hl          ; HL = SPRITE
```

- **Rejects.** A record outside the region costs 75 to 133 T.
- **The jump table multiply.** The number of rows skipped (screen clip plus
  region clip) times the sprite's width is done by jumping into
  `sprite_jump_table` at `BLIT_IDX`. Each 16-byte group adds A to itself the
  right number of times and jumps back to `.x_adjust`.
- **Patched immediates.** The next record's address and the two extents are
  written into immediates (`.next_object_at`, `.reload_y`, `.reload_x`), so
  starting the next record costs three loads.
- **The usual path** checks the orientation with one `XOR`, adds the start
  offset to the sprite pointer, counts the blit towards the turn, and jumps
  into the blitter.
- **`.unusual`** handles a mirrored-on-demand sprite or a draw-time rotation.
  It recovers IX from SP, restores the real stack so it can `CALL`, flips or
  rotates, and rejoins the usual path.

### The blit

There is one blitter (`sprite.s`), patched for each sprite by
`sprite_blit_setup`, rather than a routine for each (width, columns) pair:

- The body is six unrolled copies of the five-instruction composite above,
  each with `INC E`. Entry is a `JR` whose displacement is patched to skip
  the columns not drawn on the left.
- The row loop is a `DJNZ`, patched into a run of `POP AF`s at the position
  that steps SP past the columns not drawn on the right. The row advance adds
  the patched stride to E, carrying into D.
- It ends with `JP objects_draw_all.drawn`, and never restores SP: the walk
  sets it again for the next record, saving 30 T a blit.

The composite is **36 T a byte**, which is the Z80's floor for a masked write
of this shape. Ultimate's Head Over Heels needs 52.

### The copy

`vid_buff_copy` (`vid_buff.s`) is a chain of eight `LDI`s. It is entered
part-way through by patching the displacement of the loop's own `DJNZ`, so
one routine copies any width.

- The screen address comes from `pixelAddress`, which sits in the gap before
  `sprite_rotate_table` so the page is not wasted.
- The screen row steps down with `INC D`, and on every eighth row adds 32 to
  E and corrects D, the usual way.
- `LD C,D` before each row stops `LDI`'s BC count from borrowing into B, the
  row counter.

It costs 16 T a byte, plus about 82 T a row. There is no colour work: a room
has one attribute colour, set when it is built.

### What drawing costs

`turn.s` carries a cost model, fitted against 258 turns timed in the
emulator:

| | T-states |
|---|---|
| A turn, before anything | 5,400 |
| A blit | 1,300, plus 172 a row composited |
| A region drawn | 3,900 |
| A collision gather | 15,000 |
| A row rotated | 620 |

---

## 6. Depth order

[depth.md](depth.md) is the full account; this is what you need to work on it.

- **Boxes.** U and V are a centre and a half-width, and Z is a base and a
  height. Boxes that only touch count as apart, so a stack of cubes sorts
  cleanly.
- **The list.** It runs furthest first, starting at `object_list`. A
  **background run** at the front holds the walls and trees, which nothing
  can be behind. `background_insert` appends them without comparing anything,
  and `sort_head` marks where the sorted run begins.
- **Inserting** (`depth_insert`). The new record's box is patched into six
  `CP` immediates (`depth_cmp_setup`). The list is then walked with
  `LD SP,IY` / `POP IY`, at about 140 T a candidate. For each candidate:
  - **"They are nearer"** is taken from the first axis that separates the two
    boxes, asked in the order U, V, Z. It only moves the scan on.
  - **"We are nearer"** must be certain: every separating axis must agree.
    The record goes after the last candidate it is certainly nearer than.
  - Axes that disagree decide nothing, and boxes that overlap on all three
    axes move nothing.
  - The scan never stops early. Isometric depth is not transitive, and a
    record further down the list can still need to go behind.
- **Moving** (`depth_step`). It adds the step (D = dU, E = dV, A = dZ) to the
  record and returns at once if the step was zero. Otherwise it unlinks the
  record and inserts it again.
- **Two-part figures** (`depth_step_upper`). The knight's legs and body, or a
  guard's torso and legs, are two records. The lower one is relinked against
  the whole list, and the upper one is scanned in from just after it, so the
  two never come apart.

---

## 7. Movement and collision

### Steps

A record's wanted move is `DU`, `DV` and `DZ`. Routines that apply a step take
it in registers: **D = dU, E = dV, A = dZ**.

### Collision

`object_collide` (`object.s`) clips a step so the box does not pass through
anything:

1. **Gather.** `collide_gather` lists everything the swept box could touch.
   When Z changes it widens the list by `CARRY_REACH`, so a rider on top is
   found. It costs about 15,000 T, so it runs once a move.
2. **Three passes**, Z first, then U, then V. Each tests with the earlier
   axes' steps applied and the later axes' held at zero. `object_clamp`
   walks a step back a unit at a time while it overlaps something.
3. **What was cut** is left in `collide_hit`: bit 0 for U, 1 for V, 2 for Z.
   That means the axis was clipped, not that the step became zero. Movers turn
   round on it.

The room's walls and floor are checked separately (`object_collide_room` in
`walker.s`):

- A step that would take Z below `room_floor_z` lands exactly on it.
- A step past the room's edge is walked back, unless a character is in a
  doorway.

What a collision **does** depends on the behaviour of each side (the game's
`BEHAVIOUR_*` bands):

| Rule | When |
|---|---|
| **Shove** | A record hit along U or V is given the mover's whole step on that axis, to spend on its own turn, if it is a character or its behaviour is ≥ `BEHAVIOUR_LOOSE`. In a game built with `LOOSE_WEIGHT` it is given the step less its weight (`DATA_1`), and nothing when the weight is the whole step. |
| **Carry** | A record landing on another takes the other's DU and DV as its own, where its own are zero. So things ride on lifts and conveyors, and a knight on a moving block goes with it. |
| **Kill** | The knight dies if he walks into a behaviour in [`DEADLY`, `CRUSHING`), or if a mover in [`DEADLY`, `HARMLESS`) walks into him. Gravity proposes a Z step every turn, so standing on spikes kills too. The game sees it in `deadly_touched`. |
| **Gives** | Landing on a behaviour in [`GIVES`, `GIVES_LAST`] sets bit 3 of its `MOVE_STATE`. Sinking and collapsing blocks act on it. |

### Movers

`movers_step` (`mover.s`) gives each record in the pool a turn:

- `BEHAVIOUR − BEHAVIOUR_FIRST_TURN` indexes the game's `mover_tbl`. Records
  below `BEHAVIOUR_FIRST_TURN` have no turn.
- It stores IX in `mover_ix`, pushes a return address, and does `JP (HL)`.
- A mover may corrupt anything but IX, and must return with the stack as it
  found it.

The usual mover is a few lines:

1. Set `DU`, `DV`, `DZ`.
2. `mover_clamp`. Its `DEC DZ` is the **gravity** for every mover: DZ = 1
   hovers, DZ = 0 sinks a unit a turn, and leaving DZ alone accelerates.
3. `mover_move`, which is `mover_paint` if the clamped step is not zero.
4. Turn round on `collide_hit` with `mover_turn_if_hit`.

`movers.s` is a library of behaviours from both games. Each is assembled only
if the game names it (`IFUSED`), so a game pays only for what it uses. The
[README](README.md#the-movers) lists them with what each asks of the game.

`mover_find` maps a room template to its behaviour when a room is built,
through the game's `mover_of` table of (template, behaviour) pairs.

---

## 8. Characters

The knight (and Pentagram's Sabreman) is two records, legs then body at
`+ROOM_STRIDE`, followed by seven bytes of state: fall speed, jumping, facing,
walk phase, the legs' and body's frames, and the doorway he is in.
Characters are not in the room's pool, so movers collide with
`walker_player` explicitly.

- **`character_walk`** (`walker.s`) takes a facing, 0 to 3:
  1. It takes the step for that facing from `character_steps`.
  2. It advances the walk phase and picks the frames.
  3. It lets the game's `character_steer` adjust the step.
  4. It settles: shoves, gravity, collision, landing.
  5. It moves both records as one figure.
- **`character_stand`** does the same with a zero step, and always repaints.
- **Frames.** Bit 1 of the facing picks a block of frames, and bit 0 mirrors
  them. The body's frame goes through the game's `walker_glance` hook, which
  is how Knight Lore's knight glances around.
- **Jumping and falling.** A jump sets the fall speed to `CHARACTER_JUMP_DZ`.
  Speed drops by 1 a turn while rising with jump held, otherwise by 2, down to
  `CHARACTER_FALL_MAX`.
- **Steps** (a build option, `CHARACTER_STEP_UP`; Lightkeep has it). When
  something stops his step along U or V, `object_clamp` notes the top of the
  highest thing that did, in `collide_top`. If that is no more than
  `CHARACTER_STEP_UP` above his feet and he is not jumping,
  `character_climb` runs the whole collision again with a rise of
  `CHARACTER_CLIMB` units (2), and the floor axes, tested after Z, now pass
  over the step. Nothing is kept between turns: each turn gravity pulls him
  back a little, the step is still in the way, and he climbs again from where
  he stands, until his feet are level with its top. A game without the define
  assembles none of it.
- **Doorways.** `character_door_find` checks whether he is standing in one: a
  band of height, along the wall, and across it. In a doorway the room-edge
  clamp is off, and the game moves him to the next room once he is through
  (Knight Lore's `player_exit`).

---

## 9. Time

With interrupts off there is no frame to wait for, so a **turn** is one pass
of the game's main loop, whatever it costs. Left alone, an empty room would
run at a hundred turns a second and a busy one at twenty.

**Counting work.** Every costly thing adds to `turn_work` in units of about
172 T (`turn_add`): blits, rotated rows, regions, collision gathers, and
sound. `turn_pace`, at the end of the turn, spends what is left of
`TURN_BUDGET_T` (86,000 T) in a delay loop. Light rooms then run at 33 to 38
turns a second (35 typically), and a turn already over budget waits nothing.
The original Knight Lore manages 6 to 12 frames a second; this engine runs
18 to 35.

**Sound** is the beeper, and its time counts towards the turn (`sound.s`). A
sound clock advances by each turn's length, and raises `sound_now` once every
`SOUND_FRAME_T` (230,000 T, one of the original's frames). `sound_take` lets
one continuous sound through per such frame, so effects keep the original's
rhythm whatever the turn rate. Tunes (`tune.s`) play outside the turn, at the
menu and the end.

**Busy rooms** (`busy.s`). `busy_check` watches `turn_work` against the pace
the game is copying (`BUSY_TURNS_A_SECOND`, 15 in Knight Lore). After two turns
over it, `room_busy` makes the monsters take turns sitting one out
(`monster_sits_out`). After sixteen calm turns it eases back off.

**Input** (`input.s`). `input_read` reads the control the menu chose: the
game's own keys, Kempston (port `$1F`), cursor keys, or Interface II, with
both sticks read and ORed. Each stick sets five bits the game names with
`INPUT_*_B`.

---

## 10. Memory

### 48K

Knight Lore's map (`knightlore/knightlore.s`). The byte counts free at the end
of each region are from the build of 2026-10-03; all four are kept tight.

| From | To | Holds | Free |
|---|---|---|---|
| `$5B00` | `$5FFF` | the room builder, over the printer buffer and system variables (the ROM is never called) | 2 |
| `$6000` | `$73FF` | the room data, panel, nudge tables, font, `shift_shared`, sounds | 14 |
| `$7400` | `$7FFF` | `view_buffer` (`ALIGN 512`), the pool (38 × 32), `bit_reverse_table`, `sprite_table`, the clock, `screen_sprite` | 20 |
| `$8000` | `$FFCF` | `sprite_jump_table`, `sprite_rotate_table`, the sprites (~15K), the engine and the game, the rotation arena | 9 |
| | | the stack, the top 48 bytes (34 measured in use) | |

**Contention.** Everything that runs every turn is above `$8000`, as is
everything timed (the beeper above all). Only the room builder and the room
data, used once per room, sit in contended memory. The view buffer and the
pool are in contended memory too, and cost about 0.6% of a turn there. The
emulator does not model contention, so its timings are uncontended.

### 128K

Knight Lore 128K and Lightkeep use the same map ([memory-128k.md](memory-128k.md)):

| Bank | At | Holds |
|---|---|---|
| 5 | `$4000` | screen, room builder, cold code (menu, end screens), view buffer, pool, aligned tables |
| 2 | `$8000` | the every-turn code, the arena, the stack (`STACK_TOP = $C000`, so a `RET` never depends on paging) |
| 0 | `$C000` | the **room page**, paged in for all of play: resident sprites, then this room's sprites |
| 4 | `$C000` | the rooms and templates |
| 1, 3, 7 | `$C000` | the sprite **library** |
| 6 | `$C000` | the backdrop (§5) |

Building a room pages bank 4 to find it (`room_find`).
`room_page_fill` then copies each library sprite the room uses -- through the
arena, as a bounce buffer between banks -- into the room page, and re-points
`sprite_table` at it. Every other library graphic points at a blank sprite.
`$7FFD` is written through a shadow copy, `bank_port`. The lock bit is never
set, and the 48K ROM stays paged in.

### Alignments the engine relies on

| What | Align | Why |
|---|---|---|
| `view_buffer` | 512 | `RL D` row addressing |
| `sprite_table` | 512 | `(high sprite_table) / 2` then `ADD HL,HL` |
| the pool, `room_objects` | 32, with a trailing `ALIGN 32` | `INC L` along a record's links |
| `sprite_jump_table` | 256, within one page | `LD L,D / JP (HL)` |
| `sprite_rotate_table`, `bit_reverse_table`, `sprite_adj_index` | 256 | indexed by `LD L,A` |
| sprite records | 4 | `INC L` / `DEC L` between header and rows |

---

## 11. One turn, end to end

Knight Lore's main loop (`knightlore/main.s`):

1. If `room_number` has changed, build the new room:
   - `room_build` decodes the room record into `room_add` calls, and
     `room_show` places, sorts and draws them all;
   - then the knight is added (`character_add`), the room's colour set, and
     its collectables shown.
2. `special_step`: the collectables.
3. `player_step`: dying and appearing, the glance, the doorway check,
   `input_read`, jump, turning, then `character_walk` or `character_stand`,
   then leaving through a doorway. The player moves before the monsters, so a
   shove he gives is spent this turn.
4. `movers_step`: every monster, block and platform.
5. `day_step`: the sun and moon.
6. `redraw_flush`: the region still held back.
7. `busy_check`, then `turn_pace`.

Each move in steps 3 and 4 repaints through `redraw_defer`, so most regions
are drawn as they come. Overlapping ones are merged first.

**Building a room.** A room record is a header and a list of template
indices:

- **Scenery.** Each scenery index expands to pieces with absolute positions:
  walls, arches, gates.
- **Objects.** Each object group is a byte -- the template in bits 3 to 7, a
  count less one in bits 0 to 2 -- followed by a position byte per object.
- **Position byte.** It packs a cell on the 8 × 8 floor and a level:
  `U = (p & 7) × 16 + 72`, `V = ((p >> 3) & 7) × 16 + 72`,
  `Z = (p >> 6) × 12 + floor`.
- **Nudge.** A template's pieces add a half-cell nudge and a raise of their
  own.

`room_add` fills a record from each piece and runs `room_adjust`. `room_show`
then runs `object_place` on them all, inserts each into the depth list
(background ones without comparing), and draws the screen.

---

## 12. Building a game on it

A game includes the engine's files from its top-level `.s`, lays out memory,
and supplies the names in the [README's table](README.md#what-the-game-supplies).
Starting a new one means writing:

1. **The top-level `.s`**: the memory map, with `ASSERT`s on each region's
   end; `VIEW_BUF_*`; the stack; the aligned tables; `shift_arena`; the
   `view_clear` macro; `SAVEBIN` or `SAVEDEV`. Copy `knightlore/knightlore.s`,
   or `lightkeep/lightkeep.s` for 128K.
2. **`main.s`**: `start` (`DI`, SP, paging) and the turn loop of §11.
3. **The character**: `player.s` (room entry, exit, dying) and `knight.s`
   (the `CHARACTER_*`, `DOOR_*` and `COLLIDE_HEIGHT` numbers), plus
   `glance.s` for `walker_glance` and `character_steer`.
4. **`movers.s`** (the behaviour bands, `mover_of`, `mover_tbl`) and
   **`shared_movers.s`**: the library's names, as `EQU`s to the game's own
   routines and constants. It goes between `engine/mover.s` and
   `engine/movers.s`.
5. **`room_build.s`**: decoding the room record into `room_add` calls. For
   128K, `room_find.s`, `room_page.s`, `backdrop.s` and `backdrop_build.s`.
6. **`overlay.s`**: `redraw_hook`, straight after `redraw.s`.
7. **The rest of the screen**, sound and input: the panel, the menu,
   `sound_jump`, `sound_z` and the movers' sounds, `tune_note_at`, the
   keyboard, and the `BUSY_*` numbers.
8. **The data**, in `metadata/` and `art/`, and its generators in `scripts/`:
   - `sprite_sheet.py`, holding the game's facts such as `GRAPHIC_COUNT`;
   - `sprite_source.py`, which writes the sprite records, `sprite_table` and
     the nudge tables;
   - `rooms_source.py`, which writes the room data.

   The [Filmation Designer](../designer-guide.md) edits the data.
9. **`build.py`**: it runs each generator when one of its inputs is newer than
   its output, then sjasmplus, then writes a `.z80`. Copy `lightkeep/build.py`.
10. **Tests**: `tests/*_tests.s`, Z80 test suites assembled by
    `engine/tests/run_tests.py` and run headless on the emulator's own Z80
    core (`z80_com_runner`). Add the game to the runner's `SUITE_DIRS`.
    `engine/tests/walker_tests.s` is a working minimal example of what a game
    supplies.

---

## 13. Things that bite

- **SP is a data pointer.** Never `EI`. Keep the stack in uncontended memory
  with room below it, and measure again if you deepen a call chain:
  `STACK_RESERVE` is 48 with 34 in use.
- **Between `.x_adjust` and the end of a blit, SP points into a sprite.**
  Nothing there may `CALL` or `PUSH` except through `.unusual`, which puts
  the real stack back first.
- **Self-modifying code.** These are patched at run time:
  - the copy's `DJNZ` displacement and stride;
  - `view_clear_zeroes`' saved SP;
  - the draw walk's `.reload_x`, `.reload_y`, `.set_stack` and
    `.next_object_at`;
  - the blit's entry `JR`, stride and the `DJNZ` it lays over its `POP AF`s;
  - `sprite_flip_h`'s stride;
  - the rotation's saved SP and edge masks;
  - `screen_sprite`'s columns and bottom;
  - the depth scan's `CP` immediates;
  - the first byte of the game's `redraw_hook`, which is poked to `RET`
    while a room is built in the dark.

  Code in ROM, or assembled twice, would break.
- **Bytes 0 to 11 of the record are the draw walk's `POP` order.** Moving
  one means rewriting the walk.
- **`room_adjust` before `object_place`** whenever a record's graphic or
  mirroring changes, or it is drawn with the old nudge.
- **A mover keeps IX and balances the stack.** IX is lost across
  `object_place` and the redraw calls, so reload it from `mover_ix`, as
  `mover_paint` does.
- **Steps leak.** A shove writes into the record's DU or DV. A mover that
  never clears them slides for ever. What is left in them after a move is
  what anything riding it copies.
- **A zero step skips the repaint.** Use `mover_move_always` when only the
  graphic changed.
- **Uncounted work is padded as idle.** Anything heavy that does not go
  through `turn_add` makes the rooms it runs in slower than the budget.
- **Behaviour bands are positional.** `BEHAVIOUR_LOOSE` and above are carried
  and shoved, so keep loose things last, and `ASSERT` `mover_tbl`'s length.
- **`IFUSED` blocks fall through.** Some movers are entries into another's
  code (`mover_faller` inside `mover_faller4`, `mover_poof` inside
  `mover_poof_start`). Name the outer one, or the block is not assembled.
- **An `EQU` to a label still to come** takes the previous pass's value, and
  `IFUSED` moves code between passes. State such `EQU`s after the routine's
  file (the reason `shared_movers.s` goes where it does).
- **Region width.** `redraw_view` clamps an over-wide region for the copy but
  not for the composite. No region wider than the buffer is ever made today
  (merges refuse it, and a whole screen is drawn in tiles). Keep it that way.
