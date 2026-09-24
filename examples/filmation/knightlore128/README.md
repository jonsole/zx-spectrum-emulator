# Knight Lore 128K

Knight Lore on the 128K Spectrum, growing into a bigger castle: more rooms,
Pentagram's graphics and creatures beside Knight Lore's own, and new scenery
-- torches on the walls, more furniture, bridges, parapets. It began on
2026-09-24 as a copy of [`../knightlore/`](../knightlore/). That 48K game stays
as it is, and the two will drift apart from here.

It is built on the same engine as the other two games, [`../engine/`](../engine/README.md),
and follows the 128K memory plan in [`../engine/memory-128k.md`](../engine/memory-128k.md).

## Build and run

Launch **"ZX Spectrum: Knight Lore 128K"** from the Run and Debug view. Its
`preLaunchTask`, `knightlore128.build`, assembles the game first. By hand:

```powershell
.\.venv-win\Scripts\python.exe examples\filmation\knightlore128\build.py
```

It writes `output/knightlore128.z80`, a version 3 128K snapshot, along with
the `.sld` and the `.lst`. The 128K model needs `roms/128.rom`. The launch
entry uses it, and a server started by hand wants
`--rom roms/48.rom --rom roms/128.rom --machine 128`.

The game extracts nothing of its own. Its castle (`rooms.json`,
`templates.json`), its graphics (`sprites.png`, `sprites.json`,
`graphics.json`) and its charms (`specials.json`) are carried and are what you
edit. The font is Knight Lore's, read from `../knightlore/`'s unpacked sheet,
so that game's `kl_extract.py` must have been run once. The keys, the symbols
and the staging recipes are in [driving.md](driving.md).

## How far it has got

Each stage builds, runs in the emulator and is committed before the next one
starts.

| Stage | What | State |
|---|---|---|
| 0 | the fork: Knight Lore's game and data, building byte for byte as Knight Lore | done |
| 1 | the 128K shell: a 128K device and snapshot, paging through `page.s`, Knight Lore unchanged | done |
| 2a | room data to bank 4, the sprites to bank 0 on their own, the stack below $C000, and the menu and the end screens down to $6000 | done |
| 2b | the graphics library in bank 1 (3 and 7 as it grows), and each room's graphics copied into the room page in bank 0 | done |
| 3 | exits from a table, one destination per doorway as Pentagram has, instead of Knight Lore's 16x16 grid; up to 255 rooms | done |
| 4a | one sprite sheet holding every Knight Lore and every Pentagram sprite; Pentagram's graphics numbered 188 up | done |
| 4b | Pentagram's scenery and object templates, and rooms that use them | done |
| 4c-i | Pentagram's movers for what its rooms place: the spider, the creature, the dragons' heads, platforms, lift, conveyors, and blocks that fall, sink, crumble or are shoved | done |
| 4c-ii | what Pentagram puts up itself: the things that fall from the sky, his bolt and the puff | done |
| 5 | the pre-drawn backdrop in bank 6: the walls drawn once a room, and each redraw starting from them | done |
| 6a | graphic numbers freed for new art: duplicates of the same sprite merged, 24 numbers free | done |
| 6 | new art (placeholders for now) and the bigger castle | |
| 7 | sound on the AY | |

### Graphic numbers for new art (stage 6a)

A graphic number is one byte, and stage 4 used all of them but 255. Knight
Lore gives several things two or three numbers, each drawing the same sprite
with the same nudge. Nothing in the code tells those numbers apart: a placed
object's behaviour is its template's, not its graphic's, and what animates
steps bit 0 of its number (fires, balls, the gate), bits 0 and 1 (the ghost,
the spell), or a guard's leg bits. So each set was merged into one number:

| Numbers given back | What they drew | Now drawn by |
|---|---|---|
| 54, 55, 62, 91, 143 | the plain block, in five templates | 7 |
| 144-149, 152-157 | a guard's and the wizard's legs | 16-21, 24-29, the knight's own legs |
| 176, 177 | a second fire | 86, 87 |
| 182, 183 | a second ball | 178, 179 |
| 246, 252 | a copy of the puff's last frame; the well's bucket | nothing: neither is drawn |

