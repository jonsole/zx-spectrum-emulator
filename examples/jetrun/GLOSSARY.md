# Jetrun

A game for the 48K Spectrum: a jetpack astronaut explores a cavern planet,
finds the three parts of a broken rocket, assembles it at the launch site and
fuels it to escape. Its landscape is drawn by Ultimate's own Cyberun renderer,
and for now its world is Cyberun's (docs/adr/0007).

## The world

**World**:
The whole cavern planet: a grid of pages that wraps round from east to west
and is bounded by sky above and solid rock below.
_Avoid_: Level, map (the map is the world's data)

**Page**:
One cell of the world's grid, exactly the size of the play area: 224 pixels
across and 160 down. Positions in the world are a page and a place in it.
_Avoid_: Screen, room, cell

**Map**:
The world's grid as data: which tile each page holds.
_Avoid_: Layout, level data

**Tile**:
What a page holds: a short list of pieces. Many pages share a tile; a page
with no pieces is sky or rock, told apart only by what surrounds it.
_Avoid_: Block, screen type

**Piece**:
A straight run of identical steps in one direction, starting at a place in
its page. The pieces of a tile join end to end, and tiles join at their
edges, so the surfaces of the world are unbroken lines.
_Avoid_: Segment, line, run

**Step**:
One repeat of a piece's shape: a fixed run across and rise or fall, drawn
with one graphic.
_Avoid_: Unit, tile

**Direction**:
Which of sixteen shapes a piece's steps have: a flat floor, three slopes
climbing each way, the same seven upside down as ceilings, and a wall facing
each way.
_Avoid_: Type, kind, angle

**Floor**, **Ceiling**, **Wall**:
A surface with rock below it, with rock above it, and a vertical surface with
rock to one side. Slopes are floors or ceilings.

**Surface**:
Where rock meets sky: the line a world's pieces draw.
_Avoid_: Edge, outline, terrain line

**Sky**, **Rock**:
The two things a pixel of the world can be: open space, drawn black, and
solid ground, drawn as a checker of alternate pixels.
_Avoid_: Air, ground, empty, solid

## Drawing

**Screen is never cleared**:
The landscape is not redrawn in full each pass. Sky and rock look the same
after any move of an even number of pixels, so only what lies near a surface
can change, and only that is drawn.

**Fill**:
Painting the rows or columns a moving edge has uncovered, sky or checker,
as Cyberun's renderer does after drawing each piece.
_Avoid_: Clear, erase

**Shift**:
A step's pixel offset within its byte on the screen, 0, 2, 4 or 6; each step
graphic is built at all four.
_Avoid_: Phase, offset

**End code**:
A flat piece's two bytes saying what caps its ends: whether an end is a drop
(the ground beside it lower), and whether the run stops on the page's edge.
_Avoid_: Cap byte, extra

**Full render**:
Drawing the whole play area from nothing, for a new life: every pixel column
filled from what lies above it, using each tile's parity. Cyberun's renderer
then scrolls a page down to the view so that every surface is its own drawing.
_Avoid_: Redraw, refresh

**Parity**:
For a tile, whether each of its pixel columns is crossed by its surfaces an
odd number of times from top to bottom: whether sky above it becomes rock
below it, or the other way round.

**Pass**:
One turn of the game's loop: read the controls, move everything, draw. A pass
takes exactly two frames, 25 a second.
_Avoid_: Frame, tick, turn

## The view

**Play area**:
The part of the screen the world is drawn in: 28 characters by 20.
_Avoid_: Window, screen

**View**:
The part of the world the play area shows: a page-sized window into the
world, at any pixel position.
_Avoid_: Camera, viewport

**Centre**:
Where the view keeps the astronaut: the middle of the play area, on character
cells, so its colour covers exactly its own cells. The view follows it as far
as Cyberun's renderer can scroll in a pass.
_Avoid_: Dead zone, camera box

## Playing

**Astronaut**:
The player: a figure with a jetpack who flies, lands and walks.
_Avoid_: Player, man, ship

**Jetpack**:
What lifts the astronaut, burning jetpack fuel while it thrusts.

**Object**:
Anything in the world besides the astronaut and the landscape that moves by
the same physics: rocket parts, fuel pods, rocks, creatures.
_Avoid_: Sprite, entity, actor

**Live object**, **Parked object**:
An object near the view, moved and drawn every pass; and one far away, kept
only as its place and kind in a compact list until the view comes near.

**Creature**:
A live object that moves by itself and harms the astronaut.
_Avoid_: Enemy, alien, monster

**Held object**:
The one object the astronaut is carrying, which moves with them and adds its
mass to theirs; dropped while moving, it is thrown.
_Avoid_: Carried item, inventory

**Rocket part**, **Fuel pod**:
The three pieces of the rocket, and the canisters that fill it once it is
assembled.

**Launch site**:
The place the rocket is assembled and fuelled.

**Fuel pad**:
A place that refills the jetpack.

**Energy**:
How much harm the astronaut can still take before a life is lost.
_Avoid_: Health, shield, hit points

**Restart point**:
The last safe place the astronaut stood, where the next life begins.
