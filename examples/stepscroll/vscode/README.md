# Stepscroll Designer

Editors for `examples/stepscroll/world/` (issue #25), as a VS Code extension and as standalone HTML pages.
The extension doesn't depend on the emulator's own extension. It is installed the same way as the
Filmation designer is, by linking this folder into `%USERPROFILE%\.vscode\extensions`:

```powershell
New-Item -ItemType Junction -Path "$env:USERPROFILE\.vscode\extensions\jonsole.stepscroll-designer-0.0.1" `
         -Target examples\stepscroll\vscode
```

After that, run **Developer: Reload Window**.

## Graphics (`steps.json`)

These are the final graphics: exactly what the game draws, byte for byte. Each tile's entries in `tiles.json`
name a graphic and say where it goes (byte column and bottom line). The build draws each one as it is, adding
no margins, spare bytes or patches.

They started as what the build used to make from Cyberun's steps, which is why a step has several graphics. For
example, `floor-1-top` is a floor step with 2 margin rows above, and `floor-2-side` is the byte after a flat
run. So `floor-up-gentle-1-top-bottom` is 24×12: the 16×8 step, the checker byte its pixels shift into, and 2
rows above and below. To change the movement speed, for instance, give the graphics the margins and spare bytes
the new speed needs.

A graphic is 1 to 3 bytes wide and an even number of rows from 2 to 16, which is what the blitters draw. A
tile is only its entries. The sky and rock between and under the graphics come from the graphics themselves:
going down each column, below a graphic is whatever its bottom row shows, rock checker or sky.

Each graphic is pre-shifted at build time to fine positions 0, 2, 4 and 6, moving right by that many pixels.
What comes in on the left is the graphic's `shiftIn` strip, 6 pixels per row: the last 2, 4 or all 6 of them.
The editor shows the strip in amber to the left of the graphic, where it can be painted, and the 4 versions
below. The strips started as what the world had just left of each graphic. Where a graphic had different strips
in different places, it was split into numbered copies (for example `floor-1-top-bottom-2`).

The editor opens `steps.json` in VS Code, or use **Stepscroll: Open Step Graphics**.

| Task | How |
|---|---|
| New group | **New group**, then give it a name. |
| Rename or delete a group | Its **Rename** or **✕** button. A group can only be deleted once it's empty. Groups only organise: the tiles name graphics. |
| New graphic | A group's **+**, or **New** to add one to the selected graphic's group. |
| Copy, rename or delete a graphic | **Duplicate**, **Rename** or **Delete**. |
| Resize | **Width** and **Height** grow or cut the bitmap at the right and the bottom. |
| Paint | Click a pixel to toggle it; drag to paint more the same. |
| Rearrange or regroup | Drag a graphic in the list, before another or onto another group. |

Renaming a graphic updates the entries in `tiles.json`. Deleting a graphic is refused while an entry uses it.

## Standalone

```powershell
.venv-win\Scripts\python.exe examples\stepscroll\vscode\standalone.py   # output\steps_editor.html
```

This writes a single HTML file.

- In Chrome or Edge, **Open world folder** on `examples/stepscroll/world/`, and Save writes back into it.
- In other browsers, **Open files** takes the JSON files, and Save downloads what changed.

## Files

| File | What |
|---|---|
| `world_model.js` | world.py in JavaScript, pixel for pixel |
| `steps_model.js` | steps.json and tiles.json read and written in their own layouts, and the edits |
| `steps_view.html` | The editor's page, the same in VS Code and standalone |
| `steps_view.js` | Its VS Code host: a custom text editor on steps.json that also edits tiles.json on a rename |
| `standalone_host.js` | The host a page has in a plain browser |
| `pages.js`, `standalone.py` | Put a page together with its scripts inlined |

`tests/` runs from plain Node, for example `node examples\stepscroll\vscode\tests\steps_model_test.js`. Some tests
compare against world.py and build.py through the repo's venv, and they skip when it isn't there.

Still to come: the map and tiles editor.