A guard's legs could become the knight's because `mover_guard_face` reads the
number's bits: bit 3 is which way the legs face and the low three count the
walk. Knight Lore laid 16 and 24 out the same way as 144 and 152. Number 16
takes the guard's box, which only a template placing it reads.

That makes 24 numbers free: 54, 55, 62, 91, 143-149, 152-157, 176, 177, 182,
183, 246, 252 and 255. Something that animates needs its frames on aligned
numbers. 144-147 and 152-155 are runs of four, and 54/55, 148/149, 156/157,
176/177 and 182/183 are pairs.

What was checked, in a 128K emulator:
- Knight Lore's 127 rooms build the same objects as the 48K game, with the
  merged numbers mapped.
- Nothing drew `sprite_missing`.
- Guards walk through all twelve leg frames, in $01 and $2E. The wizard's legs
  step in $88, a bouncing ball flickers in $08, and a fire in $93.
- The designer's tests, the schema tests and the Z80 tests pass.

### The backdrop (stage 5)

**The walls are drawn once a room** (`backdrop.s`, `backdrop_build.s`). Nothing
can get behind a room's walls and the trees along its back. These are the
pieces `templates.json` names in `meta.background`, which the build marks
`OBJ_BACKGROUND`. `room_show_backdrop` draws them alone onto the screen,
while the attributes still hold it black, and copies the pixels into bank 6.
That copy is the backdrop: 6,144 bytes, 32 a row, top row first. The
background pieces then leave the depth list, the rest of the room is drawn
over the backdrop, and the room is shown.

After that, a region the knight or a monster disturbs starts from the
backdrop's bytes for its rows instead of from nothing. Engine/redraw.s calls
the game's `view_clear` where it used to clear the buffer. The draw walk only
has what stands in front of the walls. The pieces stay in the pool, so they
still stop things.

The copy is 165 T a row against the clear's 57, so a region only takes it
when it needs it. `backdrop_band` keeps, for each of the 32 columns, the first
row with anything of the backdrop in it and one past the last. A region clear
of the walls in every one of its columns is cleared the old way. That covers
most of what moves out on the floor.

