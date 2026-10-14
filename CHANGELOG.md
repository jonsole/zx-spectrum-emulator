# Changelog

One list for the emulator (`zx_server`) and the VS Code extension, which are
released together under one version. `scripts/release.py <version>` moves
what is under **Unreleased** into a section of its own, and the release on
GitHub takes its notes from that section.

## Unreleased

- **Fast 3D routines, `examples/fast3d`.** Z80 routines for 3D graphics:
  `mul8s`, a signed 8 x 8 multiply by quarter squares (154 T-states);
  `make_matrix`, the rotation for three angles, summing sines of sums of
  angles instead of multiplying; `rotate`, a vertex by that matrix
  (1,241 T-states), with the matrix written into its table addresses;
  `project`, `transform`, `draw_line` and `clear_box`; lines clipped to a
  window (`clip_line`, Cohen-Sutherland, crossings found by a binary chop,
  each end within 0.75 of a pixel of the true line); and objects -- models
  whose faces share their vertices -- at 16-bit positions, seen from a
  camera, with `cull_object` leaving out what is out of view, most of it for
  about 2,300 T-states, before a vertex is touched, and with `CULL_SKIP` not
  testing again what cannot have come into view, by a bound on how far an
  object's centre can move that is arithmetic on the camera's matrices as
  they are, whatever the camera did. `check.py` holds every
  routine to a Python model in SkoolKit's simulator, every multiply and every
  pixel. The launch configuration **ZX Spectrum: fast3d demo** flies a camera
  through forty turning objects on the 128K, about 7 frames a second (it
  says how many, in a corner), working out each picture while the last
  waits to be shown. See
  [examples/fast3d/README.md](examples/fast3d/README.md).

