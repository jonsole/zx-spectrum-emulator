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
  about 2,400 T-states, before a vertex is touched. `check.py` holds every
  routine to a Python model in SkoolKit's simulator, every multiply and every
  pixel. The launch configuration **ZX Spectrum: fast3d demo** flies a camera
  through forty turning objects on the 128K. See
  [examples/fast3d/README.md](examples/fast3d/README.md).

- **A Revs road engine, `examples/revs`.** Geoff Crammond's BBC Micro *Revs*
  rebuilt for the 48K in Z80, using the documented disassembly at
  revs.bbcelite.com as its design: so far, Silverstone's track seen from a
  camera that drives itself round it, at 16.7 frames a second. Its
  launch configuration is **ZX Spectrum: Revs road**; the track data is
  fetched at build time, never committed. `examples/revs/tests/run_tests.py`
  checks it against Python models of its maths, geometry and screen, its
  timing against the beam, and its speed, through a new cpp-core tool,
  `snapshot_probe`, that drives a snapshot from a script. See
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
