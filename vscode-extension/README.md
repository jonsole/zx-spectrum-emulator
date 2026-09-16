# ZX Spectrum Debug (VS Code extension)

A handful of things, in one small extension:

1. **Registers the `zxspectrum` debugger type** so `launch.json`'s `debugServer` field can connect
   directly to `zx-spectrum-emulator`'s DAP server -- purely declarative for this part, no adapter
   code, since `debugServer` overrides how VS Code connects.
2. **A live screen viewer.** The "ZX Spectrum: Show Screen" command opens a panel that stays live,
   fed by the emulator's screen-stream port (`--screen-port`, default `8500`) -- this is real
   extension code (`extension.js`), the first the project needed, since a webview panel can't be
   created any other way.
3. **A trace viewer and recorder.** The "ZX Spectrum: Show Trace" command opens a `.zxtrace`
   capture (see [docs/tracing.md](../docs/tracing.md)) as a banded table and a timing
   diagram. The page itself is `tools/trace_viewer.html` in the repo, hosted in a webview rather
   than copied here -- the same file opens standalone in a browser. The extension host reads the
   file and posts its text in, and re-posts it whenever the capture is rewritten, so recapturing
   updates the panel in place. Its **Record** button goes the other way, driving the debug
   session's own emulator through `startTrace`/`stopTrace`/`traceStatus` custom requests: those
   bypass the emulator's command queue, so a capture can be started and stopped while a game is
   running, and the finished file loads into the panel by itself. Its **start** and **stop**
   triggers capture a window of code (an address or symbol name, which the server resolves) or a
   window of the video frame (a T-state) rather than only a window of time.
