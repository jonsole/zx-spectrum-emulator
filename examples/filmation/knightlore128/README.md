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
| 3 | exits from a table, one destination per doorway as Pentagram has, instead of Knight Lore's 16x16 grid; up to 255 rooms | |
| 4 | one sprite sheet holding every Knight Lore and every Pentagram sprite, with Pentagram's scenery, creatures and mechanics | |
| 5 | the pre-drawn backdrop in bank 6 | |
| 6 | new art (placeholders for now) and the bigger castle | |
| 7 | sound on the AY | |

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
