# Designing a tape

A tape is designed in two JSON files, each with its own editor in VS Code and
its own schema, the way a Filmation castle is `rooms.json` and `templates.json`:

- **`game.tape.json`** -- what goes on the tape and how it loads: the **loading
  scheme**, the **blocks** it loads (keyed by name, in tape order) and where each
  goes, the address to **jump** to when they have, where the **stack** is, and,
  for a loader that can move, where it runs;
- **`game.screen.json`** -- its **loading screen**: the picture, and the order its
  rectangles are sent in.

Each is a document of its own, so each editor's undo, dirty mark and Save are
VS Code's, and the plain text editor validates both against their schemas.
`scripts/build_tape.py` builds the pair into a tape.

## Loading schemes

| Scheme | What it is | Screen | Builds |
|---|---|---|---|
| `zx-tape-loader` | The fast loader in `examples/zx-tape-loader`: a BASIC bootstrap at normal speed, then its own denser encoding with a countdown in the corner | revealed in the designed order | `.tzx` (its fast part a generalized data block), or a `.wav`/`.csw` of the waveform |
| `rom` | The Spectrum's own `LOAD ""`: a BASIC loader, the screen with `LOAD ""SCREEN$`, each block with `LOAD ""CODE`, at normal speed | whole, in the ROM's own order | `.tap` (loads at once in any emulator), `.tzx`, `.wav` or `.csw` |

The `rom` scheme's BASIC is what someone would type:

```
10 CLEAR stack: POKE 23739,111: LOAD ""SCREEN$: LOAD ""CODE: ...: RANDOMIZE USR entry
```

`POKE 23739,111` points the print channel at a `RET`, so the ROM's "Bytes:"
messages don't print over the picture as each block is found; `CLEAR` puts
RAMTOP, and the stack under it, at the tape's stack address, or just below the
lowest block when it has none.

A scheme says what it can do -- whether a screen has an order to design,
whether the loader has an address of its own -- and has its own checks, costs
and builder. Adding one is a new entry in `tape_model.js`'s `SCHEMES` with its
checks and timing, and a builder in `scripts/build_tape.py`.

## Making one

Right-click a `.scr`, `.sna`, `.z80`, `.tap` or `.tzx` in the Explorer and choose
**Design Tape...**, or run it from the Command Palette. `name.tape.json` and
`name.screen.json` appear beside it, and the tape opens:

- from a **picture**, its screen is that picture, in the order `convert_tape.py`
  would pick by itself -- top to bottom, skipping blank rows;
- from a **standard tape**, it also takes the tape's CODE files as blocks, each
  pointing straight into the tape, named after the tape's own file names, and the
  entry address its BASIC loader's `USR` gives -- so it can be built at once. A
  tape with its own turbo loader has nothing standard to take apart.

A new tape uses the `zx-tape-loader` scheme; the tape's page switches it.

## The tape's page

Opening a `.tape.json` shows the picture as it will look once loaded, and beside it:

- **Build & Run** saves the tape and its screen, builds it, and loads it into the
  emulator: a `rom` tape's `.tap` loads at once; a `zx-tape-loader` tape plays at
  tape speed, which is the point. **Build** only builds it. Either runs
  `build_tape.py` as a task, so its output is in the terminal panel. It needs
  Python 3 (and numpy for the fast loader). In this repository the builder is
  `scripts/build_tape.py`; an installed release carries its own copy, with the
  fast loader beside it, and fetches sjasmplus the first time a moved loader
  needs assembling.
- **Loading scheme** -- which one, and what it means.
- **Loading screen** -- the screen file, its picture, its rectangles and their
  time. **Design screen...** opens the designer (below); **Picture...** chooses
  another picture, keeping the order already drawn, or makes the screen file if
  there is none.
- **Blocks**, in tape order, each with its address (type over it to move it), its
  name and file, its size and its time. **Add file...** loads any file at an
  address you give it, under a name you give it; **Import tape...** adds a
  standard tape's CODE files, its screen if the tape has none, and its `USR`
  address if there is no entry yet.
- **Start** -- where to jump once everything has loaded; the **stack**, the
  address the BASIC loader `CLEAR`s (below); and for `zx-tape-loader`, where its
  433-byte loader runs, anywhere in `$8000-$FFFF` (below `$8000` the ULA's
  contention would stretch its cycle-counted bit loop). Left empty it sits at the
  top of RAM, `$FE4E`; moving it frees that for data.
