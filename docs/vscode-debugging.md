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
handler entry/exit (`RETI`/`RETN`) is invisible to it on purpose, so it
can't desync the frames it *does* track; and code that unwinds the stack by
resetting SP directly instead of matching `RET`s one-for-one (an idiom the
ROM itself uses for error handling) can leave stale frames until the next
real `CALL`/`RET` resyncs things. Cleared automatically on reset, a new
snapshot, or any direct PC/register write, since a stale call chain would
be actively misleading rather than just incomplete.

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