The walls also need no rotation buffers now. They are drawn once, so they
rotate through the shared buffer at build time (`OBJ_SHARED_SHIFT`, set by
`rooms_source.py`), and the arena is left to what moves. What moves still fills
it, though. Played for sixty turns a room, the arena reaches 4,224 of its 4,288
bytes in $13 (Pentagram's trees and piles) and 4,134 in $87 (the gates), each
with one piece short, which rotates at draw time. So it stays the size it was.

**What it saves.** The redraw was measured on its own, because two builds
with different layouts play the same keys out differently, and a turn's cost
is mostly what happens in it. In each of nine rooms, redraw_view was called on
sixteen 8x48 tiles covering the screen, and on a knight-sized region out on
the floor, in both builds:

| Room | The whole screen | A region on the floor |
|---|---|---|
| $01 | -17.5% | -5.4% |
| $41 | -16.5% | -27.4% |
| $CF | -20.0% | -6.3% |
| $97 | -19.9% | -5.4% |
| $87 | -16.8% | -72.6% |
| $88 | -5.6% | -2.9% |
| $07 | -4.5% | -2.9% |
| $13 | -3.6% | -2.0% |
| $1C | -8.3% | -7.2% |

A floor region is cheaper even where it misses the walls, because the depth
list is shorter. It is much cheaper where the floor region's box reaches the
walls behind it, as in $87 and $41. The only tiles that cost more, by about
2,500 T, are the low corners at the sides of the screen. They reach the foot
of a side wall and pay for the copy there, against the little wall they would
otherwise have drawn.

Per turn, with the knight walking about, the two builds came out between
37% faster ($87) and 9% slower ($01). That is play diverging, not the
backdrop: the same room swung from 15% faster to 5% slower between two
measurements, across a change that can only make it cheaper.

**Where it lives.** `backdrop_clear` is in the $6000 region with the cold
code, because bank 2 has no room for it. It has to come after
`engine/redraw.s`, whose `view_clear_zeroes` it expands. It runs once a
region, so it is not cold, and on a real 128K it pays for contended memory.
The emulator does not model that yet.

What was checked, in a 128K emulator:
- Nine rooms redrawn in full from the backdrop, with walls, trees, arches and
  gates as before.
- Knight Lore's 127 rooms build the same objects as the 48K game. The only
  differences are the depth-list links and the rotation fields.
- Nothing drew `sprite_missing`.
- Pentagram's movers, the flyers and the bolt, a game over back to the menu,
  and a charm picked up.
- Both 48K images are byte-identical after the engine's `view_clear` hook.
- The Z80 tests pass.

### Both games' art (stage 4a)

`sprites.png` is Knight Lore's sheet with Pentagram's underneath it, all 88
of its sprites, and `sprites.json` names them under `pentagram`:
`pentagram.wall.trees`, `pentagram.door.stone`, `pentagram.block` (the plain
block and the three frames it crumbles through), `pentagram.well` (the well
and its bucket), `pentagram.dragon`, `pentagram.homer`, `pentagram.faller`
and the rest. `pentagram_merge.py` did it, once, and says where each sprite
came from.

Knight Lore's graphic numbers stay 1-187, because its code does arithmetic on
them. Pentagram's are 188-241: one number for each sprite, nudge and box
that its rooms place or its code draws. Pentagram gave one sprite several
numbers, one for each thing its code did with it, but the remake picks a
behaviour by template, not by graphic, so one is enough. That leaves 14
numbers free. Stage 6's new art will want more than that, and the room there
is Knight Lore's scenery graphics: no code refers to them by number, so they
could be renumbered.

Some of Pentagram's art belongs to its own game and has no number: its
Sabreman, its panel, the frame round its end screen, its collectables, the
quest's items and the pentagram's pieces. It is in the sheet, and
`sprite_source.py` leaves a sprite no graphic draws out of the game: 38 of
them. Everything under `pentagram` is loaded room by room (`ROOM_GROUPS`); the
library holds 85 sprites and still fits bank 1. The busy-room code moved to
the $6000 region to make room for the longer `sprite_table`.

### The sky and the bolt (stage 4c-ii)

**Things fall out of the sky** (`flyers.s`), as in Pentagram. After 255
turns in a room with a sky, each turn has a one-in-four chance of dropping
something from Z 216 near the middle. It is one of eight: mostly homers,
which fly at him and do no harm, and fallers of two and four frames, which
roam and kill. After a drop the wait is 24 turns. There are two at most, in
two slots kept after the room's own objects.

A room has a sky when `rooms.json` says `"sky": true`. `rooms_source.py`
makes `room_sky`, a bit a room, from that, and a sky room loads the flyers'
sprites (`SKY_GROUPS` in `sprite_sheet.py`). So only a sky room can drop
anything. The imported Pentagram rooms have a sky, except the well's, where
Pentagram drops nothing. Knight Lore's rooms have none, so it plays as
before. Each flyer slot sizes its one rotation buffer from
`sprite_sky_largest`, a two-byte header the generator makes the size of the
largest flyer frame: the frames themselves are in the library at room entry.

**He can fire a bolt** (`player_fire`, in `player.s`). On the keyboard the
top row is split as Pentagram splits it, alternately: Q E T  U O jump,
W R  Y I P fire. The two halves are read separately, because the port Knight
Lore reads ORs them together. One press is one bolt, and he has at most two
in flight. A bolt goes the way he faces, eight a turn, and hurts only what
fell from the sky: it puts a flyer out in a puff, and puffs out itself
against anything else. There is no score. On a joystick the button still
jumps, as in Knight Lore, and nothing fires.

The bolt and the puff are resident (`RESIDENT_GROUPS`), since he fires in any
room.

**Not brought across:** the well and its bucket. Shooting the well 32 times
brings the bucket out, and the bucket flies to a quest item and marks it
done. That is Pentagram's quest, which this game does not have, so the well
here is only scenery.

**Making room for it.** It filled all three places at once, and four
changes made space:
- **The room templates moved to bank 4.** `room_find` copies the ones a room
  names into `room_templates`, at most 214 bytes, and points `room_bg_at`
  and `room_fg_at` at the copies, which is where `room_build` looks now.
  That gave bank 0 back about 2K.
- **The rotation arena is 4,288 bytes, not 4,992.** The arena is now the
  game's to reserve (an engine change; Knight Lore and Pentagram keep 4,992,
  byte for byte). With less of it, more wall pieces rotated at draw time:
  slower, but drawn right. Stage 5's backdrop took the walls out of rotation
  altogether.
