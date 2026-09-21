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

## The file it edits

Each game keeps its rooms in `examples/filmation/<game>/rooms.json`, and that
file is the editable form:

```
room_data.bin  --rooms.py-->  rooms.json  --rooms_source.py-->  room_data.s
   the game's                  what you                          what the
   own tables                   edit                           build assembles
```

`build.py` runs both steps, and times them separately on purpose: `rooms.json`
is only re-decoded when `room_data.bin` or `rooms.py` is newer than it, so an
edit survives a build rather than being overwritten by the original game's
rooms. Going back to those is a matter of running `rooms.py` by hand, which
says plainly that it overwrites what is there.

Both games write the same schema, so one designer serves both. Where they
differ is written down in `room_model.js` rather than branched on twice:

| | Knight Lore | Pentagram |
|---|---|---|
| The map | arithmetic: a 16 × 16 grid, the room number is a row and a column | a destination byte on each doorway |
| Doorways | the template's index says so: the first eight arches, and the two high arches | the template says so |
| Object entries | six bytes, the sixth a placement nudge | five bytes, no nudge |
| Scenery count | in bits 5-7 of the attribute byte | the same, stored less one, so eight fits |

`rooms.json` and `room_data.bin` are both carried in the repository.
`room_data.s` is not -- it is generated -- and neither is the artwork.

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
 { "graphic": "torsos_and_wizard_sprite_005_g150",
   "sizeU": 6, "sizeV": 6, "sizeZ": 24,
   "flags":   { "mirrored": false, "passable": false, "rest": 16 },
   "offsets": { "halfU": false, "halfV": true, "raiseZ": 0 } }
]
```

[graphics.py](../examples/filmation/graphics.py) is the one place the number
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

Renaming is therefore done in the sheet, and `build.py` follows it: `graphics.py`
and `sprites.json` are both inputs to the room data, so changing either
re-decodes `rooms.json` with the new names on the next build. Two sprites given
the *same* name stop it rather than quietly collapsing into one.

The cost of naming rather than numbering is that sprite names are load-bearing:
rename one in `sprites.json` and the castle's references dangle until `rooms.py`
runs again. `rooms_source.py` stops with the template and the name it could not
place rather than emitting a wrong byte.

`flags` names the two bits we know -- bit 6 mirrors a piece, bit 1 lets things
through it -- and keeps the others in `rest`. Those are the game's own, which
`rooms_source.py` drops on the way to `OBJ.FLAGS`; they are carried whole
rather than guessed at, so the file claims no more than is actually known.

So `rooms.json` also says which sheet it goes with, in its `meta`:

```json
"sprites": {
 "sheet": "sprites.png",
 "atlas": "sprites.json",
 "adjust": "sprite_adj.s"
}
```

and a graphic is resolved through it:

```
rooms.json     graphic 178
sprites.json   meta.zx.game.graphicMap[178] -> 6
               meta.zx.sprites[6].label     -> "balls_sprite_006"
               frames[...].frame            -> { x: 0, y: 177, w: 24, h: 19 }
