# Lightkeep

A game in the manner of *Fairlight* (The Edge, 1985) on the Filmation engine:
Knight Lore's knight and castle art, with objects and scenery from *Melkhior's
Mansion*, and Fairlight's way of playing -- five things carried within a load
limit, things pushed if they are not too heavy, keys for locked doors, a
sword, guards that chase, and LIFE that food and drink restore. Lightkeep is a
working name.

It began on 2026-10-01 as a copy of [`../knightlore128/`](../knightlore128/README.md),
whose README tells how that game got its 128K banks, its exit table, its
backdrop and its first placeholder art; everything there is true of this one
until a stage below changes it. Knight Lore 128K stays as it is, and the two
drift apart from here.

The rules being copied are Fairlight's own, as its disassembly found them:
[`game-disassemblies/notes/fairlight/`](../../../game-disassemblies/notes/fairlight/README.md)
-- `carrying.md`, `collision.md`, `meeting.md`, `doors.md` and `knight.md`
above all.

## Build and run

Launch **"ZX Spectrum: Lightkeep"** from the Run and Debug view. Its
`preLaunchTask`, `lightkeep.build`, assembles the game first. By hand:

```powershell
.\.venv-win\Scripts\python.exe examples\filmation\lightkeep\build.py
```

It writes `output/lightkeep.z80`, a version 3 128K snapshot, with the `.sld`
and the `.lst`. A server started by hand wants
`--rom roms/48.rom --rom roms/128.rom --machine 128`. The font is read from
`../knightlore/`'s unpacked sheet, as Knight Lore 128K's is. The keys and the
staging recipes are in [driving.md](driving.md), still Knight Lore 128K's.

## How far it has got

Each stage builds, runs in the emulator and is committed before the next
starts.

| Stage | What | State |
|---|---|---|
| 0a | the fork: Knight Lore 128K's game and data, building byte for byte as it | done |
| 0b | what Fairlight has no use for taken out of the code: the werewolf, the forty days and the sun and moon, the cauldron's quest, and Pentagram's bolt and what falls from the sky | done |
| 0c | Pentagram's creatures, rooms and art taken out, and the werewolf's, the transformation's and the sun window's art | done |
| 1 | Melkhior's art: a sheet per category, converted from your own copy of the game and never committed, and graphics.json and the graphic-map editor reading several sheets | |
| 2 | rooms that remember where things were left | |
| 3 | carrying: five slots, a weight on every template, a load limit of 7; pick up, drop, use, and keys 1-5 for the slot | |
| 4 | pushing by weight | |
| 5 | keys and locked doors | |
| 6 | LIFE, food and drink | |
| 7 | the sword, and guards that patrol and then chase | |
| 8 | the castle and the quest | |

### What stage 0b took out

The code that runs every turn had 107 bytes left below the stack in Knight
Lore 128K. With these gone it has 1,410, and the $6000 region has 1,318
where it had 259:

- **The werewolf.** The knight no longer changes at dusk and dawn, so
  `player_change`, `night` and the twinkle states are gone from `player.s`,
  and `player_form` sets his graphics once, at the start.
- **The clock.** `clock.s` and `sun.s` are gone: no days, no sun or moon
  window, and no DAYS word on the panel. The middle of the panel and the
  window on the right are empty, for LIFE and the messages in stage 6.
  `sun_fill`, the attribute fill the panel shares, is `attr_fill` now.
- **The cauldron.** The wizard's pot and its bubbles, the drop into it and
  the flash. The collectables are still there to carry, until stage 3
  replaces them.
- **The sky and the bolt.** `flyers.s`, `player_fire` and `mover_bolt`, the
  homer, the fallers and the puff, the four pool slots they kept
  (`EXTRA_SLOTS`), the rooms' `sky` table, and the bolt and puff that were
  resident in the room page. The fire key is still read; the sword will use it.
- **The end screen** says how much of the castle he saw and what it makes of
  that, without the day or the charms. The quest's own ending is stage 8.

Behaviour numbers were closed up over the six that went, and the mover tests
lost their three bolt tests. Removing `sound_fire` also fixed a fall-through:
in Knight Lore 128K, `fire_turned` falls into Pentagram's `sound_fire`, which
was put in front of the `sound_bounce` it was written to reach, so a fire
turning plays the bolt's sweep.

### What stage 0c took out

- **Pentagram's rooms**, $05 to $23 -- fourteen of them, built only of its
  templates and joined to nothing -- and its 19 scenery and 28 object
  templates. The castle is Knight Lore's 127 rooms and $25 (129 in all).
- **Pentagram's movers**: the spider, the creature, the dragons' heads, the
  platforms, the lift, the conveyors, the blocks that fall, crumble and are
  pushed in piles. The hooks the library's pacer and hopper ask for are
  Knight Lore's alone now, EQUs in `shared_movers.s` rather than routines that
  told the two games apart. Behaviour numbers closed up again: twenty in all.
- **Art no code draws**: Pentagram's 88 sprites, the werewolf's 20, the four
  twinkles, the sun and moon and the window's frame -- 116 sprites, the sheet
  912 rows tall where it was 1,311. `pentagram_merge.py` and
  `pentagram_templates.py`, which brought Pentagram in, went with them.
- **The knight's buffers** are sized from his own sprites: the sparkle for his
  legs and his tallest body, `sabreman.body.7`, for the top half.
  `sprite_sheet.py` names them rather than numbering them, so taking a band out
  of the sheet cannot move them.

That frees 101 graphic numbers, 113 in all:

    48-53, 56-61, 64-79, 88-90, 92-95, 149, 152-157, 176-177, 182-183, 186,
    188-245, 247-251, 253-255

The room page has 6,212 bytes left after the fullest room (2,116 before:
the werewolf was resident), and the code below the stack 2,110.

What was checked, in a 128K emulator: every one of the 129 rooms builds and
runs a dozen turns with a read watchpoint on `sprite_missing`, and none draws
it. Two kinds of read are stepped over as not draws: `room_page_fill` pointing
a room's unloaded graphics at it, and `backdrop_bands` reading the same
address in bank 6. The Z80 tests pass (lightkeep's movers_tests 69: the
Pentagram ones gone, the fire's pacer hooks kept), and so do the designer's
and the schema tests.

### How Melkhior's art comes in (stage 1, decided)

- **Seven sheets.** Knight Lore's `sprites.png`, committed as it is now, and
  one sheet per category of Melkhior's own viewer: Objects, Furniture, Doors,
  Characters, Walls and Floors. Each holds the whole category, in 1-bit.
- **Names are Melkhior's.** A sprite is its image and frame,
  `furniture:GrandfatherClock.2` or `objects:KeyCyan.0`, so the name on the
  "Melkhior in Mono" page is the name in the build. A plain name still means
  the main sheet.
- **`graphics.json` is the only selection.** A sprite costs a graphic number
  and room-page space only once a graphic names it, as an unused Knight Lore
  sprite costs nothing now. A small committed file holds per-sprite
  conversion settings (dithered, tiled, a threshold), and no pixels.
- **Converted once, then yours.** The converter writes each category's sheet
  into `melkhior/`, gitignored, from `~/Downloads/MelkhiorsMansion`. After
  that it is a file to retouch by hand, and the build reads it; converting
  again is a deliberate command that warns before it overwrites. It is never
  committed, so it has no backup but the one you keep.
- **The graphic-map editor learns several sheets** in the same stage, so the
  Melkhior sheets can be browsed and numbered there.