- **The pickup code, `screen_sprite` and the menu moved into bank 0.** The
  pool's four new slots had pushed the aligned tables at $7400 a page on.
- **`sun.s` and `flyers.s` are in the $6000 region.**

What was checked, in a 128K emulator:
- In sky room $06, with the wait forced, a two-frame and a four-frame faller
  fall and roam. In room $B3, which has no sky, nothing falls.
- W fires a bolt, which flies eight a turn with its three frames and puffs out
  at the wall through all seven puff frames.
- Knight Lore's 127 rooms build the same objects as the 48K game. The only
  differences are which pieces have their own rotation buffers, from the
  smaller arena.
- Nothing drew `sprite_missing`. `room_page_fill` reading the library at the
  same address is set aside.
- A game over reaches the menu, and a charm is picked up.
- `movers_tests` has three more tests, for the bolt (74 pass).

### Pentagram's movers (stage 4c-i)

Pentagram's templates now move as they do there. `mover_of` in `movers.s`
gives each its behaviour, and the behaviours are numbered in with Knight
Lore's so that the engine's bands still hold:

| | Knight Lore's | Pentagram's |
|---|---|---|
| deadly, no turn (1) | gargoyles, spikes | spiky grass, thorns, water, the thorny bush |
| deadly monsters, through `monster_gate` (3-13) | fires, guards, the ghost, balls | the spider, the creature, the pacing dragons' heads |
| deadly (14), crushing (15) | the gate | the bobbing dragon's head |
| harmless (16-25) | sliding blocks, the spell, the cauldron | platforms, the lift, conveyors, the falling block, the crumbling block |
| gives way (26-27) | the dropping and collapsing blocks | the sinking block (the same mover) |
| loose (28 up) | the moveable block, table, chest, charms | stumps, cubes, tables and stones, shoved with their pile |

Knight Lore's numbers from 10 up moved to make room.

Where the two games share one of `engine/movers.s`'s movers but gave it
different constants and hooks, `movers.s` has a small routine that looks at
the behaviour:
- **The pacer:** a fire hums, flickers and steps one; a platform or a dragon
  is silent, keeps its frame and steps two.
- **The hopper:** a ball flickers, hums and clicks; a dragon does none of it,
  and `mover_dragon_hops` gives it its own top, Z 176.
- **The monsters:** Pentagram's `monster_sits_out` never sits out, because
  `monster_gate` has already decided.

Three things are not as Pentagram has them:
- **The thorny bush is deadly but cannot be shoved.** A behaviour is either
  loose or deadly here: the loose band runs to the top, the deadly one ends
  where the harmless one starts, and the crushing gate sits at that end. So
  the spider shut in by bushes in room $16 stays shut in.
- **The bobbing dragon rises three a turn**, the balls' `HOPPER_RISE`, where
  Pentagram's rose two. It is the one constant the two cannot both have.
- **The busy rule is Knight Lore's.** Pentagram's movers sit turns out
  through `monster_gate`, not their own `monster_sits_out`.

The sun and the moon's code moved from bank 2 to the $6000 region to make
room for the engine's movers.

What was checked, in a 128K emulator:
- In the imported rooms, the dragons pace and bob and the creature and the
  spiders roam. A spider shut in by stumps or cubes stays until something is
  shoved. A conveyor carries the knight the way its graphic says.
- Nothing draws `sprite_missing`.
- Knight Lore's 127 rooms build the same objects as the 48K game, with the
  behaviour numbers mapped.
- `tests/movers_tests.s` has eight more tests for the shared hooks.

### Pentagram's templates and rooms (stage 4b)