sprites.png    that rectangle
```

The paths are relative to the `rooms.json`, and neither host will follow one
that climbs out of its directory or is absolute: the file is data, and data
does not get to point the designer at the rest of the disk. A file written
before the field existed has no `meta.sprites`, and the three names above are
what it falls back to, one key at a time -- see `spriteFilesOf` in
`room_model.js`, and the same table in `scripts/room_designer.py`.

None of this reaches the build. `rooms_source.py` reads the rooms and ignores
`meta` entirely, so naming a different sheet changes what the designer draws
and not one byte of the game.

## Opening it

**In VS Code.** Open `examples/filmation/<game>/rooms.json`, or run
**ZX Spectrum: Design Filmation Rooms...** from the Command Palette, which
offers the games it can find. The document is the model: every change goes in
through a `WorkspaceEdit`, so undo, the dirty mark and Save are the editor's
own, and an edit from anywhere else -- an undo, the text editor, `rooms.py`
having rewritten the file -- reloads the page on the room you were looking at.
To read the file as text instead, reopen it with **Text Editor**.

**Outside it.**

```powershell
python scripts/room_designer.py                 # Knight Lore
python scripts/room_designer.py pentagram
python scripts/room_designer.py --port 8900 --no-browser
```

It serves on localhost only and its **Build** button runs the game's own
`build.py`. Nothing is written until you press **Save**: changes are held in
the page, the header says "unsaved" while any are, and closing the tab asks
first.

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

**Ways out**, under it, is the room's doorways and where each leads. Knight
Lore's are arithmetic and cannot be anything else, so they are shown and not
editable. Pentagram's are a byte, and the byte is the authority -- one of its
south doorways is an exit in twenty-eight rooms and walled up in one -- so
there it is a field you change.

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
every room -- 48 of them, for `object_spike_ball_falling`. The Templates tab is
where a template's bytes are changed, and it says how many rooms that reaches.

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

**Objects**, **Scenery** and **Templates**, on the right.

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
- *Templates* edits the shared templates themselves -- the graphic each piece
  is drawn from, picked from every graphic the game has rather than typed; its
  sizes; and the flag bits by name -- and renames them. Renaming is the point of the file being JSON: Pentagram's are
  placeholders (`scenery_07`, `object_12`) until someone works out what each
  piece is, and a rename moves every room that names it. A change to a
  template's bytes moves every room that uses it, and the panel says how many
  that is.

**Checks**, at the bottom, is everything that would stop `rooms_source.py`
emitting the castle or stop the engine building a room: a room out of order, a
position off the eight-by-eight floor, more scenery than the count field holds,
a record longer than its skip byte can reach. This room's problems come first.

## How the picture is drawn

The preview is drawn in JavaScript, not by the emulator, because a designer has
to redraw while an object is being dragged and a round trip through a running
machine cannot. That means `room_render.js` is a second implementation of three
things the engine already does, and that is the risk it carries:

| In the engine | Here |
|---|---|
| `object_place` in `engine/object.s` | `project` |
| `depth_cmp` and `depth_insert` in `engine/depth.s` | `depthCompare` and `insertPlaced` |
| `room_adjust` in `engine/room.s`, over `sprite_adj.s` | `parseSpriteAdj` and `adjFor` |
| `room_unpack` in the game's `room_build.s` | `expandRoom` in `room_model.js` |

Each of those is held to the original rather than to itself.
`tests/room_render_test.js` works the projection out from `object_place`'s
eight instructions by hand and takes its depth tests -- numbers and outcomes
both -- from the worked examples in [engine/depth.md](../examples/filmation/engine/depth.md).
`tests/room_model_test.js` reads the generated `room_data.s` back and requires
the model to agree with what `rooms_source.py` wrote: the background flag
especially, which is decided by template name in Python and has to be decided
the same way here, or the preview sorts a wall the game does not.

What it does **not** draw is anything the room data does not hold: the player,
the collectables, the panel, and whatever else the game's own code puts on the
screen. A room in the designer is the room as `room_build` leaves it.

```powershell
node vscode-extension/tests/room_model_test.js
node vscode-extension/tests/room_render_test.js
```

## Where the pieces are

| File | What |
|---|---|
| `vscode-extension/room_model.js` | What a castle is: the schema, the cell-to-world arithmetic, the map, the checks, and the edits |
| `vscode-extension/room_render.js` | What it looks like: the projection, the depth list, the nudge table and the sprite-sheet lookup |
| `vscode-extension/room_view.html` | The page, the same in both hosts |
| `vscode-extension/room_view.js` | The editor's host: the custom editor, `WorkspaceEdit`s, and the build task |
| `scripts/room_designer.py` | The browser's host: a localhost server that serves the page and writes the file |
| `examples/filmation/<game>/rooms.py` | `room_data.bin` → `rooms.json` |
| `examples/filmation/<game>/rooms_source.py` | `rooms.json` → `room_data.s` |

## Not done yet

- **The player's starting position** is in the game's code, not its room data,
  so the designer neither shows nor moves it.
- **Movers' behaviour** -- what a guard patrols, which way a ball bounces --
  comes from the object's template and the game's `movers.s`, and the designer
  edits the template's bytes without knowing what they mean.
- **A new room** cannot be added: the records are walked in ascending order and
  Knight Lore's list has to end at `$FF`, which the checks enforce but the
  designer has no button for.
- **Undo outside VS Code** is the editor's, so the browser host has none.
