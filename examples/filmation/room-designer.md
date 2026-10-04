# Designing a Filmation room

This is the reference for the Filmation Designer's editors: what every rule
is and why, and how each is held to what the engine does.

The Filmation engine under `examples/filmation` does not store a room as a list
of objects. It stores templates and expands them: a room is a colour, a floor
shape and a handful of indices naming pieces of scenery and groups of objects
shared across the whole game, and `room_build.s` turns those into the forty-odd
records the engine draws. Room `$B3` of Knight Lore is four indices, and they
become nineteen objects.

The room designer opens that as a picture. It draws the room the way the game
would, lets you move what is in it, and writes the result back to the file the
build assembles from.

It opens the same page in two places: as an editor tab in VS Code, and as a
local web page outside it. Everything that differs between the two is in the
host, not the page.

## The files it edits

Each game keeps its castle in two files beside each other in
`examples/filmation/<game>/metadata/`, one job each:

| File | What it is |
|---|---|
| `rooms.json` | the rooms -- each one's shape, ink, and the templates it places where -- and the floor shapes |
| `templates.json` | the templates: castle-wide pieces every room naming one is built from |

A template is not part of a room -- a change to one moves every room that
names it -- so it has a file of its own and an editor of its own (see [The
templates](#the-templates)).

**Each file names the other**, in its `meta`: `rooms.json` says
`"templates": "templates.json"` and `templates.json` says
`"rooms": "rooms.json"`. Nothing reading them assumes either name --
`rooms.json` is where a castle is opened from, and everything else is followed
from there -- and a pair that does not name each other back is refused, by the
build and by both editors, rather than built from what might be the wrong
castle's pieces. The two together are the editable form:

```
your game  --rooms.py-->  rooms.json      --rooms_source.py-->  room_data.s
   ONCE                   templates.json                        what the
                           what you edit                     build assembles
```

The flow is **one way**, and that is the whole design. `rooms.py` decodes the
game's own tables into `rooms.json` once; from then on the JSON is the source
the game is built from, and `build.py` only ever runs the second step. It will
not re-decode, and it stops rather than re-running an extractor, so nothing you
edit can be quietly overwritten by the original game's rooms.

Going back to those is a deliberate act: run `rooms.py` by hand, which says
plainly that it overwrites what is there.

Both games write the same schema, so one designer serves both. Where they
differ is written down in `room_model.js` rather than branched on twice:

| | Knight Lore | Pentagram |
|---|---|---|
| The map | arithmetic: a 16 × 16 grid, the room number is a row and a column | a destination byte on each doorway |
| Doorways | the template's name says so, in both: `scenery_arch_e`, `door_b_n` | the same, and it carries a destination too |
| Object entries | six bytes, the sixth a placement nudge | five bytes, no nudge |
| Scenery count | in bits 5-7 of the attribute byte | the same, stored less one, so eight fits |

Those two columns are what the designer knows about those two games by name,
and they are only the fallback. **A castle can say its own rules** in its files'
`meta`, and then the designer reads those instead of keying anything on the
game -- which is how `knightlore128`, Knight Lore's castle joined by a table of
exits rather than the grid, is edited without the designer learning its name.
In `rooms.json`:

```json
"rules": { "exits": "table", "sceneryPerRoom": 7, "lastRoom": 255 }
```

| Key | What it means |
|---|---|
| `exits` | `"table"`: every scenery entry is two bytes in the record, a template and a destination, and a doorway leads to the room its `destination` names. **0 is a room** there, unlike Pentagram's byte, so a doorway walled up says `"destination": null` (or has no destination at all). Anything that is not a doorway carries no destination -- the builder refuses one. Without the key, Knight Lore's grid and Pentagram's byte apply as above. |
| `sceneryPerRoom` | the most scenery entries a room may hold. Without it, 7, or 8 for Pentagram. |
| `lastRoom` | the number the last room must have: `room_find` walks the records to the first number at least the one it wants, so there has to be one at the end every search stops at. Without it, `$FF` for Knight Lore and nothing for Pentagram. |
| `poolLimit` | the most object records one room may expand to -- every entry of every template it places. A room over it is a fault, and the header's pool reads "of" the limit. Without it there is no limit, because the remakes size their pool to the fullest room. The original games' castles, edited by the room editor in `game-disassemblies` (`scripts/room_editor.py`; see its `docs/room-editor.md`), say what each game's object table holds: 36 for Knight Lore, 48 for Pentagram, 52 for Alien 8. |
| `shapeLimit` | the most floor shapes a room can name. Without it, 4: the remakes' builders keep the shape in bits 3 and 4 of the attribute byte. The original Knight Lore's castle says 32, which is what bits 3 to 7 of its attribute byte can name. |
| `yOrigin` | the projection's Y origin, unwrapped: a point is drawn on the row this less half its V less U (plus 64), and its Z. Without it 296 -- 40 and a whole byte -- which is Knight Lore's and Pentagram's, whose projections subtract 104 from the game's upward Y. Alien 8's subtracts 40 with its floors 64 lower, so its castle says 232; both put a floor on the same row. |
| `startSpot` | where the player is put when a game starts, whichever starting room -- `u`, `v`, `z` and the box's `sizeU`, `sizeV`, `sizeZ` -- which a starting room needs clear. Without it Knight Lore's and Pentagram's: the middle of a floor at 128, 5 either way and 23 high. Alien 8's robot starts on a floor at 64, 7 either way. |
| `groupNudge` | `true`: an object group may carry a placement nudge of its own, `nudge` beside its template -- bit 0 half a cell along U, bit 1 along V, the rest a raise -- which is drawn with it and offered as the group's **raise** in the Objects tab. Alien 8's rooms set one with a header before the groups it applies to. |
| `objectTemplateLimit` | the most object templates the castle may have, when its builder says: the templates editor holds to it. |

And in `templates.json`:

| Key | What it means |
|---|---|
| `doorways` | which scenery templates are doorways, by name, and the wall each stands in: `{"scenery_arch_n": "n", ...}`. When it is there it is the whole list -- any template can be a doorway, and no other is one -- and the builder reads a table made from it. Without it, Knight Lore's and Pentagram's rule by table position applies (see [The templates](#the-templates)). |
| `background` | the scenery templates drawn first and never sorted, by exact name. Without it, each game's built-in names apply. |

`room_model.js`'s `rulesOf` is the one place the rules are read, and
`castle.py`'s `side_of` makes the same choice for the build. A rename in the
templates panel carries a template's name across `doorways` and `background`
as well as the rooms, so it cannot quietly wall up every door made from it.

Anything with a **name** is keyed by that name, and carries no `name` field of
its own -- the key is the identity, and a copy inside the entry is only
something to disagree with it. Nor an index: where an ordinal matters to the
game, it is the order the keys are written in, which JSON keeps.

A **placement** is not a name, though. A scenery template is a list of pieces
put down in order, and the same piece can appear several times -- Knight Lore's
`scenery_walls_1` lays `scenery.26` five times along a wall -- so a template is
a list, and each placement names the graphic it draws as a reference:

```json
// rooms.json
"roomDimensions": {
 "square":  { "u": 64, "v": 64, "z": 128 },
 "narrowU": { "u": 32, "v": 64, "z": 128 }
},

"rooms": [
 { "number": 0, "ink": 3, "dimensions": "square",
   "scenery": [ { "template": "scenery_arch_n" } ],
   "objects": [] }
]

// templates.json
"sceneryTemplates": {
 "scenery_arch_n": [
  { "graphic": "door.castle.1", "u": 141, "v": 196, "z": 128,
    "flags": { "mirrored": true, "passable": false, "rest": 16 } }
 ]
}
```

Nothing here is derived from the rest of the file. There is no `used` flag on a
template and no `valid` one -- the designer works both out -- and no `address`,
which described a game this file long ago stopped being a copy of. Two
templates whose pieces are identical *are* one block, which is what sharing an
address used to mean.

[castle.py](castle.py) holds that shape for the build and
`room_model.js` for the editors, and the two lay both files out identically:
`tests/room_model_test.js` requires both games' real files to come back out of
the JavaScript writers byte for byte, so saving one room in the designer does
not rewrite twelve thousand lines of diff. Everything that reads a castle reads
the two merged -- `castle.read_castle` for the build, `withTemplates` for the
editors -- and each editor writes back only the file it owns.

`rooms.json` and `templates.json` are carried, and so are `sprites.json`,
`graphics.json`, `sprites.png` and `specials.json`: those six are a remake's
source. What the extractors write in
the games' own packed shapes is not carried and is not needed again once the
JSON exists. `room_data.s` and the other `.s` files are not carried either --
the build makes them.

## The artwork it is drawn with

A template does not name a sprite. It carries a **graphic number**, which is
the game's own index -- `room_data.s` emits it and the engine's `sprite_table`
is indexed by it -- and it means nothing without a sheet numbered the same way.
`sprite_sheet.py` numbers one to match, which is why several graphic numbers
can share a bitmap: 186 valid graphics over 103 sprites, in Knight Lore.

A template does not carry that number, though -- it carries the **sprite's
name**, and the sheet is what turns one into the other:

```json
"entries": [
 { "graphic": "guard.1.g150",
   "flags":   { "mirrored": false, "passable": false, "rest": 16 },
   "offsets": { "halfU": false, "halfV": true, "raiseZ": 0 } }
]
```

[graphics.py](graphics.py) is the one place the number
and the name meet: `rooms.py` names them on the way into `rooms.json` and
`rooms_source.py` puts the numbers back on the way out, both games, so the rule
cannot drift between the four of them and leave a castle built out of the wrong
pieces. `room_model.js` derives the same names for the designer, and
`tests/room_model_test.js` runs `graphics.py` and requires the two to agree
name for name.

A name is a **path**: the groups a sprite is in, then which one it is within
its group, counting from one. `sprite_sheet.py`'s `BANDS` is a tree -- a band
with a fourth element has children, whose names hang off its own -- so the
knight's first pair of legs is `knight.legs.1`, and two groups can each have a
`walk` without clashing. The index is within the group rather than across the
sheet, so adding a sprite to one group does not renumber every name after it.

A frame shared by several graphic numbers takes the number as a last segment
-- `knight.legs.1.g144` -- because they are **not** interchangeable: the pixel
nudge is per number, and graphics 30 and 150 draw the same bitmap four rows
apart. The number is still the identity; the name is how you read and edit it.
A graphic with no artwork at all is `gfx_NN`, so a castle can still say what it
is built from.

Those names are **seeded** from the sprites the first time `sprite_sheet.py`
writes the sheet, and stored against the graphic after that. So a name belongs
to the graphic, not to the sprite under it: pointing a graphic at a different
bitmap changes what it draws and renames nothing, and every castle that places
it keeps working. Rename a graphic and it *is* a rename -- `rooms_source.py`
stops with the template and the name it could not place rather than emitting a
wrong byte, and `tests/graphic_map_model_test.js` refuses two graphics with one
name.

That is what makes the two files independent, which is the point of the whole
arrangement: edit `sprites.json` to change the graphics, edit `rooms.json` to
change the rooms, and neither disturbs the other.

`flags` names the two bits we know -- bit 6 mirrors a piece, bit 1 lets things
through it -- and keeps the others in `rest`. Those are the game's own, which
`rooms_source.py` drops on the way to `OBJ.FLAGS`; they are carried whole
rather than guessed at, so the file claims no more than is actually known.

## The box a piece occupies

What is **not** in that entry is its size. The engine sorts and collides with a
box -- half-widths along the two ground axes and a height -- and that box
belongs to the **graphic**, not to the template that happens to place one. So
it sits in `graphics.json`:

```json
"2": { "sprite": "door.castle.1", "size": { "u": 5, "v": 3, "z": 40 },
       "x": -7, "y": -3, "mirrored": { "x": -17, "y": -2 } }
```

It used to be repeated on every entry, where 120 Knight Lore entries said 39
distinct things and a doorway's box had to be kept right in nine places at
once.

Two things make that more than a move.

The box is stored **unmirrored**. Mirroring reflects a piece across the
isometric axis, so the two ground axes trade places and U and V swap; the
height never changes. Every doorway in both games is placed both ways round,
which is why the file cannot simply state the box as one of them is drawn --
`(5, 3, 40)` facing one way is `(3, 5, 40)` facing the other, and the `mirrored`
flag the entry already carries is what says which.

And an entry can still carry `sizeU`/`sizeV`/`sizeZ` of its own, which then
win. That is for the records whose bytes are not a box at all: Knight Lore's
guard templates end with a blank, passable, zero-height second entry whose U
and V are the **guard's patrol extent**, 5 × 5 for the wizard and 6 × 6 for the
two guards. Four Pentagram templates no room places decode into nonsense and
keep theirs for the same reason. Those six entries are the only ones in either
game that override; everything else takes its box from the graphic.

Lightkeep has a second use for one: an invisible box under artwork. Its
graphic `solid` draws nothing, so a template places it with a box of its own --
`scenery_raised_w` raises the floor along a west wall with one 32 x 128 x 20.
The templates editor edits such a box (see [The templates](#the-templates)).

The rule is written twice, as the naming rule is: `box_of` in
[graphics.py](graphics.py) for the build, `boxOf` in
`sheet_model.js` for the designer, and `tests/room_model_test.js` runs both
over every template entry in both games and requires them to agree. A
disagreement would draw a room whose pieces sort and collide differently from
the built game's.

## Which files a castle is drawn with

`rooms.json` says so in its `meta`:

```json
"sprites": {
 "sheet": "../art/sprites.png",
 "atlas": "sprites.json",
 "graphics": "graphics.json"
}
```

Each path is relative to `rooms.json`, in `metadata/`, and may not leave the
game's folder -- `game_layout.js` has the rule, and `scripts/layout.py` the
same one for the Python. A castle laid out flat, with no `metadata/`, keeps
all three beside `rooms.json`.

and a graphic is resolved through them:

```
rooms.json     names the graphic "balls.1.g178"
graphics.json  graphics["balls.1.g178"] -> { "number": 178, "sprite": "balls.1", ... }
sprites.json   group.balls.sprites["1"] -> { x: 1, y: 383, w: 24, h: 19 }
sprites.png    that rectangle
```

Every rectangle in `sprites.png` has a one-pixel frame just outside it, in the
colour `sprites.json` names `border` (magenta). It shows whoever paints on the
picture where each sprite ends, and `sprite_source.py` checks it on every
build: if a rectangle no longer sits on its own picture, or artwork has been
painted over the edge, the frame is broken and the build stops, naming the
sprite and the pixel, rather than reading the wrong bytes into the game.
Both games' sheets are made and read by the same code, `sheet.py`.

`graphics.json` is the only part that is the *game's* own. `kl_extract.py`
reads Knight Lore's table of 256 sprite pointers at `$7112` and resolves each
to the sprite it points at; `sprite_sheet.py` writes that out, once, and
`rooms.py` folds the boxes in beside it. So the sharing -- 186 graphics over
103 sprites -- is Ultimate's own, not something the tooling invented, and
`graphics.json` is where to change it. `sprite_source.py` reads the same table
to number `sprite_table` the way the game numbers its graphics.

The **pixel nudge** that lines a bitmap up with its logical position sits in
the same entry, because it is the other half of the same fact -- how a graphic
number is drawn -- and is keyed the same way:

```json
"guard.1.g150": { "number": 150, "sprite": "guard.1",
                  "size": { "u": 6, "v": 6, "z": 24 }, "x": -12, "y": 7 }
```

The file is keyed by the graphic's **name**, which is what `rooms.json` refers
to it by, and carries the `number` the game knows it by as a field. That way
round for a plain reason: the name used to be worked out from the sprite, so a
castle referred to names that were written down in no file at all and searching
for one found nothing. The number cannot move -- `sprite_table` is indexed by
it, and some of the numbering is arithmetic, since a collectable in flight is
its own graphic plus `SPECIAL_FLIGHT` -- but the **name is yours**. Rename a
key, rename it in the castles that place it, and the build follows.

The sources follow too. `sprite_source.py` writes `graphics_gen.s`, one EQU a
graphic, named after that key:

```
GFX_WEREWOLF_LEGS_1      EQU      48                 ; werewolf.legs.1
```

so `player.s` says `PLAYER_LEGS_GFX EQU GFX_SABREMAN_LEGS_1_G16` rather than
spelling out 16. Rename a graphic and forget to follow it through, and the
assembler stops on the missing label instead of quietly building the wrong
piece.

The parts come from different places, though, and only some can be got back.
`kl_extract.py` reads the sprites out of a snapshot whenever you like; the
nudges can only be harvested by `adj.py` from a **running** game, because
Knight Lore picks them inside twenty-nine per-graphic update routines rather
than reading a table. Every tool that writes the sheet therefore *merges* into
it rather than rewriting it, and so does the designer: taking a sprite away
leaves the name and the nudge alone, because they are the only copies there
are. A graphic can carry a nudge and no sprite -- Knight Lore's graphic 1
does.

The paths are relative to the `rooms.json`, and neither host will follow one
that climbs out of its directory or is absolute: the file is data, and data
does not get to point the designer at the rest of the disk. A file written
before the field existed has no `meta.sprites`, and the three names above are
what it falls back to, one key at a time -- see `spriteFilesOf` in
`room_model.js`, and the same table in `examples/filmation/vscode/room_designer.py`.

None of this reaches the build. `rooms_source.py` reads the rooms and ignores
`meta` entirely, so naming a different sheet changes what the designer draws
and not one byte of the game.

## Opening it

**Installing.** The designer is a VS Code extension of its own,
`examples/filmation/vscode/`, apart from the emulator's: it needs nothing from
the emulator and the emulator nothing from it. It has no build step and no
dependencies; install it by linking the folder into VS Code's extensions, then
**Developer: Reload Window**:

```powershell
# from the repo root; a junction needs no elevated shell
$dest = "$env:USERPROFILE\.vscode\extensions\jonsole.filmation-designer-0.0.1"
New-Item -ItemType Junction -Path $dest -Target (Resolve-Path .\examples\filmation\vscode)
```

The folder name is `<publisher>.<name>-<version>` from its `package.json`.
Linked rather than copied, a change to it takes effect on the next reload.

**In VS Code.** Open `examples/filmation/<game>/metadata/rooms.json`, or run
**Filmation: Design Rooms...** from the Command Palette, which
offers the games it can find. The document is the model: every change goes in
through a `WorkspaceEdit`, so undo, the dirty mark and Save are the editor's
own, and an edit from anywhere else -- an undo, the text editor, `rooms.py`
having rewritten the file -- reloads the page on the room you were looking at.
To read the file as text instead, reopen it with **Text Editor**.

**Outside it.**

```powershell
python examples/filmation/vscode/room_designer.py                 # Knight Lore
python examples/filmation/vscode/room_designer.py pentagram
python examples/filmation/vscode/room_designer.py --port 8900 --no-browser
```

It serves on localhost only and its **Build** button runs the game's own
`build.py`. Nothing is written until you press **Save**: changes are held in
the page, the header says "unsaved" while any are, and closing the tab asks
first. That one **Save** writes both files it can have edited, `rooms.json` and
`specials.json`, and the server refuses a body that is not the shape of the
file it is for rather than overwriting the game's tables with it.

**Load** takes the game beside it -- every directory under
`examples/filmation` with a `rooms.json` in it, so a new game needs nothing
configured -- and loading the one already open re-reads it from disk. It asks
before throwing unsaved changes away.

**Undo** and **Redo**, or ctrl+Z and ctrl+shift+Z, go back sixty changes. They
exist only here: in the editor every change is a `WorkspaceEdit`, so undo is
the text editor's own and a second stack would fight it. The page keeps whole
copies of the castle rather than a list of changes -- a copy is what Save
writes anyway -- and it knows when you have undone your way back to what is on
disk, so the "unsaved" mark clears again. Loading a file empties the stack,
since what is on it belonged to the last one.

It also wants the artwork -- `sprites.png` and `sprites.json` -- which is
gitignored and which the game's `build.py` unpacks from `sprite_data.bin` the
first time it runs. Without it the page still opens and still edits, and says
it has no sheet rather than drawing an empty room.

## The page

**The castle**, on the left. Knight Lore's room number *is* a place -- a row
and a column of a sixteen by sixteen grid, north a row on -- so its map is laid
out as the castle, north at the top, with the rooms this one leads to picked
out. Pentagram's numbers mean nothing of the sort, so they are simply listed.

A castle whose exits are a table has numbers that are not places either, but
its doorways say which way each room lies from the next, so its map is **walked
out of the doorways**: breadth first from the first room, each room goes one
square north, east, south or west of the room whose doorway first reaches it
with that square free. A castle need not be flat -- a doorway can lead round a
corner the grid cannot draw, or onto a square already taken -- so a room the
walk cannot place, or never reaches, is listed under the map rather than left
out. `knightlore128`'s exits were generated from Knight Lore's grid and none of
them wraps round its edge, so the walk lays it out as exactly that grid.

**Starting rooms**, under the map, are the rooms a game can begin in, for a
castle whose `rooms.json` lists them in `startRooms` -- the original Knight
Lore's four, or Pentagram's, which the room editor in `game-disassemblies`
reads from the game and writes back. Each is a button that goes to its room. A castle that
lists none shows nothing there, and one that names a room it has not got is a
fault.

To change one, go to it -- its button, or the map -- and press **Change**.
The map then chooses instead of going: rooms that cannot start a game are
dimmed, with the reason on hover, and clicking a room swaps it into that
slot and goes there. A room that is refused says why, and the choosing stays
open for another; **Cancel**, Esc, or going to a room some other way, leaves
it. The game has four and picks one at random, so a room replaces one; the
count does not change. Sabreman is put in the middle of
the floor whichever room it is -- U $80, V $80, Z $80, in a box 5 either way
and $17 high, from `plyr_spr_init_data` at $D1A1 -- so a room with anything
solid in that box is refused, naming what stands there. Passable pieces do
not count. A starting room something is later put in the middle of is a fault
in the checks, and Knight Lore's build refuses it too.

**Adding and deleting.** On Knight Lore's grid a room number is a place, so a
room is added where it goes: click an empty, greyed square on the map and it is
picked out, with **Add room $NN** under the map. A click only picks it; the
button makes the room. On a room, the same place offers **Delete room $NN**,
and says first what it would leave pointing nowhere: the doorways that lead
into it and the collectables that start in it. Delete is refused -- the button
greyed, with the reason -- for a castle's only room, for the room every search
stops at (`$FF` in Knight Lore), and for a starting room. It is one undo like
any other edit.

A castle whose numbers are not places -- Pentagram's list, a table's walked
map -- adds a room by number instead: **Add room**, under the map, is a
number -- the lowest free one to start with -- and a button. The room it makes
is empty, stands on the first floor shape,
takes the ink of the room before it, and goes in number order, because
`room_find` walks the records in ascending order; the designer goes to it, and
it is one undo like any other edit. A number already used, outside 0-255, or
after the castle's last room (`$FF` in Knight Lore) is refused with the reason
under the box. A castle whose exits are a table also keeps one number free,
since its builder needs a number no room has to mean "no exit".

**Shapes**, a tab beside Objects, is the castle's floor shapes: for each,
how far the floor reaches from the middle along U and V, and the floor's
height, as numbers to change, with how many rooms stand on it. A shape is the
castle's, so a change moves every room on it; **Add shape** makes a copy of
this room's to change from, and **Delete** takes one nothing stands on. A
room is put on one with the **Shape** picker under the picture. The castle's
`shapeLimit` rule says how many there may be.

What a shape moves is what bounds a room -- the walls you cannot walk
through, where you come in, how far into an arch takes you to the next room
-- and not the walls and arches you see, which are scenery at coordinates of
their own. So the checks look at every wall and arch piece: in both games'
castles as shipped, each one's inner face is within a unit of the edge of the
floor it stands on, and a piece further off than that, inside or out, is
reported as a warning on its room -- one line a room, naming each template
and how far off it stands. The fix is in the templates editor, or a wall
template of the new shape's own.

**Ways out**, under that, is the room's doorways and where each leads. Knight
Lore's are arithmetic and cannot be anything else, so they are shown and not
editable, and the room number is what you click to go there. Where the number
is a field to edit, a **go** button beside it does that instead. Pentagram's are a byte, and the byte is the authority -- one of its
south doorways is an exit in twenty-eight rooms and walled up in one -- so
there it is a field you change. In a castle whose exits are a table every
doorway is listed, walled up or not, as a room number to change: an empty box
is walled up (`null` in the file), and 0 is room 0. A doorway added from the
Scenery tab there starts walled up, and changing a door's template to one that
is not a doorway drops its destination.

**The room**, in the middle, drawn as the engine would draw it. Click a piece
to select it and drag it about the floor. The arrow keys nudge it a cell, and
**ctrl with up and down** lifts and lowers it through the four Z levels: those
two arrows are the ones that could mean either thing, so the floor keeps them
and height takes the modifier. `[` and `]` do the same as ctrl-down and ctrl-up,
and Delete removes it.

A selected object also has **the ground it stands on** lit, with a dashed riser
between the two. That pair is what makes its place readable: the projection
sends V up the screen and Z up it as well, so a sprite drawn high up could
equally be far away on the floor or near and in the air, and the artwork alone
does not say which. Two amber guide lines cross on the floor at its place
as well, one along U and one along V, from wall to wall and on out to the
object if it stands beyond one: a collectable put down past a wall shows its
lines leaving the floor. They are `floorGuides` in `room_render.js`, and the
templates editor draws the same ones.

The marker follows the object, not the cell its position names, because those
are not always the same place. A template carries a nudge -- half a cell in U,
half a cell in V, and a raise in Z, all in one byte -- and `object_ball_ud_xy`
uses both halves, so the ball it places sits on the corner *between* four
cells, sixteen pixels right of where its `u,v` alone would put it. That is the
game's own doing: the engine builds it at exactly the same world position.

Whatever is **nearer than the selected object** is drawn at half strength, so
the thing being moved is never lost behind the thing in front of it. The list
is furthest first, so that is simply everything after it, and an object drawn
from several sprites counts as one.

So the selected object says where it **stands** in world units as well as which
cell it is in, and names the nudge and how much of the game shares it. The
nudge is not editable from there on purpose: it belongs to the template, not to
the position, and moving it would move every object drawn from that template in
every room -- 48 of them, for `object_spike_ball_falling`. The Templates panel
is where a template is changed, and it says how many rooms that reaches.

Under the picture are the room's ink and floor shape, a **zoom**, and switches
for the floor grid, the objects' bounding boxes and whether scenery is drawn at
all -- which is the quickest way to see what is actually in a room behind its
walls.

The zoom scales the canvas rather than redrawing it, so it costs nothing and
never softens a pixel. **Fit**, the default, takes whatever the window has
left and follows it as the window changes -- and it is not a whole number,
because a window is whatever width it is and rounding down to the next whole
step throws away up to a third of it. The whole steps are still there for when
an exact 2x is what you want. Clicking reads the canvas's measured size rather
than the setting, so it lands on the same object whatever the scale.

**Objects**, **Scenery** and, for Knight Lore, **Collectables**, on the right --
each of them about the room on screen.

- *Objects* are the groups the room places. A group is one template and up to
  eight positions, because the repeat count is the bottom three bits of the
  group byte; the ninth object of a kind starts a second group, exactly as the
  game's own data does. Under them, **Place** puts another one in the middle of
  the floor, and what it would place is drawn beside it -- a template is a
  number in the file and a shape on the screen, and with Pentagram's named
  `object_00` to `object_30` the name says nothing at all. The caption gives
  what it is drawn from, how big the artwork is, and the box the collision and
  the depth sort see, which is not the same thing: a piece can be drawn far
  larger than the space it occupies.
- *Scenery* is the list of templates the room names, with what each one is --
  how many pieces, whether it is a doorway, and whether it is background. It
  has the same preview under **Add**, and a piece of scenery previews in the
  place it will actually occupy: it carries its own world coordinates and takes
  nothing from the room, so a wall shows as the whole run along the back of the
  room rather than as a tile, scaled down to fit.
## The templates

A template is not part of a room. It is a castle-wide piece that every room
naming it draws, so a change to one moves all of them -- which is a different
job from the room tabs, and has a file of its own, `templates.json`, with an
editor of its own. Opening the file opens the editor; **Templates…** in the
room designer's header opens it in a separate window -- one of VS Code's
auxiliary windows, which can be moved anywhere, resized or put on another
monitor -- and so does **Filmation: Edit Room Templates...** Where
VS Code cannot open a window of its own, it opens beside the designer instead.

Being a real editor on its own file is the point: **Ctrl+Z**, redo, the dirty
mark and **Save** are VS Code's own. The room designer draws from the
templates as they stand in the editor, unsaved changes included, and redraws
as they change; the templates editor counts rooms from `rooms.json` the same
way.

A **rename** is the one edit that reaches both files. Rooms name the templates
they place, so renaming one changes its key in `templates.json` and every
reference in `rooms.json`, as a single edit -- and VS Code, undoing it in either
file, offers to undo it in both, so the two cannot be left disagreeing.

On the left is every template, scenery then objects, each with its table
index, the number of rooms that place it, and **code** where the game's own
source refers to it. Pick one and it is drawn on its own, big, the way the
designer draws it; click a piece in the picture to select it.

**Show it** above the picture sets what the template is drawn in: on its own;
on the floor of any of the castle's room shapes, with the floor's cells and its
edge drawn under it; or in any room that places it, whole, the rest of the room
dimmed. A piece of scenery that looks right on its own can be half through a
wall in a narrow room, and this is where that shows. Only the template's own
pieces can be picked or moved -- the rest of a room is there to be seen
against. The choice is kept as you pick other templates, moving to the first
room that places the new one when the old room does not.

The bar under the picture sets how much of the window it has, and the picture
fits that space exactly -- stretched with nearest-neighbour scaling, so the
game's pixels stay hard-edged at any size.

A selected piece moves the way an object does in the room designer: **drag**
it, or use the **arrows** along the floor, with **Ctrl+↑/↓** (or `[` and `]`)
to lift and lower it and **Delete** to remove it. What a step is depends on the
piece. Scenery carries its own place in the world, so it moves a world unit at
a time, eight with **Shift**, and a drag puts it under the pointer. An object
piece takes its place from the room and has only its nudge, so an arrow
switches its half-cell on or off, and a lift is four -- the game masks the
raise to a multiple of four -- or a whole level with Shift. A drag is one step
of the editor's undo, not one for every pixel it passed through.

Under the picture is every piece, and each can be changed in place: the graphic it draws,
picked from `graphics.json` rather than typed; a scenery piece's U, V and Z;
the mirrored and passable flags; and an object's half-cell nudges and raise.
Pieces can be added, moved earlier or later -- order is the order they are
laid, and the order they join the object pool -- and removed. **Add...** shows
every graphic as a picture with its name and number, filtered by name as you
type; click one and **Add** puts it on the end of the template, or double-click
it to do both. At the bottom is
every room that places the template; clicking one takes the designer there.

The selected piece is drawn with its box, in blue, and with where it is on
the floor: the box's base shaded there, a mark under its middle, and a line up
from the mark to the piece when it stands above the floor -- the room
designer's footing, for a piece that is not on a cell. On a floor or in a
room, amber guide lines cross on the floor at its place, along U and along V,
across the room's floor and on out to the piece. A piece on the floor behind a
back wall is drawn where one on a raised floor in front of it would be, and
the lines are what tell the two apart. All of it is drawn over the pieces. A
piece whose sprite
draws nothing (Lightkeep's `solid`) is always drawn as its box, fainter, and is
picked by clicking inside it.

The picture puts every piece where it really is (`projectUnwrapped` in
`room_render.js`), not where `object_place`'s eight bits put it. A piece
lifted until its base is above the top of the screen goes on up rather than
coming back at the bottom, as the game would draw it; it is outlined in red and
the template's notes say so. The room designer keeps the game's wrap, since
what it shows is the game's screen.

The notes give the reason (`wrapOf` in `room_render.js`). The screen's edges
are one. The other is a piece too far back: `object_place` halves
V − U + 128 with `SRL`, which drops the ninth bit, so a piece with V − U past
127 is drawn 128 rows lower than it stands. A room's far corner is at exactly
128, so only a piece behind the back walls can do it.

A piece's **box** normally belongs to its graphic, and the graphic map is where
that is changed. **own box** gives one piece a box of its own, starting from
its graphic's, and its three sizes are then edited in its row -- U and V
half-widths and Z the height, at most 127, since in a game with more than 256
graphics bit 7 of it carries the graphic's ninth bit. **graphic's box** takes
it away again (`setTemplateBox` in `room_model.js`).

**How an object template moves**, in a castle whose `templates.json` says so
(`meta.movers`, Lightkeep's): template name to `{ "behaviour", "weight" }`, a
MOVE_ name of the game's `movers.s` and what a push loses. The **moves** row
picks the behaviour from the game's own list -- `behaviours.js` reads the MOVE_
names `movers.s` gives a number, leaving out a name given another name, which
only marks where a band of them begins or ends -- and marks the ones that kill
and the ones that can be pushed, from the engine's bands. Only one that can be
pushed has its weight read (`LOOSE_WEIGHT`, see the engine's README), so only
it has the weight field, and it weighs 1 or more: the field will not go
lower, and the build refuses one that can be pushed and has no weight
(`rooms_source.py` reads which behaviours a push moves from `movers.s`, as
`behaviours.js` does). `rooms_source.py` writes `mover_of` from this, in
table order, one triple a template; a template not listed stands still. A
rename, a copy and a delete carry the entry with them. A castle without
`meta.movers` -- Knight Lore, Knight Lore 128K and Pentagram -- keeps
`mover_of` in its `movers.s`, and has no row.

A template can be renamed, duplicated under a new name, created empty, and --
with one condition -- deleted. The condition is the thing to understand about
templates: **a template's position in its table is the game's own number for
it, and the game's code leans on some of those numbers.** Knight Lore's
`room_build.s` takes scenery 0-7 to be the arches, with the side in the bottom
two bits, and `BG_GATE_0`..`BG_GATE_3` to be a run; Pentagram's room builder
reads a destination byte after exactly the scenery templates at its doorway
positions. So nothing renumbers a template. A new or duplicated one goes on
the end of its table, and only the last one can be deleted, and only if no room
places it -- anything else would shift every template after it and the code
would be pointing at the wrong ones. The object table stops at 32, because a
room's group byte holds the template in five bits.

It also means **a doorway is a position, not a name** -- in Knight Lore and
Pentagram. `scenery_arch_e` is a doorway because it is template 1, and
renaming it changes nothing about that; a duplicate of it, on the end of the
table, is not a doorway at all, however much it looks like one. A castle whose
`templates.json` lists its doorways in `meta.doorways` decides by that list
instead, so there a duplicate becomes a doorway by being added to it, wherever
it sits, and the panel says which rule it is going by.

And it means **a copy does not bring the original's behaviour.** Knight Lore's
`movers.s` gives a template its behaviour by label -- `FG_GUARD_EW` walks up
and down, `FG_BALL_BOUNCE` bounces -- so a duplicate of the guard is a guard
that stands still. The panel marks every template the game's source refers to,
and says which files, because renaming one changes its label and the build
stops until the code is changed to match. `template_refs.js` works that out
from the generated `room_data.s` and the hand-written sources beside it.

Renaming is still the point of the file being JSON: Pentagram's are
placeholders (`scenery_07`, `object_12`) until someone works out what each
piece is, and a rename moves every room that names it.

**Checks**, at the bottom, is everything that would stop `rooms_source.py`
emitting the castle or stop the engine building a room: a room out of order, a
position off the eight-by-eight floor, more scenery than the count field holds,
a record longer than its skip byte can reach, a doorway to a room that is not
there, a last room that is not the one the castle needs. In a castle whose
exits are a table it also catches a destination on something that is not a
doorway, and a `meta.doorways` naming a template or a wall there is no such
thing as. A doorway with no way back is a warning rather than an error: it
builds and plays, you simply cannot return through it. This room's problems
come first.

## How the picture is drawn

The preview is drawn in JavaScript, not by the emulator, because a designer has
to redraw while an object is being dragged and a round trip through a running
machine cannot. That means `room_render.js` is a second implementation of three
things the engine already does, and that is the risk it carries:

| In the engine | Here |
|---|---|
| `object_place` in `engine/object.s` | `project` |
| `depth_cmp` and `depth_insert` in `engine/depth.s` | `depthCompare` and `insertPlaced` |
| `room_adjust` in `engine/room.s`, over the sheet's nudges | `readSpriteAdj` and `adjFor` |
| `room_unpack` in the game's `room_build.s` | `expandRoom` in `room_model.js` |

Each of those is held to the original rather than to itself.
`tests/room_render_test.js` works the projection out from `object_place`'s
eight instructions by hand and takes its depth tests -- numbers and outcomes
both -- from the worked examples in [engine/depth.md](engine/depth.md).
`tests/room_model_test.js` reads the generated `room_data.s` back and requires
the model to agree with what `rooms_source.py` wrote: the background flag
especially, which is decided by template name in Python and has to be decided
the same way here, or the preview sorts a wall the game does not.

What it does **not** draw is anything neither the room data nor `specials.json`
holds: the player, the panel, and whatever else the game's own code puts on the
screen. A room in the designer is the room as `room_build` leaves it, plus the
collectables `special_room_enter` adds to it.

```powershell
node examples/filmation/vscode/tests/room_model_test.js
node examples/filmation/vscode/tests/room_render_test.js
node examples/filmation/vscode/tests/specials_model_test.js
node examples/filmation/vscode/tests/room_page_test.js
node examples/filmation/vscode/tests/game_layout_test.js
```

The last one opens the assembled page against the real castle in a fake DOM.
That is the seam worth a test: the page is built by string replacement, so a
mistake in it is not a syntax error in any file on disk, it is one in a file
that only exists at runtime, and the panel opens blank with the reason in a
console nobody is looking at.

## The collectables

Knight Lore's thirty-two collectables are not in `rooms.json`, because they are
not in the room data: the game keeps them in a table of its own, and
`special_room_enter` puts the ones naming a room into the two records after
everything that room built. So the designer opens a second file,
`specials.json`, and a **Collectables** tab appears beside the others.
Pentagram has no such table and never shows the tab.

They are drawn in the room they start in and sort against its furniture
exactly as they will in the game -- `special_fill` gives every one of them the
same box, `SPECIAL_SIZE_UV` square by `SPECIAL_SIZE_Z`, with its flags zeroed.
Clicking one selects it and opens the tab, where its position is four numbers.

Three of the game's rules are not visible in the file and the designer says all
three:

- **A collectable has no fixed kind.** `special_init` deals the eight out from
  a random number at the start of every game, so no two games put the same
  object in the same place. The picture draws a stand-in you can cycle through;
  it is a view setting, not an edit, because nothing here can choose them.
- **A room has two slots.** `SPECIAL_SLOTS` is 2, and a third collectable
  naming the same room is simply never placed -- the game says nothing and the
  object is unreachable for that game. The panel says so in red. Ultimate's own
  table never does it, which `specials_model_test.js` checks.
- **The table is a fixed thirty-two rows**, because `special_init` copies it in
  one `LDIR`. `specials_source.py` stops rather than emit a short one.

Its U, V and Z are **world bytes**, not floor cells: the game's table holds
them that way and `special_fill` uses them as they are, without going through
`room_unpack`'s grid. So the arrow keys move a collectable one unit at a time,
or eight with shift -- half a floor cell, which is the smallest move the room
data itself can make. **Dragging** one moves it in U and V to follow the
pointer, to the unit, and leaves its height alone: ctrl with the up and down
arrows is for that. A drag is one step of undo, however far it goes.

In VS Code it is a second document, so an edit to it is a `WorkspaceEdit` on
that file and it gets its own dirty mark and its own undo: two files changed is
two files to save. The browser host holds both and writes them with one Save,
because they are edited in one page and there is nothing useful about saving
half of it.

## The sprite sheet editor

A sheet is two files: the picture, `art/sprites.png` (or one of Lightkeep's
`art/melkhior/*.png`), and the description that names it and cuts it up,
`metadata/sprites.json` (or `metadata/melkhior/*.json`). Opening the
description opens the editor on both, and so does **Filmation: Edit Sprite
Sheet...** Every sheet is drawn in four colours that mean something to the
build -- ink, paper, transparent, and the rare stray, a data bit under a hole
in the mask -- with a magenta frame just outside each sprite, which the build
checks so that a rectangle that has moved off its sprite is caught.

In the middle is the whole picture, to scroll about and zoom into: the wheel
scrolls, **Ctrl** and the wheel zoom about the pointer from ×1 to ×32, the
middle button -- or **Space** and the left -- drags it about, **Fit width**
shows the picture's whole width and **Sprite** zooms to the picked one. Click
a sprite to pick it; it is ringed, the rest of the sheet dimmed round it, and
once zoomed in a grid shows every pixel and, stronger, the picked sprite's
bytes, the columns the engine draws it in. On the left is the tree of groups,
each sprite with its thumbnail and size, and a filter by name; picking one
there brings it into view. Only the picked sprite is painted. With the
**pencil**, a click on an ink pixel makes it paper and one on paper makes it
ink, so clicking toggles a pixel between the two; a clear pixel takes the
colour picked in the toolbar. A drag keeps the colour its first pixel gave
it, so one started on ink turns ink to paper all the way along. With
**Transparent** picked, the left button rubs out instead, and the right
button always does. **Fill** takes every joined pixel of one colour by the
same rule, and **Alt**+click picks up the colour under the pointer. Painting never reaches a frame or anything
outside the sprite. The keys: 1-4 the colours, P and F the tools, G the grid,
S the picked sprite, + and - the zoom, [ and ] the sprite before and after.
The view is drawn from the pixels for whatever part of the sheet shows, so a
tall sheet -- Lightkeep's walls are 5,084 rows -- costs no more than a short
one.

On the right is what the sprite is: its size and place on the picture, which
graphic numbers draw it (from `graphics.json`), and what the build will say
about it -- a broken frame, a colour with no meaning, or, for a sprite from
one of the other sheets, a size the engine cannot draw (16 to 40 pixels wide,
64 high). Under that it is drawn as a room would: in a room's ink, on black,
at one, two and three times, both ways round.

The **Size** card grows or shrinks the sprite at one edge: a row at a time at
the top and bottom, a byte -- eight columns -- at the sides, since the build
reads a sprite in bytes. What is drawn stays where it is in the sprite, new
pixels are transparent, and the editor redraws the frame. The game stands a
sprite on its bottom row and lines it up by its left column, so a change at
the top or right leaves it where it was on the screen and one at the bottom
or left moves it there -- unless its nudge in `graphics.json` moves too, which
the graphic map's **Nudge...** is for. A sprite that no longer fits where it
is, clear of the others' frames by the gap the build lays them out with,
moves to the first place on the picture it does, and the picture grows at
the bottom if there is none; the card says where it went.

**Tidy sheet...** lays every sprite out afresh: in the tree's order, each
group from a new row, left to right with that gap between. It asks first,
because anything else painted on the picture goes -- the group names
`sprite_sheet.py` writes above each band among it. Where a sprite sits on the
picture means nothing to the game, so a tidied sheet builds the same game;
Lightkeep's own sheet and its doors sheet, tidied, built byte for byte the
same.

Each of these is one edit, as a stroke is: **Ctrl+Z** and **Ctrl+Y** undo and
redo it, the tab shows it unsaved, and **Save** writes the picture and, when
a rectangle moved or changed size, the description too. The description is
written in the layout `sheet.py` writes -- one sprite a line, the columns
lined up, the file's own line endings and its own order, even where a name
looks like a number -- so a resize diffs as the line it changed. The build
notices either file changing and regenerates the sprites (for Lightkeep's
Melkhior sheets too). If a paint program saves over the picture, or anything
over the description, while the editor has nothing unsaved, it reloads.

The PNG is written by the editor's own encoder, `png_codec.js`.
`tests/png_codec_test.js` checks it round-trips every sheet in the
repository, and that every one decodes to a whole frame round every sprite;
`tests/sprite_sheet_model_test.js` that every description comes back out of
the editor's writer byte for byte.

Not done yet: adding, renaming and deleting sprites and groups, moving a
sprite to another group, and previewing animations. Until then those are
edits to the description by hand, with the frame drawn in a paint program.

## The graphic map

`graphics.json` opens as a picture too, for the same reason: it is numbers
pointing at names, and nothing in it says what graphic 30 looks like or that
150 draws the same bitmap. Open it, or run **Filmation: Open
Graphic Map...** `sprites.json` is read alongside, for the pictures and the
rectangles they come out of, and is not edited here.

Every graphic number is a tile showing the bitmap it draws, its sprite's name
and its number. A gold border means a bitmap more than one number draws; picking one
shows which others, and they are links. A red one means the file points at a
sprite the sheet has not got. The map and the side panel scroll apart, so the
panel stays beside the high numbers.

The side panel shows the picked number -- its sprite stood in its box, its
name, frame, nudge and box -- with four buttons. **Add...** opens the sprite picker on a number nothing uses
yet (the picked one if it is free, or any up to 511 from a list, never 256 or
257; a game of 256 graphic numbers refuses the upper half when it builds) and adds that
graphic, named after the sprite, with the number on the end if that name is
taken: this is how a sprite is put into a game. **Change...** opens the picker to
point the picked number at a different sprite. **Nudge...** moves its sprite
against its box (below). **Delete** takes the sprite off
the number. Nothing changes until the picker's OK; a double click on a sprite
is pick and OK, and a double click on the map is Change (or Add, on an unused
number). The picker chooses the sheet, filters by name or group, and shows the
sprite you have picked beside OK.

The map and the picker each have a size: **Fit** gives every sprite a tile and
scales it to fill it, and **×1**, **×2** and **×3** draw every sprite at that
scale, as big as it really is against the others.

### Moving a graphic to another number

Drag a tile onto another number to move its graphic there. Dropped on an unused
number, it moves; dropped on a used one, the two swap. Nothing else is
renumbered, the side panel follows the graphic, and the drop is one edit and
one undo. Only the number changes. Rooms place a graphic by its name and the
`GFX_` label is made from the name, so both follow it, and the build rewrites
the room data with the new number (and, past 255, with bit 8 in the height --
see the Filmation README).

A graphic whose number the game's **code** relies on cannot move, and nothing
can be swapped onto one. Its tile carries a small lock, and `graphics.json`
says `"fixed": true`. The code steps the knight's legs through 16 to 29 by
arithmetic, flips the ghost between 80 and 81 by a bit, counts a torch's bottom
two bits round, and puts a collectable in flight at its number plus 8, so moving
any of those would leave the code drawing whatever took its old place. Every
graphic Knight Lore and Pentagram came with is fixed, because their code is the
originals'. In Knight Lore 128K and Lightkeep, the scenery added since -- the
`castle.*` furniture, not the animated torches, and Lightkeep's Melkhior doors
-- is not. A graphic added through **Add...** is not fixed. Mark it fixed by
hand once code refers to it by number rather than by its `GFX_` label.

The name keeps any `.g<number>` it was given when it was seeded, even when the
graphic moves away from that number: rooms refer to it by that name.

### Nudging

**Nudge...**, or a click on the picture in the side panel, opens the picked
graphic stood in its box the way the game draws it. The sprite is where
`object_place` puts it. The box is drawn in blue round the red point the
graphic stands on -- its U, V and Z -- with the edges the box hides dashed and
its floor shaded. Move the sprite by dragging it, with the arrow keys (Shift
moves 8), or by typing the numbers. It moves a Spectrum pixel at a time at
every scale, and a gold outline keeps where it started. y counts up the
screen, because the engine subtracts it from the row. The nudges in
`graphics.json` already have the sprite's trimmed rows folded in, so this is
the sprite exactly where the game draws it.

**Plain** and **Mirrored** show it each way round: mirrored flips the sprite
and turns the box, U and V swapped. Most graphics have one nudge and use it both
ways round. Moving the mirrored sprite gives the graphic a mirrored nudge of its
own, and **Use the plain one** takes that away again. **Reflect the plain one**
starts it at the plain one's mirror image: the column -(x + width), the row
kept. Knight Lore's four doorways agree with that on the column and want a row
lower, so it is a start, not the answer.

The **box** is beside it, because a nudge is only right against a box:
half-widths along U and V and a height, stored unmirrored. It is what every
template placing the graphic is sorted and collided by, so changing it changes
the rooms as well as the picture. A graphic with no box of its own -- usually
an animation's later frames -- is drawn in the first box another number drawing
the same sprite has. **Give it a box** copies that one, or works one out from
the sprite's size when there is none. A mover's graphics, such as the
knight's, have none here, because a mover gives its record a box in its code.

Nothing changes until OK, and then it is one edit and one undo. In a game of
more than 256 graphic numbers, y is kept between -64 and 63 and the height
under 128, because the engine keeps bit 8 of the graphic beside them.

It shows one graphic on its own. Judging one against another -- a body against
the legs under it, say -- is still done in the room designer or the running
game.

### Other sheets

A `graphics.json` can list sheets besides the game's own, under `"sheets"`:

```json
 "sprites": "sprites.json",
 "sheets": {
  "objects":    "melkhior/objects.json",
  "furniture":  "melkhior/furniture.json"
 },
```

Each is a description in the same shape as `sprites.json`, relative to
`graphics.json`, and names its own picture. A sprite on one is named with the
sheet's name and a colon in front -- `furniture:GrandfatherClockNE.2` -- and
the graphic made from it gets the same name with a dot: `furniture.GrandfatherClockNE.2`.
The picker then has a list of the sheets above its filter. Only the sprites a
graphic names go into the build (`examples/filmation/scripts/sheet.py`), so a
sheet of hundreds costs nothing for the ones no graphic uses, and an unused
sprite on one is not reported as a problem the way one on the game's own sheet
is. A sheet whose picture is not there is listed as "not converted here", and
the build needs it only once a graphic names a sprite on it.

A frame bigger than the engine draws as one sprite -- more than 40 pixels wide
or 64 high, or narrower than 16 -- has a dashed border in the picker, and the
build stops on one a graphic names. Lightkeep's Melkhior's Mansion sheets are
the use for all this: see [lightkeep/README.md](lightkeep/README.md).

The room designer and the templates editor draw from all of them, each in the
room's ink as the game's own sheet is, and the templates editor offers their
graphics to add.

Picking a sprite never touches the **nudge** or the **box**, even when the
sprite goes; only the Nudge dialog changes them, and only on its OK. A
sprite can be re-extracted from a snapshot whenever you like; the nudge came
off a running game and there is no other copy, so no click here throws one
away, and the box is the graphic's rather than the bitmap's -- drawing it with
a different sprite does not make it a different size.

It writes the file back in the layout `graphics.py` writes it in, a graphic to
a line with the columns lined up, rather than as reflowed JSON. It is a file
people edit by hand, and a panel that reflowed all 187 lines the first time a
graphic was re-pointed would make every change diff as the whole file.
`graphic_map_model_test.js` requires both games' real files to come back out of
it byte for byte.

Editing it is editing the **game's** mapping, which is worth saying twice: the
sharing is Ultimate's own, read out of Knight Lore's table of 256 sprite
pointers at `$7112`, and the numbers that share a bitmap are still not
interchangeable, because the nudge is per number -- and it is right there in
the same entry, which is how you can see that 30 and 150 sit four rows apart.

```powershell
node examples/filmation/vscode/tests/graphic_map_model_test.js
node examples/filmation/vscode/tests/graphic_map_page_test.js
node examples/filmation/vscode/tests/templates_page_test.js
node examples/filmation/vscode/tests/template_refs_test.js
node examples/filmation/vscode/tests/behaviours_test.js
```

## Editing the files as text

Each of the JSON files here has a schema, registered by the extension, so
opening one as text gives completion, hover documentation on every field and a
squiggle under a value the build would reject:

| File | Schema |
|---|---|
| `rooms.json` | `examples/filmation/vscode/schemas/rooms.schema.json` |
| `templates.json` | `examples/filmation/vscode/schemas/templates.schema.json` |
| `graphics.json` | `examples/filmation/vscode/schemas/graphics.schema.json` |
| `sprites.json` | `examples/filmation/vscode/schemas/sprites.schema.json` |
| `specials.json` | `examples/filmation/vscode/schemas/specials.schema.json` |

`sprites.schema.json` still describes the sheet as it was before the group
tree, so it is **not** in the test below: it would pass every file vacuously
and prove nothing, which is the one thing that test exists to stop. It goes
back in when it is rewritten for the sheet's own shape.

To read a file that has a designer as text instead, reopen it with **Text
Editor**.

`examples/filmation/vscode/tests/schemas_test.py` holds each schema against every real
file it claims to describe, and then against a deliberately broken copy of
each, which must fail it. A schema that merely looks plausible is worse than
none: it puts errors on a file that is actually right, and you learn to ignore
them.

```powershell
.venv-win\Scripts\python.exe examples/filmation/vscode/tests/schemas_test.py
```

## Where the pieces are

| File | What |
|---|---|
| `examples/filmation/vscode/room_model.js` | What a castle is: the schema, the cell-to-world arithmetic, the map, the checks, and the edits |
| `examples/filmation/vscode/room_render.js` | What it looks like: the projection, the depth list, the nudge table and the sprite-sheet lookup |
| `examples/filmation/vscode/room_view.html` | The page, the same in both hosts |
| `examples/filmation/vscode/room_view.js` | The editor's host: the custom editor, `WorkspaceEdit`s, and the build task |
| `examples/filmation/vscode/room_designer.py` | The browser's host: a localhost server that serves the page and writes the file |
| `examples/filmation/vscode/game_layout.js` | Where a game keeps what: its folder, `metadata/`, `art/`, `generated/`, and how far a file may point |
| `examples/filmation/<game>/scripts/rooms.py` | `room_data.bin` → `rooms.json`, once, for someone who has extracted their own |
| `examples/filmation/<game>/scripts/rooms_source.py` | `rooms.json` → `generated/room_data.s` |
| `examples/filmation/vscode/specials_model.js` | What a collectable is: the game's own limits, and the edits |
| `examples/filmation/vscode/graphic_map_model.js` | What a graphic map says, what it hides, how to re-point one, and the box and sprite the nudge dialog draws |
| `examples/filmation/vscode/graphic_map_view.html` | The graphic map's page |
| `examples/filmation/vscode/graphic_map_view.js` | Its editor host |
| `examples/filmation/vscode/schemas/` | The five JSON schemas, for editing any of it as text |
| `examples/filmation/<game>/metadata/sprites.json` | the graphics: the sprites, their names, which sprite each graphic number draws and the nudge that lines it up |
| `examples/filmation/knightlore/metadata/specials.json` | where the collectables start and the order the wizard wants them, → `specials_gen.s` |
| `examples/filmation/knightlore/scripts/specials_source.py` | `specials.json` → `specials_gen.s` |

## Not done yet

- **The player's starting position** is in the game's code, not its room data,
  so the designer neither shows nor moves it.
- **A collectable cannot be dragged.** Its table holds world bytes rather than
  floor cells, so there is no grid to drop it on; the arrow keys and the boxes
  in the panel are what move it.
- **Which kind a collectable is** is not anyone's to choose: `special_init`
  deals them from a random number every game. The designer shows a stand-in.
- **Movers' behaviour** -- what a guard patrols, which way a ball bounces --
  comes from the object's template and the game's `movers.s`, and the designer
  edits the template's bytes without knowing what they mean.
- **A room cannot be renumbered**, and deleting one leaves the doorways into
  it and the collectables in it pointing nowhere: the designer says so before,
  and the checks after, but does not change them for you.
- **The walked map is only a map.** It cannot be edited -- a doorway is changed
  in Ways out, and the map follows -- and a castle that is not flat has rooms
  listed under it rather than drawn in some second layer.
- **Undo outside VS Code** is the editor's, so the browser host has none.
