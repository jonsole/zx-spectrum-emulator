# Stepscroll Designer

Editors for `examples/stepscroll/world/` (issue #25), as a VS Code extension and as standalone HTML pages.
The extension doesn't depend on the emulator's own extension. It is installed the same way as the
Filmation designer is, by linking this folder into `%USERPROFILE%\.vscode\extensions`:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.vscode\extensions\jonsole.stepscroll-designer-0.0.1" `
         -Target examples\stepscroll\vscode
```

After that, run **Developer: Reload Window**.

## Tiles (`tiles.json`)

These are the final tiles: exactly what the game draws, byte for byte. Each block's entries in `blocks.json`
name a tile and say where it goes (byte column and bottom line). The build draws each one as it is, adding
no margins, spare bytes or patches.

The tiles are plain, straight-edged graphics: sky, rock checker, and a 2-pixel solid line where rock meets sky.
Each block's tiles are cut from its picture wherever a 2-pixel move changes something, and they never overlap.
A cut includes the margin rows and spare bytes a move needs, so to change the movement speed, for instance,
you'd give the tiles the margins and spare bytes the new speed needs. Tiles are grouped by the ground they
come from (`floor`, `floor-up-gentle`, `wall-rock-left`, ...). The `simple-*` groups are cut from the
`simple_up` and `simple_down` blocks, which run through every gradient: flat, 1:1, 1:2, 2:1, 1:3, 3:1 and
walls. `../make_simple.py` makes those two blocks from a list of ground segments.

A tile is 1 to 3 bytes wide and an even number of rows from 2 to 24, which is what the blitters draw. A
block is only its entries. The sky and rock between and under the tiles come from the tiles themselves:
going down each column, below a tile is whatever its bottom row shows, rock checker or sky.

Each tile is pre-shifted at build time to fine positions 0, 2, 4 and 6, moving right by that many pixels.
What comes in on the left is the tile's `shiftIn` strip, 6 pixels per row: the last 2, 4 or all 6 of them.
The editor shows the strip in amber to the left of the tile, where it can be painted, and the 4 versions
below. Each strip starts as what the world has just left of the tile.

The editor opens `tiles.json` in VS Code, or use **Stepscroll: Open Tiles**.

| Task | How |
|---|---|
| New group | **New group**, then give it a name. |
| Rename or delete a group | Its **Rename** or **✕** button. A group can only be deleted once it's empty. Groups only organise: the blocks name tiles. |
| New tile | A group's **+**, or **New** to add one to the selected tile's group. |
| Copy, rename or delete a tile | **Duplicate**, **Rename** or **Delete**. |
| Resize | **Width** and **Height** grow or cut the bitmap at the right and the bottom. |
| Paint | Click a pixel to toggle it; drag to paint more the same. |
| Rearrange or regroup | Drag a tile in the list, before another or onto another group. |

Renaming a tile updates the entries in `blocks.json`. Deleting a tile is refused while an entry uses it.

## Blocks (`blocks.json`)

A block is its entries: tiles from `tiles.json`, each at a byte column and a bottom line in the 256 × 256
page, drawn in order. In VS Code, `blocks.json` opens in the blocks editor, or use **Stepscroll: Open Blocks**.

| Task | How |
|---|---|
| New, copy, rename or delete a block | The buttons above the block list. A rename updates `map.json`. A block on the map can't be deleted. |
| Place a tile | Pick it on the right, then click on the page to put its top left at the pointer. Escape or the right button stops placing. |
| Move an entry | Drag it, or select it and use the arrow keys (a byte, or 2 lines). Entries snap to byte columns and odd bottom lines. |
| Delete an entry | Select it, then press Delete. |
| Drawing order | The ↑ and ↓ buttons in the entry list. A later entry draws over an earlier one. |
| Edit a tile | Double-click it on the page, in the entry list or among the tiles: the tiles editor opens on it (standalone, in a new tab). |
| See the joins | Around the page, dimmed, are its neighbours on the map. **On the map at** picks which of the block's places to show. |

## Standalone

```powershell
.venv-win\Scripts\python.exe examples\stepscroll\vscode\standalone.py   # output\tiles_editor.html, output\blocks_editor.html
```

This writes one HTML file for each editor.

- In Chrome or Edge, **Open world folder** on `examples/stepscroll/world/`, and Save writes back into it.
- In other browsers, **Open files** takes the JSON files, and Save downloads what changed.

## Files

| File | What |
|---|---|
| `world_model.js` | world.py in JavaScript, pixel for pixel |
| `tiles_model.js` | tiles.json and blocks.json read and written in their own layouts, and the edits |
| `blocks_model.js` | blocks.json and map.json edits: blocks, and entries placed, moved, reordered and removed |
| `tiles_view.html`, `blocks_view.html` | The editors' pages, the same in VS Code and standalone |
| `designer_host.js` | Their VS Code host: a custom text editor on each file, which also edits the file beside it when a rename reaches it |
| `standalone_host.js` | The host a page has in a plain browser |
| `pages.js`, `standalone.py` | Put a page together with its scripts inlined |

`tests/` runs from plain Node, for example `node examples\stepscroll\vscode\tests\tiles_model_test.js`. Some tests
compare against world.py and build.py through the repo's venv, and they skip when it isn't there.

Still to come: the map editor.
