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
| 0b | what Fairlight has no use for taken out: the werewolf, the forty days and the sun and moon, the cauldron's quest, Pentagram's creatures, rooms, bolt and flyers, and Pentagram's art | |
| 1 | Melkhior's art, made at build time from your own copy of the game and never committed | |
| 2 | rooms that remember where things were left | |
| 3 | carrying: five slots, a weight on every template, a load limit of 7; pick up, drop, use, and keys 1-5 for the slot | |
| 4 | pushing by weight | |
| 5 | keys and locked doors | |
| 6 | LIFE, food and drink | |
| 7 | the sword, and guards that patrol and then chase | |
| 8 | the castle and the quest | |
