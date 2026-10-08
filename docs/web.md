# The emulator in a browser

Part of the [zx-spectrum-emulator README](../README.md).

`web/` is the emulator as a web page: the C++ core compiled to WebAssembly
with Emscripten, a page around it, and a workflow that publishes it to GitHub
Pages. It runs whatever 48K or 128K `.z80` or `.sna` a visitor opens, and
beside it `knightlore.html` makes the Filmation Knight Lore from a visitor's
own copy of the original, to download or to play.

Once Pages is on it is at **https://jonsole.github.io/zx-spectrum-emulator/**.

## What it hosts

The emulator, the ROMs and the Knight Lore remake without its font. A
visitor opens a snapshot from their own disk; it is read in the page and
never uploaded. The page keeps the last one opened in that browser's
`localStorage`, so it's back on the next visit. A Filmation game runs as its
`build.py` writes it (`knightlore/output/knightlore.z80`, say).

The ROMs are hosted. Amstrad allow their distribution, which is why the
release bundles them. The workflow fetches them with `scripts/fetch_roms.py`
for each build, so the repository still never holds them.

## Knight Lore from your own copy

`knightlore.html` takes a 48K `.z80` or `.sna` of the original Knight Lore
and gives back the `knightlore.z80` that
`examples/filmation/knightlore/build.py` would write -- byte for byte -- to
download, or to play: **Play it** puts it where the emulator page keeps its
last snapshot and opens that page.

The site has the remake with everything of Ultimate's left out -- the font,
the sprites, the "DAY" lettering, the castle and the collectables -- and the
page takes them from the visitor's copy. It needs no assembler, because
none of them changes the layout of the image, only bytes within it:

- **The font** is copied byte for byte: `kl_extract.py` takes
  `$6108`-`$6247` out of the game, and the build writes the same 320 bytes
  back at the label `font`.
- **The sprites** are the game's records from `$728C`, which `kl_extract.py`
  walks, turning back the ones the game has mirrored. Every row the build
  emits is one of a record's rows: stored bottom row first and emitted top
  row first, with the blank rows at the bottom trimmed off
  (`sprite_sheet.py`) and the mask inverted (`sprite_source.py`). The image
  keeps each sprite's size; the rows are the page's to write. Which record
  is which sprite comes from the copy's own graphic table at `$7112`: the
  site says only, for each sprite on the sheet, a graphic number that draws
  it, where its rows go, and its size.
- **The "DAY"** over the day count is four characters `panel_data.s` copies
  from the game's `day_font` at `$BCEC`; the page copies the same 32 bytes.
