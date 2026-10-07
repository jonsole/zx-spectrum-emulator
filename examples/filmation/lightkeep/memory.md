# Lightkeep's memory

Where everything in Lightkeep is, bank by bank, how much is left, and what
makes each part grow. The figures are from the build with carrying in
(stage 3), and bank 5 laid out so that every graphic number up to 511 fits.

The build prints the main figures every time, on the lines starting `>`. The
rest come from `output/lightkeep.sld`, which records each label's bank as well
as its address. [../engine/memory-128k.md](../engine/memory-128k.md) is the
plan these banks were laid out by. This is what they hold now.

**Bank 2 is kept for code that has to page other banks in.** Code that pages
$C000 cannot itself live there, so bank 2 is the only uncontended home for it,
and there is less of it than of anything else. Data and buffers go in bank 5,
or in a paged bank if they are only read while a room is built.

## At a glance

| Where | What | Used | Free | Grows with |
|---|---|---|---|---|
| bank 5, $4000 | the screen | 6,912 | -- | -- |
| bank 5, $5B00 | the room builder | 952 | 328 | room building code |
| bank 5, $6000 | data, and the backdrop's code | 4,132 | 988 | rooms' templates, things, graphics past 255 |
| bank 5, $7400 | view buffer, sprite table, object pool | 2,432 | 640 | the fullest room, the highest graphic number |
| bank 2, $8000 | the code that runs every turn, the rotation arena, the stack | 14,181 | 2,155 | code |
| bank 0, $C000 | resident sprites, the menu, end screen and carrying, then the room being played's sprites | 10,816 at most | 5,568 | the fullest room's sprites, carried things' sprites |
| bank 1, $C000 | the sprite library | 8,307 | 8,077 | sprites any room uses |
| bank 4, $C000 | rooms, templates, the thing table | 9,477 | 6,907 | rooms, templates, things |
| bank 6, $C000 | the backdrop | 6,144 | 10,240 | -- |
| banks 3, 7 | nothing yet | 0 | 32,768 | the library, when bank 1 fills |

During play bank 0 is at $C000. Banks 4, 1 and 6 are paged in only while
something is copied out of them: a room's record and things (bank 4), a room's
sprites (bank 1), a region of backdrop (bank 6). The stack is at the top of
bank 2, never in the bank that pages.

## Graphics past 255

Lightkeep is built for 512 graphic numbers, but today nothing uses one above
255. The first one that does costs bank 5 about 1,000 bytes. **The layout
below leaves room for all of them**, which was checked with a build that gave
the bridge deck graphic 511, as the worst case:

| Region | Today | With a graphic at 511 |
|---|---|---|
| $6000: the nudge tables gain a second page for 256-511 | 988 free | 540 free |
| $7400: the sprite table doubles to 1,024, and the pool moves up behind it | 640 free | 128 free |

In that build room $83's decks drew from the table's top half, and a game over
ran through the end screen to a new game.

## Bank 5, $4000-$7FFF: contended, always there

### $5B00-$5FFF, the room builder (952 used, 328 free)

| From | What |
|---|---|
| $5B00 | `room_build.s`: building a room, its variables, unpacking positions |
| $5D78 | `../engine/room.s`: `room_add`, `room_adjust`, the room's bounds and doorways |
| $5E79 | `glance.s` |

### $6000-$73FF, data and the backdrop's code (4,132 used, 988 free)

| From | Bytes | What |
|---|---|---|
| $6000 | 256 | `bit_reverse_table`: every byte with its bits the other way round, for mirroring. It has to start a page, and $6000 does |
| $6100 | 578 | `generated/room_data.s`: the room shapes, which templates are doorways, `mover_of`, `pickup_tbl`, `room_vertical_tbl`, `start_rooms`, and the buffers a room's templates are copied into |
| $6342 | 510 | `panel_data.s` and `generated/sprite_adj_gen.s`, every graphic's nudges, its index on a page boundary at $6400 |
| $6540 | 320 | `generated/font.s` |
| $6680 | 416 | `shift_shared`: the one buffer every deferred rotation goes through |
| $6820 | 226 | `sound_fx.s` |
| $6902 | 46 | `monster_gate.s` |
| $6930 | 236 | `room_find.s`, with `room_record`, a copy of the room's record |
| $6A1C | 555 | `things.s`, with `things_here` (12 things × 14) and `thing_record`, which writes an entry for carry.s |
| $6C47 | 371 | `storeys.s` |
| $6DBA | 129 | `room_page.s` and `page.s` |
| $6E3B | 120 | `busy.s` and the engine's |
| $6EB3 | 369 | `backdrop.s` and `backdrop_build.s`: run for every region, so not cold, but they page bank 6 |
| $7024 | 988 | free |

`room_templates` is sized by `rooms_source.py`: the most template bytes one
room names, plus room for four more things arriving through a hole, each
copying the largest kept template (52).

### $7400-$7FFF, the view buffer, the sprite table and the pool (2,432 used, 640 free)

| From | Bytes | What | Aligned to |
|---|---|---|---|
| $7400 | 512 | the view buffer: 8 bytes × 64 rows | 512 |
| $7600 | 512 | `sprite_table`: a pointer for each graphic number 0-255; 1,024 once one is 256 or more | 512 |
| $7800 | 1,408 | the object pool: 44 slots of 32 | 32 |
| $7D80 | 640 | free | |

