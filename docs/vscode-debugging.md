# Connecting VS Code (DAP)

Part of the [zx-spectrum-emulator README](../README.md). This is the reference:
how each feature works and why. For a task-by-task introduction, start with the
[user guide](vscode-user-guide.md).

The repo's `.vscode/` folder is a ready-to-use workspace: `tasks.json` builds
`cpp-core` and starts `zx_server.exe`, and `launch.json`'s **"ZX Spectrum:
Step through ROM"** configuration points at it. Two one-time setup steps are
required first, on top of [Setup](../README.md#setup):

1. **A real 48K ROM** — see [ROM](../README.md#rom) in the README.
   `launch.json` expects it at `roms/48.rom`. For the 128K, the 32K ROM pair
   at `roms/128.rom` as well: the **"ZX Spectrum 128: Step through ROM"**
   configuration uses it, and any configuration becomes a 128K by adding
   `"machine": "128"` alongside a 32K `rom` (or by loading a 128K snapshot,
   which switches the machine to the model it was taken on).
2. **Install the `vscode-extension/` extension.** VS Code requires
   `launch.json`'s `type` to match a registered `contributes.debuggers`
   entry before it will even attempt a `debugServer` connection — this is
   true even though no actual adapter code is needed for that part, since
   `debugServer` overrides which process VS Code talks to (see the [extension
   guide](https://code.visualstudio.com/api/extension-guides/debugger-extension)).
   The repo's `vscode-extension/` directory is a small real extension (it
   also provides the live screen viewer — see below) — copy or symlink it
   into your VS Code extensions folder:

   ```powershell
   # PowerShell, from the repo root
   Copy-Item -Recurse .\vscode-extension "$env:USERPROFILE\.vscode\extensions\jonsole.zxspectrum-debug-0.0.2"
   ```

   Then reload VS Code ("Developer: Reload Window") to pick it up. See
   `vscode-extension/README.md` for details and re-install instructions after
   editing it.

Every setting and `launch.json` attribute is listed in the [VS Code settings
reference](vscode-settings.md).

With both in place, open the Run and Debug view and launch **"ZX Spectrum:
Step through ROM"**. The extension starts `zx_server` itself if nothing is
listening on the DAP port, and waits for it to be ready before connecting --
see [Starting the emulator from the
extension](#starting-the-emulator-from-the-extension). Only **"Step through
ROM (rebuild the emulator)"** goes the other way, through a `preLaunchTask`
that rebuilds the server first; watch its output in the dedicated terminal
panel.

Without the ROM disassembly built (see below), this drives VS Code's
**Disassembly View** rather than a source view: breakpoints are instruction
breakpoints set from there, and each stack frame is labeled with just the
disassembled instruction at its address (no symbol name). Stepping is `next`
(one Z80 instruction) regardless. Supported requests: `initialize`, `launch`/`attach`,
`configurationDone`, `setInstructionBreakpoints`, `setBreakpoints`,
`continue`/`next`/`stepIn`/`stepOut`/`pause`, `threads`, `stackTrace`,
`disassemble`, `scopes`/`variables` (a **Registers** scope — including the
shadow set `AF'`/`BC'`/`DE'`/`HL'` — and a **Flags** scope breaking `F` out
into `S`/`Z`/`H`/`P·V`/`N`/`C` booleans), `setVariable` (double-click a
register or flag in the Variables pane to change it — a register takes
anything an address does, `0x8000`, `8000` or `KEY_INT+9`; a flag, `IM` or a
flip-flop takes `0`/`1` or `true`/`false`), `readMemory`/`writeMemory`, and
`disconnect`.

**Verified working in an actual live VS Code session**, not just
protocol-level: launch, breakpoints, continue-to-breakpoint, disassembly-view
navigation (forward and backward from an arbitrary PC, including across the
0xFFFF/0x0000 address wrap), and register inspection all confirmed by hand
against the real ROM. A couple of real bugs turned up exactly this way and
are already fixed — see [Status & roadmap](status.md) and the git
history for details.

One current UI rough edge, not fixable from the adapter side: for a
source**less** frame (i.e. without the ROM disassembly built), VS Code
doesn't reliably auto-populate the Registers panel or auto-focus the
Disassembly View on every stop — clicking the Call Stack entry once after a
stop refreshes it. Tracked upstream as
[microsoft/vscode#131253](https://github.com/microsoft/vscode/issues/131253).

### Where the focus goes when it stops

VS Code focuses the editor, and raises its window, every time a debug session
stops -- which is right when you pressed the key that stopped it, and wrong
here as often as not: a step or a pause can come from an MCP client, a
watchpoint can fire while you are typing in another file, and the screen panel
loses the keyboard exactly when the machine is doing something worth watching.

The workspace's `.vscode/settings.json` turns both off:

```json
"debug.focusEditorOnBreak": false,
"debug.focusWindowOnBreak": false
```

Neither stops the debugger following the program: the call stack, the
variables, the disassembly and the current-line highlight all still move on
every stop. They only stop the keyboard and the window being taken. Set them
in your own user settings to get the same everywhere, or drop them from the
workspace file to have VS Code's own behaviour back.

Those two settings still leave VS Code *revealing* the stopped line -- opening
its file, and so switching the editor tab you were reading -- and opening the
Run and Debug view on a breakpoint. For a stop you asked for that is the point;
for one an MCP client caused, while you were reading something else, it is the
editor being taken over by somebody else's step. So the adapter tells them
apart:

- **A stop an MCP client caused** -- its `run`, `step`, `pause`, `reset`, a load
  or a step back -- goes out with DAP's `preserveFocusHint`. VS Code updates the
  call stack but selects nothing, so the editor, the sidebar and the window
  stay as they were. An `invalidated` event follows it, because with no frame
  newly selected VS Code would otherwise leave the Variables pane showing the
  registers from *before* the stop.
- **A stop this window asked for** -- F5, F10, Pause, a step back from the
  toolbar, a launch -- goes out without it, so the editor follows the program
  as you step, exactly as before.

What counts is who last set the machine *moving* (`Engine::set_driver`): an
agent polling `get_state` or reading memory while you step does not make your
next stop its own. And a breakpoint of yours that an agent's `run` happens to
hit is its stop -- shown in the call stack and the registers, and one click on
the top frame away, but not snatched into view.

One thing stays stale: the small address in the CALL STACK pane's header is the
last stop VS Code *selected*, so after an agent's step it still shows the stop
before. The frames themselves are current.

## Starting the emulator from the extension

A configuration that leaves out `debugServer` has the extension do it: the
debug adapter descriptor factory (`server_view.js`) connects to
`zxspectrum.server.dapPort`, and when nothing is listening there it starts
`zx_server` itself and waits for the port to answer. That is how all but one
of the repo's own configurations work, and it is all a project of your own
needs:

```json
{ "name": "ZX Spectrum", "type": "zxspectrum", "request": "launch", "rom": "${workspaceFolder}/roms/48.rom" }
```

- **Which server.** `zxspectrum.server.path`, or else
  `cpp-core/build/RelWithDebInfo/zx_server.exe` in any workspace folder, or
  else `PATH`. It runs in the root of the checkout it was built in, where
  `rom_disassembly/` is.
- **How.** The ports, the sound (`device`, `panel` or `off`), the ROMs to boot
  with and any extra flags are settings -- see [Starting the
  emulator](vscode-settings.md#starting-the-emulator). The screen and audio
  panels connect to the same port settings, so a server on other ports is seen
  by the panel too.
- **Joined, not replaced.** Anything already listening on the port -- a
  task's server, an MCP client's, another window's -- is used as it is. A
  start in progress is shared by sessions that ask at once.
- **Lifetime.** Like a task's server, it outlives the debug session, so MCP
  clients keep their machine. It is stopped when the window closes, unless
  `zxspectrum.server.stopOnExit` is off.
- **Seeing it.** The server's output goes to the **ZX Spectrum Emulator**
  output channel. While an emulator is running, a **Spectrum** item in the
  status bar says whose it is and offers Stop, Restart and the log; the same
  are **ZX Spectrum: Start / Stop / Restart Emulator** and **Show Emulator
  Log** in the Command Palette. Stopping one this window did not start asks
  first, and (on Windows) finds the process by the port it holds.
- **Not polled.** The status is refreshed when a session starts or ends, on
  those commands, and when the window regains focus -- a probe is a connection
  the server logs, and one every few seconds would fill its log.

A configuration with a `debugServer` never reaches any of this: VS Code
connects to that port itself, before an extension is asked.

## Opening snapshots and tapes

`.sna`, `.z80`, `.tap` and `.tzx` files open -- from File > Open, the
Explorer, or anywhere else -- in a small read-only editor (`program_view.js`)
that says what the file is: the snapshot format and the Spectrum it needs, or
the tape's blocks and the files its headers name. Beside that it draws the
program's screen in its border colour, scaled to the editor. The page measures
itself and puts the picture beside the details or above them, whichever lets
it be larger with the details -- and the Run button -- still wholly in view,
and redoes that whenever the editor is resized:

- **A snapshot's** is the 6912 bytes at `$4000` -- straight out of a `.sna`
  (after its 27-byte header, on a 128K too, since `$4000` is always page 5), or
  unpacked from a `.z80`'s memory (all of it in version 1, page 8 in versions 2
  and 3). The border is the one the snapshot saved.
- **A tape's** is its loading screen: the data block a `SCREEN$` header
  announces, or failing that the first headerless block that is a flag byte and
  6912 bytes, with or without a checksum -- which is how most custom loaders
  carry theirs. A screen a loader packs or splits (Exolon's, Head Over
  Heels') is not found, and the page shows none. Tapes carry no border colour,
  so the border is white.

A `.tap` with stray bytes after its last block -- common in the wild -- is
read up to them, and the page says how many were ignored. Its **Run** button starts a
debug session on it that carries straight on running; **Debug** stops at the
first instruction. The same two are **Run in ZX Spectrum** and **Debug in ZX
Spectrum** on the Explorer's context menu, and ticking *Run programs as soon as
they are opened* (`zxspectrum.program.runOnOpen`) skips the page.

- **The session.** A launch with `snapshot` or `tape` (auto-started) and no
  `debugServer`, so the emulator is started if it is not running. A program
  already being debugged is stopped first: there is one machine.
- **The ROM.** Chosen by size from `zxspectrum.server.roms` or the checkout's
  `roms/`: the 32K pair for a 128K snapshot (with `machine` set to match), the
  16K ROM otherwise.
- **Source.** A `.sld` of the same name beside the file, with an `.asm`, `.s`
  or `.a80` of that name too, is loaded with it. The source may also be one
  folder up, for a build that writes into an `output/` of its own, as
  `examples/filmation` does.
- **Running on.** The server stops every session on entry; `stopOnEntry:
  false` (a launch attribute anyone can use) has the extension continue from
  that one stop.
- **`.z80` source files.** The extension is also a Z80 assembly editor, and
  `.z80` is an assembly extension as well as a snapshot one. A `.z80` whose
  first 4K has no NUL bytes and almost no control characters is text, and is
  handed straight to the text editor.

## Designing Filmation rooms

The Filmation remakes' room designer, templates editor and graphic map are not
part of this extension: they are an extension of their own, in
`examples/filmation/vscode/`, which needs nothing from the emulator.
[room-designer.md](../examples/filmation/room-designer.md) says how to install
it and has the whole of it.

## Attaching to a running emulator

Every configuration above **launches**: the `launch` request resets the
machine and loads whatever the config names (and, in the one configuration
with a `preLaunchTask` that starts the server, rebuilds `zx_server` first).
That is what you want
when you are starting a debugging session from nothing, and exactly what you
do not want when something is already running and you would like to look at
it -- a machine an MCP client started (see
[tools/zxserver](../tools/zxserver/README.md)), or one left behind by an
earlier session.

**"ZX Spectrum: Attach to running emulator"** does the latter. It joins the
machine as it is: no reset, no ROM, no snapshot, no tape, nothing typed at
the keyboard. Whatever the Spectrum was doing, it carries on doing, and
breakpoints, stepping, registers, memory and the disassembly view all work
from there.

Two differences from the launch configurations are worth knowing:

- **It never resets.** Like the launch configurations, it has no
  `debugServer`, so the extension joins whatever is listening on the DAP port
  and starts a server only if nothing is (see
  [above](#starting-the-emulator-from-the-extension)). Never give an attach
  the rebuild configuration's `preLaunchTask`: that task stops the running
  server and rebuilds it, which is exactly what an attach must not do.
- **`sld` and `asm` are the only settings it accepts.** Debug info is not
  machine state, so loading it disturbs nothing; `rom`, `snapshot` and `tape`
  are all ignored, because each of them resets the machine and would destroy
  the thing being attached to.

To step your own program's source over an attach, add the same `sld`/`asm`
pair a launch config uses -- see [Source-level debugging of your own
program](#source-level-debugging-of-your-own-program).

## Live screen viewer

Run **"ZX Spectrum: Show Screen"** from the Command Palette (or just launch a
debug session — it opens automatically) for a live view of the display
alongside your code, fed by a third server port (`--screen-port`, default
`8500`) that streams the screen as a continuous sequence of PNG frames (10fps)
to any connected client. The extension bridges that stream into a webview
panel; watch it update in real time as you step, run, or drive the machine
over MCP.

This port is a plain, independent front-end onto the shared `Engine` — the
same standalone-server design as DAP and MCP, not something that only works
through VS Code. Any client can connect directly and read the same frames
(4-byte big-endian length prefix + that many PNG bytes, repeated for as long
as the connection stays open) — see `cpp-core/src/screen_stream.cpp`.

### Scaling and filtering

The magnifier in the panel's title bar -- or **ZX Spectrum: Screen
Scaling...** from the Command Palette -- sets how the 352x312 picture is
drawn, and remembers it as a user setting (`zxspectrum.screen.filter` and
`zxspectrum.screen.scale`, also in the Settings editor):

| Filter | Looks like |
|---|---|
| **Nearest neighbour** (the default) | hard-edged pixels, as the ULA drew them -- but at an in-between size some rows and columns come out a device pixel wider than others |
| **Sharp bilinear** | hard-edged pixels, evenly sized at any size: nearest neighbour up to the largest whole multiple, then bilinear for the fraction that is left, so only pixel edges are blended |
| **Bilinear** | smoothed, the way a television softened it |

| Size | |
|---|---|
| **Fit, whole multiples** (the default) | as large as the panel allows in whole steps, so nearest neighbour stays exact |
| **Fit** | fill the panel, keeping the shape -- the one where the filter matters |
| **1x - 4x** | a fixed size; a panel too small for it scrolls |

**Border** (`zxspectrum.screen.border`) is how much of the border to show, as
a percentage of what the emulator draws -- 48 pixels each side, 64 lines above
and 56 below. At 100 (the default) you see all of it; at 0, only the 256x192
paper; in between, each side keeps that share of its own depth, so the border
stays in proportion. The picture is scaled to fit what is left, so a smaller
border buys a bigger playfield in the same panel. The picker offers 100, 75,
50, 25 and 0%, and a custom value takes anything in between.

**Scanlines** (`zxspectrum.screen.scanlines`) darken the lower half of every
Spectrum line by a percentage -- the picker offers off, 25, 50, 75 and 100%, and
a custom value takes any whole number in between. They are laid over the
picture after the filter, as a CRT's gaps are in the glass rather than in the
picture, and they fall exactly between the lines whatever the size. A line
needs at least two device pixels for a gap to fit, so at 1x on an unscaled
display the setting has no effect; at 2x, 50% leaves the top pixel of each
line as it was and halves the one below.

Sizes are worked out in device pixels, so on a scaled display (125%, 150%) the
whole-multiple sizes are whole numbers of *physical* pixels, and the canvas is
never stretched by the browser behind the filter's back. At a whole-multiple
size, sharp bilinear and nearest neighbour are the same picture; the
difference shows at **Fit**. The panel used to be a fixed 2x whatever its size.

Frames are read via `engine.machine.render_screen()` directly rather than
through the engine's normal command queue — a `run()` in progress occupies
the actor loop for its entire duration, so a queued read would sit unserved
(and the view would visibly freeze) until it stopped. Same queue-bypass
pattern DAP's own memory reads already use, for the same reason.

## Graphics viewer

The screen panel answers "what does the machine look like". This one answers
the question that comes first: **is the data right, and if not, which byte is
wrong?**

Run **"ZX Spectrum: Show Graphics"** for a panel that points at bytes and draws
them the way the ULA would. The bytes come from one of three places, because a
sprite is all three things over its life:

- **Memory** — an address, or a symbol name, in the running machine. Symbols
  complete as you type (the same `matchSymbols` request the trace panel's
  address fields use), and `sprite_000+4` works as readily as `$8000`. Reads go
  through DAP's `readMemory`, which the engine services at a run's own yields
  about twice a frame — so ticking **Live** watches a buffer being built
  *without stopping the machine to look*. It also re-reads by itself the moment
  a breakpoint hits.
- **File** — a `.scr`, or a raw blob like `examples/filmation/knightlore/sprite_data.bin`,
  with no debug session needed at all. That is the build-time half of the same
  question.
- **Selection** — select `DEFB` lines in an assembler source and press **Grab
  selection** in the dialog, or right-click and use **"Show Selection as ZX
  Spectrum Graphics"**, which opens the dialog on them. Everything sjasmplus
  writes for a byte is understood: `0x3C`, `$3C`, `#3C`, `3Ch`, `0b00111100`,
  `%00111100`, `60`. When the selection contains `DEFB` lines only those
  contribute, so catching the label above the table or an `EQU` beside it does
  not push numbers into the middle of the picture.

### Formats

**Sprites** lays the bytes out as a grid of items: `width` bytes across,
`height` pixel rows, `count` of them, `cols` per row of the sheet. Three
further knobs exist because real sprite data is rarely a bare bitmap:

- **Mask** — whether each row byte is preceded by (`mask, data`) or followed by
  (`data, mask`) a mask byte, interleaved per byte across the row. A masked
  pixel is drawn transparent over a checkerboard, so a mask with the wrong
  polarity is obvious rather than merely wrong-looking; **invert** flips which
  way round a set mask bit reads.
- **flip** — row 0 of the data is the *bottom* row of the picture, which is how
  Ultimate stored theirs and therefore how `examples/filmation`'s are stored.
- **Header** — bytes to skip before *each* item, for data that carries a
  per-sprite width/height pair ahead of its bitmap.

**Font** is the same decode with the shape a character set has (1 byte wide,
8 rows, 96 of them) filled in for you, and labels showing each glyph's code and
character. Point it at `$3D00` for the ROM's own.

**Screen** reads the display file's scrambled layout and, when there are 6912
bytes rather than 6144, colours it from the attributes that follow. A `.scr` on
disk and `$4000` in the running machine are the same picture by two routes.

### Every setting, and where it lives

A sprite carries its own copy of the first group, which is what lets one sheet
hold sprites of different shapes; the second group belongs to the sheet, so
changing one of those changes every tile at once. The MCP column is what
`set_graphics_view` calls the same thing, and the atlas column what
[the atlas file](graphics-atlas.md) calls it.

| Dialog | MCP | Atlas | Values | Default | What it does |
|---|---|---|---|---|---|
| Name | -- | `name` | letters, digits, `_` | offered | The label the export writes for it |
| Group | -- | `group` | a group's name | last used | Which group it is in |
| Source | `source` | `source` | `memory`, `file`, `selection` | `memory` | Where the bytes come from |
| Address | `address` | `address` | a number or a symbol, `sprite_000+4` | `$4000` | For `memory`. Re-read on every stop and **Refresh** |
| File | `file` | `file` | a path | -- | For `file`: `.scr`, `.sna`, `.z80` or a raw blob |
| Offset | `offset` | `offset` | 0-2147483647 | 0 | For `file` and selections: bytes skipped first |
| Format | `format` | `format` | `sprite`, `font`, `screen` | `screen` | The layout the bytes are read with |
| Width | `width` | `width` | 1-64 | 2 | Bytes across an item, before mask interleaving -- so 3 is 24 pixels |
| Height | `height` | `height` | 1-256 | 16 | Pixel rows an item |
| Count | `count` | `count` | 1-1024 | 16 | Items. Higher than the data runs is fine: the extra are reported, not drawn as rubbish |
| Cols | `columns` | `columns` | 1-64 | 8 | Items per row, on the sheet and in the exported picture |
| Header | `header` | `header` | 0-64 | 0 | Bytes skipped before **each** item, for data carrying its own width/height |
| First | `first` | `first` | 0-255 | 32 | In a `font`: the character code of item 0 |
| Mask | `interleave` | `interleave` | `none`, `md`, `dm` | `none` | Mask and data per byte across a row: none, mask first, data first |
| Invert | `invert_mask` | `invertMask` | boolean | false | A **clear** mask bit means transparent |
| Flip | `flip` | `bottomUp` | boolean | false | Row 0 of the data is the bottom row of the picture |
| Ink, Paper | `ink`, `paper` | `ink`, `paper` | 0-15 | 0, 15 | The ULA colours a set and a clear bit are drawn in |

Sheet-wide, and so not part of a sprite: **zoom** (`zoom`, 1-16, default 3),
**grid** (`grid`, on, and suppressed below 3x where the lines would be most of
the picture), **labels** (`labels`, on) and **Live**.

How many bytes a sprite reads follows from the layout: a row is `width` bytes,
doubled when a mask is interleaved; an item is `header` plus `height` rows; and
a sprite is `count` items. A `screen` is 6,912 -- 6,144 of bitmap and 768 of
attributes -- or 6,144 with no colour.

### The point of it

Hover any pixel. The status line says which item it is in, where it is within
that item, **the address of the byte holding it and which bit**, the byte in
binary, and the mask byte beside it. Everything else in the panel is in service
of being able to point at one wrong pixel and be told where to go and fix it.

Layout changes in the dialog redraw its preview from the bytes already in
hand rather than re-reading, so dragging the width up and down until an unknown
sprite format snaps into focus costs nothing.

### Adding and changing a sprite

**Add...** opens a dialog holding every per-sprite setting — where the bytes
come from, the layout, the mask arrangement and the colours — beside a preview
of what they draw. Nothing reaches the sheet until **Add**; **Cancel** (or
Escape) throws the attempt away. The dialog opens where the last Add left off,
so a run of similar sprites only needs the offset changed each time. **Add**
stays disabled until the preview has bytes, so a sprite that reads nothing
cannot be added.

Every sprite has a **name**, and it is a label: letters, digits and
underscores, since the export writes it as the atlas frame and the assembler
label. The dialog offers one made from where the data came from — the symbol
(`guard_tab`), the file and offset (`sprite_data_120`), or `sprite1`,
`sprite2`... when there is nothing better — and keeps offering a fresh one as
the source changes, until you type your own. Clearing the box hands naming back
to the dialog. **Group** picks the group the sprite goes in (see below). Two
sprites in the same group, or two outside any group, cannot share a name; the
same name in two groups is fine.

**Double-click** a sprite on the sheet (or press its **✎**) to open the same
dialog on it. **OK** changes that sprite in place, keeping its number and its
position; **Cancel** leaves it as it was. Editing a sprite does not change
where the next **Add...** starts.

### The sheet

The sheet holds the sprites that have been added, in order. **Drag** a sprite
to move it: dropping on the left half of another sprite puts it before that
one, the right half after, and dropping on empty sheet sends it to the end.
Each sprite carries its own frozen copy of everything per-sprite — name,
group, source, address or file, size, format, mask arrangement, colours — so a
sheet can hold sprites of **different sizes, from different files, in
different formats** at once.

That is the answer to "show me several sprites when they are not all the same
shape". Nothing else works for a set like Knight Lore's, where each record
carries its own width and height and no two neighbours need agree: a single
fixed grid can only ever describe one shape, and repacking the data into one
would throw away the byte addresses that make the panel worth having.

Each sprite has three buttons: **✎** opens it in the dialog, **⤓** exports
just that sprite, and **🗑** removes it.

Only `zoom`, `grid`, `labels` and `Live` are properties of the sheet rather
than of a sprite, so changing those changes every tile at once. The dialog's
preview zoom is the sheet's zoom, so what the preview shows is what the sheet
will.

**Refresh** re-reads every sprite on the sheet — a sprite from an address in
memory is exactly the thing you add in order to watch it change, and the same
goes for the automatic refresh on every stop. A sprite from a file keeps that
file's path, so it goes on reading the file it came from after **Choose
file...** has moved on to another.

The sheet is remembered across a panel close and a window reload, per
workspace: the page hands it to the extension on every change, and a newly
opened panel starts from it. (A webview's own saved state would not do — VS
Code drops it when the panel is closed.) Memory and file bytes are not — they are re-read, because megabytes of sprite do not
belong in a store meant for a little UI state. A sprite taken from a selection
is the exception: there is nothing to re-read it from once the selection has
moved, so its bytes (up to 64 KB) are kept with it and it is never re-read.

### Groups

**New group** adds a named group to the sheet, with its name ready to type
(it is a label too, so `knight team` becomes `knight_team`). The sheet then
shows the sprites in no group first, under "Not in a group", and each group
after, under its own heading. Sprites join a group by being dragged into it —
onto one of its sprites, to land beside that one, or anywhere else in the group
to go at its end — or by being added with that group chosen in the dialog.
Dragging one into "Not in a group" takes it out again.

A group's heading has its name (double-click it, or press **✎**, to rename;
Enter keeps the new name and Escape drops it), how many sprites it holds, and:

- **+** opens **Add...** with the group already chosen. The next **Add...**
  starts in the group last added to, so a run of frames goes into one group
  without choosing it each time.
- **⤓** exports the group on its own, named after it.
- **🗑** removes the group. Its sprites stay on the sheet, out of any group, and
  one whose name is already used there gets a `_2`.

In an export a group is a prefix: a sprite `walk` in the group `knight` is
`knight_walk` in the atlas and the source, so `walk` in `knight` and `walk` in
`guard` never collide. The groups are listed in the atlas too, and each one
starts a new row of the picture.

### Exporting and importing

**Export...** saves the whole sheet, a group's **⤓** saves that group, and a
sprite's **⤓** saves that sprite. A dialog asks what to write; the save dialog
then asks for the atlas's name, and the other files go beside it under the same
name — `knight.json`, `knight.png`, `knight.sna`, `knight.s`.

- **Atlas (.json)** — always written, and specified field by field in
  [The graphics atlas](graphics-atlas.md). It is TexturePacker's "JSON (Hash)"
  layout, which Aseprite also writes and Phaser loads as it is: a `frames`
  object keyed by frame name, and `meta`. A sprite with several items has a
  frame for each: `knight_walk_0`, `knight_walk_1`..., or `font_65` by
  character code in a font. Everything the panel knows rides along under `zx`
  keys, which engines ignore: for each frame, its sprite, group, item, byte
  offset and address; in `meta.zx`, the groups in order, and every sprite's
  settings, where it was read from, its length and, unless the export points
  instead (below), its bytes in base64.
- **Picture (.png)** — ticked by default. The sprites at one image pixel per
  Spectrum pixel, without the grid or the labels, each sprite keeping its own
  columns, a pixel apart so an engine that filters the picture never bleeds one
  frame into the next. Masked pixels are fully transparent; ink and paper are
  the sprite's own colours, and a screen uses its attributes. With a picture,
  each frame in the atlas has its rectangle in it (`frame`, `sourceSize` and
  the rest); without one, the atlas has no `meta.image` and its frames only
  say what they are and where their bytes live.
- **Point into the snapshot instead of carrying the bytes** — the atlas names
  where each sprite's bytes are rather than holding a copy. A sprite read from
  memory gets `snapshot: { file, offset, address }` into the machine, which the
  export saves as a `.sna` beside the atlas (it needs the debug session for
  that, through a `saveSnapshot` request, and the snapshot is the machine as it
  is at the moment of export). A sprite from a `.sna` file points into that
  file, with the address its bytes load at; one from any other file is found by
  its own `file` and `offset`. A sprite from a selection has nowhere else to be
  read from, and one in the ROM (the character set at `$3D00`, say) is not in a
  `.sna`, so those carry their bytes either way. File paths are written
  relative to the atlas, so an export inside a repo works from another clone.
- **Assembler source (.s)** — sjasmplus `DEFB` lines, byte for byte as they
  were read and in their original order: mask bytes where they were, header
  bytes first, bottom row first when the data runs that way. It assembles back
  to exactly the data it came from. Each row is written in binary with a
  picture of the row beside it (`#` ink, `.` paper, a space where the mask is
  clear); a screen is written in hex, 32 bytes to a line, with `_bitmap` and
  `_attrs` labels. Each sprite, each of its items and each group gets a label,
  and every label in the file is unique — a sprite named `ball` with two items
  writes `ball`, `ball_0` and `ball_1`, so a second one named `ball_1` becomes
  `ball_1_2`.

The dialog remembers what was ticked. A sprite with no data read yet is left
out, and the status line says which.

**Import...** reads an atlas back and adds its sprites to the end of the sheet,
in their groups — a group whose name is already taken comes in beside it as
`knight_2` rather than mixing two sets of sprites. Each sprite shows the bytes
it was exported with, or, for an atlas that points, the bytes read from its
snapshot or file. It stays tied to where it came from, though: the next
**Refresh**, or the next stop, reads a memory sprite from the running machine
again. A file that is not an export from this panel is refused, and a
hand-edited atlas loses only the fields that do not make sense, each clamped or
reset to its default rather than refusing the whole sheet.

### Driving it from MCP

`set_graphics_view` points the panel at something: it opens the **Add**
dialog on that view, so the person sees the preview and decides whether it goes
on the sheet. It is the only MCP tool that
moves anything in the editor rather than in the machine — it changes nothing
the emulator does and returns no picture, so it is for putting a sprite in
front of the person you are working with ("here is what is actually at
`sprite_017`"), not for looking at one yourself.

```
set_graphics_view(source="memory", address="sprite_000", format="sprite",
                  width=3, height=31, count=8, columns=4, header=2,
                  interleave="md", flip=true)
```

The fields are the dialog's, under the names in the table above -- `flip` for
the dialog's flip (`bottomUp` in an atlas) and `invert_mask` for its invert.
Every field is left as it was when omitted, so a width can be corrected without
restating the address. Numbers out of range are clamped rather than refused —
these land in a UI, and the nearest sensible value beats an error nobody sees —
but a misspelled `source`, `format` or `interleave` **is** refused, because a
typo that reached the panel would leave it drawing nothing with the mistake
three processes away from whoever had to find it.

`pin=true` **adds** the sprite to the sheet straight away, with no dialog,
which is how a set of differently-sized sprites is put up: one call
per sprite, each with its own width, height and format. Every other field
merges over the previous call, so a run of sprites in the same format only has
to restate what actually differs — usually just an offset and a size:

```
set_graphics_view(source="file", file="...Knight Lore.sna", offset=19237,
                  format="sprite", width=4, height=29, count=1, header=2,
                  interleave="md", invert_mask=true, flip=true, pin=true)
set_graphics_view(offset=18983, width=3, height=42, pin=true)
```

`pin` is the one field that does **not** merge: it is an instruction rather
than a setting, and one left set would quietly turn the next correction into
another tile. It is cleared on every call.

The panel opens itself if it is closed. With no debug session at all the view
is remembered, and the panel picks it up when one starts — though only the last
one, since the server holds a view rather than a sheet, and only as where
**Add...** starts: a view caught up on like that neither opens the dialog nor
adds to the sheet, even with `pin`. The same catch-up happens at every session
start, and acting on it again would put the last pinned sprite on the
remembered sheet once more each time.

#### How it gets there

MCP and DAP are separate front-ends onto one `Engine` with no channel between
them, so this travels the long way round:

```
MCP set_graphics_view  ->  Engine::set_graphics_view (a GraphicsView + a version)
                       ->  DAP broadcasts a `zxGraphicsView` event
                       ->  the extension moves its panel
```

`GraphicsView` lives in `engine.h` for the same reason the raster view does:
it is the only thing both front-ends can see. Unlike the raster view it changes
nothing the emulator draws, so it neither queues nor waits — it lands mid-run
as readily as at a breakpoint.

The traffic is one-way. What you then do with the panel's own controls is not
written back, so the server holds what was last *asked for* rather than what is
on screen. A panel that wrote back would turn every drag of the width box into
a round trip, and nothing on that side wants to know.

The version counter is not decoration. The panel remembers its own last layout,
and one that opened onto whatever the server happened to hold would throw that
away every time — so "nobody has ever asked for anything" (version 0) has to be
distinguishable from "someone asked for the defaults". A panel opening later
reads the current view with a `graphicsView` DAP request and applies it only if
the version has moved past what it last applied.

## Raster position

A stopped machine has a beam somewhere in the middle of a frame, and for
anything synchronised to the frame that position is the whole question. Where
a border stripe lands, whether a sprite is redrawn before or after the beam
reaches it, how much of the screen an interrupt handler has left to work in:
all of it is "which line are we on", and a still picture of the last completed
frame says nothing about it.

Three things answer it, all of them only while the machine is **stopped** —
stepping, or sitting on a breakpoint. A running machine is never annotated and
always shows one whole completed frame; the code path it takes is exactly the
one it took before any of this existed. Set them with `set_raster_view
{marker, in_progress, pending}` over MCP, `setRasterView {marker, inProgress,
pending}` over DAP, or the Command Palette entries named below. Each field is
left alone when not given, and changing one republishes the screen
immediately, so a toggle shows its effect without needing a step first.

### The beam marker

A dashed line across the raster line the beam is on — full canvas width, so
the border is included — and a solid tick standing out of that line at the
exact dot. Step, and it walks down the frame. On by default;
**"ZX Spectrum: Hide Raster Position"** turns it off, which is worth doing if
you are comparing screenshots and want the picture alone.

It is drawn by *inverting* what is underneath rather than in a colour of its
own. Every Spectrum colour channel is 0, `0xCD` or `0xFF`, so an inverted
pixel always contrasts sharply with its surroundings — no fixed colour can
promise that against a screen which might be any of them.

### The frame in progress

On by default, and the reason the marker is worth having: the picture is
composed the way a CRT has it at that instant — **this** frame's drawing down
to the beam, the previous frame beyond it — instead of the last completed
frame. So a border stripe appears at the line the `OUT` happened on, as you
step onto it, rather than turning up all at once in the next completed frame.
Stop half-way down a frame and the split is visible at the marker: fresh work
above it, last frame's picture below.

**"ZX Spectrum: Show Last Completed Frame"** goes back to the plain frame,
which is what a screenshot for comparison wants.

### Pending writes

Off by default. With it on, every display byte written **since the beam last
passed it** keeps its own colours while the rest of the screen is dimmed to
half brightness around it: the changes that are in memory but not yet on the
picture, because the beam has not reached them. That is precisely what a
frame-synchronised routine is racing, and it is invisible in any picture of
the screen.

Dimming the rest, rather than tinting the pending bytes, is deliberate. What
is interesting about a pending write is *what it is about to show*, and a tint
is exactly what would hide that.

The dim goes on **whether or not anything is pending**. An empty map is a real
answer — for a game that draws in one burst per pass, most of the pass has
nothing waiting — and it has to look different from the view being switched
off, or every such moment reads as the feature being broken. So a wholly
dimmed screen means "the beam has displayed everything written so far".

The map itself is kept whether or not you are looking at it, so switching the
view on shows what is *already* waiting rather than starting from empty and
filling up only as the program happens to write again. `bench_machine`
measures the cost of keeping it as being inside the run-to-run noise.

Pending is measured against the **beam**, not the frame counter. A byte's
tint is cleared by the screen fetch that puts it on the picture, so a byte
written into the bottom border for a row near the top stays pending across the
frame boundary, exactly as it should. Both halves of the display file count —
bitmap bytes tint the eight pixels they hold, attribute bytes their whole 8×8
cell. Attributes are included here, unlike in the [display-write
overlay](#display-write-overlay), precisely because a colour change landing on
the wrong side of the beam is the classic thing to get wrong. Nor does it care
whether the byte was cleared: the question is whether the picture will change
when the beam arrives, and an erase changes it as much as a draw.

**"ZX Spectrum: Show Pending Display Writes"** turns it on. It is off by
default because it is a specialised view that replaces the picture's own
brightness, not because it is expensive.

All three are annotations on a *copy*. The ULA's own frame never receives any
of them, so nothing the emulator does next is affected by their having been
drawn.

## Display-write overlay

The screen shows what a program *drew*; it says nothing about what it
**touched**. A sprite routine that redraws half the screen every frame and one
that updates eight bytes produce the same picture, and the difference between
them is usually the thing you are trying to see.

The eye button in the screen panel's title bar (**"ZX Spectrum: Show Display
Writes"** from the Command Palette, `set_write_overlay` over MCP,
`setWriteOverlay` over DAP) turns on an overlay that answers it. The whole
picture is dimmed to half brightness, border included, and every byte written
to the screen bitmap — by the program or by a debugger poke — is shown at full
brightness, all eight of its pixels in their own colours, on the frame it was
written. It is the same look as the [pending-writes view](#pending-writes)
on a stopped machine: what was drawn and what it looks like are read off one
picture. By default a byte drops back into the dim at the next frame boundary,
so what you see is one frame's drawing and nothing else.

A byte is lit whole, whatever bits it holds, whether or not they differ from
what was already there, and whether or not they are all zero: the byte is the
unit the program works in, and what matters is that the routine went to the
trouble of writing it. An erase is a write like any other, so a sprite routine
that clears last frame's shape before drawing this frame's shows both halves
of its work. One deliberate omission keeps it readable:

- **No attributes.** One colour byte covers 64 pixels, so tracking attributes
  drowns the pixel work underneath them — a screen-wide attribute effect would
  light the whole display and say nothing about what was actually drawn.

### Opacity and fade

Two percentages tune it, both settable with `set_write_overlay
{opacity_percent, fade_percent}` over MCP, `setWriteOverlay {opacityPercent,
fadePercent}` over DAP, or the **"ZX Spectrum: Set Display Write Opacity…"**
and **"…Fade…"** commands in the Command Palette, which offer the values below
and switch the overlay on with the choice. Either can be set without
disturbing the other, and the panel's on/off button disturbs neither.

**Opacity** is how far a byte is lifted out of the dim on the frame it is
written:

| Opacity | What you see |
| --- | --- |
| `100` (default) | Full brightness. The clearest read on what was drawn. |
| `75` / `50` | Part-way between the dimmed picture and full brightness, so a busy area stands out less. |
| `25` | Barely lifted — enough to spot activity without the screen changing much. |

**Fade** is how much of that brightness a frame boundary removes:

| Fade | What you see |
| --- | --- |
| `100` (default) | Only the frame just drawn. The clearest read on "what is this frame's work". |
| `25` | A short trail, about a fifth of a second — enough to see which way a sprite is going. |
| `10` | A trail of about a second. |
| `0` | Never fades: everything the program has drawn since you switched it on, which is how to find the parts of the screen nothing ever touches. |

One thing to expect from fade: **it only bites where drawing stops.** A game
that repaints its playfield every frame refreshes those bytes to full
brightness before the fade can touch them, so the actively-drawn area looks the
same at every fade value and only the trailing edges differ. Opacity is the
knob that changes how the busy areas read.

### How it works

Two things follow from it being painted *into* the picture. It dims everything
that was not written this frame, so it is a view to switch on when you want it
rather than leave on; and it is baked into the frame itself, so `get_screen` and the
screen stream both show it, which is what makes it usable from an MCP client
and not just from the panel. It is off at every server start, at the default
fade.

Writes are noted at the machine's bus (`spectrum.cpp`'s `service_bus`), the one
place every CPU write passes through, and the overlay is composited at the
frame boundary onto the completed frame — a byte written after the beam had
already passed it still belongs to the frame that wrote it. With the overlay
off, `Ula::note_write` is a relaxed atomic load and a branch, and the per-frame
compositing pass is skipped entirely.

## Execution profile

Where a program's time goes, painted onto its source. **Start Profiling** (the
flame on the debug toolbar, or the Command Palette) has the emulator count every
instruction it executes from then on: which address it started at, and how many
T-states it took. Let the program run -- play the part of the game worth
measuring -- and the open source files warm up as it goes. Starting, stopping
and reading a profile never pause the machine, and the editor re-reads it once
a second while it counts.

On the source:

- **Tint.** Each line that ran is tinted by its share of the busy time counted,
  six shades from faint to strong, with the same marks in the scrollbar so a
  long file's hot spots can be found without scrolling. Idle lines are tinted
  grey (see [idle time](#idle-time)).
- **Labels.** Lines with at least half a percent get their numbers written
  after them -- share, T-states a frame and runs a frame, e.g. `18% · 12,400
  T/frame · 950×/frame` -- and a routine's label line leads with the whole
  routine's total.
- **Calls count on the `CALL` line.** A `CALL` line carries the time its calls
  took as well as its own (see [below](#calls-counted-on-the-call-line)), so
  the heat leads from the main loop down to where the time goes.
- **Hover** for the exact figures: T-states, runs, T-states a run, and for a
  `CALL` line its own share and its calls' share separately.
- **Show Profile Hot Spots** (or a click on the status bar's flame) lists the
  most expensive routines and lines, and jumps to one.

**Stop Profiling** freezes the counts: the map stays up, and is re-read whenever
the machine stops. **Start** again counts from zero; **Clear Profile** takes the
map down.

The numbers are per frame whenever frames went by, because that is the budget a
game works to: a 48K frame is 69,888 T-states. A profile taken only by stepping
reads in totals instead.

### Calls counted on the CALL line

By default a `CALL` line is tinted with the time its calls took as well as its
own: everything the routine it called did, down the whole call path, from that
line. So `call redraw_flush` in the main loop is as hot as the redraw is, and
following the heat down through the calls leads to where the time actually
goes. The label says so -- `44% with calls` -- and the hover splits it into the
line's own share and its calls'. A call of an idle routine reads `idle with
calls`. A routine that recurses back through the same `CALL` is counted once,
from its outermost call, and a call still running (a main loop that never
returns) counts what it has done so far.

**Tint Lines By Their Own Code Only**, in the profile view's `...` menu, shows
each line's own instructions alone; **Tint CALL Lines With Their Calls' Time**
switches back. The choice is kept per workspace and applies to a
[worst frame](#worst-frames) painted on the source as well.

### The call tree

**ZX Spectrum Profile**, in the debug sidebar under the tape pane, shows the
same profile by routine. Every routine the profile saw is listed, most expensive
first, with its share, T-states a frame and calls a frame; expand one and it
lists the routines *it* called, with what those calls cost it, plus a row for
its own code. Those expand the same way, as deep as the calls went. Clicking a
row opens the routine.

What makes the numbers under a routine trustworthy is that the emulator records
calls by *path*, not by name: `sprite_blit` called from `objects_draw_all` and
`sprite_blit` called from `redraw_view` are counted separately, so expanding
`objects_draw_all` shows only the blitting it did. (A call graph read off the
source could only put each routine's whole cost under every caller.) At the top
level a routine reached along several paths is added up across them -- once,
from its outermost call, if it recurses.

The title bar switches the order between **total** (a routine and everything it
called: where to drill in) and **own code** (the instructions in the routine
itself: where they are slow), and each row's numbers follow the order.
Interrupt handlers show with a lightning icon, under whatever they interrupted;
idle routines show a clock; **(outside any call)** is code that ran with no call
open, which for most games is little more than the top of the main loop.

How a call is followed: a `CALL` or `RST` that pushes a return address starts
one, and it ends when that address is gone from the stack -- read off it by
`RET`, `RETI`, or a `POP` or `INC SP` that throws it away, or written over by a
later `CALL` or `PUSH` into the same slot after the stack was reset. SP merely
moving ends nothing: code that borrows SP as a data pointer (`LD SP,HL` and a
run of `PUSH`es to fill a buffer, or `POP`s to walk a bitmap, as filmation's
renderer does) stays inside the call it is in. Code reached by `JP` is not a
call, so it counts as the routine that jumped to it -- a dispatcher that ends in
`JP (HL)` owns the time of whatever it dispatched to. The source tint, which is
by address, still puts that time on the right lines.

### Idle time

A game that paces itself spends much of every frame waiting -- filmation's
`turn_pace` busy-waits out whatever is left of each turn's budget, and a profile
that counts that as work reads as 58% pacer and a squeezed few percent of
everything worth optimising. So waiting is counted apart:

- a `HALT` waiting for its interrupt is always idle;
- any routine can be marked idle: right-click it in the profile view (**Mark as
  Idle**), or **Set Idle Routines...** from the view's `...` menu. From then on
  its time is counted as idle.

Every share -- on the source, in the tree, in the hot spots list -- is then of
*busy* time. Idle lines are tinted grey and labelled `idle · N T/frame`, idle
routines show a clock and sort below the work, and the status bar says how much
of the time was idle. The list is kept per workspace and sent with every start;
a routine is matched by its label in the loaded debug info (up to the next
routine's label), and a name that matches nothing is reported. Marking a routine
idle applies from then on; time already counted stays as it was.

### Worst frames

Averages hide the frames that actually drop: a room being built, a burst of
redraws. So the emulator also keeps every frame's busy time, and the ten busiest
frames in full -- their own time per line and per call path.

**Worst frames** heads the profile view. Its row carries a strip of busy time
across the whole run, one block per frame (or the busiest of several), where a
full block is a frame with no time left over; its tooltip says how many frames
had no idle time at all. Expanded, it lists the worst ten, busiest first, each
expanding into *that frame's* routines exactly as the whole profile expands.
Click one, or its eye button, to paint just that frame onto the source; the
status bar then names it, and clicking that (or the view's closed-eye button)
goes back to the whole profile.

A frame is the default unit, but not every game's work fits in one: when a turn
of the game loop takes one and a half frames, "the worst frame" cuts turns in
half. **Set Profile Period...** (the view's `...` menu) makes a period a turn
instead -- from one arrival at a chosen routine to the next -- and the list
becomes **Worst turns of** that routine, each saying how many frames long it
was. Changing the period starts the periods again; the rest of the profile is
kept.

Nothing about a frame's cost means anything without idle time counted: every
48K frame is exactly 69,888 T-states long. Mark the pacing loop idle (or rely on
a `HALT`) before reading the worst frames.

### What is counted, exactly

- **Clock time, not nominal time.** Each instruction is timed off the machine's
  own clock, so a `DJNZ` taken (13T) and not (8T) average out to what this run
  actually did. ULA memory contention is not emulated yet, so contended code
  costs what it would uncontended -- its real cost on hardware can be higher.
- **Interrupts separately.** An acknowledge sequence runs straight after
  whatever instruction INT happened to interrupt; it is counted in a bucket of
  its own (shown in the status bar tooltip), not charged to that line.
- **A `HALT`'s waiting on the `HALT`,** where it reads as idle time.
- **Through the loaded debug info** -- the program's SLD, then the ROM's --
  exactly as stack frames get their source lines. Time at addresses no source
  covers is grouped by 256-byte page in the routine list (`$9000-$90FF`), so a
  game with no source still shows where its time goes.
- **By 16-bit address.** On a 128K, code in two pages at the same address shares
  a count.
- **What it costs.** A few percent of emulation speed while counting
  (`bench_machine`'s "profiling" line, see
  [Testing and performance](testing-and-performance.md#performance)), and
  nothing measurable while not.

MCP clients get the same numbers from the `profile` tool -- see
[Connecting an MCP client](mcp.md#execution-profile) -- which is how a change can
be measured before and after rather than estimated.

## Watchpoints

A breakpoint asks *when does execution reach here*. A watchpoint asks the
question that actually comes up: *what wrote that?* Set one on an address and
the machine stops when the program touches it, with the call stack of the
routine that did.

**Watch Address...** -- in the editor's context menu, the Command Palette, or
the eye on the **ZX Spectrum Watchpoints** view in the debug sidebar -- takes an
address or a symbol, optionally with a length (`player 8`, `$5C3A,2`), and then
asks what to stop on:

| | Stops when |
|---|---|
| **Writes that change it** (the default) | the program writes a different value there |
| **Every write** | any write, including one that rewrites the value already there |
| **Reads** | the program reads it as data -- not when it executes it |
| **Reads and writes** | either |

The stop lands on the instruction *after* the one that made the access -- there
is no safe place to stop inside an instruction -- and says what happened, in the
Debug Console and beside the stop: `player+2 ($F6DE) $00 -> $5E, written by
object_update.on_screen ($CFF8)`. One **Step Back Into** puts you just before
the write, with everything as it was (see [stepping
backwards](#stepping-backwards)).

The sidebar view lists what the emulator is watching, whoever set it, each with
what it is watching for and how often it has stopped the machine; a click on the
eye switches one off without forgetting it, and the cross removes it.

VS Code's own **Break on Value Change**, in the memory inspector, works too --
the adapter answers DAP's data-breakpoint requests, so those watchpoints appear
in the BREAKPOINTS pane with their own checkboxes, with `= 0` or `<> 3` in their
condition field if you want one. Watchpoints set that way and watchpoints set
from the view live side by side; neither clears the other. A register row's
Break on Value Change says to watch the memory it points at instead: registers
live in the CPU, where nothing on the bus can see them change.

**What counts as an access.** The program's own reads and writes, including its
stack: a watchpoint on a stack slot catches whatever overwrote a return address.
A debugger's own poke does not count, and neither does the ULA reading the
screen fifty times a second, so watching display memory is about the program,
not the picture. Executing a watched address is not reading it -- that is what a
breakpoint is for.

**Reverse Continue stops at a watchpoint too**, at the last access before where
you are, which is the whole of "what wrote that?" with no forward planning:
notice the bad value, watch it, and run backwards.

**Not yet:** hit counts (`stop on the 40th write`) are accepted from VS Code but
ignored, with a message saying so; on a 128K a watchpoint watches the 16-bit
address, whichever bank is paged there; and a watchpoint watches memory, not
registers. Watching costs nothing measurable while a program runs -- see
[Testing and performance](testing-and-performance.md#performance) -- so leaving
one armed is free.

## Logpoints

A logpoint is a breakpoint that reports instead of stopping. Right-click the
gutter and choose **Add Logpoint...**, and type a message: whenever execution
reaches that line, the message is filled in and printed in the Debug Console,
and the program carries on as if nothing had happened.

A message is text with values in braces:

| Written | Gives |
|---|---|
| `{A}`, `{HL}`, `{IX}`, `{AF'}` | a register, in hex: `0x41`, `0x9001` |
| `{(HL)}`, `{(IX+5)}` | the byte at the address in a register pair, with an optional offset |
| `{(0x5C00)}`, `{($5C00)}`, `{(23552)}` | the byte at an address |
| `{(PLAYER_X)}`, `{(table+2)}` | the byte at a symbol, from the loaded debug info |
| `{...:d}` | decimal instead of hex |
| `{...:c}` | as a character: itself if printable, a new line for `0x0D`, `\xNN` otherwise |
| `{(...):w}`, `{(...):wd}` | the little-endian word there, in hex or decimal |
| `{{`, `}}` | a brace |

So `lives {(LIVES):d}, drawing {(IX+2)} at {HL}` on the line that loses a life
says each time how many are left and what was about to be drawn. A symbol is
looked up when the logpoint is set, so a misspelt one greys the logpoint out at
once, with the reason on hover, rather than failing quietly at every hit.

The message is filled in just before the instruction on that line runs, so a
register it loads still holds its old value. Reading memory for a message
touches nothing: no watchpoint sees it.

**Many reports.** A logpoint in a busy loop can report hundreds of thousands
of times a second. Reports are sent in batches, a few a second while the
program runs and always before a stop is announced, so they read in order with
everything else in the console; past 20,000 in one batch the rest are counted
and dropped, and the console says how many.

**For programs rather than people.** An extension that wants to see what a game
does -- every character a text adventure prints, say -- can set logpoints by
address without going through the Breakpoints pane, with the adapter's own
`setLogpoints` request: `{group, logpoints: [{address, message}]}`, where the
address is a number or anything [an address field](#watchpoints) takes. Each
call replaces what that connection set under the same group, and the reports
come back as `zxLog` events -- `{group, lines: [{id, pc, text}], dropped}` --
rather than in the console. A connection's logpoints go when it closes.

**Not yet:** conditions and hit counts on logpoints; an MCP tool for them; and,
as with breakpoints, a logpoint on a 128K is on the 16-bit address, whichever
bank is paged there. A rewind replays the machine without its logpoints, so
stepping back does not report the same lines again.

## Stepping backwards

Stopped at a breakpoint or a pause, you can go **backwards** through what the
program just did, with the whole machine -- registers, memory, the stack, the
screen -- exactly as it was at each point:

| Control | Lands on |
|---|---|
| **Step Back** (VS Code's own button) | the previous instruction in this routine; a call just returned from is passed over, landing on its `CALL` |
| **Step Back Into** (toolbar, ←) | the previous instruction executed, whatever it was -- after a `RET`, the `RET` |
| **Step Back Out** (toolbar, ↑) | the `CALL` that entered the routine you are in |
| **Reverse Continue** (VS Code's own button) | the most recent earlier breakpoint hit, or the start of the history |
| **Run Back to Cursor** (editor context menu) | the last time execution reached that line |
| **Run Back to Last Write...** (editor context menu, Command Palette) | the instruction that last wrote an address or symbol -- who put that value there. It lands before the write; step forward once to see it happen |

Each lands like a step: the call stack, registers, disassembly and screen all
refresh. A search that finds nothing leaves the machine where it was and says so
in the status bar and the Debug Console. A long one -- Reverse Continue with no
breakpoints, through a minute of history -- takes a second or so, and **Pause**
cancels it.

**In the past**, the status bar shows how far back the machine is ("4.5 frames
before live"). Stepping or running forward from there **replays** what really
happened: the same keys at the same instants, the same tape, the same pokes --
as often as you like. A run carries straight on into the present once it gets
there. **Return to Live** (the status bar item, or → on the toolbar) replays to
the newest instant and stops.

**Changing anything in the past starts a new timeline**: a key pressed or
released, a memory or register edit, a tape command, or stepping by T-states.
Everything after that point is discarded, and recording carries on from there.

**How much history.** About the last minute of emulated time (a checkpoint of
the machine every ten frames, up to 256 MB -- a minute of a 48K is about 15 MB).
A reset, loading a snapshot, a ROM or a tape, ejecting a tape and switching
model all start a new history, since none of them can be replayed.

**How it works.** The emulator is deterministic, so no instruction-by-instruction
record is kept. The history is a checkpoint of the whole machine every ten frames
plus a log of every input from outside it, each stamped with the half-clock it
arrived at. Going back restores the checkpoint before the target and replays to
it; a search replays one interval at a time, newest first, noting each
instruction boundary's address and call depth until one matches. The call depth
is the [call stack](#call-stack)'s, so Step Back Out and Step Back over a call
cope with a stack pointer borrowed for data just as the call stack does. Running
live, keeping the history costs a few percent of emulation speed at most (see
[Testing and performance](testing-and-performance.md#performance)).

**Not yet:** Run Back to Last Write finds writes the CPU made, not a debugger's
pokes; on a 128K it watches the 16-bit address, whichever bank is paged there.
A server built with `-NoRewind` (see
[Testing and performance](testing-and-performance.md)) has none of this, and
VS Code shows none of the buttons. The design and its internals are in
[rewind-design.md](rewind-design.md).

## Call stack

`stackTrace` shows a real, multiple-frame call stack, not just the current
PC: `Spectrum` tracks `CALL`/`RST` and their matching `RET` as they
execute (`spectrum.cpp`'s call-stack tracking), so stepping into a routine adds a
frame for it, each labeled and sourced exactly like the top frame (using
whichever debug info covers that address — the loaded program's own, or the
ROM's). It's a live opcode-level watch, not stack-memory guesswork — the Z80
has no frame-pointer convention, so there's no reliable way to tell a return
address from ordinary pushed data by inspection alone.

Two things it deliberately doesn't track, both rare in practice: interrupt
handler entry/exit (`RETI`/`RETN`) is invisible to it on purpose, so it can't
desync the frames it *does* track; and code that abandons the stack by resetting
SP directly, instead of matching `RET`s one-for-one (an idiom the ROM itself
uses for error handling), keeps its old frames until the stack is used again
over their slots. A frame ends when its return address is read off the stack
(`RET`, `POP`) or written over (a `CALL` or `PUSH` into its slot) -- not when SP
merely moves, which is also what a routine borrowing SP as a data pointer does,
so the call stack no longer empties while one is paused mid-blit. The
[profile's call tree](#the-call-tree) follows the same rule. Cleared
automatically on reset, a new snapshot, or any direct PC/register write, since
a stale call chain would be actively misleading rather than just incomplete.

## Source-level debugging of the ROM

The 48K ROM's disassembly has been reverse-engineered and fully commented by
others — [SkoolKit's `skoolkid/rom`](https://github.com/skoolkid/rom)
reproduces *The Complete Spectrum ROM Disassembly* (Logan & O'Hara) as a
`.skool` file. `scripts/build_rom_source.py` turns that into a real source
view for the DAP session:

```
skoolkid/rom (.skool)  →  skool2asm.py  →  sjasmplus --sld  →  rom_disassembly/
                                                                  rom.asm  (readable, labeled source)
                                                                  rom.sld  (address <-> source-line map)
```

Run it once. The `scripts/` helpers are Python — the only part of the project
that still is — and want their own venv: `python -m venv .venv-win` then
`.\.venv-win\Scripts\pip.exe install skoolkit`, plus `sjasmplus` on PATH (see
the script's `--help` for where to get a build per platform):

```sh
.venv-win\Scripts\python.exe scripts\build_rom_source.py
```

It clones `skoolkid/rom` into `.rom-disassembly-src/` and writes
`rom_disassembly/rom.asm` + `rom.sld` — both gitignored, since the
disassembly (like the ROM binary itself) is copyrighted material fetched
locally, never committed. The script **refuses to write output** unless the
freshly assembled binary is byte-for-byte identical to `roms/48.rom` — a
mismatch would mean the address↔source-line map can't be trusted for
debugging, which is worse than not having one.

Once built, the DAP server picks it up automatically (no config needed) the
next time it starts: stack frames get a real `source`/`line` into
`rom.asm` (VS Code opens it and highlights the current line on every stop,
labeled with its nearest routine — e.g. `KEY_INT+3`), and breakpoints can be
set by clicking the gutter in that file directly, resolved to addresses via
the SLD map. Instruction breakpoints (from the Disassembly View) still work
and can be mixed freely with source breakpoints in the same session.

## Source-level debugging of your own program

Assembled your own program with `sjasmplus --sld`? Attach its `.sld` plus
the source it was built from, and get everything above for your own code
too — real `source`/`line` in stack frames, gutter breakpoints, and
`resolve_symbol`/`resolve_address`. It's layered on top of the ROM's own
source (not a replacement for it): your program's debug info is checked
first, and a `CALL` into a ROM routine still resolves to `rom.asm` once
execution is inside it, so you don't lose one to get the other.

Over MCP:

```
load_snapshot(sna_base64=...)
load_debug_info(sld_path="C:/path/to/yourprogram.sld", asm_path="C:/path/to/yourprogram.asm")
```

Over DAP, add `sld`/`asm` to the launch config alongside `snapshot`:

```json
{
  "name": "My program",
  "type": "zxspectrum",
  "request": "launch",
  "rom": "${workspaceFolder}/roms/48.rom",
  "snapshot": "${workspaceFolder}/yourprogram.sna",
  "sld": "${workspaceFolder}/yourprogram.sld",
  "asm": "${workspaceFolder}/yourprogram.asm",
  "preLaunchTask": "assemble-my-program"
}
```

### Programs built from more than one file

`asm` (and `load_debug_info`'s `asm_path`) names the **entry** source only. A
program whose entry file `INCLUDE`s others produces one SLD covering all of
them, and every file in it is picked up: the SLD's own file field is what each
address is filed under, and the other files are resolved beside the entry
`.asm` — which is where `INCLUDE` looks for them too, so the layout matches.

This matters more than it sounds. sjasmplus numbers lines **per file**, so a
program built from five files has five different line 40s. Stack frames name
the file the code is actually in and step between them, and a gutter breakpoint
is resolved against the file it was clicked in. A path no loaded source
describes comes back unverified rather than landing on some other file's line
of the same number.

`examples/filmation/` is the worked example — one entry source plus the
engine/ and knightlore/ files it includes; launch **"ZX Spectrum: Filmation"**.

Loading a *new* snapshot always clears the previously-attached debug info
(it almost certainly doesn't match the new program's addresses) — reattach
with `load_debug_info`/relaunch for whatever program you loaded next. The
ROM's own source is unaffected either way; it's always available
independently once built.

## Editing Z80 assembly

The extension also makes VS Code a Z80 editor. `.asm`, `.s` and `.a80` files
open as **Z80 Assembly** (language id `z80-asm`), coloured for sjasmplus -- the
assembler every program in this repo is built with: instructions, registers,
jump conditions (the `c` in `jr c,.loop` is carry, not the register),
directives, every number format, strings and comments. The workspace's
`.vscode/settings.json` maps `*.asm` and `*.s` to it, so another installed
assembly extension claiming those extensions doesn't take them.

On top of the colouring:

- **Go to Definition** (F12 / Ctrl+click) on any label, constant, macro, macro
  parameter, struct, struct field or `DEFINE`. A local label resolves under its
  own parent (`.loop` in `sprite_blit` is `sprite_blit.loop`), and a dotted name
  goes to the part clicked: `OBJ` in `OBJ.FLAGS` is the struct, `FLAGS` the
  field. On an `INCLUDE` or `INCBIN` path it opens the file.
- **Find All References** (Shift+F12).
- **Rename Symbol** (F2) changes the last part of a name wherever that part is
  written: renaming `.loop` rewrites `.loop` inside its routine and
  `sprite_blit.loop` elsewhere; renaming `sprite_blit` rewrites
  `sprite_blit.loop` but leaves the `.loop`s alone. A name already taken, a
  reserved word, or a name defined in more than one program is refused.
  Comments are not changed.
- **Show Call Hierarchy** (Shift+Alt+H) on a routine, or anywhere inside one:
  who `CALL`s, `JP`s, `JR`s or `DJNZ`s to it, grouped by the routine each call
  sits in, and what it calls in turn. Macro invocations count; jumps to a
  routine's own locals are control flow and are left out.
- **Hover** shows a symbol's definition line and the comment block above it --
  the ROM disassembly's routine descriptions, for instance. What a caller most
  needs -- which registers a routine takes, which it hands back and which it
  leaves changed -- is pulled out of the comment and shown first, as a table,
  with the rest of the comment after it. See [A routine's
  header](#a-routines-header).
- **Outline**, breadcrumbs and **Go to Symbol** (Ctrl+Shift+O), with local labels
  nested under their routine, and **Go to Symbol in Workspace** (Ctrl+T).

This is read from the source files, not from the emulator, and works with no
debug session running. Every `.asm`/`.s`/`.a80` in the workspace is indexed the
first time one of these is used (about a second for this repo), then kept
current from the editor and from disk. Several programs here share label names,
so a name resolves within the files the current one is `INCLUDE`d together with
first, and across the whole workspace only when it isn't defined there. `MODULE`
prefixes are not modelled.

### A routine's header

The hover reads three labelled lines, directly above the label:

```
; Add a step to an object's U, V and Z.
;
; (why it works this way)
;
; In:  IX -> the object
;      D  = the step in U
;      E  = the step in V
;      A  = the step in Z
; Out: Z set if the step was zero, and so moved nothing
; Corrupts: AF, C
depth_add_step:  ...
```

- `->` for a pointer, `=` for a value. A line indented to where the entries
  start is the next entry; one indented further continues the one above.
- Write `In: nothing` or `Out: nothing` rather than leaving the line out, so a
  missing line always means a missing note.
- `Corrupts` lists every register that can come back changed and is not an
  output, including through the routine's calls; anything not named in `Out` or
  `Corrupts` is preserved.
- An `ASSERT`, `IFUSED`, `IFNUSED` or `ALIGN` between the comment and the label
  is stepped over.

Older headers are read too, so the sources need not all change at once:
inputs as indented register lines with no label (`;   IX -> the object`),
`Entry:`/`Exit:` and `On entry:`/`On exit:` for In and Out, `Corrupts AF, C.`
and `Preserves DE.` as sentences, and either of those tacked onto the end of an
`Out:` line. A memory variable (`collide_mask - the bit to set`) can be an entry
in a list a register has started, but does not start one. The hover gets at
most the 24 comment lines nearest the label, so a long header loses its top,
never its registers.