4. **A graphics viewer.** The "ZX Spectrum: Show Graphics" command opens a panel that draws bytes
   the way the ULA would -- as a sprite sheet, a character set, or a screen dump. The bytes come
   from the running machine's memory (by address or symbol, live while it runs), from a file, or
   from a `DEFB` selection in an editor. **+ Add** keeps the sprite being dialled in and frees the
   controls for the next, so one sheet can hold sprites of different sizes, from different files,
   in different formats; a bin button on each removes it. Hovering a pixel names the byte and bit
   holding it. The
   page is `graphics_view.html`, beside `extension.js` rather than in `tools/` like the trace
   viewer: every byte it draws arrives from the extension host, so unlike that one it is no use
   standalone, and it goes where the install already carries it. See
   [docs/vscode-debugging.md](../docs/vscode-debugging.md#graphics-viewer).
5. **A tape pane.** A tree in the debug sidebar, docked with Call Stack and Breakpoints, listing
   what is on the inserted tape block by block. See "Tape pane" below.
6. **An execution profiler.** Where the CPU's time goes, as a heat map on the source, a call tree
   and the worst frames in the debug sidebar. See "Execution profile" below.
7. **Z80 assembly editing.** sjasmplus colouring, Go to Definition, references, rename, call
   hierarchy, hover and the outline, with or without a debug session. See "Z80 assembly" below.

## Settings

Every `settings.json` setting and `launch.json` attribute this extension understands, with
examples, is in [docs/vscode-settings.md](../docs/vscode-settings.md).

## Screen scaling

The magnifier in the screen panel's title bar (**ZX Spectrum: Screen Scaling...**) picks the
filter -- nearest neighbour, sharp bilinear or bilinear -- the size -- fit in whole multiples,
fit, or a fixed 1x-4x -- and how dark the scanline gaps are, from off to black, stored as the
`zxspectrum.screen.filter`, `zxspectrum.screen.scale` and `zxspectrum.screen.scanlines` settings. The panel draws into a canvas sized in device pixels, so the chosen filter is the only
one applied. `screen_scaling.js` (tested by `node tests/screen_scaling_test.js`) does the sizing,
and its functions are inlined into the page as source. See
[docs/vscode-debugging.md](../docs/vscode-debugging.md#scaling-and-filtering).

## Raster position

While the machine is stopped — stepping, or on a breakpoint — the screen panel
shows where the ULA's beam has got to and what it has left to do. Three
Command Palette pairs, all `setRasterView` custom requests, and none of it
ever appears while running:

- **Show / Hide Raster Position** — a dashed line across the raster line, full
  canvas width so the border is included, and a tick at the exact dot. On by
  default; step and it walks down the frame.
- **Show Frame In Progress / Show Last Completed Frame** — compose the picture
  the way a CRT has it at that instant: this frame's drawing down to the beam,
  the previous frame beyond it. On by default, and what makes a border stripe
  appear at the line the `OUT` happened on as you step onto it.
- **Show / Hide Pending Display Writes** — every display byte written since
  the beam last passed it keeps its own colours while the rest of the screen
  is dimmed to half brightness: in memory, but not yet on the picture. The dim
  goes on whether or not anything is pending, so a wholly dimmed screen means
  the beam has already shown everything written. Off by default.

See [docs/vscode-debugging.md](../docs/vscode-debugging.md#raster-position).

## Display writes

The eye button in the screen panel's title bar turns on the display-write
overlay: the picture is dimmed to half brightness, and every byte the program
(or a debugger poke) writes to the screen bitmap is shown at full brightness,
all eight of its pixels in their own colours, on the frame it was written. So
the panel shows what is being *drawn* rather than only what the picture ended
up as. Every write counts, erases and rewrites of an unchanged value included;
attributes are not tracked.

Two palette commands tune it. **"ZX Spectrum: Set Display Write Opacity…"**
trades the default full brightness for a smaller lift out of the dim, and
**"…Set Display Write Fade…"** trades the default clear-every-
frame for a trail of a fifth of a second, of a second, or one that never
fades. Both are `setWriteOverlay` custom requests, and each leaves the other
alone; the state lives in the emulator, so the same overlay shows in
`get_screen` over MCP and in anything else reading the screen stream. Off at
every launch.

## Load Tape

**"ZX Spectrum: Load Tape…"** puts a `.tap`, `.tzx`, `.wav` or `.csw` into a
session that is
already running, over a `loadTape` custom request — the same channel the trace
panel's Record button uses. It resets, types `LOAD ""`, starts the tape and
opens the screen panel, so the load is visible as it happens.

A tape that is always the same is better named in `launch.json` (`tape`, plus
`tapeAutoStart` and `tapeFastLoad`); this command is for reaching for a
different one mid-session.

## Tape pane

**ZX Spectrum Tape** appears in the debug sidebar while a `zxspectrum` session
is running, below Call Stack and Breakpoints. It lists the tape a block at a
time — the headers with their filenames decoded, the data blocks that follow
them, the tone and pause blocks a `.tzx` can carry, and the stretches of signal
an audio recording is cut into at its silences — with the block that is
playing marked, the ones already loaded dimmed, and a clock icon on any block
whose timings are non-standard, which is the answer to "why is this one loading
at real speed".

Expand a row for its `.tzx` block ID, its pause and whether fast load will take
it. Hovering a row gives a **seek** button that positions the tape at that block
with the motor stopped, so *Play* starts the load from there — which is how to
replay one part of a multi-load tape without rewinding through everything in
front of it.

The title bar carries a play/pause button that swaps with the state of the
motor — the way the debug toolbar's Continue and Pause share one slot — then
Rewind, the fast-load toggle, Load tape and Eject. All of it goes over the
`tapeControl` custom request, which bypasses the emulator's command queue, so
every button works mid-load and mid-game — and greys out when there is no
session to send it to.

The pane polls for its position, and only while it is actually visible —
collapse the section and it stops asking.

## Z80 assembly

`.asm`, `.s` and `.a80` files open as **Z80 Assembly** (language id `z80-asm`),
coloured for sjasmplus -- the assembler everything in this repo is built with.
The workspace's `.vscode/settings.json` maps `*.asm` and `*.s` to it as well, so
another installed assembly extension claiming those extensions doesn't win.

On top of the colouring:

- **Go to Definition** (F12 / Ctrl+click) on any label, constant, macro,
  macro parameter, struct, struct field or `DEFINE`. A local label resolves
  under its own parent (`.loop` in `sprite_blit` is `sprite_blit.loop`), and a
  dotted name goes to the part clicked: `OBJ` in `OBJ.FLAGS` is the struct,
  `FLAGS` is the field. On an `INCLUDE`/`INCBIN` path it opens the file.
- **Find All References** (Shift+F12) and **Peek References**.
- **Rename Symbol** (F2) changes the last part of a name wherever that part is
  written: renaming `.loop` rewrites `.loop` inside its routine and
  `sprite_blit.loop` elsewhere; renaming `sprite_blit` rewrites
  `sprite_blit.loop` but leaves the `.loop`s alone, since they don't spell it
  out. A name already taken, a reserved word, or a name defined in more
  than one program is refused. Comments are not touched.
- **Show Call Hierarchy** (Shift+Alt+H) on a routine, or anywhere inside one:
  who `CALL`s, `JP`s, `JR`s or `DJNZ`s to it, grouped by the routine each call
  sits in, and what it calls in turn. Macro invocations count as calls. Jumps
  to a routine's own locals are control flow, not calls, and are left out.
- **Hover** shows the definition line and the comment block above it -- the
  ROM disassembly's routine descriptions, for instance.
- **Outline**, breadcrumbs and **Go to Symbol** (Ctrl+Shift+O), with local
  labels nested under their routine; **Go to Symbol in Workspace** (Ctrl+T).

Every `.asm`/`.s`/`.a80` in the workspace is indexed the first time one of
these is used (about a second for this repo), then kept current from the editor
and from disk. Several programs here share label names, so a name resolves
within the files the current one is `INCLUDE`d together with first, and only
across the whole workspace when it isn't defined there. `MODULE` prefixes are
not modelled. The parser has its own tests, no vscode needed:
`node tests/asm_index_test.js`.

## Execution profile

**Start Profiling** (flame button on the debug toolbar) has the emulator count
every instruction's cost; the open source files are tinted by how hot each
line is -- a `CALL` line including the time its calls took, unless **Tint Lines
By Their Own Code Only** is chosen -- the hottest get `share · T/frame ·
runs/frame` written after them, and **Show Profile Hot Spots** lists the worst routines and lines to jump
to. The **ZX Spectrum Profile** view in the debug sidebar has every routine,
most expensive first, each expanding into the routines it called and what
those calls cost it (`profile_tree.js`), headed by the worst frames (or turns
of a chosen routine) with a strip of busy time; any of them can be painted on
the source on its own. A routine marked idle -- a pacing loop -- is counted as
waiting, so every share is of busy time. The editor re-reads it every second
while counting and on every stop once stopped. See [docs/vscode-debugging.md](../docs/vscode-debugging.md#execution-profile)
for what is counted and how; `profile_model.js` (tested by
`node tests/profile_model_test.js`) turns the server's report into the map,
and `profile_view.js` paints it.

## Watchpoints

**Watch Address...** (the editor's context menu, the Command Palette, or the eye on the **ZX
Spectrum Watchpoints** view) watches an address, a symbol or a range for writes, reads, or only
writes that change the value; the machine stops at the instruction after the access and says what
changed and what changed it. The view lists what the emulator is watching, whoever set it, with hit
counts, an eye to switch one off and a cross to remove it. VS Code's own **Break on Value Change**
in the memory inspector works too -- the adapter answers `dataBreakpointInfo`/`setDataBreakpoints`
-- and the two kinds live side by side. `watchpoint_view.js` does the wiring and
`watchpoint_model.js` (tested by `node tests/watchpoint_model_test.js`) the labels and the input
parsing. See [docs/vscode-debugging.md](../docs/vscode-debugging.md#watchpoints).

## Stepping backwards

When the server declares `supportsStepBack`, VS Code shows its own **Step Back** and **Reverse
Continue** buttons; this extension adds **Step Back Into** and **Step Back Out** beside them,
**Run Back to Cursor** and **Run Back to Last Write...** to the editor's context menu, and a
status bar item while the machine is in the past ("4.5 frames before live") that returns to live
when clicked. Each sends one of the server's own requests (`stepBackInto`, `stepBackOut`,
`runBackToAddress`, `runBackToWrite`, `returnToLive`); the landing arrives as an ordinary
`stopped` event, then a `zxRewind` event whose message, when there is one, goes to the status bar.
`rewind_view.js` does the wiring and `rewind_model.js` (tested by `node tests/rewind_model_test.js`)
the status text. See
[docs/vscode-debugging.md](../docs/vscode-debugging.md#stepping-backwards).

## Install

Copy (or symlink) this directory into your VS Code extensions folder as
`<publisher>.zxspectrum-debug-<version>` (values from `package.json` -- currently
`jonsole.zxspectrum-debug-0.0.2`):

```powershell
# PowerShell, from the repo root
$dest = "$env:USERPROFILE\.vscode\extensions\jonsole.zxspectrum-debug-0.0.2"
Copy-Item -Recurse .\vscode-extension $dest
# The trace viewer lives in tools/, outside this directory -- copy it in too, or
# "Show Trace" has to fall back to finding it in the open workspace.
Copy-Item .\tools\trace_viewer.html $dest
```

Then **"Developer: Reload Window"** to pick it up. Re-run the copy (or use a symlink instead, so
edits show up without re-copying) after changing anything here, then reload again.

## Notes

- `SCREEN_HOST`/`SCREEN_PORT` in `extension.js` are hardcoded to match the server's own defaults
  (`127.0.0.1:8500`) -- edit both sides together if you run a non-default `--screen-port`.
- The panel auto-opens when a `zxspectrum`-type debug session starts (`vscode.debug.onDidStartDebugSession`),
  or open it manually via the Command Palette.
- If the emulator server restarts (a normal part of picking up code changes during development),
  the panel reconnects on its own within about a second rather than needing to be reopened.
- Each sprite on the graphics sheet is read under its own id, and every reply carries that id
  back -- without it a sheet reading from several places could not tell whose bytes had arrived.
  A sprite pinned from a file carries that file's path in its own read, so it keeps reading the
  file it came from rather than following the picker.
- The graphics panel is the one thing in the editor an MCP client can move: the emulator's
  `set_graphics_view` tool sets a `GraphicsView` on the shared `Engine`, the DAP server broadcasts
  it as a `zxGraphicsView` event, and `onDidReceiveDebugSessionCustomEvent` picks it up here. VS
  Code hands extensions unknown DAP events for exactly this purpose. One-way: the panel's own
  controls are not written back.
- The graphics panel's memory reads go through DAP `readMemory`, which the engine services at a
  running machine's own yields -- so its **Live** box re-reads about four times a second without
  pausing anything. It also refreshes on every `stopped` event, which the extension hears by
  registering a debug adapter tracker (VS Code surfaces stack frames to extensions, not DAP
  events).
- "Grab selection" uses the last non-empty selection seen in a text editor, remembered as it
  changes rather than read when the button is pressed: `activeTextEditor` is undefined while a
  webview has focus, which is exactly when that button gets clicked.
- "Show Trace" looks for `trace_viewer.html` beside `extension.js` first, then at
  `../tools/trace_viewer.html` (the symlink-install case), then in `tools/` of any open workspace
  folder. If none of those exist it says so rather than opening an empty panel.
- Recording writes `live.zxtrace` into the first workspace folder, one fixed name that each
  capture supersedes. Record is disabled, and says so, when there is no `zxspectrum` debug
  session to record from.
- A **to** address is armed with a second `stopTrace` request once `startTrace` has answered,
  since that is the request which carries one. If the address will not resolve, the capture just
  started is closed again rather than left running with no stop on it.
- The address fields complete against the session's symbol table over a `matchSymbols` custom
  request, one per keystroke (debounced, latest answer wins). It reads a parsed file and never
  touches the machine, so it answers mid-game. A server too old to have the request simply
  offers nothing rather than reporting an error.
- If a start or stop trigger comes back unarmed, Record cancels the capture and says the gate
  was ignored. DAP drops request arguments it does not recognise without complaining, so a
  server or extension host older than a field would otherwise record from the wrong place in
  silence -- which reads as a broken trigger rather than a stale link. Note the panel HTML is
  re-read from disk whenever the panel opens, but `extension.js` is only loaded when the window
  loads: new fields can appear in a strip that an old host does not yet know how to send.
  "Developer: Reload Window" is the fix for that half; restarting the debug session (which
  rebuilds via the preLaunchTask) is the fix for the server half.
- If the image doesn't appear, check the webview's own console: **"Developer: Open Webview Developer
  Tools"** while the panel is focused.
