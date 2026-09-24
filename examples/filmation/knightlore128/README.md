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
| 2 | the graphics library in banks 1, 3 and 7, room data in bank 4, and each room's graphics copied into the room page in bank 0 | |
| 3 | exits from a table, one destination per doorway as Pentagram has, instead of Knight Lore's 16x16 grid; up to 255 rooms | |
| 4 | one sprite sheet holding every Knight Lore and every Pentagram sprite, with Pentagram's scenery, creatures and mechanics | |
| 5 | the pre-drawn backdrop in bank 6 | |
| 6 | new art (placeholders for now) and the bigger castle | |
| 7 | sound on the AY | |

### Where stage 1 leaves memory

The image is Knight Lore's 48K layout, laid into the three banks a 128K starts
with: bank 5 at $4000, bank 2 at $8000 and bank 0 at $C000. The other five
banks are empty, so none of the 128K's extra memory is used yet.

`page.s` puts a bank at $C000 and keeps a copy of what it wrote, because
$7FFD cannot be read back. `start` pages bank 0 in, with the 48 BASIC ROM,
and nothing else pages anything yet. The stack is still at the top of bank 0,
where Knight Lore has it, so until it moves below $C000 nothing may page
bank 0 out. It moves in stage 2, which frees the space for it.

What was checked:
- The banks agree with the 48K image.
- All 127 rooms build object pools byte-identical to Knight Lore 48K's.
- In the emulator, a game starts, crosses rooms and picks up a charm, with
  $7FFD at $10 throughout.
