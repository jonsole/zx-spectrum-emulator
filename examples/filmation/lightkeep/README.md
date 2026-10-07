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
`../knightlore/extracted/`'s unpacked sheet, as Knight Lore 128K's is. The keys and the
staging recipes are in [driving.md](driving.md), still Knight Lore 128K's.

Where everything is in memory, and how much is left, is in
[memory.md](memory.md).

## How far it has got

Each stage builds, runs in the emulator and is committed before the next
starts.

| Stage | What | State |
|---|---|---|
| 0a | the fork: Knight Lore 128K's game and data, building byte for byte as it | done |
| 0b | what Fairlight has no use for taken out of the code: the werewolf, the forty days and the sun and moon, the cauldron's quest, and Pentagram's bolt and what falls from the sky | done |
| 0c | Pentagram's creatures, rooms and art taken out, and the werewolf's, the transformation's and the sun window's art | done |
| 0d | the collectables and the wizard taken out: the charms, picking up and putting down, the carried objects in the corner, the extra life, and the wizard who walked room $88 | done |
| 1 | Melkhior's art: a sheet per category, converted from your own copy of the game and never committed, and graphics.json and the graphic-map editor reading several sheets | done |
| 2 | rooms that remember where things were left: the thing table | done |
| 2b | up and down: holes in the floor to drop through, and stairs up to the room above | done |
| 3 | carrying: five slots, a weight on every template, a load limit of 7; pick up, put down, and keys for the slot | done, but using what is carried waits for stage 6 |
| 4 | pushing by weight | begun: see [What moves, and how heavy it is](#what-moves-and-how-heavy-it-is) |
| 5 | keys and locked doors | |
| 6 | LIFE, food and drink | |
| 7 | the weapon, and soldiers who patrol, see the knight and come for him | |
| 8 | the castle and the quest | |

### The plan for stages 2 to 8

Fairlight's numbers, where a stage copies them, are from its notes; a turn
here is one of Fairlight's passes.

**2. Rooms that remember.** Done: see [What stage 2 did](#what-stage-2-did-rooms-that-remember).
A thing is anything that can be moved -- pushed, carried, or both -- and the
soldiers; wherever it was left is where it is when the room is entered again.
What moves by itself and is neither -- the balls, the fires, the spiked
balls -- starts again each time, as it does now. Left for the stages that
need them: a pool with room for things dropped in the fullest room (stage 3),
and the room $FE for something carried or used up.

**2b. Up and down.** Done: see [What stage 2b did](#what-stage-2b-did-up-and-down).
The new castle (stage 8) is built in storeys. The knight drops through a hole
into the room below, and climbs stairs or a ledge into the room above, never
a jump or a ladder. Things fall through holes too, soldiers included.

**3. Carrying.** Done: see [What stage 3 did](#what-stage-3-did-carrying).
Using what is carried comes with something to use, at stage 6.

**4. Pushing by weight.** Mostly there. To do: chains (a pushed thing
pushing the next), pushed things kept where they stop (stage 2), and movers
that take steps as steps.

**5. Keys and locked doors.** A doorway in `rooms.json` can name a key, a
thing. The knight goes through only with that key in the slot in use, and
the key is not used up; without it, LOCKED. Arriving where a thing already
stands, BLOCKED. Whether a locked doorway looks different -- a gate from
Melkhior's doors sheet -- is for then.

**6. LIFE, food and drink.** LIFE is two decimal digits, 99 at the start, in
the empty middle of the panel. A hurtful touch costs 10 and the thing that
touched vanishes; a soldier touching the knight drains it 1 a turn; a fall of
more than 40 units costs 1 a turn past that; a pit floor costs all of it. Food
gives 10 back, up to 99, and drink fills it. What `BEHAVIOUR_DEADLY` means in
`movers.s` changes with it, since a touch no longer kills outright. LIFE at 00
ends the game, as in Fairlight: Knight Lore's lives go, and the head and
count beside them on the panel with them.

**7. The weapon and the soldiers.** The soldiers are Knight Lore's guards to
look at -- two records, torso and legs, walking as one -- but they behave as
neither game's. A soldier patrols, along a line or round a square as the
guards do now, until he sees the knight: within 30 units in any direction,
Fairlight's rule. Then he walks towards him, aiming along one axis at a time
as Fairlight's chasers do, and goes back to patrolling once he has lost him.
The weapon is a thing lying in the castle; carried in any slot, it lets the
fire key shoot a bolt, as often as the knight likes. The bolt is Knight Lore
128K's, which 0b took out -- `player_fire` and `mover_bolt` -- with its pool
slots and its art resident again. A soldier the bolt hits leaves only his
helmet, which falls to the floor and is a thing like any other from then on,
to push or carry: a new graphic cut from the guard's own. The hit turns the
soldier's entry in the stage 2 table into the helmet's, and 30 seconds later
the helmet stands up as a soldier again, wherever it has been taken -- so a
helmet carried into another room and dropped there is a soldier patrolling
that room later. The 30 seconds pass whether or not the knight is in the
helmet's room, but not while he carries it. One that has no room to stand
waits until it has. Since a soldier can then be in any room, his sprites and
the helmet's are resident, like everything carried.

Nothing ticks every helmet every turn. A clock counts seconds -- sixteen bits
of them, eighteen hours before it wraps -- and a helmet lying in a room keeps
the second it is due to stand up. Picking it up turns that into the seconds
it has left, and putting it down turns them back into a due second, so time
carried does not count. A room being built stands up the helmets in it that
are due, and while the knight is in a room only its own helmets, a few at
most, are looked at.

**8. The castle and the quest.** A new map, not Knight Lore's: its rooms are
drawn with Knight Lore's art, Melkhior's and some of Pentagram's. Knight
Lore's 129 rooms stay until then as the place every stage before this one is
tried in. Pentagram's art came out in 0c, but its sheet is still in
`../pentagram/art/`, and stage 1's `"sheets"` in `graphics.json` can list it
beside Melkhior's six, so that only the sprites a graphic names are built in
-- whether its description reads as a sheet's does is still to check. Then
the thing that ends the quest and the room it is taken to, and Fairlight's
set pieces where they fit: the book and the wraith, the ghost that steals,
the freeze, the teleport and the decoys. The title, the end screen and a
release.

Between stages, the tools: the room designer and the templates editor drawing
Melkhior's graphics, the room designer placing things and setting a doorway's
key, and Z80 tests for carrying, LIFE and the soldiers worked out from
Fairlight's numbers.

**Not decided yet:**

- whether a push keeps Lightkeep's rule (it slows by the weight, and 3 holds)
  or takes Fairlight's (the knight pushes up to 7, and the thing coasts on for
  the difference and 6 turns) -- for stage 4, best settled by trying both on
  room 10's table;
- the keys for drop, use and slots 1-5 beside an Interface II joystick, for
  stage 3.

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

### What stage 0d took out

- **The collectables.** `special.s` and `pickup.s` are gone, and with them
  the thirty-two charms dealt out at the start of a game, the two slots a room
  kept for them in the object pool, the pick-up key's handling, the three
  carried objects drawn in the bottom-left corner, and the extra life that was
  taken by touching it. `specials.json`, `specials_source.py` and the
  `specials_gen.s` it wrote go too, and `MOVE_SPECIAL` with them: nineteen
  behaviours. The pick-up key is still read into `input_now`, for stage 3.
  `attr_fill`, which the panel colours with, moved from `pickup.s` to
  `panel.s`.
- **The wizard.** His template comes out of room $88, which keeps its arches,
  its blocks and the pot, and `room_scenery_move` no longer sets him walking
  a guard's square.
- **Their art.** The seven collectables and the wizard's two frames come off
  the sheet (912 rows to 817), and 25 graphic numbers with them: the
  collectables lying in a room (96-102), in flight (104-110) and in the
  wanted list (168-174), the extra life at 103 and 175, and the wizard's 158
  and 159. The panel's head by the lives, graphic 140, is the same bitmap and
  stays.
- **The spiked balls** in an even room were held up until the knight picked
  something up there. Nothing is picked up now, so they stay up until stage 3
  gives that back.

That leaves 138 graphic numbers free (0 is not one: it means an empty record):

    48-53, 56-61, 64-79, 88-90, 92-110, 149, 152-159, 168-177, 182-183, 186,
    188-245, 247-251, 253-255

The code below the stack has 2,275 bytes left (2,110 at 0c), the room page
7,524 after the fullest room (6,212), and the $6000 region 1,884.

What was checked, in a 128K emulator: every one of the 129 rooms builds and
runs a dozen turns with a read watchpoint on `sprite_missing`, and none draws
it. With the sheet shorter, `sprite_missing` landed on an address two more
readers use in other banks, which are stepped over with the two from 0c:
`backdrop_clear` copying the backdrop out of bank 6, and `room_find` copying
a room out of bank 4. In room $88 the pick-up key held for ten turns does
nothing, and the panel is whole. The Z80 tests pass, and so do the
designer's and the schema tests.

### What stage 1 did: Melkhior's art as sheets to pick from

Melkhior's Mansion's art comes in as six sprite sheets, one for each category
of its own viewer, beside Knight Lore's `sprites.png`. They are a catalogue:
nothing on them is in the game until a graphic number draws it.

**Converting.** `scripts/melkhior_sheets.py` reads your own unpacked copy of
the game -- `~/Downloads/MelkhiorsMansion` unless `--from` says otherwise, the
viewer's `data.json` for each type's frames and `out/Graphics/` for the
pictures -- and writes, for each category:

| | |
|---|---|
| `art/melkhior/<category>.png` | the sheet: gitignored, and yours to retouch |
| `metadata/melkhior/<category>.json` | where each sprite is on it: names and rectangles, no pixels, committed |

```powershell
.\.venv-win\Scripts\python.exe examples\filmation\lightkeep\scripts\melkhior_sheets.py
```

A sheet that is there already is left alone, since it may hold retouching
that has no other copy; `--force` converts it again over the top, and naming
categories (`melkhior_sheets.py --force walls`) does only those. The same copy
of the game gives the same rectangles every time, so a fresh tree that
converts matches the committed descriptions. Back the pictures up yourself:
nothing else holds them.

Each sprite is one frame of one Melkhior type in 1-bit, the way the "Melkhior
in Mono" page showed them: trimmed to its mask, Melkhior's black as paper and
every other colour as ink. It is named by its sheet, its type and Melkhior's
own frame number -- `objects:Bell.0`, `furniture:GrandfatherClockNE.2` -- and a
frame that repeats an earlier one is dropped and leaves a gap in the numbers
rather than renumbering the rest. A type that is another one mirrored
(`Milky2` is `Milky1` facing the other way) or another's frames exactly is left
out, and its name is written beside the one it duplicates on the sheet: the
engine mirrors a sprite itself.

| Sheet | Types | Sprites | Too big for one sprite |
|---|---|---|---|
| objects | 65 | 298 | 4 |
| furniture | 49 | 283 | 57 |
| doors | 18 | 92 | 12 |
| characters | 24 | 972 | 13 |
| walls | 75 | 341 | 161 |
| floors | 31 | 276 | 164 |

"Too big" is wider than 40 pixels or taller than 64, which the engine does not
draw as one sprite. Those are on the sheets whole, to be seen and cut up.

**Choosing.** `metadata/graphics.json` lists the six under `"sheets"`, and
that is the only selection. Open it in the graphic-map editor, pick an unused
number -- Lightkeep's free ones are the list above -- choose a sheet from the
list over the picker, and click a sprite. That adds a graphic named after the
sprite, `objects.Bell.0`, drawing `objects:Bell.0`; the build gives it a
`GFX_OBJECTS_BELL_0` label and a place in the sprite library, loaded only by
the rooms that place it. A frame too big for one sprite has a dashed border in
the picker, and the build stops on one a graphic names.

**Building.** `examples/filmation/scripts/sheet.py` reads every sprite on the
game's own sheet and, from the other sheets, only the ones a graphic names --
so a sheet's picture is needed only once something on it is used, and a tree
without Melkhior's Mansion still builds while nothing is. With the sheets
listed and no Melkhior graphic yet, Lightkeep builds byte for byte as before,
and so do the other three games. A trial with two (a bell and a mushroom on
48 and 49) put both in the library; a frame too big, a sprite a sheet has not
got, a sheet `graphics.json` does not list and a missing picture each stop the
build and say which.

**Not done yet:**

- The room designer and the templates editor draw from Knight Lore's sheet
  only, so a Melkhior graphic placed in a room is built but not drawn there.
- A new graphic has no box (`size`) and no nudge: they are set by hand in
  `graphics.json`, as before.
- Cutting a big frame into pieces is by hand, on its sheet. There are no
  per-sprite conversion settings (a dither, a threshold, tiling) yet: the one
  rule above converts everything.

### Melkhior's doorways

Six doorway templates are made from Melkhior's castle doors, one for each
wall and Knight Lore's two raised ones: `scenery_melkhior_door_n`, `_e`, `_s`
and `_w`, and `scenery_melkhior_high_door_e` and `_s`, 48 up for a walkway.
Each is listed in `meta.doorways`, so the room builder takes it for a way
through, as it does an arch. Room $88 uses the four plain ones in place of its
arches, which is where they were tried; every other room still has Knight
Lore's.

A doorway is Melkhior's own three pieces, as its viewer builds one: a post
(`doors:DoorSide1.0`), a second post, shaded, 13 Melkhior units along it
(`doors:DoorSide1.1`), and the lintel over both, 27 up (`doors:DoorTop1.0`).
They are graphics 200, 201 and 202, each with its box and with a nudge for each
way round. (Lightkeep is built for 512 graphic numbers -- see the Filmation
README -- and had them at 258-260 first, the first in the upper half; none are
there now.) The north and south walls draw them mirrored, as Melkhior flips
them for its NE and SW walls. The lintel is passable; the posts are not.

`scripts/melkhior_doors.py` works all of that out from your copy of the game
and writes the graphics into `graphics.json` and the templates into
`templates.json`; running it again writes the same files. It takes each
piece's box and hot spot from the viewer's `data.json`, and where the doors
sheet trimmed each frame from Melkhior's own picture, and places them through
the projection melkhior128 used, which is pixel for pixel. In a room 64
Melkhior units square that projection puts the posts exactly where Knight
Lore's arch leaves are -- 115 and 141 along the wall, 196 out in the north and
east -- so the doorway is measured the same; in the south and west they stand
at 60, where Knight Lore's leaves are at 59.

Lightkeep now draws from the doors sheet, so building it needs
`art/melkhior/doors.png`: convert it once with `scripts/melkhior_sheets.py`.

Checked in a 128K emulator: in room $88 the knight came in by each of the four
doorways and, turned round, walked out by it into the room it leads to --
152, 137, 120 and 135.

Not done: the coloured gates that lock a doorway (stage 5), the caverns
doorway (the same posts' other two frames and the other lintel), the threshold
and Melkhior's main door.

### Stairs and ledges

Fairlight has raised floors -- a ledge along a wall with a door on it -- and
staircases up to them, both built from artwork with invisible boxes under it.
Lightkeep builds them the same way:

- **The knight walks up steps.** `lightkeep.s` defines `CHARACTER_STEP_UP` as
  6, the engine's build option for stairs (see `../engine/README.md`): anything
  solid no more than 6 units above his feet he climbs, two units a turn, while
  he keeps walking at it. A 4-unit tread takes him two turns. Anything higher
  is still a wall, or a jump.
- **An invisible box.** Graphic 203, `solid`, draws a sprite 16 pixels wide,
  1 row high and every pixel clear (`solid.box`, top left of the sheet). A
  template places it with its own `sizeU`, `sizeV` and `sizeZ`, so one graphic
  makes a box of any size. Put it in a template listed under
  `meta.background`: background pieces are never depth-sorted, and something
  that draws nothing has no business in the sort. The room designer draws
  nothing for it yet.
- **A raised rear section.** `scenery_raised_w` raises the floor along the
  west wall, U 64 to 96, the whole length of the wall: one invisible `solid`
  box 36 high, so its top is at 164 -- object level 3, where a guard placed on
  it stands -- with castle wall stones along its front face at U 96. The box is background, never
  sorted. Nothing stands on its front edge, so a guard pacing there walks off
  and falls to the floor, legs and all, gathering speed as the knight does --
  `lightkeep.s` defines `PAIR_GRAVITY`, the engine's option for it.
- **A test room.** Room 106 has the raised section, a guard on it, and
  `scenery_test_stairs` up to it: five bridge decks along U at V 100, each
  6 units above the last -- the knight's step -- from 134 to 158. The decks
  are a stand-in for stair artwork.

Height matters for anything placed on it: an object stands at a level, 128,
140, 152 or 164, so a raised floor anything is to stand on is 12, 24 or 36
high. One 47 high left the guard placed at 164 eleven units inside it,
overlapping it on every axis, and he could not move at all.

Checked in a 128K emulator, in room 106: with a rail along the front edge
the guard paced along the top from U 71 to 88, his torso and legs both at 164;
the knight walked up the treads 128, 134, 140, 146, 152, 158 and onto the
section at 164. The rail is gone again, so the guard now walks off the edge.

### What moves, and how heavy it is

Which object templates move, and how, is `templates.json`'s `meta.movers`, not
code: template name to a behaviour -- a MOVE_ name of `movers.s` -- and a
weight. The templates editor sets both, and `scripts/rooms_source.py` writes
the game's `mover_of` table from them into `generated/room_data.s`. A template
not listed stands still.

`lightkeep.s` defines `LOOSE_WEIGHT`, the engine's option that makes a push
lose the weight of what it pushes. Something a push moves weighs 1 or more,
and the build refuses one that does not. Pushed by the knight, who walks 3 a
turn, 1 moves a table 2 a turn, 2 moves it 1, and 3 or more holds it. Weight
0 is gone: a push of the knight's whole step left a gap he spent a turn
closing, and the table lurched 3 every other turn, slower than at weight 1.
The movable block, the table and the chest weigh 1.

`movers.s` gives each behaviour a number, and gives the names that mark a band
-- `MOVE_CRUSHING`, `MOVE_HARMLESS`, `MOVE_LOOSE`, `MOVE_MONSTER_LAST` -- the
behaviour they mark by name, which is how the editor tells the two apart. The
`MOVE_STATE` bit that was `MOVE_RISING` is `STATE_RISING`.

Checked in a 128K emulator, pushing room 10's table: at weight 1 it moved 2
every turn, at 3 not at all; at what was weight 0, 3, 0, 3, 0.

Not done: ledge and stair artwork, a wireframe for invisible pieces in the room
designer (the templates editor has one), and steps for anything but the knight's own walk. The movers still
treat every step as a wall.

### What stage 2 did: rooms that remember

Every table, chest and movable block, and every soldier, is now a *thing*:
an entry in one table, as Fairlight keeps them, rather than a placement in
its room's record. 56 of them: 21 tables, 16 chests, 9 blocks and 10
soldiers, at most 8 in one room.

- **Which templates.** Anything a push moves -- a behaviour at or past
  `BEHAVIOUR_LOOSE` -- and anything `meta.movers` in `templates.json` marks
  `"kept": true`, which is the two guard templates. The templates editor keeps
  the mark when a behaviour is changed; it has no control for it yet.
- **The table.** `scripts/rooms_source.py` takes every placement of those
  templates out of its room's record and writes it as an entry in
  `things_start`, in bank 4 with the rooms: the room, the template, U, V and Z,
  the state, and two spare bytes. U, V and Z are the place before the template's
  offsets go on -- what `room_unpack` makes of a packed byte -- so a thing
  starts exactly where its old placement stood. `things_live` beside it is the
  copy play uses; `things_new_game` copies one over the other.
- **Building a room.** `things_gather` copies the room's entries out of bank 4,
  and their templates after the record's. `room_things_place` then places them
  after the room's own objects, through the second half of `room_unpack`, now
  `room_unpack_base`, and puts each one's `MOVE_STATE` back. For a soldier that
  is which way he paces, or which leg of his round he is on.
- **Leaving.** `things_save` runs before every room is built, which is the
  last moment the pool still holds the room being left. It writes each thing's
  U, V, Z and state back into its entry. A death rebuilds the room through the
  same path, so what was moved stays moved. A room that turns out not to exist
  leaves the old one up and its things still listed, and they are saved again
  when it is really left.

Building a room now also clears `room_weight`, which `room_add` copies into
every record. It held whatever the last room's last `mover_find` left, which,
with things placed last, was a table's weight. Only a loose record reads it,
so nothing behaved differently.

Bank 4 has 7,097 bytes left (7,609 before), the $6000 region 1,127
(1,566), the room builder at $5B00 349 (381) and the code below the stack
2,158 (2,164).

Checked in a 128K emulator:

- **Unchanged.** With nothing moved, every room builds the same objects as
  before the table, compared record by record against a build of the commit
  before: 127 rooms identical, and room $09's two portcullis records differ
  only in the stale weight above.
- **Kept.** In all 30 rooms that have things, each of the 56 had its driving
  record moved and its state changed. The knight left for a room with none,
  then went back to each: every one was where it was left, with its state.
- **Reset.** Room $0A's table was moved and the room left, so the live table
  differed from the starting one. After the last life was lost, the end
  screen, the menu and a new game, the two were the same again.

Not done: the room designer still places a thing on the packed grid, as it
does every object; the pool has no spare slots for things brought into a room
(stage 3); and nothing yet uses the room $FE, or the two spare bytes.

### Heights off the levels

A room's record places an object by a packed byte: three bits of U, three of V
and two of level, so it stood on the floor or 12, 24 or 36 above it, plus
whatever raise its template carries. The new castle's ledges, pits and stairs
want more than that. A group's count byte only ever needed three bits for its
one to eight, so the other five now carry a **shift in Z**: signed, 4 units a
step, from -64 to +60. Every object in the group moves by it, so an object can
stand between the levels, above the top one, or below the floor.

- **In `rooms.json`** a group says it with `"shiftZ"`, left out when it is 0.
  `meta.rules.groupShiftZ` says the castle's builder reads one, and
  `rooms_source.py` will not build without it.
- **In the build**, `room_objects_of` takes the count from bits 0-2 and the
  shift from bits 3-7, one `AND` and one `SRA`. `room_unpack` adds it to the
  base, so it goes on after the template's offsets. A thing's starting Z
  includes its group's shift.
- **In the room designer** the shift is never shown. An object has a height,
  and the designer works out the group:
  - **Ctrl** with up and down moves it a level, and with **Shift** as well,
    4 units.
  - The side panel's Z is the height itself.
  - Off a level, the object goes into a group with the shift that makes up the
    difference from the nearest level. The designer makes that group, and
    folds the object back into a plain one when it returns to a level.
  - The panel says when the selected object is in such a group.

Checked in a 128K emulator:

- **No shifts.** Every room builds the same objects as at stage 2.
- **Shifts.** With room $00's two block groups shifted -64 and +60, and room
  $0A's table (a thing) +8, those 16 records moved by exactly their shifts and
  nothing else in either room moved. The table started at Z 136.

The designer's tests cover the heights, the grouping and the panel's note.

### What stage 2b did: up and down

A room can have a way down, a hole in its floor, and a way up, stairs to the
room above: `"down"` and `"up"` in `rooms.json`, each a room number.
`rooms_source.py` writes the rooms that have either into `room_vertical_tbl`,
and says when a way has no way back. `storeys.s` does the rest, with one rule:
**a storey is 96 units**. A place in one room is the same U and V in the
other, 96 higher in the room below.

- **Down.** Whatever drops 24 below the floor is in the room below, 96 higher.
  The knight arrives at the top of its view and falls onto what is under him.
- **Up.** The knight climbing to 72 above the floor (24 short of a storey) is
  in the room above, 96 lower.
- **No bouncing.** The two lines are exactly a storey apart, so arriving never
  puts him past the line that would send him back. A staircase between two
  rooms is one staircase: the treads below the hole go on in the hole above, a
  storey lower, and walking up or down them crosses from one room to the other
  without a jolt.
- **The floor.** It is not an object but one height, `room_floor_z`. So a room
  with a way down has it lowered by 64 once the room is built and drawn
  (`room_vertical`). Everything else stands on invisible `solid` boxes, 64
  deep, laid round the hole as background scenery. No engine change: the
  engine's own floor is only the bottom of the pit now. The portcullis and the
  spiked ball read that floor too, so a room with a hole must not have them.
- **Things fall through.** `things_fall`, every turn in a room with a hole,
  finds any thing past the line. It writes the thing's entry with the room
  below and 96 more Z, and takes its records out of the room (`object_hide`).
  It arrives where it crossed the line, a storey up, and falls when that room
  is next played. A soldier goes legs and all, since `things_here` now knows
  how many records each thing has.
- **Landing on something.** A thing that fell first waits in the air where the
  knight will arrive if he follows it. Two records inside each other never
  move, so `vertical_clear` lifts him onto anything solid he would be inside.
  Lifted that high he can be past the way up's line, and the thing is in the
  room below's table only, so going up would drop him straight back onto it.
  The way up therefore waits until he has once been below its line
  (`vertical_hold`).
- **Dying** in a room he dropped into or climbed into puts him back where he
  came in, as a doorway does.
- **Room for arrivals.** Things now move between rooms, so a room can hold
  more than it starts with:
  - 4 more entries in `things_here`;
  - 8 more slots in the object pool (`POOL_SPARE`);
  - template space for 4 more of the largest kept template.

  Without that last, a block dropped into room $83 ran its template copy over
  `room_vertical_tbl`, and leaving the room jumped into the ROM. A room still
  too full leaves a thing waiting in the table until there is room.

**The test stairwell.** Room $A7 has a hole (down to $83), and $83 stairs (up
to $A7). It is one staircase of sixteen treads, 6 high and 6 deep, running
along V at U 100-116 in the middle of both rooms, clear of their doorways'
paths. Going up is walking north.

- **In $83:** treads 1 to 12 rise from V 80 to Z 200 at V 146-152.
- **In $A7:** the hole is U 100-116, V 128-176. Treads 12 to 16 continue there,
  a storey lower, from 104 up to the floor. Its south 18 units (V 128-146) are
  open, to drop through. The floor round it is four invisible boxes.

`scripts/stairwell.py` makes all of it. It writes the templates
(`scenery_stairs_up`, `scenery_hole_floor`, `scenery_hole_treads`) and the two
rooms, and it draws the tread it is built from: `stair.tread`, graphic 204, one
step 16 × 6 × 6, drawn to exactly its box, with its nudge worked out from the
projection. Running it again writes the same files. A tread is a slab with
nothing under it, so the high end of a staircase can be walked under, as under
a real flight. $A7 also has a movable block, at 152,136, to push in.

It was first built against the south walls, from invisible boxes with bridge
decks over them for art. The decks were 16 deep on 8-deep treads, overlapped
one another and reached past their boxes. The south doorway's post stood
nearer than a knight down in the hole, and covered him, which looked like a
sorting fault. Treads drawn to their own boxes, in the middle of the room,
put both right, and halved the records: 12 in $83 where there were 24.

A game starts in $A7, to try the stairwell straight away. The rooms a game can
start in are `rooms.json`'s `startRooms` (one, two, four or eight, picked at
random), which the room designer edits and `rooms_source.py` writes into
`start_rooms`. They were Knight Lore's four, written into `main.s`.

Bank 4 has 6,572 bytes left (the stairwell's templates).

As first built, the stage left the $7400 region full, with no room for the
sprite table to grow past graphic 255. Bank 5 was laid out again to make the
room back:

- the sprite table goes before the pool;
- `bit_reverse_table` moved to $6000;
- room $83 had fewer records (now its 12 treads);
- the end screen and the tunes moved to bank 0.

Now the $6000 region has 1,012 bytes free, the $7400 region 640, and the code
below the stack 2,103. A build with a graphic numbered 511 still fits.
[memory.md](memory.md) has the whole map.

Checked in a 128K emulator, driving the server over MCP:

- **Down.** The block put over the gap fell through in 7 turns, its entry now
  in $83 at Z 196. The knight followed and arrived in $83 at 196, then landed
  on tread 11 at 194.
- **Up.** Walking west from tread 11, he was in $A7 at Z 104 on tread 12 after
  4 turns, and walked on up out of the hole to the floor at U 70.
- **Down the stairs.** Walking east off tread 12 in $A7, he was in $83 at 198,
  and landed on tread 11.
- **After a thing.** Following the block down the same spot, he arrived lifted
  onto it, at 208, and stood there on it at 206 once it had settled on the
  tread, without going back up.
- **A soldier.** One put over the gap (for the test only) arrived in $83 whole,
  both records, and walked on down the stairs.
- **Dying.** A death in $83 put the knight back where he had dropped in.
- **The rest unchanged.** Every other room builds as before, and stage 2's
  things are still kept: 57 in 31 rooms, the new block among them.

Not done:

- **Art.** A hole draws nothing: Knight Lore's floor is black, so only the
  treads show where it is, and the knight falling into one is drawn over its
  front edge rather than behind it. The rim, and a front lip sorted in front of
  him, want art.
- **The room designer** keeps `"down"` and `"up"` but cannot set them, and its
  map does not show them. The stairwell's templates were written by a script,
  not drawn.
- **Things** do not go up. Anything else that falls into a hole -- a ball, say
  -- lands on the pit's floor and stays there.

### What stage 3 did: carrying

Five slots and a load limit of 7, as in Fairlight.

**The keys** are provisional:

| Key | Does |
|---|---|
| Z X C V B | choose slot 1 to 5 |
| N | pick up into the slot, or put down what is in it |
| M | use what is in the slot (nothing yet: stage 6) |

They are on the bottom row whatever is steering, since an Interface II
joystick takes the number keys. On a joystick that is not steering by
direction, down picks up and puts down as well, as in Knight Lore. On the
keyboard, turning moved from the bottom row to O and P, and the top row's
other keys jump (Q E T U) and fire (W R Y I).

**What can be carried** is `templates.json`'s `meta.movers` marking a template
`"pickup": true`: for now the movable block and the chest. A pickable template
has to be something a push moves, since a carried thing falls when put down
and is kept where it was left. It also has to be one sprite, numbered under
256. Its weight is the one a push already loses, and the whole load may not
come to more than 7.

**Picking up** takes the first pickable thing next to him into the slot in
use, if that slot is empty and he stands on something inside the room's
edges. "Next to him" is Knight Lore's test: within 4 of touching, along the
floor and in height. Too heavy, and TOO HEAVY is printed instead. A carried
thing leaves the room altogether: its records go, and its entry in the thing
table takes room `THING_CARRIED`, a number no room has.

**Putting down** puts what is in the slot in use beside him, on the side he
faces, at his feet's height, to fall from there. It has to be inside the room's
edges and clear of everything, or BLOCKED is printed and it stays carried. It
takes an empty record in the pool, or one more at the end (`POOL_SPARE`), and
an empty `things_here` entry, or one more. The slot keeps what its record is
made of, so putting it down needs no template, in a room that may never have
placed one. Put down over a hole, it falls through like anything else.

**Where the sprites come from.** A room loads only its own sprites, so:

- everything that can be carried is resident: the block and the chest,
  464 bytes;
- a room also loads the sprites of the things that can fall into it from the
  rooms above, following their ways down.

That second one fixes a fault left by stage 2b: a block falling into $83, which
never placed one, would have been drawn as the missing-sprite square.

**The panel** shows the slot in use in a box under the lives: what is in it,
drawn straight onto the screen, and its number beside it. It is put back
whenever a region reaches it, as the panel's own pieces are. Refusals are
printed right of the middle for 25 turns, and printed again each turn, since a
region can wipe them.

`carry.s` is in bank 0, beside the menu: about 1.1 KB, and it pages nothing in.
The one routine that writes the thing table in bank 4, `thing_record`, is in
`things.s` in bank 5. [memory.md](memory.md) has the figures.

Checked in a 128K emulator, from $A7:

- **Picking up.** The block went into slot 1 (graphic 7, weight 1), left the
  room, and its entry said `THING_CARRIED`.
- **Putting down.** Facing +U from 136, it landed at 150, which is his half,
  its half and one, and its entry said $A7 again.
- **Refusals.** With its weight set to 8, TOO HEAVY came up and nothing was
  picked up. Against the west wall, BLOCKED came up and it stayed carried.
- **Slots.** X and Z changed the slot in use, and it was picked up into slot 2.
- **Rooms.** Carried to $02 and put down at 142, it was still there after a
  trip to $0D and back. Put down over $A7's gap, it fell through to $83, and
  was drawn on tread 11 there.
- **Repeats.** Twenty rounds of picking up and putting down left one entry
  in `things_here` and the pool steady at 27.
- **Keys.** O and P turn him on the keyboard.
- **Nothing else changed.** Every room builds as at c22f671, the 57 things are
  still kept, and the stairwell still goes down and up. The Z80, designer and
  schema tests pass, and the other three games build.

Not done:

- **Using things.** M is read and does nothing, until there is food and drink
  (stage 6) and keys (stage 5).
- **The editor** keeps `"pickup"` but cannot set it: it is set in the JSON.
- **Small things.** Only the block and the chest can be carried, both big.
  Fairlight's small things -- food, bottles, keys -- want art, and Melkhior's
  objects sheet has it.
- **Putting down** is always beside him: never in front of a doorway he is
  standing in, nor on top of something, as Fairlight allows.
