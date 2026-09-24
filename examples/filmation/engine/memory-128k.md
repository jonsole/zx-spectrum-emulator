# The 128K memory map

A plan, being built in [`../knightlore128/`](../knightlore128/README.md), whose
README says which parts exist so far. The 48K builds keep the map in the
[README](README.md#laying-out-memory); this is the layout a 128K build of the
engine would use, so that a game can carry three times Knight Lore's room data
and three times its graphics. The sizes are Knight Lore's and Pentagram's,
measured with [`../room_budget.py`](../room_budget.py) and the emulator's
profiler on 2026-09-18.

## Contents

1. [The idea](#1-the-idea)
2. [Banks](#2-banks)
3. [Addresses](#3-addresses)
4. [When it pages](#4-when-it-pages)
5. [The room page budget](#5-the-room-page-budget)
6. [The backdrop](#6-the-backdrop)
7. [What the map forces](#7-what-the-map-forces)
8. [Open questions](#8-open-questions)
9. [What was built, and where it differs](#9-what-was-built-and-where-it-differs)

---

## 1. The idea

Only $C000-$FFFF pages on a 128K, and every sprite a room draws has to be
visible while it is drawn. All the graphics together cannot be: three times
Knight Lore's 15,572 bytes is 46.7K. But no room draws more than a fraction of
them, so the graphics live in a **library** spread over three banks, and on
entering a room the ones it draws are copied into one working bank, the
**room page**, which stays paged in for the whole of play.

Walls and the scenery along the back of the room are not drawn during play at
all. They are drawn once, when the room is built, into a **backdrop** -- a
6K picture of the room's background -- and a region redraw starts from a copy
of the backdrop instead of from a cleared buffer. Their graphics never need to
be in the room page, which is what leaves it room for the rest; and a floor or
a wall can be patterned at no cost during play, since the copy costs the same
whatever is in it.

## 2. Banks

| Bank | Paged at | Contended (128K/+2) | Holds |
|---|---|---|---|
| 5 | $4000, fixed | yes | the screen, then code and tables below $8000 |
| 2 | $8000, fixed | no | the code used every turn, the rotation arena, the stack |
| 0 | $C000 during play | no | the **room page**: resident graphics, this room's data, this room's graphics |
| 6 | $C000 for the backdrop copy | no | the **backdrop**, 6,144 bytes, and 10K spare |
| 1, 3, 7 | $C000 at room entry | yes | the graphics library, 48K |
| 4 | $C000 at room entry | no | room data (about 10.5K at three times Knight Lore's), a directory of the library, spare |

Bank 0 is uncontended on every 128K model, the +2A and +3 included -- those
contend banks 4-7 instead -- which is why it holds the room page. The library
banks are read only while a room is built, so their contention does not matter.

## 3. Addresses

### Bank 5, $4000-$7FFF

| Address | Contents |
|---|---|
| $4000-$5AFF | screen |
| $5B00-$5FFF | room builder, and the new library copy and backdrop build |
| $6000-$73FF | what room data used to fill: cold code (menu, end screens) moved down from $8000, panel data, font, specials, `shift_shared`, sound effects |
| $7400-$75FF | `view_buffer`, 8 x 64, `ALIGN 512` |
| $7600-$7AFF | `room_objects`, the pool |
| $7B00-$7BFF | `bit_reverse_table` |
| $7C00-$7DFF | `sprite_table`, rebuilt on room entry to point into the room page |
| $7E00-$7FFF | pickup and `screen_sprite`, as now |

### Bank 2, $8000-$BFFF

| Address | Contents |
|---|---|
| $8000 | `sprite_jump_table` |
| $8100-$8EFF | `sprite_rotate_table`, 7 x 512 |
| $8F00- | engine and game code: Knight Lore's, less its sprites and arena, is about 8.6K of this |
| up to $BFBF | `shift_arena`, about 4K |
| $BFC0-$BFFF | stack |

### Bank 0, the room page, $C000-$FFFF

| Address | Contents |
|---|---|
| $C000-$E3FF | resident graphics -- the player, collectables, anything the game's code puts up in any room. Copied once |
| $E400-$E5FF | this room's data: its record and its templates, expanded |
| $E600-$FFFF | this room's own graphics, refilled on every entry |

### Bank 6, $C000-$FFFF

| Address | Contents |
|---|---|
| $C000-$D7FF | the backdrop |
| $D800-$FFFF | spare: AY music, or a cache of shifted copies later |

### Port $7FFD

Bits 0-2 are the bank at $C000. Bit 3 stays 0, so bank 5 is the screen. Bit 4
is 1, for the 48 ROM. Bit 5, the lock, is never set. The port cannot be read
back, so the game keeps its own copy of the last value written.

## 4. When it pages

| When | Banks | Cost |
|---|---|---|
| a turn | none | -- |
| a region redraw | 6, then 0 | two `OUT`s, about 25 T, around the backdrop copy |
| entering a room | 4, then 1/3/7, then 6, then 0 | a few frames |

Interrupts stay off, as they must for the drawing path anyway, so nothing can
run with the wrong bank in.

## 5. The room page budget

From `python room_budget.py`, as of 2026-09-24:

| | Knight Lore | Pentagram |
|---|---|---|
| resident graphics (named by no room) | 7,700 | 8,806 |
| room page left for one room's graphics | 8,172 | 7,066 |
| drawn during play, busiest room | 2,278 (room 1) | 1,758 (room 71) |
| drawn during play, median room | 908 | 866 |
| pieces that go into the backdrop | 49% | 54% |
| headroom over the busiest room | 3.6x | 4.0x |

The first measurement, on 2026-09-18, gave resident 9,084 and 9,098, and
Knight Lore's busiest room as 2,458 (room 103). Two things have changed since,
and neither is a change in the rooms:
- The sheets now hold each sprite with its blank bottom rows trimmed off. That
  is 508 bytes of Knight Lore and 292 of Pentagram, which is all of
  Pentagram's difference.
- Knight Lore's mover frames now come from the `animations` block in its
  `sprites.json`, not from the sheet groups that were read before. That
  groups the frames more tightly.

"Resident" is everything no room's templates name. That overcounts: it sweeps
in the animation frames of movers that rooms place, and the panel's graphics,
which are drawn straight to the screen and could stay in the library. The sum
is right; the split between resident and per-room leans to resident.

Rooms three times as rich as Knight Lore's busiest come close to the limit;
three times as many rooms of the same richness fit easily.

## 6. The backdrop

**What goes in it.** A piece of scenery is backdrop when nothing can ever get
behind it: it stands at or beyond the room's west edge (U low) or north edge
(V high) -- depth is `U - V + Z`, see [depth.md](depth.md) -- and it is not a
doorway, which something walks into. Knight Lore already marks exactly these
pieces `OBJ_BACKGROUND` by hand (its walls and trees), and `room_budget.py`
checks the rule reproduces that. Pentagram marks nothing, so there the rule is
new. Anything that moves, vanishes or can be shoved is not backdrop, whatever
its position -- and an interior hedge the player can walk behind is not either.

Backdrop pieces stay in the pool, because they still collide. They leave the
draw walk and the depth list.

**What it saves.** Measured in Pentagram's start room: with its 12 wall pieces
culled from the draw, a turn went from 133,159 T to 120,038 T of work, 13,121 T
or 9.9%, nearly all of it blitting and the draw walk. The copy that replaces
the clear gives some back: the clear is 57 T a row, and the copy costs about
what `vid_buff_row` costs for the same rows -- 7,000 T a turn there, against
about 2,400 T of clear. Net, about 8,500 T a turn, or 6%.

That room was a good case -- the only thing moving was a monster against the
back wall -- so rooms whose action is away from the walls will save less. The
walk still visited the culled pieces, and depth-list savings were not
exercised, so on those counts the figure is low. Knight Lore has not been
measured.

## 7. What the map forces

1. **The arena only just fits in bank 2.** About 4.1K is left below the stack.
   The arena needed up to 5.7K in Knight Lore, but mostly for walls and trees
   at sub-byte offsets, which the backdrop takes. If it is short, the menu and
   the end screens move down to $6000.
2. **Library to room page goes through a bounce buffer.** Both are at $C000.
   The arena is empty while a room is built, so it is the bounce: two copies of
   about 9K, around five frames a room.
3. **Drawing the backdrop goes through the view buffer.** `redraw_screen`
   already composites in tiles the size of the view buffer. Each tile is drawn
   with the library paged in -- per object, so `sprite_table` needs a bank for
   each entry while the room is built -- and then copied into bank 6.
4. **No stored per-room graphics lists.** The builder derives a room's graphics
   from its templates, plus a small table of the frames each mover animates
   through. Lists for three times Knight Lore's rooms would overfill bank 4.
5. **Every graphic a room can show must be in its list or resident.** A graphic
   in neither draws garbage. Mover frames, carried items, the cauldron's
   cycling graphic and Pentagram's falling objects are the ones to watch. The
   build should work out each room's set and fail when a room overfills the
   page, and a debug build should check at run time.
6. **No shadow screen.** Bank 7 is library. Double buffering would need 16K
   found elsewhere.
7. **Never call the 128 ROM.** $5B00-$5BFF is its paging workspace, and this map
   puts code there.
8. **The view buffer stays contended.** It stays in bank 5 because bank 2 is
   full; moving it above $8000 would help on real hardware, at 512 bytes of
   arena.

## 8. Open questions

- How big the arena needs to be once backdrop pieces no longer rotate.
- Knight Lore's backdrop saving, and a room where the action is mid-floor.
- Whether mirrored graphics should be copied into the room page already
  mirrored. Scenery used only one way round would then never be flipped in
  place, which is most of `sprite_flip_h`'s 2.3% of a turn; the player keeps
  flipping as he turns.
- Tape: about 58K more to load, some five minutes at ROM speed. The .z80 is
  unaffected; a turbo loader or compression would help the .tzx.

## 9. What was built, and where it differs

Built in `../knightlore128/` on 2026-09-24 (stages 2 and 5 in its README).
Two engine changes went with it, and both leave Knight Lore's and Pentagram's
images byte for byte as they were: the game reserves the rotation arena, and
the game says what a region starts from (`view_clear`, in `redraw.s`). Where it
departs from the plan above:

- **The resident graphics are assembled into bank 0, not copied there.** They
  sit at $C000 from the start, and the room page proper begins after them.
- **The library is in bank 1 alone for now.** Knight Lore's loaded sprites
  come to 6.2K. The generator moves on into banks 3 and 7 when it needs to.
- **Each room's list is stored, in bank 4.** It is a count and a library
  number per sprite, about 20 bytes a room. §7.4 argued against stored lists,
  but bank 4 has room for them, and the build then knows each room's exact
  load and fails when a room overfills the page.
- **Resident or loaded is decided by sprite group, and a room loads whole
  groups.** That replaces the table of mover frames in §7.4. The groups are
  `ROOM_GROUPS` in `sprite_sheet.py`. Anything missed draws `sprite_missing`,
  which a read watchpoint catches.
- **The bounce buffer is the arena past the knight's kept buffers**, one
  record at a time, as §7.2 has it. The arena stayed in the middle of bank 2,
  where `shift.s` puts it, because there was no need to move it.
- **The room's record is copied into `room_record`, in bank 5**, not into
  the page. With Pentagram's templates beside Knight Lore's (stage 4), the
  templates moved to bank 4 as well. `room_find` copies the ones a room names
  into `room_templates`, in bank 5, as §3 planned for the page. Bank 5 was
  chosen because bank 4 is paged in while they are copied.
- **The arena is the game's to reserve** (`shift_arena`, `SHIFT_ARENA_SIZE`,
  just before `engine/shift.s`). knightlore128's is 4,288. The backdrop took the walls out of it, but what
  moves fills it still: played for sixty turns, rooms $13 and $87 reach 4,224
  and 4,134, so there was nothing to give back.
- **The stack is at $C000** (SP), in bank 2, and the menu, the end screens and
  the tune player moved down to $6000, as §7.1 foresaw.
- **The backdrop is captured from the screen**, not drawn into bank 6. The
  background alone is drawn to the screen while its attributes still hold it
  black, and the pixels are copied into bank 6 in row order. The existing
  draw code then needs no second destination.
- **A region takes the backdrop only where it has something.** The copy is
  165 T a row against the clear's 57. A table of each column's first and last
  rows with backdrop in them lets a region clear of the walls in every column
  be cleared as before. §6's 6% counted the copy on every region.
- **What it saved**, measured on the redraw alone in nine of Knight Lore's
  rooms: a full-screen redraw 3.6% to 20% cheaper, and a knight-sized region
  on the floor 2% to 73% cheaper. Where a region misses the walls, the gain is
  the shorter depth list. A turn's own cost could not be compared, because the
  two builds play the same keys out differently. See the fork's README.
- **The copy runs from contended memory**, in the $6000 region, because
  bank 2 was full.
- **Not yet built:** the room data at three times the size. The room list is
  in bank 4, but the castle is still Knight Lore's 128 rooms, with Pentagram's
  beside them.
