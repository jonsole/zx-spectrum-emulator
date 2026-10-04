# Filmation Designer

A VS Code extension for editing the Filmation remakes in
[examples/filmation](..): their castles, the templates the rooms are built
from, and which sprite each graphic draws. It is separate from the emulator's
extension and needs nothing from it; **Build** runs the game's own `build.py`
as a task.

- **The room designer** opens `examples/filmation/<game>/metadata/rooms.json`.
  It shows the room the way the engine draws it, the castle's map, and the
  room's scenery, objects and (for Knight Lore) collectables. Hosted by
  `room_view.js` and `room_view.html`. The same page runs in a browser, served
  by `room_designer.py`.
- **The templates editor** opens `templates.json`. It edits the pieces of each
  template and shows the template on its own, on a room's floor, or in a room
  that places it. Hosted by `templates_view.js` and `templates_view.html`.
- **The graphic map** opens `graphics.json`: which sprite each graphic number
  draws, and its box, from the game's own sheet or the others it lists under
  `"sheets"` (Lightkeep's Melkhior's Mansion sheets). Hosted by
  `graphic_map_view.js` and `graphic_map_view.html`.
- **The sprite sheet editor** opens a sheet's description --
  `metadata/sprites.json`, or one of Lightkeep's `metadata/melkhior/*.json` --
  and paints the picture it names, pixel by pixel. Hosted by
  `sprite_sheet_view.js` and `sprite_sheet_view.html`.
- **Schemas** under `schemas/` cover every JSON file a remake is built from,
  so editing one as text gives completion and checking.

A game keeps its JSON in `metadata/` and its sprite sheet in `art/` (the
layout `examples/filmation/scripts/layout.py` describes), and the files name
each other relative to themselves: `rooms.json` names its picture
`../art/sprites.png`. Neither host follows a path out of the game's folder. A
folder with no `metadata/` in it is taken as flat, its JSON at the top, and
opens the same way -- that is how game-disassemblies' room editor hands over a
castle. `game_layout.js` has the rule.

What a castle is and how it looks are in files that don't import `vscode`:
`room_model.js`, `room_render.js`, `sheet_model.js`, `specials_model.js`,
`graphic_map_model.js`, `template_refs.js`, `behaviours.js`, `game_layout.js`, `sheet_files.js`,
`sprite_sheet_model.js`, `sprite_sheet_document.js` and `png_codec.js`. They are
tested from plain Node, one file per topic, in `tests/`:

```powershell
node examples\filmation\vscode\tests\room_model_test.js
.venv-win\Scripts\python.exe examples\filmation\vscode\tests\schemas_test.py
```

There is no build step and there are no dependencies. To install it, link the
folder into VS Code's extensions folder, then run **Developer: Reload Window**:

```powershell
$dest = "$env:USERPROFILE\.vscode\extensions\jonsole.filmation-designer-0.0.1"
New-Item -ItemType Junction -Path $dest -Target (Resolve-Path .\examples\filmation\vscode)
```

The full description is in [room-designer.md](../room-designer.md).