- **Memory** -- the 64K as the tape leaves it, with anything a block would load
  over that must survive the load marked in red. Hover it for addresses.
- **Checks** -- everything that would stop the tape loading, and what is only
  worth knowing, in the builder's own words (below).

## The loading-screen designer

**Design screen...** opens the `.screen.json` in its own editor, in a window of
its own. It shows the picture with every rectangle outlined and numbered in
order, and the order as a list with each rectangle's time.

- **Drag on the picture** to add a rectangle; it goes on the end of the order.
- **Drag a rectangle** to move it; hold **Alt** to draw a new one over another.
- **Click** a rectangle or a row to select it. Arrow keys nudge it, Shift with
  them resizes it, `[` and `]` move it earlier or later, and Delete takes it out.
- **Drag a row** to reorder it.
- **Fill from picture** replaces the order with the automatic one.
- **Play** runs the load at tape speed (or a quarter to four times it), and the
  slider scrubs to any moment in it.
- **Picture...** chooses another picture, keeping the order.
- **Copy as Python** puts the order on the clipboard as `gen_block()` calls, for a
  hand-written build script like `build_lunarjetman_tape.py`.

Unloaded bytes read as zero and unloaded attributes as black on black, which is
what the machine really shows: a cell whose pixels arrive before its colours is
invisible until they land -- which is why each rectangle sends a character row's
attributes before its pixels.

Along the bottom: the screen's time, bytes and runs, then **cells that are never
loaded** -- artwork no rectangle covers (Lunar Jetman's own hand-written order
has three, in column 31) -- and **bytes sent twice**, where one rectangle covers
ground another already did: the price of a deliberate reveal, like a narrow box
drawn before a wider pass over the same rows.

The designer edits only the screen file; the tape's page follows it as it
changes, unsaved or not. The order matters only to a scheme that reveals a
screen in pieces: the `rom` scheme loads the picture whole, so its page offers
no designer.

## The stack

Both schemes start with a BASIC loader, and its `CLEAR` decides where the
machine stack is: RAMTOP goes at the address, and the stack grows down from just
under it. The loading happens on that stack, and the program is entered on it
-- `RANDOMIZE USR` leaves SP `$17` below the `CLEAR` address in either scheme --
so it is also where a game starts with its stack, if it doesn't set its own.

- **`zx-tape-loader`** `CLEAR`s `$5F41` unless told otherwise: just above its
  BASIC, where `loader.s` has always put it. SP sits at `$5F2A` while the loader
  runs, and its bit loop calls two deep below that, so `$5F26-$5F29` can't be
  loaded over. A game that loads there -- Pentagram's main block is 31K at
  `$5E00` -- needs the stack moved out of its way: `"stack": "$FE4D"` puts it
  just under the loader at the top of RAM. The loader's calls then reach
  `$FE32-$FE35`, and Pentagram loads and runs. Any address from `$5F41` up that
  keeps the loader's `$1B` bytes of stack clear of the loader itself will do;
  the builder assembles the loader afresh with `-DSTACK_AT=`, the way it does a
  moved loader.
- **`rom`** `CLEAR`s just below the lowest block unless told otherwise. Set, the
  stack can go anywhere above the BASIC loader's own workspace, and blocks keep
  the `$40` bytes under it clear: loading reaches `$11` below it and the program
  is entered `$17` below it (both measured on the emulator), and the rest is
  for the interrupts BASIC takes between loads.

A failed fast load returns to BASIC along the stack it came by, so a block over
BASIC's part of the stack, or over the BASIC loader itself, is worth a warning:
the tape still loads, but after a tape error there is no BASIC left to return
to.

## The checks

Every scheme refuses a block that starts in the ROM, runs past `$FFFF`, is
empty, or whose file can't be read, and a tape with no entry address; it warns
of a block over the loading screen, a block over part of an earlier one, and an
entry outside every block.

- **`zx-tape-loader`** also refuses a loader outside `$8000-$FFFF`, a stack below
  `$5F41` or one that runs into the loader, and a block over the loader itself
  or over the four bytes of stack its calls use (`$5F26-$5F29` by default); it
  warns of a block over BASIC's stack above that, or over the BASIC loader.
