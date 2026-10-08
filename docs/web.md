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

It needs no assembler in the browser, because of what the repository
already carries. Of everything the remake is built from, the sprite sheet,
the rooms, the templates and the collectables are all in the tree, and the
font is the one thing `extract.py` still has to take from an original. It is
copied byte for byte: `kl_extract.py` takes `$6108`-`$6247` out of the
game's RAM, and the build writes the same 320 bytes back at the label
`font`. So the workflow builds the remake with a blank font
(`web/knightlore_template.py`), and the page reads the font out of the
visitor's copy, checks its SHA-256 against `knightlore/original.json`, and
puts it in.

That the font is the only difference is checked, not assumed: the template
script builds the game twice, with a blank font and a patterned one, and
stops unless the two images differ only at `font`.
`web/tests/knightlore_test.js` then checks the page's `.z80` for the
patterned font against the one `build.py` wrote, and its reading of every
form of 48K snapshot against `examples/filmation/original.py`'s.

The site holds no more of Ultimate's than the repository does: the remake's
sprites and rooms are the carried files, and the font comes only from the
visitor's copy.

## What it is

| File | What |
|---|---|
| `web/zx_web.cpp` | A handful of C functions over a `Spectrum`: load a ROM or a snapshot, run a frame, the screen, the samples, keys |
| `web/main.js` | The page's script: runs frames against the clock, draws them, plays the samples, maps the PC keyboard |
| `web/index.html`, `web/style.css` | The page, and how the PC keyboard maps onto the Spectrum's |
| `web/build.py` | Compiles the core and copies the pages into `web/site/` (gitignored) |
| `web/knightlore.html`, `web/knightlore.js` | The Knight Lore page: takes the visitor's copy, offers the remake |
| `web/remake.js` | What it makes the remake with: reads a 48K snapshot, checks the font, fills the template, writes the `.z80` |
| `web/knightlore_template.py` | Builds the remake with a blank font into `web/site/knightlore/`, checking that the font is all that differs |
| `web/tests/knightlore_test.js` | The page's `.z80` against `build.py`'s, and its snapshot reading against `original.py`'s |
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
  more from its original than a font, so it would need more than a
  template with a hole in it.
- **None of the debugger.** No breakpoints, no stepping backwards, no
  profiler. That's what VS Code is for.
