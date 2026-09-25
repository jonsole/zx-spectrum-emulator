# Pentagram on the Filmation engine

A VS Code workspace holding a remake of Ultimate's *Pentagram* (1986), written
in Z80 assembly on a Filmation engine of its own, to build, run, step through
and change on the emulator in the **ZX Spectrum Debug** extension.

The remake's code is here. The game's artwork and tables -- its sprites, its
font, its rooms -- are Ultimate's, and are not: you make them from **your own
copy of the original**, once, and the workspace checks they came out right.

## Before you start

- **ZX Spectrum Debug** (`zxspectrum-debug-<version>-win32-x64.vsix`) from the
  [releases page](https://github.com/jonsole/zx-spectrum-emulator/releases),
  installed with **Extensions: Install from VSIX...** -- the emulator, the ROMs
  and the debugger.
- **Python 3** on the PATH, with **Pillow**: `pip install pillow`.
- **Your own copy of Pentagram**: its tape -- .tzx or .tap -- or a snapshot, .sna or .z80, taken at the menu before a game is started.
- Optional: the **Filmation Designer** (`filmation-designer-<version>.vsix`, same
  page) -- editors for the rooms, their templates and the graphic map.

## First: extract the game from your copy

Open this folder in VS Code (**File > Open Folder...**, the folder this README
is in). Put your copy in it, then run **Terminal > Run Task... > Extract
Pentagram** and press Enter at the prompt (or type the path to a copy
elsewhere).

It pulls the artwork and tables out of your copy, turns them into the files
the build reads (`sprites.png`, `sprites.json`, `rooms.json`, ...), and checks
each against the hashes a right copy gives. A copy that differs -- another
release, a crack, a snapshot taken mid-game -- is refused with the reason, and
nothing of it is kept. The tape is the best source; a snapshot works as long as no game has been played in it.

## Running it

**Run > Start Debugging** (F5) builds the game and runs it. Click the **ZX
Spectrum Screen** panel and play from the keyboard:
`examples/filmation/pentagram/driving.md` has the keys. Pause (F6) to stop
wherever it is and step in the source, or set a breakpoint in any `.s` file
under `examples/filmation/`.

## Changing it

Edit any `.s` file and launch again: the build runs first and only redoes what
changed (**Ctrl+Shift+B** builds without launching). The assembler, sjasmplus,
is fetched by the extension the first time, or one on the PATH is used. Errors
land in the Problems panel.

The extracted files are yours to edit too: `sprites.png` is the artwork,
`rooms.json` the world. With the Filmation Designer installed, opening
`rooms.json`, `templates.json` or `graphics.json` under
`examples/filmation/pentagram/` opens its editor --
`examples/filmation/room-designer.md` explains them.

## What is here

| | |
|---|---|
| `examples/filmation/engine/` | The Filmation engine, shared with the Knight Lore remake |
| `examples/filmation/pentagram/` | The game's code, `build.py`, and `graphics.json` -- which sprite each graphic number draws and the nudge that places it, the remake's own |
| `examples/filmation/extract.py`, `original.py` | The extraction from your copy |
| `examples/filmation/pentagram/original.json` | The hashes a right copy gives -- hashes only, nothing of the game |
| `examples/filmation/*.py`, `tools/` | What the build uses to turn the data into source |
| `examples/filmation/README.md` | How the engine works |

The layout is the repository's own
([examples/filmation](https://github.com/jonsole/zx-spectrum-emulator/tree/master/examples/filmation)),
which is what the designer's editors and the documentation's paths expect. The
engine and the remake's code are MIT-licensed; *Pentagram* itself is copyright
Ultimate Play the Game. See `THIRD_PARTY_NOTICES.md`.