`pentagram_templates.py`, run once, brought across every template a
Pentagram room places, 19 scenery and 28 object, named for what they are:
`scenery_pentagram_trunk_arch_n`, `scenery_pentagram_stone_arch_e`,
`scenery_pentagram_trees_0`, `object_pentagram_well`,
`object_pentagram_dragon_hops`, `object_pentagram_conveyor_1` and so on.
Their archways are in `meta.doorways` and their walls in `meta.background`.
The raised archway on a walkway and its ledge stayed behind. Their opening is
off the middle of the wall, and this game's doorway test assumes the middle.

It also brought two corners of Pentagram's map, so the templates have
somewhere to be seen:
- the forest round the well: Pentagram's rooms 29, 22, 12, 11, 13, 10, 14 and
  9, here $05, $06, $07, $11, $13, $15, $16 and $17;
- stone rooms: 95, 96, 97, 108, 82 and 98, here $19, $1A, $1B, $1C, $1E and
  $23.

Doorways within a cluster still lead to each other; doorways out of it are
walled up. Neither cluster is joined to the castle: that is for the castle's
design. Until then, write `room_number` to go there, or use the 1 and 2 keys
of a `--debug-room` build. Everything in them stands still, because the
behaviour that goes with Pentagram's templates is stage 4c.

Three things had to change to make room:
- **An object group is now two bytes**: the template, then the count.
  Knight Lore packs both into one byte, which reaches 32 templates, and the
  two games together have 57. `meta.rules.groupBytes` says so, and the room
  designer follows it.
- **The templates moved into bank 0**, after the resident sprites. They are
  read while a room is built, when bank 0 is paged in, and Pentagram's
  doubled them past what the $6000 region could hold. The fullest room still
  fits the page, with about 1,150 bytes to spare. If it runs short, the next
  step is to copy only a room's own templates out of bank 4, as `room_find`
  copies its record.
- **The busy-room code moved to $6000**, to make room for the longer
  `sprite_table` (that was in 4a).

What was checked:
- Each of the 14 imported rooms builds and runs 20 turns in a 128K emulator,
  drawing Pentagram's tree and stone walls, archways, the well, stumps,
  thorns, blocks and the rest, and nothing draws `sprite_missing`.
- Knight Lore's 127 rooms still build the same objects as the 48K game.

### How the rooms join (stage 3)

Knight Lore works out where a doorway leads: the room number is a row and a
column of a 16 x 16 grid, so north is +$10 and east +1. This castle reads it
instead, so that a bridge or a tower can join any two rooms.

- **In `rooms.json`**, every doorway's scenery entry says the room it leads to:
  `{ "template": "scenery_arch_n", "destination": 16 }`. Room 0 is a real
  room, so a doorway with no way through says `null`, or leaves the
  destination out. It is then drawn but walled up.
  `meta.rules.exits: "table"` says the castle works this way.
- **In `templates.json`**, `meta.doorways` names the doorway templates and
  the wall each stands in, and `meta.background` names the walls and trees.
  Knight Lore decided both by the template's position in the table. Here any
  template can be a doorway, a new arch or a bridge, by adding it to the list.
- **In the room record**, a scenery entry is two bytes: the template and the
  room it leads to. `ROOM_NO_EXIT`, a number no room has, stands for nowhere.
- **In the code.** `room_door_note` looks each template's wall up in
  `scenery_door_side`, a table the generator makes from `meta.doorways`, and
  keeps the destination in `room_door_to`. `player_exit` reads it back.
  Pentagram's builder and exit work the same way.
- **The checks.** `rooms_source.py` stops on a destination that is not a room,
  or one on scenery that is not a doorway. It says, without stopping, when a
  doorway has no door back or a room has no way in.

Knight Lore's 286 doorways were each given the room its arithmetic lands on.
Every one leads back, and every room can be reached from the four start rooms.
The end screen's percentage and rating are worked out from `ROOM_COUNT`, not
from 128. For 128 rooms that gives Knight Lore's own `$A41A` and `$28`.

What was checked for stage 3, in a 128K emulator:
- After each of the 128 rooms is built, `room_door_z` and `room_door_at` agree
  with Knight Lore 48K's for every side with a doorway, and `room_door_to`
  holds each doorway's destination from the table.
