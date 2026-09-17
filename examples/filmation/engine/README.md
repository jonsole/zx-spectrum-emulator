# engine

The isometric engine under `examples/filmation`: masked sprites composited
through a small view buffer, objects kept in depth order, dirty-region redraw,
and the collision, character and mover machinery a Filmation game is built
from. `../knightlore/` is the game built on it.

The engine is not assembled on its own. A game's top-level file (here
`../knightlore/knightlore.s`) includes these files, lays out memory, and supplies the few
names listed under [What the game supplies](#what-the-game-supplies). Every
call between the two is a plain `CALL` or `JP` to a label, and every setting is
an `EQU`, so the split costs no bytes and no T-states.

## Files

| File | What it does |
|---|---|
| `object_struct.s` | The `OBJ` record and `ROOM_STRIDE`, the 32-byte slot every record sits in |
| `sprite_defs.s` | Sprite header layout and the `sprite_width_class` macro |
| `sprite.s` | The blit: `sprite_jump_table` into width-specific routines, and the 7×512-byte `sprite_rotate_table` for sub-byte shifts |
| `sprite_flip.s` | `sprite_flip_h` mirrors a sprite in place; `bit_reverse_bytes` makes its table |
| `object.s` | Projection (`object_place`), bounds and rotation (`object_update`), the draw walk (`objects_draw_all`), and collision (`object_collide`) |
| `depth.s` | The depth-ordered list: insert, unlink, step and relink. See [depth.md](depth.md) |
| `shift.s` | The rotation arena: per-object buffers for sub-byte shifts, and the shared buffer when it runs out |
| `vid_buff.s` | `pixelAddress`, and `vid_buff_copy` from the view buffer to the screen |
| `redraw.s` | Dirty regions: `region_reset`/`region_add`, `redraw_defer`/`redraw_flush`, `redraw_view`, `redraw_screen` |
| `turn.s` | Turn pacing: work is counted in units with `turn_add`, and `turn_pace` spends the rest of a fixed budget |
| `sound.s` | The beeper: `sound_cycle` and `sound_tone`, which count their time towards the turn |
| `room.s` | The room: bounds, doorways, the object count, and `room_add` → `room_show` |
| `walker.s` | Characters: two records moving as one figure, with walk, jump, gravity, doorways and the room-edge clamp |
| `mover.s` | The mover framework: `movers_step` gives every behaviour its turn, plus move, paint, clamp and the pair move |
| `screen.s` | `screen_sprite`: a graphic straight onto the screen, masked and byte-aligned |
| `tests/` | Z80 unit tests for the engine, the harness every suite shares, and `run_tests.py`, which runs these and the game's |

## Laying out memory

The game's top-level file owns the memory map, and has to honour these:

- **`view_buffer`**, `VIEW_BUF_ROWS * VIEW_BUF_WIDTH` bytes, at `ALIGN 512`.
  The row address folds into D with one `rl d`, which needs an even high byte.
  Define `VIEW_BUF_WIDTH` (8) and `VIEW_BUF_ROWS` (64) before the engine is
  included.
- **`room_objects`**, the pool, `POOL_SLOTS` records at `ALIGN 32`, with a
  trailing `ALIGN 32` so the last record is a whole slot. `depth.s` relies on
  every record's low byte being a multiple of `ROOM_STRIDE`.
- **`shift_shared`**, `SHIFT_SHARED_SIZE` bytes, anywhere.
- **`bit_reverse_table`** at `ALIGN 256`, filled by `bit_reverse_bytes`.
- **`sprite_table`** at `ALIGN 512`, since it is read through
  `(high sprite_table) / 2`.
- **`sprite_adj_index`** page-aligned, as the generated file lays it out.
- **`sound.s` above `$8000`**, because its timing assumes uncontended memory.
  The same goes for anything else that runs every turn.
- **Interrupts stay off.** The blit, the draw walk and the buffer clear all use
  SP as a data pointer, so an interrupt would push into a sprite. Put the stack
  in uncontended memory and leave room below it.

Two things must sit next to each other:

- **`redraw.s` falls through into the game's `redraw_hook`**, which must be
  included straight after it. The game's file should
  `ASSERT $ == redraw_view_end`. The hook draws whatever the game keeps
  straight on the screen over a region that has just wiped it, and returns.
  Its first byte may be poked to `RET` while a room is drawn in the dark.
- **`sprite.s`, `object.s` and `shift.s`** reach into each other's code
  (`object_update.shift_final`, `objects_draw_all.x_adjust`,
  `object_update.rotate`), and `sprite_jump_table` is computed from the size of
  a code block in `object_update`. They go into a build together.

## What the game supplies

The engine names nothing else of the game's.

| Name | Kind | Used by | What it is |
|---|---|---|---|
| `POOL_SLOTS` | EQU | object.s | Records in the pool |
| `ROOM_SLOTS` | EQU | room.s | How many of them `room_add` may fill |
| `room_objects` | label | object.s, mover.s, room.s | The pool (see above) |
| `COLLIDE_HEIGHT` | EQU | object.s, walker.s | A character's height as one collision box |
| `BEHAVIOUR_DEADLY`, `BEHAVIOUR_CRUSHING`, `BEHAVIOUR_HARMLESS` | EQU | object.s | Behaviours in `[DEADLY, CRUSHING)` kill a character they touch; those in `[CRUSHING, HARMLESS)` only when they move into it |
| `BEHAVIOUR_GIVES`, `BEHAVIOUR_GIVES_LAST` | EQU | object.s | Behaviours in this range get `MOVE_STATE` bit 3 when landed on |
| `BEHAVIOUR_LOOSE` | EQU | object.s | This and above are carried by what they stand on and shoved by what hits them |
| `BEHAVIOUR_FIRST_TURN` | EQU | mover.s | The lowest behaviour that gets a turn |
| `mover_tbl` | table | mover.s | One `DW` per behaviour from `BEHAVIOUR_FIRST_TURN` up. Each gets `IX` → its record, may corrupt anything but must leave the stack balanced, and returns |
| `deadly_touched` | byte | object.s | Set to 1 when a character touches something deadly |
| `walker_player` | label | mover.s | The character, which is not in the pool, so movers collide with it explicitly |
| `walker_glance` | routine | walker.s | A = block + phase in, the body frame to show out; IX → legs. Corrupts C. Return A unchanged for no glance |
| `sound_jump`, `sound_z` | routines | walker.s | A jump starting; a fall faster than two units a turn |
| `CHARACTER_STEP`, `CHARACTER_HALF_U/V`, `CHARACTER_BODY_UP`, `CHARACTER_JUMP_DZ`, `CHARACTER_FALL_MAX` | EQU | walker.s | How far a character walks, how wide it is, how high its body rides, how it jumps and falls |
| `CHARACTER_LARGEST`, `CHARACTER_TALLEST` | EQU | walker.s | Sprites sizing the two rotation buffers `character_keep` takes for good |
| `DOOR_ACROSS`, `DOOR_ALONG`, `DOOR_LEVEL`, `DOOR_HEIGHT` | EQU | walker.s | The box around a doorway that counts as standing in it |
| `character_steer` | routine | walker.s | Called with the step in D, E before a walk; may adjust it. Corrupts AF, BC, HL. A plain `RET` will do |
| `sprite_table`, `sprite_adj_index`, `sprite_adj_pairs`, `sprite_adj_mirror` | tables | object.s, room.s, screen.s | Generated from the game's artwork by `../knightlore/sprites.py` |

The top-level file also provides `VIEW_BUF_WIDTH`, `VIEW_BUF_ROWS`,
`view_buffer`, `shift_shared` and `bit_reverse_table`, as laid out above.

`tests/walker_tests.s` and `tests/mover_tests.s` supply most of this list
themselves -- the walker's numbers, a one-behaviour `mover_tbl`, stubs for
the rest -- which makes them a working minimal example.

## Using it

**A room's lifetime.** The game's builder empties the room state
(`shift_reset`, `object_list`/`sort_head`, `room_object_count`,
`room_door_z`), sets `room_half_u/v` and `room_floor_z`, and fills records
with `room_add`: IX → the next free record, HL → sprite, U, V, Z, size U,
size V, size Z, flags, and `room_behaviour` holding the behaviour. Both
pointers move on to the next. `room_show` then places them, sorts
them and draws the whole screen. Characters join afterwards with
`character_add`.

**Each turn.** A typical turn:

1. `movers_step` gives every behaviour its turn.
2. The game moves its characters with `character_walk` or `character_stand`.
3. `redraw_flush` draws whatever region is still waiting.
4. `turn_pace` spends the rest of the turn's budget.

Moves repaint through `region_reset`, `region_add`, `redraw_defer`: the old
extent and the new one are unioned and drawn once, and overlapping regions
merge.

**Moving an object yourself.**

1. `region_reset`, then `region_add`.
2. `depth_step`, with the step in D, E and A.
3. `room_adjust`, then `object_place`.
4. `region_add`, then `redraw_defer`.

`mover_paint` is exactly this, for a record whose DU, DV and DZ are set.

**Drawing straight to the screen.** `screen_sprite` takes A = graphic,
C = x, E = the row below the sprite, and D = 1 to mirror it.
