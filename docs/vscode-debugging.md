# Connecting VS Code (DAP)

Part of the [zx-spectrum-emulator README](../README.md).

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
Step through ROM"**. The `preLaunchTask` starts the server automatically
(watch its output in the dedicated terminal panel) and waits for it to be
ready before connecting.

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

The adapter can go further if that is not enough -- DAP's `stopped` event
carries a `preserveFocusHint` which asks the client not to change focus at all
-- but it is deliberately not sent: VS Code honours it by not selecting the
stack frame either, so the editor would stop following the program as you step
through it.

## Attaching to a running emulator

Every configuration above **launches**: the `preLaunchTask` stops any running
`zx_server`, rebuilds it, starts a fresh one, and the `launch` request then
resets the machine and loads whatever the config names. That is what you want
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

- **A different `preLaunchTask`.** `zxspectrum-cpp.start-server-if-absent`
  starts a server only when nothing is listening on the DAP port, and never
  stops one that is. It also does not build -- a build would replace the
  executable of the process being attached to.
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
- **File** — a `.scr`, or a raw blob like `examples/filmation/sprite_data.bin`,
  with no debug session needed at all. That is the build-time half of the same
  question.
- **Selection** — select `DEFB` lines in an assembler source and press **Grab
  selection**, or right-click and use **"Show Selection as ZX Spectrum
  Graphics"**. Everything sjasmplus writes for a byte is understood: `0x3C`,
  `$3C`, `#3C`, `3Ch`, `0b00111100`, `%00111100`, `60`. When the selection
  contains `DEFB` lines only those contribute, so catching the label above the
  table or an `EQU` beside it does not push numbers into the middle of the
  picture.

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

### The point of it

Hover any pixel. The status line says which item it is in, where it is within
that item, **the address of the byte holding it and which bit**, the byte in
binary, and the mask byte beside it. Everything else in the panel is in service
of being able to point at one wrong pixel and be told where to go and fix it.

Layout changes redraw from the bytes already in hand rather than re-reading, so
dragging the width up and down until an unknown sprite format snaps into focus
costs nothing.

### The sheet

The controls describe **one** sprite: the one being dialled in, shown first and
outlined. **+ Add** keeps it, and the settings are then free to move on to the
next one. Each kept sprite carries its own frozen copy of everything
per-sprite — source, address or file, size, format, mask arrangement, colours —
so a sheet can hold sprites of **different sizes, from different files, in
different formats** at once.

That is the answer to "show me several sprites when they are not all the same
shape". Nothing else works for a set like Knight Lore's, where each record
carries its own width and height and no two neighbours need agree: a single
fixed grid can only ever describe one shape, and repacking the data into one
would throw away the byte addresses that make the panel worth having.

Each kept sprite has two buttons:

- **✎** puts its settings back into the controls, so a near-miss can be
  adjusted and re-added rather than retyped.
- **🗑** removes it.

Only `zoom`, `grid`, `labels` and `Live` are properties of the sheet rather
than of a sprite, so changing those changes every tile at once.

**Refresh** re-reads the whole sheet, not just the sprite being dialled in —
a sprite pinned to an address in memory is exactly the thing you pin in order
to watch it change, and the same goes for the automatic refresh on every stop.
A sprite pinned from a file keeps that file's path, so it goes on reading the
file it came from after **Choose file...** has moved on to another.

The sheet is remembered across a panel close and a window reload. The bytes
are not — they are re-read, because megabytes of sprite do not belong in a
store meant for a little UI state.

### Driving it from MCP

`set_graphics_view` points the panel at something. It is the only MCP tool that
moves anything in the editor rather than in the machine — it changes nothing
the emulator does and returns no picture, so it is for putting a sprite in
front of the person you are working with ("here is what is actually at
`sprite_017`"), not for looking at one yourself.

```
set_graphics_view(source="memory", address="sprite_000", format="sprite",
                  width=3, height=31, count=8, columns=4, header=2,
                  interleave="md", flip=true)
```

Every field is left as it was when omitted, so a width can be corrected without
restating the address. Numbers out of range are clamped rather than refused —
these land in a UI, and the nearest sensible value beats an error nobody sees —
but a misspelled `source`, `format` or `interleave` **is** refused, because a
typo that reached the panel would leave it drawing nothing with the mistake
three processes away from whoever had to find it.

`pin=true` **adds** the sprite to the sheet instead of replacing the one being
dialled in, which is how a set of differently-sized sprites is put up: one call
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
one, since the server holds a view rather than a sheet.

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
  "debugServer": 4711,
  "rom": "${workspaceFolder}/roms/48.rom",
  "snapshot": "${workspaceFolder}/yourprogram.sna",
  "sld": "${workspaceFolder}/yourprogram.sld",
  "asm": "${workspaceFolder}/yourprogram.asm",
  "preLaunchTask": "zxspectrum-cpp.start-server"
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

`examples/filmation/` is the worked example — one entry source plus four
includes; launch **"ZX Spectrum: Filmation"**.

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
  the ROM disassembly's routine descriptions, for instance.
- **Outline**, breadcrumbs and **Go to Symbol** (Ctrl+Shift+O), with local labels
  nested under their routine, and **Go to Symbol in Workspace** (Ctrl+T).

This is read from the source files, not from the emulator, and works with no
debug session running. Every `.asm`/`.s`/`.a80` in the workspace is indexed the
first time one of these is used (about a second for this repo), then kept
current from the editor and from disk. Several programs here share label names,
so a name resolves within the files the current one is `INCLUDE`d together with
first, and across the whole workspace only when it isn't defined there. `MODULE`
prefixes are not modelled.
