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
| 4c-ii | what Pentagram puts up itself: the things that fall from the sky, the well's bucket, the bolt and the puff | |
| 5 | the pre-drawn backdrop in bank 6 | |
| 6 | new art (placeholders for now) and the bigger castle | |
| 7 | sound on the AY | |

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

### Where memory is now (stage 2)

| Bank | At | Holds | Free |
|---|---|---|---|
| 5 | $4000 | the screen; the room builder at $5B00; the room templates, the tables, the font, `room_find`, `room_page_fill`, `page.s`, the menu and the end screens from $6000; the view buffer, the object pool, `sprite_table` and the other aligned tables from $7400 | 16 at $5B00, about 600 at $6000, 20 at $7400 |
| 2 | $8000 | the code that runs every turn and the rotation arena, then the stack below $C000 | about 350 |
| 0 | $C000 | the **room page**: the resident sprites (8.9K), then the room being played's own; paged in for the whole of play | 3,224 after the fullest room |
| 4 | $C000 | the rooms (`room_list.s`), and what each loads into the room page (`room_sprites.s`) | about 10,000 |
| 1 | $C000 | the **library**: the sprites loaded room by room (6.2K) | about 10,000 |

Banks 3, 6 and 7 are empty. The library moves on into banks 3 and 7 when it
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
$7FFD cannot be read back. Only `room_find` and `room_page_fill` page
anything, both while a room is built, and both put bank 0 back before they
return. The stack is at the top of bank 2, so a RET never depends on what is
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