- The knight was put inside each doorway and walked out, in both builds.
  In each build, 107 doorways took him to the room the table names, by the
  right side. The rest stalled against something in the room, and 152 of
  them stalled in both builds; one more in each build stalled where the other
  got through, which is the random start. That is the test's placement and
  not the exits: none took him anywhere wrong.
- All 127 rooms still build the same objects as Knight Lore 48K's, and no
  graphic drew `sprite_missing`.

### Where memory is now (stage 5)

| Bank | At | Holds | Free |
|---|---|---|---|
| 5 | $4000 | the screen; the room builder at $5B00; from $6000 the room shapes and this room's templates, the tables, the font, `room_find`, `room_page_fill`, `page.s`, the busy rule, the sun, the sky, the backdrop's copy and its build, the end screens; from $7400 the view buffer, the object pool, `sprite_table` and the other aligned tables | 28 at $5B00, about 265 at $6000, none at $7400 |
| 2 | $8000 | the code that runs every turn and the rotation arena (4,288), then the stack below $C000 | about 100 |
| 0 | $C000 | the **room page**: the resident sprites, the pickup code and the menu, then the room being played's own; paged in for the whole of play | about 650 after the fullest room |
| 4 | $C000 | the rooms and every template (`room_list.s`), and what each room loads into the room page (`room_sprites.s`) | about 6,000 |
| 1 | $C000 | the **library**: the sprites loaded room by room, both games' | about 2,000; it goes on into bank 3 by itself |
| 6 | $C000 | the **backdrop**: the room's walls, 6,144 bytes | about 10K |

Banks 3 and 7 are empty. The library moves on into banks 3 and 7 when it
outgrows bank 1; `sprite_source.py` does that by itself.

**Resident or loaded.** `ROOM_GROUPS` in `sprite_sheet.py` names the sprite
groups loaded room by room: the walls, the doors, the scenery, and the art of
the movers rooms place (guard, wizard, fires, balls, ghost, gate). Everything
else is drawn by the code in any room, so it is resident in bank 0 for good.
That covers the knight and the wolf, the spells and the twinkle, the
collectables, the sun, the window, the panel and the menu. A room that names
any sprite in a loaded group gets the whole group, which covers a mover
cycling through its frames without a list of which frames each mover uses.
The fullest room, $01, loads 4,220 bytes.

**Entering a room.** `room_build` calls `room_page_fill` (`room_page.s`)
once `room_find` has the record. It pages bank 4 in and resets `sprite_table`
from `sprite_base`. Resident graphics then point at their sprites, and every
library graphic points at `sprite_missing`, a checked square. Then, for each
library sprite the room loads, it:
- pages that sprite's bank in;
- points the sprite's graphics at where it is about to go in the page;
- copies it into the rotation arena, past the knight's kept buffers;
- pages bank 0 in and copies it on into the page.

The library and the page are both at $C000, which is why the copy goes
through the arena. That is about 4K of copying on entering the fullest room,
two or three frames.

A graphic the rules missed draws the checked square, not whatever the page
last held. The check below puts a read watchpoint on it.

`page.s` puts a bank at $C000 and keeps a copy of what it wrote, because
$7FFD cannot be read back. `room_find` and `room_page_fill` page while a
room is built, and so does the backdrop's capture. `backdrop_clear` pages
bank 6 in for a region that takes the backdrop, which is the one paging
during play. All of them put bank 0 back before they return. The stack is at the top of bank 2, so a RET never depends on what is
paged in.

In stage 2a the menu and the end screens moved down to the $6000 region, which
is cold code in contended memory. That moved the rooms-seen bitmap across a
page boundary, and `room_seen` indexed it with L alone. Its bits then landed a
page lower, in the room templates, and the tally read 63% after two rooms. It
now carries into H.

What was checked:
- In a 128K emulator, all 127 rooms build the same objects as Knight Lore
  48K's. Sprite, buffer and list pointers are compared by the sprite or label
  they point at, since every address moved.
- Each room then runs for 40 turns, movers and all, with a read watchpoint on
  `sprite_missing`. Nothing read it.
- A game starts, walks through a doorway and picks up a charm.
- Losing the last life shows a right tally and goes back to the menu.
- $7FFD is $10 whenever the game is running.
