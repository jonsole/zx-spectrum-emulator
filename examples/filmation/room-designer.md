# Designing a Filmation room

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
`examples/filmation/<game>/`, one job each:

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
 "sheet": "sprites.png",
 "atlas": "sprites.json",
 "graphics": "graphics.json"
}
```

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

**In VS Code.** Open `examples/filmation/<game>/rooms.json`, or run
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

**Add room**, under the map, is a number -- the lowest free one to start with
-- and a button. The room it makes is empty, stands on the first floor shape,
takes the ink of the room before it, and goes in number order, because
`room_find` walks the records in ascending order; the designer goes to it, and
it is one undo like any other edit. A number already used, outside 0-255, or
after the castle's last room (`$FF` in Knight Lore) is refused with the reason
under the box. A castle whose exits are a table also keeps one number free,
since its builder needs a number no room has to mean "no exit".

**Ways out**, under that, is the room's doorways and where each leads. Knight
Lore's are arithmetic and cannot be anything else, so they are shown and not
editable. Pentagram's are a byte, and the byte is the authority -- one of its
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
does not say which.

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
laid, and the order they join the object pool -- and removed. At the bottom is
every room that places the template; clicking one takes the designer there.

A piece's **box** is not here: it belongs to the graphic, and the graphic map
is where it is changed.

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
data itself can make.

In VS Code it is a second document, so an edit to it is a `WorkspaceEdit` on
that file and it gets its own dirty mark and its own undo: two files changed is
two files to save. The browser host holds both and writes them with one Save,
because they are edited in one page and there is nothing useful about saving
half of it.

## The graphic map

`graphics.json` opens as a picture too, for the same reason: it is numbers
pointing at names, and nothing in it says what graphic 30 looks like or that
150 draws the same bitmap. Open it, or run **Filmation: Open
Graphic Map...** `sprites.json` is read alongside, for the pictures and the
rectangles they come out of, and is not edited here.

Every graphic number is a tile showing the bitmap it draws, its sprite's name
and its number. A gold border means a bitmap more than one number draws; picking one
shows which others, and they are links. A red one means the file points at a
sprite the sheet has not got. Re-pointing a graphic is a click in the picker,
filtered by name or group, and "mark unused" takes the sprite off a number.

It never touches the **nudge** or the **box**, even when the sprite goes. A
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
| `examples/filmation/<game>/rooms.py` | `room_data.bin` → `rooms.json`, once, for someone who has extracted their own |
| `examples/filmation/<game>/rooms_source.py` | `rooms.json` → `room_data.s` |
| `examples/filmation/vscode/specials_model.js` | What a collectable is: the game's own limits, and the edits |
| `examples/filmation/vscode/graphic_map_model.js` | What a graphic map says, what it hides, and how to re-point one |
| `examples/filmation/vscode/graphic_map_view.html` | The graphic map's page |
| `examples/filmation/vscode/graphic_map_view.js` | Its editor host |
| `examples/filmation/vscode/schemas/` | The five JSON schemas, for editing any of it as text |
| `examples/filmation/<game>/sprites.json` | the graphics: the sprites, their names, which sprite each graphic number draws and the nudge that lines it up |
| `examples/filmation/knightlore/specials.json` | where the collectables start and the order the wizard wants them, → `specials_gen.s` |
| `examples/filmation/knightlore/specials_source.py` | `specials.json` → `specials_gen.s` |

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
- **A room cannot be deleted or renumbered.** Add room makes one; taking one
  away would leave every doorway into it pointing nowhere, and nothing yet
  offers to deal with those.
- **The walked map is only a map.** It cannot be edited -- a doorway is changed
  in Ways out, and the map follows -- and a castle that is not flat has rooms
  listed under it rather than drawn in some second layer.
- **Undo outside VS Code** is the editor's, so the browser host has none.