- **The castle** is not copied but re-encoded. `rooms.py` decodes the game's
  room tables (`$6248`-`$6FF1`) into `rooms.json` and `templates.json`, and
  `rooms_source.py` writes them out again in the remake's own layout as
  `room_data.s`: the room records with a scenery count where the game has
  an `$FF`, the flags in the engine's `OBJ.FLAGS` layout -- including which
  graphics some room wants both ways round and so draws from a private copy,
  worked out over the whole castle -- the two templates no room places left
  out, and the tables pointing at the rest. `remake.js` does all of that
  from the copy's tables, to the same bytes; the site gives it only what the
  remake decides for itself (the flag a template's name adds, and the
  encoder's constants).
- **The collectables** are four bytes of each of the 32 rows at `$6FF2` and
  the wizard's list at `$C27D`, copied as they are.

The page checks the font against `knightlore/original.json`'s hash, and
everything else against hashes of what the build puts in the image -- the
castle along with the three counts the code is sized by. It does not check `sprite_data.bin`'s hash, as `extract.py` does:
that covers bits of every record the build never reads -- the flags in a
sprite's width byte, which the game leaves set or not depending on when the
copy was saved -- and a copy saved at the menu fails it although it makes the
very same game. So does a copy with the menu frame's corner upside down,
which the game does to it in place as it draws the frame, recording it
nowhere; the page tries that sprite both ways up.

The page can only make what an original has, so the template script stops
when any of the carried files -- the sprite sheet, the castle, the
collectables -- has been edited away from `original.json`'s carried hashes:
an edited one would have the page turn every copy away. Edit the castle in
the room designer and the site stops deploying until it is put back.

None of this is assumed. `web/knightlore_template.py` builds the game four
times -- the template, with a blank font and the carried files; with a
patterned font; with the sheet's ink and paper swapped; and with every
position in the castle and of the collectables moved -- and stops unless
each changes only what the page fills in, and unless every sprite's rows are
where the page will write them, as it will write them. It then makes a test
original out of the carried files -- its sprites in another order and two of
them mirrored, its room templates laid out in another order than the
game's -- and runs the real `kl_extract.py`, `rooms.py` and
`sprite_sheet.py` on it: they must give back the carried sprite sheet,
castle and collectables.
`web/tests/knightlore_test.js` gives the page that original, in every form of
48K snapshot (read as `examples/filmation/original.py` reads them, checked
against it), and the page has to make the `.z80` `build.py` made, byte for
byte.

The remake's encoding of the castle is therefore written twice, in
`rooms_source.py` and in `remake.js`. The test is what keeps them together:
a change to one that the other does not follow fails it, and the site does
not deploy.

Checked with a real copy of Knight Lore, saved at the menu: the page's
`.z80` is byte for byte the one `build.py` makes from it.

## What it is

| File | What |
|---|---|
| `web/zx_web.cpp` | A handful of C functions over a `Spectrum`: load a ROM or a snapshot, run a frame, the screen, the samples, keys |
| `web/main.js` | The page's script: runs frames against the clock, draws them, plays the samples, maps the PC keyboard |
| `web/index.html`, `web/style.css` | The page, and how the PC keyboard maps onto the Spectrum's |
| `web/build.py` | Compiles the core and copies the pages into `web/site/` (gitignored) |
| `web/knightlore.html`, `web/knightlore.js` | The Knight Lore page: takes the visitor's copy, offers the remake |
| `web/remake.js` | What it makes the remake with: reads a 48K snapshot, takes and checks the font and sprites, fills the template, writes the `.z80` |
| `web/knightlore_template.py` | Builds the remake with its font and sprite rows blank into `web/site/knightlore/`, checking that those are all that differ, and makes the test original |
| `web/tests/knightlore_test.js` | The page given the test original, against `build.py`'s `.z80`; its snapshot reading against `original.py`'s |
| `web/tests/smoke_test.js` | Runs the built module from Node: the ROMs, a 48K and a 128K `.z80` and a `.sna`, a second of frames each |
| `.github/workflows/pages.yml` | Builds and tests the site on a pull request, and on a push to `master` deploys it too |

`zx_web.cpp` drives the `Spectrum` itself rather than through the Engine.
The Engine exists to share one machine between a run thread and the protocol
servers. A page has one thread and no servers, so the queue would be all
cost. For the same reason the core is built with `ZX_REWIND=0`, and without
the Engine, the servers or the video recorder.

The page runs frames against `performance.now()`, not one per animation
frame. That keeps a 48K at 50.08 Hz on a 60 Hz or 144 Hz display. Each
frame's samples are queued on a Web Audio clock a little ahead of time, and
dropped if more than a quarter of a second has built up. A key tapped faster
than a frame is held for three frames, because a program reads the keyboard
once an interrupt and would never see the tap otherwise.

The module gets a 1 MB stack, not Emscripten's default 64 KB. `load_z80`
keeps all eight 128K banks on the stack while it decodes them, and on 64 KB
every `.z80` overflowed it. The first site did that, and crashed the tab on
any `.z80` it was given.

## Building it

Needs [Emscripten](https://emscripten.org/docs/getting_started/downloads.html)
(the workflow pins the version, in `EMSDK_VERSION`):

```sh
python scripts/fetch_roms.py --dest roms
source path/to/emsdk/emsdk_env.sh
python web/build.py --roms roms
node web/tests/smoke_test.js
python -m http.server -d web/site
```

The smoke test runs the module the page loads, without the page. The
workflow runs it before deploying anything. Then open http://localhost:8000.
A page opened from `file://` won't work: the browser won't fetch the
`.wasm` or the ROMs from one.

The Knight Lore page needs the remake built into the same site, which takes
sjasmplus (as `build.py` finds it) and Pillow:

```sh
python web/knightlore_template.py --out web/site --reference knightlore-test
node web/tests/knightlore_test.js web/site knightlore-test
```

sjasmplus has no Linux release; the workflow builds the version
`scripts/fetch_sjasmplus.py` fetches for Windows from its source.

To publish, turn Pages on in the repository's **Settings > Pages**, with
**GitHub Actions** as the source. The workflow then deploys on the next
push to `master` that touches `web/`, the core or `examples/filmation/`, or
when it's run by hand.

## Not done

- **No Kempston joystick.** The core doesn't emulate one, so a game set to
  Kempston reads nothing. Keyboard and cursor (the arrow keys) work.
- **No tapes**, only snapshots. The core can play them, but the page has no
  transport for them.
- **No touch controls**, so it can't be played on a phone or tablet
  without a keyboard.
- **Only Knight Lore** is made from an original. Pentagram's build takes
  its quest and sound data from its original as well as its font and
  sprites, and nothing here does those.
- **`extract.py` still refuses some genuine copies**: one saved at the menu
  with the frame's corner upside down, or with different flag bits in its
  sprites' width bytes, fails its `sprite_data.bin` hash. The page takes
  them.
- **None of the debugger.** No breakpoints, no stepping backwards, no
  profiler. That's what VS Code is for.
