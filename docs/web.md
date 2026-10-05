# The emulator in a browser

Part of the [zx-spectrum-emulator README](../README.md).

`web/` is the emulator as a web page: the C++ core compiled to WebAssembly
with Emscripten, a page around it, and a workflow that publishes it to GitHub
Pages. It runs whatever 48K or 128K `.z80` or `.sna` a visitor opens.

Once Pages is on it is at **https://jonsole.github.io/zx-spectrum-emulator/**.

## What it hosts

The emulator and the ROMs, and nothing to run on them. A visitor opens a
snapshot from their own disk; it is read in the page and never uploaded. The
page keeps the last one opened in that browser's `localStorage`, so it's back
on the next visit. A Filmation game runs as its `build.py` writes it
(`knightlore/output/knightlore.z80`, say) -- the page runs snapshots, it does
not build them.

The ROMs are hosted. Amstrad allow their distribution, which is why the
release bundles them. The workflow fetches them with `scripts/fetch_roms.py`
for each build, so the repository still never holds them.

## What it is

| File | What |
|---|---|
| `web/zx_web.cpp` | A handful of C functions over a `Spectrum`: load a ROM or a snapshot, run a frame, the screen, the samples, keys |
| `web/main.js` | The page's script: runs frames against the clock, draws them, plays the samples, maps the PC keyboard |
| `web/index.html`, `web/style.css` | The page, and how the PC keyboard maps onto the Spectrum's |
| `web/build.py` | Compiles the core and copies the page into `web/site/` (gitignored) |
| `web/tests/smoke_test.js` | Runs the built module from Node: the ROMs, a 48K and a 128K `.z80` and a `.sna`, a second of frames each |
| `.github/workflows/pages.yml` | Builds the site on a push to `master` that touches it or the core, and deploys it |

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
workflow runs it before deploying anything. Then open http://localhost:8000. A page opened from `file://` won't work:
the browser won't fetch the `.wasm` or the ROMs from one.

To publish, turn Pages on in the repository's **Settings > Pages**, with
**GitHub Actions** as the source. The workflow then deploys on the next
push to `master` that touches `web/` or the core, or when it's run by hand.

## Not done

- **No Kempston joystick.** The core doesn't emulate one, so a game set to
  Kempston reads nothing. Keyboard and cursor (the arrow keys) work.
- **No tapes**, only snapshots. The core can play them, but the page has no
  transport for them.
- **No touch controls**, so it can't be played on a phone or tablet
  without a keyboard.
- **None of the debugger.** No breakpoints, no stepping backwards, no
  profiler. That's what VS Code is for.