- **Aviator, `examples/aviator`.** Geoff Crammond's BBC Micro flight
  simulator, being ported to the 48K from Mark Moxon's documented
  disassembly at aviator.bbcelite.com. The original runs in Python on a 6502
  interpreter as the reference; the whole game is ported to Python and
  matches it byte for byte over three scripted flights; and the Z80 version,
  the whole game, is checked against that port: flight model, keys and an
  Interface II stick, dashboard, the Theme's aliens and guns, scoring,
  crashes, and the sound on the beeper, its state and screen matching the
  port's every frame of four scripted flights. It runs at about 8.2 frames
  a second (the BBC's is 9), before any optimising beyond the 3D view. Its
  launch configuration is **ZX Spectrum: Aviator**; Acornsoft's files are
  fetched at build time, never committed. See
  [examples/aviator/README.md](examples/aviator/README.md).

- **A Revs road engine, `examples/revs`.** Geoff Crammond's BBC Micro *Revs*
  rebuilt for the 48K in Z80, using the documented disassembly at
  revs.bbcelite.com as its design: Silverstone's track with a sign beside it
  and a car parked on it, seen from a camera you can speed up, slow down and
  move across the track with Q, A, O and P or an Interface II stick. It runs
  unsynchronised, as fast as the work allows (about 20 updates a second), or
  synchronised to the beam at 16.7 with `build.py --define SYNCED`. Its
  launch configuration is **ZX Spectrum: Revs road**; the track data is
  fetched at build time, never committed. `examples/revs/tests/run_tests.py`
  checks it against Python models of its maths, geometry, objects and
  screen, its timing against the beam, and its speed, through a new cpp-core
  tool, `snapshot_probe`, that drives a snapshot from a script;
  `tests/profile.py` shows where its time goes, by routine, source line or
  instruction. The experiment stops there: the road alone takes about 32K,
  and the rest of the game would not fit the 48K. See
  [examples/revs/README.md](examples/revs/README.md).

- **The Filmation games' `extract.py` takes a Knight Lore saved at the menu.**
  Drawing the menu turns its frame's corner upside down in place, and the game
  records that nowhere, so such a copy was refused. It is now tried both ways
  up, its sprites are checked by the sheet they make rather than by a hash
  that also covers flag bits nothing reads, `sprites.png` is compared by its
  pixels where another Pillow writes the same picture as other bytes, and a
  copy that fails leaves the carried files as they were.

- **The emulator in a browser.** `web/` compiles the core to WebAssembly
  and publishes it to GitHub Pages, where it runs whatever 48K or 128K
  `.z80` or `.sna` a visitor opens from their own disk. Beside it,
  `knightlore.html` makes the Filmation Knight Lore from a visitor's own copy
  of the original, taking its font, sprites, castle and collectables from it -- the same
  `knightlore.z80` `build.py` writes -- to download or to play, and
  `pentagram.html` the Filmation Pentagram, from its tape or a snapshot, every
  part of it from the copy. See [docs/web.md](docs/web.md).

- **The Filmation examples are laid out alike.** Every game folder keeps its
  `build.py` and its own assembler at the top, its Python in `scripts/`, the
  JSON you edit in `metadata/`, its sprite sheet in `art/`, what the build
  writes in `generated/`, and what the Extract task pulls from your copy of the
  original in `extracted/`; the Python every game shares is in
  `examples/filmation/scripts/`. The Knight Lore and Pentagram workspaces' Extract
  task runs `examples/filmation/scripts/extract.py`.
- **The graphic map picks sprites from more than one sheet.** A `graphics.json`
  can list other sheets under `"sheets"`, and a sprite on one is named
  `objects:Bell.0`; the picker has a list of the sheets, marks a frame too big
  for the engine to draw as one sprite, and picking a sprite for an unused
  number adds that graphic. The build takes only the sprites a graphic names
  from those sheets, and stops on one too big. The picker's tiles had been
  captioned "undefined" since sprites were named rather than numbered, and a
  click on one took the sprite off the graphic; that is fixed.
- **The graphic map is easier to work in.** The map and the side panel scroll
  apart; the panel shows the picked number with Add, Change and Delete, and the
  sprite picker opens in a dialog of its own. The map and the picker each draw
  at Fit, ×1, ×2 or ×3, the fixed sizes keeping sprites true to one another.
- **The Filmation engine can have 512 graphic numbers** in a game that needs
  them (Lightkeep): the ninth bit rides in the object record's y nudge, and the
  code for it is assembled only in such a game, so the others build as they
  did. The graphic map offers numbers up to 511, never 256 or 257.
- **The graphic map edits nudges and boxes by eye.** The side panel shows the
  picked graphic stood in its 3D box, and **Nudge...** opens it big. Drag the
  sprite, use the arrow keys or type the numbers, plain and mirrored, while a
  gold outline keeps where it started. The box can be changed beside it, or
  given to a graphic that has none. The picture uses the room designer's
  projection, so the sprite sits exactly where the game draws it.
- **Graphics can be renumbered by dragging them on the graphic map.** Dropped
  on an unused number a graphic moves there, and dropped on a used one the two
  swap; rooms follow, because they place graphics by name. A graphic whose
  number the game's code relies on is marked `"fixed": true` in
  `graphics.json`, shows a lock, and stays put. Every graphic the original
  Knight Lore and Pentagram came with is fixed.
- **Filmation characters can walk up stairs**, in a game built with
  `DEFINE CHARACTER_STEP_UP n`: anything solid whose top is no more than `n`
  units above his feet is climbed, two units a turn, rather than jumped, the
  way Fairlight's knight climbs its staircases. Lightkeep has it at 6, and an
  invisible `solid` graphic for boxes under stair and ledge artwork. Room 106
  has a raised section along its west wall, an invisible box with the castle's
  wall stones on its front face (`scenery_raised_w`), and test stairs up to
  it. Knight Lore, Knight Lore 128K and
  Pentagram don't define it and build byte for byte as before.
- **The templates editor shows a piece's box and where it stands.** The
  selected piece is drawn with its box, the box's base shaded on the floor, a
  mark under its middle, a line up to it when it is raised, and guide lines
  crossing on the floor at its place, which run on out of the room when the
  piece is outside it, while it is dragged as well. The room designer draws
  the same guide lines under a selected object or collectable. A piece whose sprite draws nothing, such as Lightkeep's
  invisible `solid`, is drawn as its box and picked by clicking inside it. A
  piece can be given a box of its own, edited in its row, or go back to its
  graphic's. A piece lifted off the top of the screen stays above the rest,
  outlined in red with a warning, rather than jumping to the bottom; the game
  would draw it wrapped round to the bottom. A piece behind a room's far
  corner, which the game draws 128 rows lower, is outlined and named the same
  way.
- **Lightkeep's guards fall like the knight, legs and all.** A guard that
  walks off a raised floor now gathers speed as the knight does, and his legs
  come down with him: a two-part figure's legs used to follow its torso along
  the floor but not down. It is a build option of the Filmation engine,
  `PAIR_GRAVITY`; Knight Lore, whose guards never fall, builds as before.
- **Lightkeep's moving objects are chosen in the templates editor, and can
  weigh something.** An object template has a **moves** row: one of the
  game's behaviours, read from its `movers.s` and marked if it kills or can be
  pushed, or none. One that can be pushed has a weight from 1 up, which a
  push loses, so a heavier object moves less and one as heavy as the push not
  at all: the knight pushes a weight of 1 at 2 a turn, smoothly, where a table
  used to lurch 3 every other turn. It is
  saved in `templates.json`, and the build writes the game's table from it. The
  weight is a Filmation engine build option, `LOOSE_WEIGHT`; Knight Lore,
  Knight Lore 128K and Pentagram build as before.
- **How the Filmation engine works**, `examples/filmation/engine/how-it-works.md`:
  the engine explained for a Spectrum programmer, from the record the draw
  walk POPs to the 48K and 128K memory maps.
- **A user guide for the Filmation Designer**,
  `examples/filmation/designer-guide.md`: the room designer, the templates
  editor, the graphic map and the sprite sheet editor, task by task, with
  screenshots.
- **A sprite sheet editor for the Filmation games.** Opening a sheet's
  description (`metadata/sprites.json`, or a Melkhior one) opens its picture
  for pixel editing: the sprites in their groups, a pencil and a fill in ink,
  paper and transparent, a mirrored view, previews in a room's ink, which
  graphics draw each sprite, and what the build will say about it. A sprite
  grows or shrinks at any edge, keeping its frame and moving to free space
  when it no longer fits, and **Tidy sheet** re-lays the whole picture; the
  description is rewritten to match, in the layout the build writes. Undo,
  redo and Save are VS Code's own. Naming and grouping sprites are to follow.
- **The templates editor adds a piece from pictures.** **Add...** shows every
  graphic as a picture with its name, filtered by name as you type, and the
  editor and the room designer now draw pieces from the other sheets
  `graphics.json` lists, so Lightkeep's Melkhior doorways show in both. The graphic map takes a game's
  `GRAPHIC_COUNT` from its `sprite_sheet.py`, so the numbers it offers and how
  far a y nudge may go follow what the game is built with.
- **Lightkeep's rooms remember where things were left.** A table pushed into
  a corner is still in the corner when the knight comes back, and a soldier is
  where he was, walking the way he was. Everything a push moves, and every
  template `templates.json` marks `"kept": true`, is an entry in one table, as
  in Fairlight. A new game puts it all back.
- **Lightkeep's objects can stand at any height in steps of 4**, from 64
  below the floor to 96 above it, not only on the four levels. A shift in Z
  rides in the spare bits of an object group's count byte, so the room data
  is no bigger. The room designer hides it. Ctrl with up and down moves an
  object a level, and with Shift 4 units. The designer makes and merges the
  groups a height needs, and says when the selected object is in one.
- **Lightkeep has storeys.** A room can have a hole down to the room below and
  stairs up to the room above (`"down"` and `"up"` in `rooms.json`). A storey
  is 96 units, so a staircase runs on from one room into the next. The knight
  drops through a hole and climbs the stairs. Things fall through too, soldiers
  included, and land in the room below. Rooms $A7 and $83 have a test
  stairwell. The hole has no art of its own yet.
- **Lightkeep's knight carries things**, five at most and a load of 7, as in
  Fairlight, with one key, as Knight Lore has it. Each press of N moves what
  he carries along by one place. Something next to him is picked up into the
  first, and whatever falls off the end is put down. The panel shows all five
  places, and TOO HEAVY and BLOCKED say why not. A thing carried to another
  room and put down stays there. Templates marked `"pickup"` can be carried:
  for now the movable block and the chest. Keyboard turning has moved to O
  and P.

## 0.1.0 (2026-09-29)

The first release: the emulator and the VS Code extension, packaged.

- **Installs in one step.** The extension's `.vsix` carries `zx_server` and the
  48K and 128K ROMs, so a debug session works without building anything. A
  checkout's own build and ROMs are still used first. The emulator is also
  published on its own, as a zip, for MCP clients and other editors.
- **The machine:** a 48K and 128K Spectrum emulated per half-T-state, pin by
  pin, with the AY chip, `.sna`, `.z80`, `.tap`, `.tzx`, `.wav` and `.csw`.
- **Debugging in VS Code:** breakpoints, stepping in the ROM's and your own
  assembly source, stepping backwards, watchpoints, logpoints, a call stack
  that follows a borrowed stack pointer, an execution profiler, a live screen
  with raster position and a display-write overlay, graphics and tape tools.
- **More than one emulator at once**, each announcing its ports, with the
  screen panel following whichever the debugger is on.
- **MCP:** the same machine driven by an AI agent, alongside the debugger.
- **Example workspaces**, each its own zip: stepping through the ROM in its
  commented disassembly, and the Knight Lore and Pentagram remakes on the
  Filmation engine. The remakes' workspaces carry none of Ultimate's data: an
  Extract task makes it from your own copy of the original (`.sna`, `.z80`,
  and for Pentagram `.tzx` or `.tap`) and checks it came out right.
- **The Filmation designer** -- the room, templates and graphic-map editors --
  released as its own `.vsix`. The room designer adds and deletes rooms from
  the map, lists a castle's starting rooms under it and swaps them, drags
  collectables, edits the floor shapes on a Shapes tab and warns when a room's
  walls no longer sit on its floor, and holds a castle to a limit on each
  room's pieces; it also drives the room editor for the original Knight Lore,
  Pentagram and Alien 8 in `game-disassemblies`, a castle stating where it
  draws, where its player starts and its groups' own nudges.
- **Works outside the repository:** Run and Debug on a snapshot, F5 with no
  `launch.json`, the trace viewer and the tape designer's Build all work in any
  folder. sjasmplus, which the examples and the tape designer assemble with,
  is fetched the first time it is needed.
- **ZX Spectrum: Save Snapshot...** saves the machine as a `.z80` or `.sna`.
- **Opening a `.tzx`** shows its loader -- SpeedLock 1, SpeedLock 2 and the like,
  when the tape names it -- with its title, publisher and year. The loading
  screen from a custom loader is no longer drawn garbled: Knight Lore's is
  drawn right, and one that can't be read is left out.
- `zx_server --version`, and a version in `serverInfo`; the extension warns
  when a server is older than it.
- MIT licence; third-party terms in `THIRD_PARTY_NOTICES.md`.