- **`rom`** refuses a block below the BASIC loader, its variables and the stack
  `CLEAR` leaves under the lowest block -- `$5CCB`, the program's length, and
  `$100` more -- and, with a stack set, a stack below that or a block over the
  `$40` bytes under it.

**Build** is refused while any error stands, on the page and in the builder.

## Building

```sh
.venv-win\Scripts\python.exe scripts\build_tape.py game.tape.json               # the scheme's own default: .tap for rom, .tzx for the fast loader
.venv-win\Scripts\python.exe scripts\build_tape.py game.tape.json game.wav      # the waveform, to play into a real Spectrum
.venv-win\Scripts\python.exe scripts\build_tape.py game.tape.json game.csw      # exact pulses, for an emulator
.venv-win\Scripts\python.exe scripts\build_tape.py game.tape.json --flutter     # a .wav with a cassette's wow and flutter
.venv-win\Scripts\python.exe scripts\build_tape.py game.tape.json --sjasmplus tools\sjasmplus\sjasmplus.exe  # a moved loader or stack
```

A `zx-tape-loader` tape is a `.tzx` by default, because its encoding can be
written down exactly rather than recorded: the BASIC bootstrap is
standard-speed blocks and the fast part is one **generalized data block**
(`0x19`), which spells out the loader's own alphabet -- a 1 bit is one pulse,
a 0 bit two half-length ones -- and then sends the bits packed. Pentagram's
tape is 41KB that way, 600KB as a `.csw` and 30MB as a `.wav`. Build a `.wav`
to play into a real Spectrum, with `--flutter` for a cassette's wow and
flutter; a `.csw` is the exact pulses for an emulator that won't read `0x19`.

`build_tape.py` reads both files and turns everything they name into bytes;
`scripts/tape_screen.py` finds the loading screen in whatever the picture is,
exactly as the designer does. A `rom` tape is written by `scripts/tape_rom.py`
and needs nothing beyond Python. A `zx-tape-loader` tape is encoded by the
submodule's `loader.py` (which needs numpy), and a moved loader or stack is
assembled afresh from `loader.s` with `-DLOADER_AT=` and `-DSTACK_AT=` in a
scratch folder, leaving the committed `loader.tap` alone. Audio of a `rom` tape ends with a few pulses after
the last block: an emulator reading a recording, and a real ULA, can lose the
last bit's final edge into the silence otherwise.

The extension runs it with the repository's venv and `tools/sjasmplus`; the
settings `zxspectrum.tapeDesigner.builder`, `.python` and `.sjasmplus` say
otherwise. `convert_tape.py --pattern game.screen.json` in the submodule takes
just a screen's order, for converting a whole standard tape the old way.

## The files

```json
{
  "meta": {"version": 1},
  "scheme": "zx-tape-loader",
  "loaderAddress": "$9000",
  "loadingScreen": "lunarjetman.screen.json",
  "blocks": {
    "relocator": { "file": "jetman.bin", "address": "$7000" },
    "level": { "file": "game.tap", "address": "$A000", "offset": 7235, "length": 4000 }
  },
  "entry": "$7000",
  "stack": "$FE4D"
}
```

```json
{
  "meta": {"version": 1},
  "picture": "LunarJetman.scr",
  "order": [
    { "x": 11, "y": 0, "w": 10, "h": 2 },
    { "x": 0, "y": 8, "w": 32, "h": 8 }
  ]
}
```

Paths are relative to the file that names them, and everything is a reference
rather than a copy: rebuild the artwork or the code and the design shows the new
bytes -- both editors watch the files. A block is named by its key; without a
`length` it is the rest of its file from its `offset`. Addresses read as
`$7000`, `#7000`, `0x7000` or `28672`. `stack` is the `CLEAR` address, `null`
for the scheme's own; `loaderAddress` belongs to `zx-tape-loader` alone, `null`
for the top of RAM; and an `output` names what to build. One block and one rectangle per line, so a diff reads as the tape
changing. `vscode-extension/schemas/tape.schema.json` and `screen.schema.json`
say all of this to the text editor.

`vscode-extension/tests/tape_model_test.js` holds the designer's costs, checks
and the `rom` scheme's `.tap` to what the Python really does -- byte for byte and
word for word -- and `tape_page_test.js` and `screen_page_test.js` run both pages
as the extension assembles them.