The order is the point: the two tables that need a 512 boundary come first,
and the pool, which needs only 32, goes last. Nothing is lost lining them up,
and when the sprite table doubles the pool simply moves up behind it.

The pool is `ROOM_MAX_OBJECTS` + `POOL_SPARE` slots: the fullest room's records
(36), worked out by `rooms_source.py`, and 8 more for things brought in from
other rooms (stage 2b).

### How it got here

Stage 2b filled the region. Room $83's test stairs had 24 records, 12 boxes
and 12 decks, which made the fullest room 41. With the 8 spare slots the pool
was 49, and in the old order -- pool, then the reversal table, then the sprite
table -- 224 bytes went on alignment. Nothing was free, and the sprite table had
no room to double. Three changes made the room back:

- **The order.** The sprite table now comes before the pool.
- **`bit_reverse_table` moved to $6000.** That address starts a page, so the
  move cost nothing to line up.
- **Room $83 has a deck every other tread.** It keeps all 12 invisible boxes,
  so climbing is unchanged. The fullest room is 36 again.

Graphics past 255 also want the $6000 region's room, for their second page of
nudges, so the end screen and the tunes (`end.s`, `../engine/tune.s`) moved to
bank 0 beside the menu. Neither pages a bank in.

## Bank 2, $8000-$BFFF: uncontended, always there (14,181 used, 2,155 free)

| From | Bytes | What |
|---|---|---|
| $8000 | 3,840 | `sprite_jump_table`, the blit's entry points |
| $8F00 | 78 | `sprite_flip_h` |
| $8F4E | 1,639 | `../engine/object.s`: placing, collision, the draw walk; its `collide_list` is two bytes a pool slot |
| $95B5 | 284 | `../engine/depth.s` |
| $96D1 | 4,288 | `shift_arena`: the rotation buffers, the knight's two kept for good |
| $A793 | 193 | `../engine/shift.s` |
| $A854 | 785 | `../engine/walker.s` and `knight.s` |
| $AB65 | 1,341 | the movers: `movers.s`, `../engine/mover.s`, `shared_movers.s`, `../engine/movers.s` |
| $B0A2 | 457 | sound, the panel and input |
| $B26B | 238 | `main.s` and `../engine/turn.s` |
| $B359 | 631 | `player.s` |
| $B5D0 | 405 | the redraw, the overlay and the copy to the screen |
| $B765 | 2,155 | free |
| $BFD0 | 48 | `STACK_RESERVE`, kept clear below the stack (34 measured in use) |

The stack starts at $C000, so its first push lands at $BFFE.

## Bank 0, the room page, $C000-$FFFF: paged in for all of play

| From | Bytes | What |
|---|---|---|
| $C000 | 4,406 | the resident sprites: the knight, everything the code draws by number, and everything that can be carried (the block and the chest), which can be put down in any room |
| $D136 | 703 | the menu (`screen.s`, `menu.s`, `end_at.s`) |
| $D3F5 | 618 | the end screen and the tunes (`end.s`, `../engine/tune.s`) |
| $D65F | 1,333 | carrying (`carry.s`): it pages nothing in, so it can live in the bank that is always in during play |
| $DB94 | 3,756 | `room_page`: the room being played's own sprites, copied out of the library when it is built -- 3,756 for the fullest, room $01 |
| $EA40 | 5,568 | free, after the fullest room |

## Bank 1, $C000: the library (8,307 used, 8,077 free)

Every sprite a room loads, 47 of them, the largest 352 bytes. A room also
loads the sprites of the things that can fall into it from the rooms above. `room_page_fill`
copies a room's into bank 0 through the rotation arena. When this bank fills,
the library carries on into bank 3 and then 7. Melkhior graphics go here as
rooms come to use them.

## Bank 4, $C000: the rooms (9,477 used, 6,907 free)

| From | Bytes | What |
|---|---|---|
| $C000 | 5,479 | `generated/room_list.s`: every scenery and object template, the 129 room records, and the thing table twice -- `things_start` and `things_live`, 57 things × 8 each |
| $D567 | 3,998 | `generated/room_sprites.s`: which library sprites each room loads, its index on a 512 boundary |

## Bank 6, $C000: the backdrop (6,144 used, 10,240 free)

A copy of the room's background, 32 bytes × 192 rows, drawn once as the room is
built. Every redraw starts its region from it rather than from nothing.

## Banks 3 and 7: free

Nothing yet. Bank 7 is the 128K's second screen, which nothing shows. Both are
where the library goes after bank 1, and any table only read while a room is
built can go here too. During play they can be paged in only between turns,
since bank 0 has to be in for the drawing.

## Measuring again

`build.py` prints the six `>` lines. Each comes from a `DISPLAY` in
`lightkeep.s`. Every region in banks 5, 2 and 0 has an `ASSERT` that stops the
build when it overflows. Bank 4 has none, so its free figure is the one to
watch. For the detail, list the labels by bank from the SLD: the fifth field of
each line is the bank, the sixth the address. This file's tables were made that
way. To check graphics past 255 still fit, give any graphic in `graphics.json`
the number 511 and build.
